import Foundation
import WidgetKit
import CryptoKit
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
        return WatchLibraryDefaults(suiteName: WatchWidgetSnapshot.group)
    }()
}

/// watchOS aborts when a preferences domain grows past its byte limit.
/// Keep settings in preferences and bulk library records in atomic shared files.
final class WatchLibraryDefaults: UserDefaults, @unchecked Sendable {
    private let settings: UserDefaults
    private let recordsDirectory: URL
    private let recordLock = NSRecursiveLock()

    init(suiteName: String, directory: URL? = nil) {
        let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: suiteName)
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        recordsDirectory = directory ?? container.appendingPathComponent("Library/Application Support/NovaLibraryRecords", isDirectory: true)
        settings = UserDefaults(suiteName: suiteName)!
        super.init(suiteName: suiteName)!
        // Migrate only this suite. Remove each old value only after a durable write.
        for (key, value) in settings.persistentDomain(forName: suiteName) ?? [:] {
            guard key != "widget.playback", let data = value as? Data else { continue }
            do {
                if !FileManager.default.fileExists(atPath: recordURL(key).path) { try writeRecord(data, forKey: key) }
                else { settings.removeObject(forKey: key) }
            } catch { NSLog("Nova Music could not migrate library record: %@", error.localizedDescription) }
        }
    }
    private func recordURL(_ key: String) -> URL {
        let name = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return recordsDirectory.appendingPathComponent(name + ".data")
    }
    func writeRecord(_ data: Data, forKey key: String) throws {
        recordLock.lock(); defer { recordLock.unlock() }
        try FileManager.default.createDirectory(at: recordsDirectory, withIntermediateDirectories: true)
        try data.write(to: recordURL(key), options: .atomic)
        settings.removeObject(forKey: key)
    }
    override func data(forKey defaultName: String) -> Data? {
        recordLock.lock(); defer { recordLock.unlock() }
        return (try? Data(contentsOf: recordURL(defaultName))) ?? settings.data(forKey: defaultName)
    }
    override func object(forKey defaultName: String) -> Any? {
        recordLock.lock(); defer { recordLock.unlock() }
        return (try? Data(contentsOf: recordURL(defaultName))) ?? settings.object(forKey: defaultName)
    }
    override func set(_ value: Any?, forKey defaultName: String) {
        recordLock.lock(); defer { recordLock.unlock() }
        if let data = value as? Data {
            do { try writeRecord(data, forKey: defaultName) }
            catch { NSLog("Nova Music could not save library record: %@", error.localizedDescription) }
        } else {
            // A key can change type or be cleared; do not retain its previous file.
            if FileManager.default.fileExists(atPath: recordURL(defaultName).path) { try? FileManager.default.removeItem(at: recordURL(defaultName)) }
            settings.set(value, forKey: defaultName)
        }
    }
    override func removeObject(forKey defaultName: String) {
        recordLock.lock(); defer { recordLock.unlock() }
        try? FileManager.default.removeItem(at: recordURL(defaultName))
        settings.removeObject(forKey: defaultName)
    }
}
