#if NOVA_MUSIC
import Foundation
import Combine
import WatchConnectivity

struct WatchPhoneSnapshot: Codable, Equatable {
    var revision: UUID
    var song: YouTubeVideo?
    var playing: Bool
    var time: Double
    var duration: Double
    var queue: [YouTubeVideo]
    var index: Int
    var shuffle: Bool
    var repeatMode: String
    var updated: Date
    var lyrics: TrackLyrics? = nil
    var calibration: LyricCalibration? = nil
    var queueOffset: Int? = nil
    var queueCount: Int? = nil
    var liked: Bool? = nil

    /// WatchConnectivity has a finite message budget. Send a useful queue window
    /// while retaining absolute positions for commands to the phone.
    func boundedForWatch(maximumBytes: Int = 48_000) -> WatchPhoneSnapshot {
        var result = self
        let low = max(0, min(index, queue.count) - 5), high = min(queue.count, max(low, index + 31))
        result.queue = Array(queue[low..<high]); result.index = max(0, index - low)
        result.queueOffset = (queueOffset ?? 0) + low; result.queueCount = queueCount ?? queue.count
        let encoder = JSONEncoder()
        while (try? encoder.encode(result).count) ?? Int.max > maximumBytes {
            if result.queue.count > result.index + 1 { result.queue.removeLast() }
            else if result.index > 0 { result.queue.removeFirst(); result.index -= 1; result.queueOffset = (result.queueOffset ?? 0) + 1 }
            else if result.lyrics != nil { result.lyrics = nil; result.calibration = nil }
            else { break }
        }
        return result
    }
}
struct WatchPhoneCommand: Codable {
    var version = 1
    var id = UUID()
    var created = Date()
    var action: String
    var revision: UUID?
    var song: YouTubeVideo?
    var queue: [YouTubeVideo]?
    var shuffle: Bool?
    var context: String?
    var value: Double?
    var absoluteQueueIndex: Bool? = nil
}
struct WatchPhoneChunk: Codable {
    let id: UUID
    let index: Int
    let count: Int
    let created: Date
    let payload: Data
}
struct WatchPhoneReply: Codable { var snapshot: WatchPhoneSnapshot?; var error: String? }

@MainActor
final class WatchPhoneBridge: NSObject, ObservableObject {
    enum Mode: String, CaseIterable { case watch = "Apple Watch", phone = "iPhone" }
    static let shared = WatchPhoneBridge()
    @Published var mode: Mode = .watch
    @Published private(set) var reachable = false
    @Published private(set) var snapshot: WatchPhoneSnapshot?
    @Published var error: String?
    private var store: YouTubeStore?
    private var subscription: AnyCancellable?
    private var revision = UUID()
    private var signature = ""
    private var receipts: [UUID: WatchPhoneReply] = [:]
    private struct Assembly { var created: Date; var count: Int; var parts: [Int: Data] }
    private var assemblies: [UUID: Assembly] = [:]
    private let session: WCSession?
    init(session: WCSession? = WCSession.isSupported() ? .default : nil) {
        self.session = session
        super.init(); session?.delegate = self; session?.activate()
    }
    func connect(_ store: YouTubeStore) {
        self.store = store
        #if os(iOS)
        subscription = store.player.objectWillChange.throttle(for: .seconds(1), scheduler: RunLoop.main, latest: true).sink { [weak self] _ in Task { @MainActor in self?.publish() } }
        publish()
        #endif
    }
    func refresh(silent: Bool = false) async {
        if silent && (session?.activationState != .activated || session?.isReachable != true) { return }
        do { _ = try await send(.init(action: "snapshot")); error = nil }
        catch { if !silent { self.error = error.localizedDescription } }
    }
    func control(_ action: String, value: Double? = nil) async {
        do { _ = try await send(.init(action: action, revision: snapshot?.revision, value: value, absoluteQueueIndex: action == "entry" ? true : nil)); error = nil }
        catch { self.error = error.localizedDescription }
    }
    func play(_ song: YouTubeVideo, queue: [YouTubeVideo], shuffle: Bool, context: String?) async throws {
        do { _ = try await send(.init(action: "playSongs", song: song, queue: queue, shuffle: shuffle, context: context)); error = nil }
        catch { self.error = error.localizedDescription; throw error }
    }
    func enqueue(_ songs: [YouTubeVideo], next: Bool) async {
        do { _ = try await send(.init(action: next ? "enqueueNext" : "enqueue", revision: snapshot?.revision, queue: songs)); error = nil }
        catch { self.error = error.localizedDescription }
    }
    private func send(_ command: WatchPhoneCommand) async throws -> WatchPhoneReply {
        guard let session, session.activationState == .activated, session.isReachable else { throw YouTubeAPI.Failure(message: "Your iPhone is unavailable. Open Nova Music on iPhone, or choose Apple Watch.") }
        let data = try JSONEncoder().encode(command)
        guard data.count <= 8_000_000 else { throw YouTubeAPI.Failure(message: "This queue is too large to transfer to iPhone.") }
        if data.count > 48_000 {
            let count = (data.count + 35_999) / 36_000
            var reply = WatchPhoneReply()
            for index in 0..<count {
                try Task.checkCancellation()
                let range = index * 36_000..<min(data.count, (index + 1) * 36_000)
                let chunk = WatchPhoneChunk(id: command.id, index: index, count: count, created: Date(), payload: data.subdata(in: range))
                reply = try await sendData(JSONEncoder().encode(chunk), session: session)
            }
            return reply
        }
        return try await sendData(data, session: session)
    }
    private func sendData(_ data: Data, session: WCSession) async throws -> WatchPhoneReply {
        guard session.isReachable else { throw URLError(.notConnectedToInternet) }
        return try await withCheckedThrowingContinuation { continuation in
            let pending = WatchPhonePending(continuation)
            pending.timeout = Task { try? await Task.sleep(for: .seconds(10)); guard !Task.isCancelled else { return }; pending.finish(.failure(URLError(.timedOut))) }
            session.sendMessageData(data) { data in
                Task { @MainActor in
                    do {
                        let reply = try JSONDecoder().decode(WatchPhoneReply.self, from: data)
                        if let snapshot = reply.snapshot { self.accept(snapshot) }
                        if let error = reply.error { throw YouTubeAPI.Failure(message: error) }
                        pending.finish(.success(reply))
                    } catch { pending.finish(.failure(error)) }
                }
            } errorHandler: { error in Task { @MainActor in pending.finish(.failure(error)) } }
        }
    }
    func accept(_ value: WatchPhoneSnapshot) { guard snapshot.map({ value.updated >= $0.updated }) ?? true else { return }; snapshot = value }
    private func currentSnapshot() -> WatchPhoneSnapshot? {
        guard let store else { return nil }; let player = store.player
        let next = player.queueEntries.map { $0.id.uuidString }.joined() + (player.currentVideoID ?? "")
        if signature != next { signature = next; revision = UUID() }
        let index = min(max(0, player.playlistIndex), max(0, player.queueEntries.count - 1))
        let low = max(0, index - 5), high = min(player.queueEntries.count, index + 31)
        var value = WatchPhoneSnapshot(revision: revision, song: player.currentVideoID.flatMap { player.musicTracks[$0] ?? store.knownVideo($0) } ?? store.current, playing: player.intendsPlayback, time: player.currentTime, duration: player.duration,
                     queue: player.queueEntries[low..<high].map { player.musicTracks[$0.videoID] ?? store.knownVideo($0.videoID) ?? .placeholder($0.videoID) }, index: index - low,
                     shuffle: player.shuffled, repeatMode: player.repeatMode.rawValue, updated: Date())
        value.queueOffset = low; value.queueCount = player.queueEntries.count
        #if os(iOS)
        value.lyrics = player.trackLyrics; value.calibration = player.lyricCalibration
        value.liked = value.song.map { store.isLiked($0) }
        #endif
        return value.boundedForWatch()
    }
    private func publish() {
        #if os(iOS)
        guard session?.isPaired == true, session?.isWatchAppInstalled == true, session?.activationState == .activated, let snapshot = currentSnapshot(), let data = try? JSONEncoder().encode(snapshot) else { return }
        try? session?.updateApplicationContext(["novaPlayback": data])
        #endif
    }
    private func receive(_ chunk: WatchPhoneChunk) -> WatchPhoneReply {
        assemblies = assemblies.filter { Date().timeIntervalSince($0.value.created) < 120 }
        guard chunk.count > 0, chunk.count <= 224, (0..<chunk.count).contains(chunk.index), chunk.payload.count <= 36_000,
              abs(chunk.created.timeIntervalSinceNow) < 30 else { return .init(error: "The queue transfer expired. Try again.") }
        if let receipt = receipts[chunk.id] { return receipt }
        if assemblies[chunk.id] == nil {
            guard assemblies.count < 3 else { return .init(error: "Another queue is being transferred. Try again.") }
            assemblies[chunk.id] = Assembly(created: Date(), count: chunk.count, parts: [:])
        }
        guard var assembly = assemblies[chunk.id], assembly.count == chunk.count,
              assembly.parts[chunk.index].map({ $0 == chunk.payload }) ?? true else { return .init(error: "The queue transfer couldn’t be verified.") }
        assembly.parts[chunk.index] = chunk.payload
        guard assembly.parts.values.reduce(0, { $0 + $1.count }) <= 8_000_000 else { assemblies[chunk.id] = nil; return .init(error: "This queue is too large.") }
        assemblies[chunk.id] = assembly
        guard assembly.parts.count == assembly.count else { return .init() }
        let data = (0..<assembly.count).reduce(into: Data()) { $0.append(assembly.parts[$1]!) }
        assemblies[chunk.id] = nil
        guard var command = try? JSONDecoder().decode(WatchPhoneCommand.self, from: data), command.id == chunk.id else { return .init(error: "The queue couldn’t be read.") }
        command.created = Date()
        return receive(command)
    }
    func receiveData(_ data: Data) -> WatchPhoneReply {
        if let command = try? JSONDecoder().decode(WatchPhoneCommand.self, from: data) { return receive(command) }
        if let chunk = try? JSONDecoder().decode(WatchPhoneChunk.self, from: data) { return receive(chunk) }
        return .init(error: "The playback command couldn’t be read.")
    }
    private func receive(_ command: WatchPhoneCommand) -> WatchPhoneReply {
        #if os(iOS)
        if let saved = receipts[command.id] { return saved }
        guard command.version == 1, abs(command.created.timeIntervalSinceNow) < 30, let store else { return .init(error: "That command expired. Refresh the iPhone controls.") }
        let player = store.player
        if ["remove", "moveUp", "moveDown", "entry", "clear", "enqueue", "enqueueNext"].contains(command.action), command.revision != currentSnapshot()?.revision { return .init(snapshot: currentSnapshot(), error: "The iPhone queue changed. Try again.") }
        if command.action == "entry", command.absoluteQueueIndex != true, (currentSnapshot()?.queueOffset ?? 0) > 0 {
            return .init(snapshot: currentSnapshot(), error: "Update Nova Music on Apple Watch to choose a song from this queue.")
        }
        switch command.action {
        case "snapshot": break
        case "play": player.play()
        case "pause": player.pause()
        case "next": player.next()
        case "previous": player.previous()
        case "seek": if let value = command.value, value.isFinite { player.seek(to: value) }
        case "shuffle": player.toggleShuffle()
        case "repeat": player.repeatMode = player.repeatMode == .off ? .all : player.repeatMode == .all ? .one : .off
        case "like": if let song = store.current { store.toggleLike(song) }
        case "clear": player.clearUpcomingQueue()
        case "remove": if let value = command.value, value >= 0, value < 100000 { player.removeUpcomingQueue(at: IndexSet(integer: Int(value))) }
        case "moveUp", "moveDown": if let value = command.value, value >= 0, value < 100000 { let index = Int(value); player.moveUpcomingQueue(from: IndexSet(integer: index), to: command.action == "moveUp" ? max(0,index-1) : index+2) }
        case "entry": if let value = command.value, value >= 0, value < Double(player.queueEntries.count) { player.playQueueEntry(player.queueEntries[Int(value)].id) }
        case "enqueue", "enqueueNext":
            guard let songs = command.queue, songs.count <= 10000, songs.allSatisfy({ YouTubeLink.validID($0.id) }) else { return .init(error: "These songs could not be added.") }
            for song in songs { player.musicTracks[song.id] = song }
            player.enqueue(songs.map(\.id), next: command.action == "enqueueNext")
        case "playSongs":
            guard let song = command.song, YouTubeLink.validID(song.id), (command.queue?.count ?? 0) <= 10000 else { return .init(error: "This music could not be opened on iPhone.") }
            store.play(song, minimized: true, music: true, queue: command.queue ?? [], shuffle: command.shuffle, context: command.context)
        default: return .init(error: "Update Nova Music on both devices to use this control.")
        }
        let reply = WatchPhoneReply(snapshot: currentSnapshot()); receipts[command.id] = reply
        if receipts.count > 100 { receipts = [command.id: reply] }; publish(); return reply
        #else
        return .init(error: "Choose Apple Watch to play here.")
        #endif
    }
}
@MainActor
private final class WatchPhonePending {
    var continuation: CheckedContinuation<WatchPhoneReply, Error>?
    var timeout: Task<Void, Never>?
    init(_ continuation: CheckedContinuation<WatchPhoneReply, Error>) { self.continuation = continuation }
    func finish(_ result: Result<WatchPhoneReply, Error>) { guard let continuation else { return }; self.continuation = nil; timeout?.cancel(); continuation.resume(with: result) }
}
extension WatchPhoneBridge: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in
            reachable = session.isReachable
            if let data = session.receivedApplicationContext["novaPlayback"] as? Data, let value = try? JSONDecoder().decode(WatchPhoneSnapshot.self, from: data) { accept(value) }
            #if os(watchOS)
            if reachable { await refresh(silent: true) }
            #endif
        }
    }
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            reachable = session.isReachable
            #if os(watchOS)
            if reachable { await refresh(silent: true) }
            #endif
        }
    }
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let data = applicationContext["novaPlayback"] as? Data, let value = try? JSONDecoder().decode(WatchPhoneSnapshot.self, from: data) else { return }; Task { @MainActor in accept(value) }
    }
    nonisolated func session(_ session: WCSession, didReceiveMessageData messageData: Data, replyHandler: @escaping (Data) -> Void) {
        Task { @MainActor in
            let reply = receiveData(messageData)
            replyHandler((try? JSONEncoder().encode(reply)) ?? Data())
        }
    }
    #if os(iOS)
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    #endif
}
#endif
