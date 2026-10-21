import Foundation
import Combine
import CloudKit

@MainActor
final class MusicAccountSync: ObservableObject {
    @Published private(set) var status = "Saved on Apple Watch"
    @Published private(set) var error: String?
    @Published private(set) var lastSynced: Date?
    @Published private(set) var cloudEnabled = false
    let usesGitHub = false
    var controlsRemoteOutput: Bool { WatchPhoneBridge.shared.mode == .phone }
    private weak var store: YouTubeStore?
    private let cloud: NovaCloudStorage
    private var identity: String?
    private var document = NovaSyncDocument()
    private var previous: [String: NovaSyncValue] = [:]
    private let actorID: UUID
    private var epoch = UUID()
    private var applying = false
    private var syncing = false
    private var poll: Task<Void, Never>?
    private var pending: Task<Void, Never>?
    private var remotePlayback: Task<Void, Error>?
    private var subscriptions = Set<AnyCancellable>()
    private var cacheKey: String { "watch.icloud.document." + (identity ?? "guest") }
    init(store: YouTubeStore, cloud: NovaCloudStorage? = nil) {
        self.store = store; self.cloud = cloud ?? NovaCloudKitStorage()
        actorID = store.defaults.string(forKey: "watch.syncActor").flatMap(UUID.init(uuidString:)) ?? UUID()
        store.defaults.set(actorID.uuidString, forKey: "watch.syncActor")
        store.objectWillChange.sink { [weak self] _ in
            guard let self, !self.applying else { return }
            self.pending?.cancel(); self.pending = Task { try? await Task.sleep(for: .milliseconds(900)); guard !Task.isCancelled else { return }; self.capture(); await self.sync() }
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .CKAccountChanged).sink { [weak self] _ in
            Task { @MainActor in self?.disconnect(); self?.error = NovaCloudFailure.accountChanged.localizedDescription }
        }.store(in: &subscriptions)
    }
    func bootstrap() async {
        guard store?.defaults.object(forKey: "watch.icloud.enabled") as? Bool != false else { return }
        await enableICloud(automatic: true)
    }
    func enableICloud(automatic: Bool = false, mergeLibrary: Bool = true) async {
        do {
            guard let store else { return }
            let id = try await cloud.accountID()
            if automatic, let previous = store.defaults.string(forKey: "watch.icloud.identity"), previous != id { throw NovaCloudFailure.accountChanged }
            identity = id; epoch = UUID()
            document = store.defaults.data(forKey: cacheKey).flatMap { try? JSONDecoder().decode(NovaSyncDocument.self, from: $0) } ?? NovaSyncDocument()
            document = document.cloudPartition(connection: false); try document.validate()
            previous = document.values
            cloudEnabled = true
            if mergeLibrary { capture() }
            else {
                applying = true
                defer { applying = false }
                try MusicAccountLibrary.apply(document.values, to: store)
                previous = try MusicAccountLibrary.values(store, preserving: document.values)
            }
            store.defaults.set(id, forKey: "watch.icloud.identity"); store.defaults.set(true, forKey: "watch.icloud.enabled")
            await sync()
            if poll == nil {
                poll = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(30))
                        guard !Task.isCancelled, self?.cloudEnabled == true else { return }
                        await self?.sync()
                    }
                }
            }
        } catch { self.error = error.localizedDescription }
    }
    func disconnect() {
        capture(); epoch = UUID(); pending?.cancel(); poll?.cancel(); poll = nil; cloudEnabled = false
        store?.defaults.set(false, forKey: "watch.icloud.enabled")
        identity = nil; document = NovaSyncDocument(); previous = [:]; status = "Saved on Apple Watch"; error = nil
    }
    private func capture() {
        guard let store, cloudEnabled, !applying else { return }
        do {
            let values = try MusicAccountLibrary.values(store, preserving: document.values)
            document = try document.updating(previous: previous, next: values, actor: actorID).cloudPartition(connection: false)
            previous = values; try save()
        } catch { self.error = error.localizedDescription }
    }
    private func save() throws {
        guard let defaults = store?.defaults else { return }
        let data = try JSONEncoder().encode(document)
        if let files = defaults as? WatchLibraryDefaults { try files.writeRecord(data, forKey: cacheKey) }
        else { defaults.set(data, forKey: cacheKey) }
    }
    func sync() async {
        guard !syncing, cloudEnabled, let identity, let store else { return }
        syncing = true; let requestEpoch = epoch; defer { syncing = false }
        do {
            guard try await cloud.accountID() == identity else { throw NovaCloudFailure.accountChanged }
            capture(); status = "Syncing with iCloud…"; error = nil
            for _ in 0..<5 {
                let remote = try await cloud.load("nova-library")
                guard epoch == requestEpoch else { return }
                capture()
                let merged = try document.merging(remote.document.cloudPartition(connection: false))
                if merged != remote.document {
                    do { try await cloud.save(merged, named: "nova-library", revision: remote.revision) }
                    catch NovaCloudFailure.conflict { continue }
                }
                guard epoch == requestEpoch else { return }
                capture(); document = try merged.merging(document)
                applying = true
                defer { applying = false }
                try MusicAccountLibrary.apply(document.values, to: store)
                previous = try MusicAccountLibrary.values(store, preserving: document.values); try save()
                if document != merged { continue }
                status = "Synced with iCloud"; lastSynced = Date(); return
            }
            throw NovaCloudFailure.conflict
        } catch {
            guard epoch == requestEpoch else { return }
            if case NovaCloudFailure.accountChanged = error { disconnect() }
            self.error = error.localizedDescription; status = "Changes saved on Apple Watch"
        }
    }
    func routePlay(_ song: YouTubeVideo, queue: [YouTubeVideo], shuffle: Bool?, context: String?) -> Bool {
        guard controlsRemoteOutput else { return false }
        remotePlayback = Task { try await WatchPhoneBridge.shared.play(song, queue: queue, shuffle: shuffle ?? false, context: context) }; return true
    }
    func routePlaylist(_ playlist: YouTubePlaylist, index: Int, shuffle: Bool?) -> Bool {
        guard controlsRemoteOutput else { return false }
        remotePlayback = Task {
            let songs: [YouTubeVideo]
            if let id = playlist.youtubePlaylistID { songs = try await YouTubeAPI.musicRankedSongs(id) } else { songs = playlist.videos }
            guard !songs.isEmpty else { throw YouTubeAPI.Failure(message: "This playlist is empty.") }
            try await WatchPhoneBridge.shared.play(songs[min(max(0,index), songs.count-1)], queue: songs, shuffle: shuffle ?? false, context: "playlist:" + playlist.id.uuidString.lowercased())
        }; return true
    }
    func waitForPendingPlayback() async throws { if let remotePlayback { try await remotePlayback.value; self.remotePlayback = nil } }
}