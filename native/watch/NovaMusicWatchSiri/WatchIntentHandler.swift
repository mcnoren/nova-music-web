import Intents
import Foundation

final class WatchIntentHandler: INExtension, INPlayMediaIntentHandling {
    @MainActor private lazy var store = YouTubeStore(defaults: UserDefaults(suiteName: WatchWidgetSnapshot.group) ?? .standard, musicOnly: true)
    override func handler(for intent: INIntent) -> Any { self }
    func resolveMediaItems(for intent: INPlayMediaIntent, with completion: @escaping ([INPlayMediaMediaItemResolutionResult]) -> Void) {
        Task { @MainActor in
            do {
                store.reloadWatchSiriLibrary()
                let request = MusicSiriRequest(intent)
                if request.needsSearchName { completion([.needsValue()]); return }
                let resolution = try await MusicSiriResolver(store: store).resolution(for: intent)
                WatchSiriHandoff.save(resolution)
                completion(resolution.candidates.first.map { [.success(with: $0.item)] } ?? [.unsupported()])
            } catch { completion([.unsupported(forReason: .serviceUnavailable)]) }
        }
    }
    func resolvePlayShuffled(for intent: INPlayMediaIntent, with completion: @escaping (INBooleanResolutionResult) -> Void) { completion(intent.playShuffled.map { .success(with: $0) } ?? .notRequired()) }
    func handle(intent: INPlayMediaIntent, completion: @escaping (INPlayMediaIntentResponse) -> Void) {
        let activity = NSUserActivity(activityType: "com.example.NovaMusic.watch.play")
        activity.userInfo = ["novaReceipt": UUID().uuidString]
        activity.addUserInfoEntries(from: ["requestedAt": Date().timeIntervalSince1970])
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: intent, requiringSecureCoding: true) { activity.addUserInfoEntries(from: ["novaIntent": data]) }
        completion(INPlayMediaIntentResponse(code: .continueInApp, userActivity: activity))
    }
}
