import Foundation
import WidgetKit
struct WatchWidgetSnapshot: Codable {
    var title: String
    var artist: String
    var playing: Bool
    var updated: Date
    static let group = "group.com.example.NovaMusic.watch"
    static func write(title: String, artist: String, playing: Bool) {
        let defaults = UserDefaults(suiteName: group)
        if let data = defaults?.data(forKey: "widget.playback"), let old = try? JSONDecoder().decode(Self.self, from: data), old.title == title, old.artist == artist, old.playing == playing { return }
        defaults?.set(try? JSONEncoder().encode(Self(title: title, artist: artist, playing: playing, updated: Date())), forKey: "widget.playback")
        WidgetCenter.shared.reloadAllTimelines()
    }
    static func read() -> Self { (UserDefaults(suiteName: group)?.data(forKey: "widget.playback")).flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? .init(title: "Nova Music", artist: "Your music, on your wrist", playing: false, updated: Date()) }
}

enum WatchEnvironment {
    static let defaults: UserDefaults = {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-nova-watch-ui-testing") || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            let defaults = UserDefaults(suiteName: "NovaMusicWatch.UITesting")!
            defaults.removePersistentDomain(forName: "NovaMusicWatch.UITesting")
            defaults.set(false, forKey: "watch.icloud.enabled")
            return defaults
        }
        #endif
        return UserDefaults(suiteName: WatchWidgetSnapshot.group) ?? .standard
    }()
}
