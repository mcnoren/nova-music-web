import XCTest
import AVFoundation
import Network
@testable import NovaMusic

// A real HTTP audio response that stops delivering bytes after its first few
// seconds. AVFoundation must exhaust its buffer; no player state is mocked.
private final class LockScreenStallServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "NovaTests.stalledAudio")
    private let data: Data
    private let cutoff: Int
    private var connections: [NWConnection] = []
    init(file: URL, cutoff: Int) throws {
        data = try Data(contentsOf: file); self.cutoff = cutoff
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }
    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.listener.stateUpdateHandler = nil
                    continuation.resume(returning: URL(string: "http://127.0.0.1:\(self.listener.port!.rawValue)/audio.wav")!)
                case .failed(let error):
                    self.listener.stateUpdateHandler = nil; continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                self.connections.append(connection); connection.start(queue: self.queue)
                self.receive(connection, buffer: Data())
            }
            listener.start(queue: queue)
        }
    }
    func stop() {
        listener.cancel()
        queue.async { [self] in connections.forEach { $0.cancel() }; connections = [] }
    }
    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] chunk, _, complete, error in
            guard let self, error == nil else { connection.cancel(); return }
            var request = buffer; if let chunk { request.append(chunk) }
            guard let header = String(data: request, encoding: .utf8), header.contains("\r\n\r\n") else {
                if complete { connection.cancel() } else { self.receive(connection, buffer: request) }; return
            }
            let range = header.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("range: bytes=") }
            let limits = range?.components(separatedBy: "=").last?.split(separator: "-", omittingEmptySubsequences: false)
            let start = max(0, limits?.first.flatMap { Int($0) } ?? 0)
            let end = min(self.data.count - 1, limits?.last.flatMap { Int($0) } ?? self.data.count - 1)
            guard end >= start else { connection.cancel(); return }
            let partial = range != nil
            var response = "HTTP/1.1 \(partial ? "206 Partial Content" : "200 OK")\r\nContent-Type: audio/wav\r\nContent-Length: \(end - start + 1)\r\nAccept-Ranges: bytes\r\nConnection: close\r\n"
            if partial { response += "Content-Range: bytes \(start)-\(end)/\(self.data.count)\r\n" }
            response += "\r\n"
            var body = Data(response.utf8)
            // Permit tail metadata probes, but starve sequential audio reads.
            let deliveredEnd = start > self.data.count - 8192 ? end : min(end, self.cutoff - 1)
            if deliveredEnd >= start { body.append(self.data[start...deliveredEnd]) }
            let finished = deliveredEnd == end || header.hasPrefix("HEAD ")
            if header.hasPrefix("HEAD ") { body = Data(response.utf8) }
            connection.send(content: body, completion: .contentProcessed { _ in if finished { connection.cancel() } })
        }
    }
}

@MainActor
final class LockScreenPlaybackTests: XCTestCase {
    private func waitForMusicPlayback(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(4)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), "Playback did not reach the expected state", file: file, line: line)
    }

    private func makeLockAudioFixture(seconds: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LockAudio-\(UUID()).wav")
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false])
        let count = AVAudioFrameCount(seconds * 44100)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count))
        buffer.frameLength = count
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<Int(count) { samples[index] = Float(sin(Double(index) * 2 * .pi * 440 / 44100) * 0.1) }
        try file.write(from: buffer)
        return url
    }

    func testLockedPlaybackRecoversAfterRealHTTPAudioBufferExhaustion() async throws {
        let file = try makeLockAudioFixture(seconds: 45)
        let server = try LockScreenStallServer(file: file, cutoff: 44_100 * 2 * 3 + 4096)
        let url = try await server.start()
        let suite = "NovaMusic.LockedNetworkStall.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { server.stop(); try? FileManager.default.removeItem(at: file); defaults.removePersistentDomain(forName: suite) }
        var requests = 0
        let player = YouTubePlayer(defaults: defaults, audioSourceProvider: { _ in
            requests += 1
            return .init(url: requests == 1 ? url : file, isLive: false, isAudioOnly: true)
        })
        defer { player.stop() }
        player.audioOnly = true; player.load("aaaaaaaaaaa")
        try await waitForMusicPlayback { player.ready }
        player.nativePlayer.playImmediately(atRate: 1)
        try await waitForMusicPlayback { player.hasStartedPlayback }
        XCTAssertEqual(requests, 1, "The HTTP fixture must start before its buffer is exhausted")
        player.enterBackground()
        let bufferingDeadline = ContinuousClock.now + .seconds(20)
        while requests == 1, player.nativePlayer.timeControlStatus == .playing, ContinuousClock.now < bufferingDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(requests > 1 || player.nativePlayer.timeControlStatus == .waitingToPlayAtSpecifiedRate, "The network fixture must exhaust AVFoundation's buffer")
        let stalledPosition = player.nativePlayer.currentTime().seconds
        let started = ContinuousClock.now
        while requests < 2, started.duration(to: .now) < .seconds(7) { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(requests, 2, "A stalled locked player must reconnect before the foreground 25-second wait")
        try await waitForMusicPlayback { player.hasStartedPlayback && player.nativePlayer.currentTime().seconds > stalledPosition + 0.25 }
        XCTAssertTrue(player.intendsPlayback); XCTAssertEqual(player.currentVideoID, "aaaaaaaaaaa"); XCTAssertNil(player.error)
        print("NOVA_LOCK_RECOVERY_SECONDS=\(started.duration(to: .now))")
    }

    func testBackgroundBufferingGrantEndsOnPlaybackAndPause() async throws {
        let file = try makeLockAudioFixture(seconds: 20)
        let suite = "NovaMusic.BufferGrant.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: file); defaults.removePersistentDomain(forName: suite) }
        let player = YouTubePlayer(defaults: defaults, audioSourceProvider: { _ in .init(url: file, isLive: false, isAudioOnly: true) })
        defer { player.stop() }
        player.audioOnly = true; player.enterBackground(); player.load("aaaaaaaaaaa")
        try await waitForMusicPlayback { player.hasStartedPlayback && !player.hasNativeBackgroundWork }
        player.protectBackgroundBuffering()
        XCTAssertTrue(player.hasNativeBackgroundWork)
        try await waitForMusicPlayback { !player.hasNativeBackgroundWork }
        player.protectBackgroundBuffering(); player.pause()
        XCTAssertFalse(player.hasNativeBackgroundWork)
        player.protectBackgroundBuffering()
        XCTAssertFalse(player.hasNativeBackgroundWork, "User Pause must never start recovery work")
        XCTAssertFalse(player.intendsPlayback)
    }

    func testStaleStallNotificationCannotRecoverPausedOrDifferentItem() async throws {
        let file = try makeLockAudioFixture(seconds: 20)
        let suite = "NovaMusic.StaleStall.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: file); defaults.removePersistentDomain(forName: suite) }
        let player = YouTubePlayer(defaults: defaults, audioSourceProvider: { _ in .init(url: file, isLive: false, isAudioOnly: true) })
        defer { player.stop() }
        player.audioOnly = true; player.enterBackground(); player.load("aaaaaaaaaaa")
        try await waitForMusicPlayback { player.hasStartedPlayback && !player.hasNativeBackgroundWork }
        NotificationCenter.default.post(name: AVPlayerItem.playbackStalledNotification, object: AVPlayerItem(url: file))
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertFalse(player.hasNativeBackgroundWork)
        let item = try XCTUnwrap(player.nativePlayer.currentItem)
        player.pause()
        NotificationCenter.default.post(name: AVPlayerItem.playbackStalledNotification, object: item)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertFalse(player.hasNativeBackgroundWork); XCTAssertFalse(player.intendsPlayback)
    }
}
