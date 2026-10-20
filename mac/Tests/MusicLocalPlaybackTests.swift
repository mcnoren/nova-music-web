import Foundation

@main struct MusicLocalPlaybackTests {
    @MainActor static func main() async throws {
        let key = Data(repeating: 42, count: 32), other = Data(repeating: 7, count: 32)
        let id = "10000000-0000-4000-8000-000000000001"
        let packet = MusicLocalPlayback.Packet(sender: id, payload: Data("seek:82".utf8))
        let sealed = try MusicLocalPlayback.seal(packet, key: key)
        let opened = try MusicLocalPlayback.open(sealed, key: key); precondition(opened.payload == packet.payload)
        do { _ = try MusicLocalPlayback.open(sealed, key: other); fatalError("Wrong account key accepted") } catch {}
        var damaged = sealed; damaged[damaged.count - 1] ^= 1
        do { _ = try MusicLocalPlayback.open(damaged, key: key); fatalError("Modified packet accepted") } catch {}
        do { _ = try MusicLocalPlayback.open(sealed, key: key, now: Date().addingTimeInterval(61)); fatalError("Expired packet accepted") } catch {}
        let frame = MusicLocalPlayback.framed(sealed)
        var buffer = Data(frame.prefix(3)); let partial = try MusicLocalPlayback.takeFrame(from: &buffer); precondition(partial == nil)
        buffer.append(frame.dropFirst(3)); buffer.append(frame)
        let decoded1 = try MusicLocalPlayback.takeFrame(from: &buffer); precondition(decoded1 == sealed)
        let decoded2 = try MusicLocalPlayback.takeFrame(from: &buffer); precondition(decoded2 == sealed); precondition(buffer.isEmpty)
        var oversized = Data([0xff, 0xff, 0xff, 0xff])
        do { _ = try MusicLocalPlayback.takeFrame(from: &oversized); fatalError("Unbounded frame accepted") } catch {}
        print("Local playback encryption, authentication, expiry, fragmentation and frame limits passed")
        if CommandLine.arguments.contains("--lan") {
            var clock = Date()
            let first = MusicLocalPlayback(now: { clock }), second = MusicLocalPlayback()
            let secondID = "20000000-0000-4000-8000-000000000002"
            var received: Data?, firstReceipt: Data?
            first.onReceive = { firstReceipt = $0 }; second.onReceive = { received = $0 }
            first.start(id: id, key: key, payload: Data("song:first".utf8))
            second.start(id: secondID, key: key, payload: Data("song:second".utf8))
            defer { first.stop(); second.stop() }
            for _ in 0..<500 { if first.peers.contains(secondID), second.peers.contains(id) { break }; try await Task.sleep(for: .milliseconds(20)) }
            guard first.peers.contains(secondID), second.peers.contains(id) else { throw NSError(domain: "LAN discovery", code: 1, userInfo: [NSLocalizedDescriptionKey: "Bonjour peers did not connect; check Local Network access."]) }
            let target = Data("seek:82".utf8), start = Date()
            first.publish(target)
            for _ in 0..<200 { if received == target { break }; try await Task.sleep(for: .milliseconds(5)) }
            precondition(received == target)
            print(String(format: "Bonjour connection and first-to-second update: %.1f ms", Date().timeIntervalSince(start) * 1000))
            second.publish(Data("seek:24".utf8))
            for _ in 0..<200 { if firstReceipt == Data("seek:24".utf8) { break }; try await Task.sleep(for: .milliseconds(5)) }
            precondition(firstReceipt == Data("seek:24".utf8)); print("Second-to-first update passed")
            second.stop(); received = nil
            for _ in 0..<200 { if !first.peers.contains(secondID) { break }; try await Task.sleep(for: .milliseconds(10)) }
            precondition(!first.peers.contains(secondID))
            second.start(id: secondID, key: key, payload: Data("rejoined".utf8))
            for _ in 0..<500 { if received == target { break }; try await Task.sleep(for: .milliseconds(20)) }
            precondition(received == target, "Reconnect must restore the current snapshot")
            print("Disconnect, Bonjour reconnect and current-state delivery passed")
            received = nil; firstReceipt = nil
            clock = clock.addingTimeInterval(20)
            await first.refresh()
            precondition(first.peers.isEmpty, "A resumed app must discard its stale connection")
            for _ in 0..<500 { if received == target && firstReceipt == Data("rejoined".utf8) { break }; try await Task.sleep(for: .milliseconds(20)) }
            precondition(received == target && firstReceipt == Data("rejoined".utf8), "Resume must reconnect and exchange both current snapshots")
            print("Suspension recovery, reauthentication and bidirectional state restoration passed")
        }
    }
}
