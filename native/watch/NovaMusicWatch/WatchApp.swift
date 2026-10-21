import SwiftUI
import WatchKit
import Intents

@MainActor
enum MusicPlaybackSession {
    static let store: YouTubeStore = {
        let store = YouTubeStore(defaults: WatchEnvironment.defaults, musicOnly: true)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-nova-watch-preview-player") {
            let track = YouTubeVideo(id: "00000000001", title: "Moonlight Sonata", channel: "Ludwig van Beethoven", thumbnail: Bundle.main.url(forResource: "beethoven", withExtension: "jpg", subdirectory: "ClassicalPortraits"))
            store.likedSongs = [track]; store.current = track; store.player.musicTracks[track.id] = track
            store.player.currentVideoID = track.id; store.player.duration = 345; store.player.currentTime = 92
            store.player.queueEntries = [.init(videoID: track.id, manual: false, order: 0)]; store.player.playlistIDs = [track.id]
        }
        #endif
        return store
    }()
}
@MainActor
final class WatchNavigation: ObservableObject {
    static let shared = WatchNavigation()
    @Published var player = false
    private var task: Task<Void, Never>?
    private var handled = Set<UUID>()
    private lazy var resolver = MusicSiriResolver(store: MusicPlaybackSession.store)
    func presentPhonePlayback() {
        WatchPhoneBridge.shared.mode = .phone
        player = true
        Task { await WatchPhoneBridge.shared.refresh(silent: true) }
    }
    func handle(_ intent: INPlayMediaIntent, receipt: UUID = UUID(), completion: ((INIntentResponse) -> Void)? = nil) {
        guard handled.insert(receipt).inserted else { completion?(INPlayMediaIntentResponse(code: .success, userActivity: nil)); return }
        if handled.count > 100 { handled = [receipt] }
        task?.cancel()
        let store = MusicPlaybackSession.store
        WatchPhoneBridge.shared.mode = .watch; store.cancelAutomaticMusic(); player = true
        let initialContext = store.musicQueueContext
        task = Task {
            do {
                guard intent.playbackSpeed == nil || intent.playbackSpeed == 1,
                      intent.playbackQueueLocation == .unknown || intent.playbackQueueLocation == .now else { throw YouTubeAPI.Failure(message: "That playback option isn’t supported.") }
                let resolver = self.resolver
                let resolution: MusicSiriResolution
                if let handoff = WatchSiriHandoff.consume(intent) { resolution = handoff }
                else { resolution = try await resolver.resolution(for: intent) }
                try Task.checkCancellation()
                guard store.musicQueueContext == initialContext else { throw CancellationError() }
                let deadline = ContinuousClock.now + .seconds(20)
                var failed = Set<String>(); var lastError: Error = URLError(.resourceUnavailable)
                for target in resolution.candidates.prefix(3) {
                    try Task.checkCancellation(); guard ContinuousClock.now < deadline else { break }
                    do {
                        let shuffle = intent.playShuffled ?? (intent.mediaSearch == nil ? store.player.shuffled : false)
                        try await resolver.play(target, shuffle: shuffle)
                        let expectedID = store.player.currentVideoID, context = store.musicQueueContext, generation = store.automaticMusicGeneration
                        while !store.player.hasStartedPlayback, store.player.intendsPlayback, store.player.error == nil, store.player.currentVideoID == expectedID, store.musicQueueContext == context, store.automaticMusicGeneration == generation, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(100)) }
                        try Task.checkCancellation()
                        guard store.player.currentVideoID == expectedID, store.musicQueueContext == context, store.automaticMusicGeneration == generation, store.player.intendsPlayback else { throw CancellationError() }
                        guard store.player.hasStartedPlayback else { throw YouTubeAPI.Failure(message: store.player.error ?? "Music couldn’t start in time.") }
                        switch intent.playbackRepeatMode { case .one: store.player.repeatMode = .one; case .all: store.player.repeatMode = .all; case .none: store.player.repeatMode = .off; default: break }
                        resolver.populateSongQueue(resolution, selected: target, failed: failed, shuffle: shuffle)
                        completion?(INPlayMediaIntentResponse(code: .success, userActivity: nil)); return
                    } catch { try Task.checkCancellation(); if error is CancellationError { throw error }; lastError = error; failed.insert(target.item.identifier ?? "") }
                }
                throw lastError
            } catch {
                if !Task.isCancelled && !(error is CancellationError) { store.player.error = error.localizedDescription; store.player.pause() }
                completion?(INPlayMediaIntentResponse(code: .failure, userActivity: nil))
            }
        }
    }
}
final class WatchApplicationDelegate: NSObject, WKApplicationDelegate {
    func handleRemoteNowPlayingActivity() {
        // watchOS calls this when the paired iPhone starts audio, respecting the
        // user's Auto-Launch Audio Apps setting. No workout/background workaround.
        WatchPhoneBridge.shared.connect(MusicPlaybackSession.store)
        WatchNavigation.shared.presentPhonePlayback()
    }
    func handle(_ userActivity: NSUserActivity) {
        let archived = (userActivity.userInfo?["novaIntent"] as? Data).flatMap { try? NSKeyedUnarchiver.unarchivedObject(ofClass: INPlayMediaIntent.self, from: $0) }
        guard let intent = userActivity.interaction?.intent as? INPlayMediaIntent ?? archived else { return }
        let receipt = (userActivity.userInfo?["novaReceipt"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
        WatchNavigation.shared.handle(intent, receipt: receipt)
    }
    func handle(_ intent: INIntent, completionHandler: @escaping (INIntentResponse) -> Void) {
        guard let intent = intent as? INPlayMediaIntent else { completionHandler(INPlayMediaIntentResponse(code: .failure, userActivity: nil)); return }
        WatchNavigation.shared.handle(intent, completion: completionHandler)
    }
    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            if let task = task as? WKURLSessionRefreshBackgroundTask {
                Task { @MainActor in WatchDownloadStore.shared.registerBackgroundTask(identifier: task.sessionIdentifier) { task.setTaskCompletedWithSnapshot(false) }; await WatchDownloadStore.shared.recover() }
            } else { task.setTaskCompletedWithSnapshot(false) }
        }
    }
    func applicationDidEnterBackground() { MusicPlaybackSession.store.player.save() }
}
@main
struct NovaMusicWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchApplicationDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            WatchRootView(store: MusicPlaybackSession.store)
                .modifier(WatchDebugPresentation())
                .tint(Color(red: 0.4, green: 0.92, blue: 0.62))
                .task {
                    WatchPhoneBridge.shared.connect(MusicPlaybackSession.store)
                    await WatchDownloadStore.shared.recover()
                    await MusicPlaybackSession.store.musicAccount.bootstrap()
                }
                .onOpenURL { url in if url.host == "player" { WatchNavigation.shared.player = true } }
        }.onChange(of: scenePhase) { previous, phase in
            if phase == .active, previous == .background {
                let active = WatchPhoneBridge.shared.mode == .phone ? WatchPhoneBridge.shared.snapshot?.playing == true : MusicPlaybackSession.store.player.intendsPlayback
                if active { WatchNavigation.shared.player = true }
            }
            if phase == .active { Task { await MusicPlaybackSession.store.musicAccount.sync() } }
            else { MusicPlaybackSession.store.player.save() }
        }
    }
}

private struct WatchDebugPresentation: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-nova-watch-large-type") { content.dynamicTypeSize(.accessibility2) }
        else { content }
        #else
        content
        #endif
    }
}
