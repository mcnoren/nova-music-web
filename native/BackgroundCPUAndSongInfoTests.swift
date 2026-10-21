import XCTest
import AVFoundation
import Combine
@testable import NovaMusic

@MainActor
final class BackgroundCPUAndSongInfoTests: XCTestCase {
    func testBackgroundPlaybackDoesNotRepublishSteadyStateForOneMinute() async throws {
        let file = try makeAudioFixture(seconds: 70)
        let suite = "NovaMusic.BackgroundCPU.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: file); defaults.removePersistentDomain(forName: suite) }
        let player = YouTubePlayer(defaults: defaults, audioSourceProvider: { _ in .init(url: file, isLive: false, isAudioOnly: true) })
        defer { player.stop() }
        player.audioOnly = true; player.enterBackground(); player.load("aaaaaaaaaaa")
        try await waitForMusicPlayback { player.hasStartedPlayback && !player.loading }
        var loadingEvents = 0, phaseEvents = 0, clockEvents = 0
        let a = player.$loading.dropFirst().sink { _ in loadingEvents += 1 }
        let b = player.$musicStartupPhase.dropFirst().sink { _ in phaseEvents += 1 }
        let c = player.$currentTime.dropFirst().sink { _ in clockEvents += 1 }
        defer { a.cancel(); b.cancel(); c.cancel() }
        try await Task.sleep(for: .seconds(60))
        XCTAssertEqual(loadingEvents, 0, "Steady playback must not trigger library/device sync four times a second")
        XCTAssertEqual(phaseEvents, 0)
        XCTAssertGreaterThan(clockEvents, 40); XCTAssertLessThan(clockEvents, 80)
        XCTAssertGreaterThan(player.nativePlayer.currentTime().seconds, 59)
        XCTAssertTrue(player.intendsPlayback); XCTAssertNil(player.error)
        XCTAssertNotNil(player.nowPlayingInfoCenter.nowPlayingInfo)
        print("NOVA_BACKGROUND_CPU loadingEvents=\(loadingEvents) phaseEvents=\(phaseEvents) clockEvents=\(clockEvents) duration=60")
    }

    func testSongBackgroundKeepsNarrativeAndOmitsTablesAndReferences() {
        let text = """
        Original is a song by Artist. This introduction identifies the recording and its release.
        == Background and writing ==
        The song was written during the album sessions and developed through collaboration.
        === Recording ===
        The recording used acoustic instruments and layered voices.
        == Charts ==
        Weekly chart table should be omitted.
        == Critical reception ==
        Reviewers discussed the arrangement and vocal performance.
        == References ==
        Reference list should be omitted.
        """
        let result = MusicDescriptions.songBackgroundText(text)
        XCTAssertTrue(result.contains("album sessions")); XCTAssertTrue(result.contains("layered voices"))
        XCTAssertTrue(result.contains("Reviewers discussed")); XCTAssertFalse(result.contains("chart table"))
        XCTAssertFalse(result.contains("Reference list")); XCTAssertLessThanOrEqual(result.count, 9000)
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
