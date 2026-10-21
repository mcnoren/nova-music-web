import XCTest
import SwiftUI
import UIKit
@testable import NovaMusic

@MainActor
private final class CloudFixture: NovaCloudStorage {
    var identity = "00000000-0000-4000-8000-000000000001"
    var documents: [String: NovaSyncDocument] = [:]
    var revisions: [String: Int] = [:]
    var offline = false
    var conflictOnce = false
    var writes = 0
    var cloudRecordNames: [String] = []
    func accountID() async throws -> String { if offline { throw URLError(.notConnectedToInternet) }; return identity }
    func load(_ name: String) async throws -> NovaCloudSnapshot {
        cloudRecordNames.append(name)
        if offline { throw URLError(.notConnectedToInternet) }
        return NovaCloudSnapshot(document: documents[name] ?? NovaSyncDocument(), revision: revisions[name].map(String.init))
    }
    func save(_ document: NovaSyncDocument, named name: String, revision: String?) async throws {
        cloudRecordNames.append(name)
        if offline { throw URLError(.notConnectedToInternet) }
        if conflictOnce {
            conflictOnce = false
            let old = documents[name] ?? NovaSyncDocument()
            documents[name] = try old.updating(previous: old.values, next: old.values.merging(["setting:remote": .string("concurrent edit")], uniquingKeysWith: { _, r in r }), actor: UUID())
            revisions[name] = (revisions[name] ?? 0) + 1
            throw NovaCloudFailure.conflict
        }
        guard revision == revisions[name].map(String.init) else { throw NovaCloudFailure.conflict }
        documents[name] = document; revisions[name] = (revisions[name] ?? 0) + 1; writes += 1
    }
}

/// In-memory LAN bus. The fixture's connection document is the local bus state;
/// its CloudKit methods are used only for the library.
@MainActor
private final class LocalPlaybackFixture: MusicLocalPlaybackTransport {
    let storage: CloudFixture
    var onReceive: (Data) -> Void = { _ in }
    var onPeersChanged: (Set<String>) -> Void = { _ in }
    var onError: (String?) -> Void = { _ in }
    init(_ storage: CloudFixture) { self.storage = storage }
    private(set) var configured = false
    func start(id: String, key: Data, payload: Data) { configured = key.count == 32 }
    func publish(_ data: Data) {
        guard !storage.offline, let incoming = try? JSONDecoder().decode(NovaSyncDocument.self, from: data) else { return }
        let current = storage.documents["nova-connection"] ?? NovaSyncDocument()
        storage.documents["nova-connection"] = try? current.merging(incoming)
    }
    func refresh() async {
        guard !storage.offline, let document = storage.documents["nova-connection"], let data = try? JSONEncoder().encode(document) else { return }
        var peers = Set(document.values.filter { $0.key.hasPrefix("connect:device.") }.compactMap { try? $0.value.decoded(MusicConnectedDevice.self).id })
        if let session = try? document.values["connect:session"]?.decoded(MusicConnectedSession.self) { peers.insert(session.owner) }
        onPeersChanged(peers); onReceive(data)
    }
    func stop() {}
}

@MainActor
final class PlaybackSyncEfficiencyTests: XCTestCase {
    private func fixture() -> (YouTubeStore, CloudFixture, MusicAccountSync) {
        let suite = "ICloudSyncTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let store = YouTubeStore(defaults: defaults, musicOnly: true)
        let cloud = CloudFixture()
        let account = MusicAccountSync(store: store, cloud: cloud, localPlayback: LocalPlaybackFixture(cloud))
        store.musicAccount = account
        addTeardownBlock { await MainActor.run { account.disableICloud(); defaults.removePersistentDomain(forName: suite) } }
        return (store, cloud, account)
    }
    func testDuplicatePlayerStatusDoesNotPublishOrPersistTheLibrary() async throws {
        let (store, cloud, account) = fixture(); try await account.enableICloud()
        let song = YouTubeVideo(id: "abcdefghijk", title: "Stable song", channel: "Artist")
        store.current = song; store.queueVideos = [song]; store.playingMusic = true
        store.player.mirrorConnectedPlayback(ids: [song.id], index: 0, position: 15, duration: 180, playing: true)
        try await Task.sleep(for: .seconds(2))
        let before = cloud.documents["nova-connection"]
        for _ in 0..<100 { store.player.loading = false; store.player.playing = true }
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(cloud.documents["nova-connection"], before)
        let key = "music.icloud.document." + cloud.identity.lowercased()
        let data = try XCTUnwrap(store.defaults.data(forKey: key))
        let cached = try JSONDecoder().decode(NovaSyncDocument.self, from: data)
        XCTAssertFalse(cached.values.keys.contains { $0.hasPrefix("connect:") })
        store.defaults.set(42, forKey: "music.lastPlaybackPosition.test")
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(store.defaults.data(forKey: key), data, "Playback checkpoints must not recapture the library")
    }
}
