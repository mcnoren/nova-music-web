import XCTest
import AVFoundation
@testable import NovaMusic

@MainActor
final class BackgroundPlaybackTests: XCTestCase {
    func testBackgroundMusicRetriesNativeAudioInsteadOfDependingOnWebFallback() async throws {
        let file = try makeAudioFixture(seconds: 12)
        let suite = "NovaMusic.BackgroundRetry.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: file); defaults.removePersistentDomain(forName: suite) }
        var audioRequests = 0, fallbackRequests = 0
        let player = YouTubePlayer(defaults: defaults, streamSourceProvider: { _, _ in
            fallbackRequests += 1; throw URLError(.networkConnectionLost)
        }, audioSourceProvider: { _ in
            audioRequests += 1
            if audioRequests == 1 { throw URLError(.networkConnectionLost) }
            return .init(url: file, isLive: false, isAudioOnly: true)
        }, playbackStallTimeout: 1)
        defer { player.stop() }
        player.audioOnly = true; player.enterBackground(); player.load("aaaaaaaaaaa")
        try await waitForMusicPlayback { player.hasStartedPlayback }
        XCTAssertEqual(audioRequests, 2)
        XCTAssertEqual(fallbackRequests, 1)
        XCTAssertTrue(player.intendsPlayback); XCTAssertNil(player.error)
    }

    func testPreparedBackgroundQueueAdvancesBeforeAppStateDelivery() async throws {
        let file = try makeAudioFixture(seconds: 2)
        let suite = "NovaMusic.NativeQueueBoundary.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: file); defaults.removePersistentDomain(forName: suite) }
        let player = YouTubePlayer(defaults: defaults, audioSourceProvider: { _ in .init(url: file, isLive: false, isAudioOnly: true) }, queueEventDeliveryDelay: 0.8)
        defer { player.stop() }
        player.audioOnly = true; player.enterBackground(); player.loadPlaylist(["aaaaaaaaaaa", "bbbbbbbbbbb", "ccccccccccc"])
        try await waitForMusicPlayback { player.hasStartedPlayback && player.nativePlayer.items().count == 2 }
        let first = try XCTUnwrap(player.nativePlayer.currentItem)
        XCTAssertEqual(player.nativePlayer.actionAtItemEnd, .advance)
        // Delay only Nova's queue notifications, leaving AVFoundation's own
        // callbacks running. It must advance before our end handler can do so.
        try await waitForMusicPlayback { player.nativePlayer.currentItem !== first }
        XCTAssertEqual(player.currentVideoID, "aaaaaaaaaaa", "The engine advanced before app state delivery")
        try await waitForMusicPlayback { player.currentVideoID == "bbbbbbbbbbb" && player.hasStartedPlayback }
        XCTAssertEqual(player.playlistIndex, 1); XCTAssertNil(player.error)
    }

    func testPrematureEndAfterNativeAdvanceRecoversOriginalSong() async throws {
        let file = try makeAudioFixture(seconds: 20)
        let suite = "NovaMusic.NativeEarlyEnd.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: file); defaults.removePersistentDomain(forName: suite) }
        var originalRequests = 0
        let player = YouTubePlayer(defaults: defaults, audioSourceProvider: { id in
            if id == "aaaaaaaaaaa" { originalRequests += 1 }
            return .init(url: file, isLive: false, isAudioOnly: true)
        })
        defer { player.stop() }
        player.audioOnly = true; player.enterBackground(); player.loadPlaylist(["aaaaaaaaaaa", "bbbbbbbbbbb"])
        try await waitForMusicPlayback { player.hasStartedPlayback && player.nativePlayer.items().count == 2 }
        let first = try XCTUnwrap(player.nativePlayer.currentItem), requests = originalRequests
        player.nativePlayer.advanceToNextItem()
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: first)
        try await waitForMusicPlayback { originalRequests > requests && player.currentVideoID == "aaaaaaaaaaa" && player.hasStartedPlayback }
        XCTAssertEqual(player.playlistIndex, 0); XCTAssertNil(player.error)
    }

    func testBackgroundMusicContinuesBeyondStartupGrantAndRespectsPause() async throws {
        let file = try makeAudioFixture(seconds: 45)
        let suite = "NovaMusic.SustainedBackground.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: file); defaults.removePersistentDomain(forName: suite) }
        let player = YouTubePlayer(defaults: defaults, audioSourceProvider: { _ in .init(url: file, isLive: false, isAudioOnly: true) })
        defer { player.stop() }
        player.audioOnly = true; player.enterBackground(); player.load("aaaaaaaaaaa")
        try await waitForMusicPlayback { player.hasStartedPlayback }
        let item = try XCTUnwrap(player.nativePlayer.currentItem)
        try await Task.sleep(for: .seconds(32))
        XCTAssertTrue(player.nativePlayer.currentItem === item)
        XCTAssertGreaterThan(player.nativePlayer.currentTime().seconds, 30)
        XCTAssertTrue(player.intendsPlayback); XCTAssertNil(player.error)
        player.pause()
        let paused = player.nativePlayer.currentTime().seconds
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertFalse(player.intendsPlayback); XCTAssertEqual(player.nativePlayer.rate, 0)
        XCTAssertEqual(player.nativePlayer.currentTime().seconds, paused, accuracy: 0.15)
    }

    func testUnexpectedMusicEndReconnectsCurrentSongInsteadOfAdvancingPreparedQueue() async throws {
        let file = try makeAudioFixture(seconds: 20)
        defer { try? FileManager.default.removeItem(at: file) }
        let suite = "NovaMusic.EarlyEnd." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        var requests = 0
        let player = YouTubePlayer(defaults: defaults, audioSourceProvider: { _ in
            requests += 1
            return .init(url: file, isLive: false, isAudioOnly: true)
        })
        defer { player.stop(); defaults.removePersistentDomain(forName: suite) }
        player.audioOnly = true
        player.loadPlaylist(["aaaaaaaaaaa", "bbbbbbbbbbb"])
        try await waitForMusicPlayback { player.hasStartedPlayback && player.nativePlayer.items().count == 2 }
        let item = try XCTUnwrap(player.nativePlayer.currentItem)
        XCTAssertEqual(player.nativePlayer.actionAtItemEnd, .advance)
        let before = requests
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: item)
        try await waitForMusicPlayback { requests > before && player.hasStartedPlayback }
        XCTAssertEqual(player.currentVideoID, "aaaaaaaaaaa")
        XCTAssertEqual(player.playlistIndex, 0)
        XCTAssertNil(player.error)
    }

    func testCompletedMusicItemAdvancesPreparedQueueOnce() async throws {
        let file = try makeAudioFixture(seconds: 2)
        defer { try? FileManager.default.removeItem(at: file) }
        let suite = "NovaMusic.RealEnd." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let player = YouTubePlayer(defaults: defaults, audioSourceProvider: { _ in
            .init(url: file, isLive: false, isAudioOnly: true)
        })
        defer { player.stop(); defaults.removePersistentDomain(forName: suite) }
        player.audioOnly = true
        player.loadPlaylist(["aaaaaaaaaaa", "bbbbbbbbbbb", "ccccccccccc"])
        try await waitForMusicPlayback { player.currentVideoID == "bbbbbbbbbbb" && player.hasStartedPlayback }
        XCTAssertEqual(player.playlistIndex, 1)
        XCTAssertNil(player.error)
    }

    private func makeAudioFixture(seconds: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MusicQueue-\(UUID()).caf")
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false])
        let length = AVAudioFrameCount(seconds * 44100)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: length))
        buffer.frameLength = length
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<Int(length) { samples[index] = Float(sin(Double(index) * 2 * .pi * 440 / 44100) * 0.1) }
        try file.write(from: buffer)
        return url
    }

    private func waitForMusicPlayback(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(4)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), "Playback did not reach the expected state", file: file, line: line)
    }
}
