import XCTest
@testable import NovaMusic

@MainActor
final class MusicWatchConnectivityTests: XCTestCase {
    private func makeStore() -> (YouTubeStore, UserDefaults, String) {
        let name = "NovaWatchPhoneTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        return (YouTubeStore(defaults: defaults, musicOnly: true), defaults, name)
    }
    func testRepeatedWatchReceiptDoesNotToggleLikeTwice() throws {
        let (store, defaults, name) = makeStore(); defer { defaults.removePersistentDomain(forName: name); store.player.stop() }
        let bridge = WatchPhoneBridge(session: nil); bridge.connect(store)
        let song = YouTubeVideo(id: "abcdefghijk", title: "Song", channel: "Artist", thumbnail: nil); store.current = song
        let command = WatchPhoneCommand(action: "like"), encoder = JSONEncoder()
        XCTAssertNil(bridge.receiveData(try encoder.encode(command)).error)
        XCTAssertTrue(store.isLiked(song))
        XCTAssertNil(bridge.receiveData(try encoder.encode(command)).error)
        XCTAssertTrue(store.isLiked(song), "Replayed receipts must not repeat the mutation")
    }
    func testStaleQueueRevisionAndExpiredCommandsAreRejected() throws {
        let (store, defaults, name) = makeStore(); defer { defaults.removePersistentDomain(forName: name); store.player.stop() }
        let bridge = WatchPhoneBridge(session: nil); bridge.connect(store)
        let reply = bridge.receiveData(try JSONEncoder().encode(WatchPhoneCommand(action: "remove", revision: UUID(), value: 0)))
        XCTAssertNotNil(reply.error); XCTAssertNotNil(reply.snapshot)
        var expired = WatchPhoneCommand(action: "pause"); expired.created = Date().addingTimeInterval(-60)
        XCTAssertNotNil(bridge.receiveData(try JSONEncoder().encode(expired)).error)
    }
    func testLargeTransferCommitsOnceOnlyAfterAllChunksArrive() throws {
        let (store, defaults, name) = makeStore(); defer { defaults.removePersistentDomain(forName: name); store.player.stop() }
        let bridge = WatchPhoneBridge(session: nil); bridge.connect(store)
        let song = YouTubeVideo(id: "abcdefghijk", title: "Song", channel: "Artist", thumbnail: nil); store.current = song
        let command = WatchPhoneCommand(action: "like", context: String(repeating: "transfer", count: 16000))
        let data = try JSONEncoder().encode(command), width = 36000, count = (data.count + 35999) / 36000
        var final: Data?
        for index in (0..<count).reversed() {
            let chunk = WatchPhoneChunk(id: command.id, index: index, count: count, created: Date(), payload: data.subdata(in: index*width..<min(data.count,(index+1)*width)))
            let message = try JSONEncoder().encode(chunk); XCTAssertLessThan(message.count, 50000)
            XCTAssertNil(bridge.receiveData(message).error)
            if index > 0 { XCTAssertFalse(store.isLiked(song), "A partial message must never execute") }
            else { final = message }
        }
        XCTAssertTrue(store.isLiked(song))
        XCTAssertNil(bridge.receiveData(try XCTUnwrap(final)).error); XCTAssertTrue(store.isLiked(song))
    }
}

@MainActor
extension MusicWatchConnectivityTests {
    func testLargePhoneQueuePublishesABoundedWindowWithAbsolutePositions() throws {
        let (store, defaults, name) = makeStore(); defer { defaults.removePersistentDomain(forName: name); store.close() }
        let bridge = WatchPhoneBridge(session: nil); bridge.connect(store)
        let songs = (0..<2000).map { YouTubeVideo(id: String(format: "%011d", $0), title: "Song \($0)", channel: "Artist") }
        store.current = songs[1000]
        store.player.restoreMusicSession(tracks: songs, entries: [], index: 1000, position: 15, duration: 180, shuffle: false, repeatMode: .off)
        let reply = bridge.receiveData(try JSONEncoder().encode(WatchPhoneCommand(action: "snapshot")))
        let value = try XCTUnwrap(reply.snapshot)
        XCTAssertEqual(value.queueCount, 2000); XCTAssertEqual(value.queueOffset, 995)
        XCTAssertEqual(value.index, 5); XCTAssertEqual(value.queue[value.index].id, songs[1000].id)
        XCTAssertEqual(value.queue.count, 36); XCTAssertLessThan(try JSONEncoder().encode(reply).count, 50_000)
        let legacy = WatchPhoneCommand(action: "entry", revision: value.revision, value: 6)
        XCTAssertNotNil(bridge.receiveData(try JSONEncoder().encode(legacy)).error, "Older watches must never play the wrong absolute queue position")
    }
    func testWatchSnapshotOptionalFieldsDecodeOlderPhonePayloads() throws {
        let value = WatchPhoneSnapshot(revision: UUID(), song: nil, playing: false, time: 0, duration: 0, queue: [], index: 0, shuffle: false, repeatMode: "off", updated: Date())
        let data = try JSONEncoder().encode(value), restored = try JSONDecoder().decode(WatchPhoneSnapshot.self, from: data)
        XCTAssertNil(restored.lyrics); XCTAssertNil(restored.queueOffset); XCTAssertEqual(restored.queue, [])
    }
    func testOversizedLyricsCannotMakeWatchMessagesUnbounded() throws {
        let song = YouTubeVideo.placeholder("abcdefghijk")
        var value = WatchPhoneSnapshot(revision: UUID(), song: song, playing: true, time: 0, duration: 180, queue: [song], index: 0, shuffle: false, repeatMode: "off", updated: Date())
        value.lyrics = TrackLyrics(lines: [], plainText: String(repeating: "Long lyrics ", count: 10_000), instrumental: false)
        let bounded = value.boundedForWatch()
        XCTAssertLessThan(try JSONEncoder().encode(bounded).count, 48_000)
        XCTAssertNil(bounded.lyrics); XCTAssertEqual(bounded.song?.id, song.id)
    }
}
