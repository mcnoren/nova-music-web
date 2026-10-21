import Foundation
import Intents
@MainActor
enum MusicSiriDiagnostics {
    static func record(_ stage: String, intent: INIntent? = nil, result: String? = nil) {
        let defaults = UserDefaults(suiteName: WatchWidgetSnapshot.group)
        var trace = defaults?.stringArray(forKey: "watch.siriTrace") ?? []
        trace.append(Date().ISO8601Format() + " " + stage + " " + (result ?? ""))
        defaults?.set(Array(trace.suffix(30)), forKey: "watch.siriTrace")
    }
}

/// Persistent provider metadata supports cold launches with downloaded collections.
enum WatchCatalogStorage {
    static var defaults: UserDefaults { WatchEnvironment.defaults }
    static var offline: Bool { defaults.bool(forKey: "watch.offlineOnly") }
    static func read<T: Decodable>(_ key: String) -> T? { defaults.data(forKey: "watch.catalog." + key).flatMap { try? JSONDecoder().decode(T.self, from: $0) } }
    static func save<T: Encodable>(_ value: T, key: String) { defaults.set(try? JSONEncoder().encode(value), forKey: "watch.catalog." + key) }
}

enum WatchSiriAuthorization {
    static func request(_ completion: @escaping (INSiriAuthorizationStatus) -> Void) {
        #if targetEnvironment(simulator)
        completion(.restricted)
        #else
        INPreferences.requestSiriAuthorization(completion)
        #endif
    }
}

/// Transfers resolved catalog metadata across the Siri extension/app boundary.
/// The app cannot assume a remotely resolved song already belongs to its library.
struct WatchSiriHandoff: Codable {
    struct Target: Codable {
        var kind: String
        var song: YouTubeVideo?
        var artist: YouTubeChannel?
        var album: YouTubeMusicAlbum?
        var playlist: YouTubePlaylist?
        var publicPlaylist: YouTubePublicPlaylist?
        init(_ target: MusicSiriTarget) {
            switch target {
            case .song(let value): kind = "song"; song = value
            case .artist(let value): kind = "artist"; artist = value
            case .album(let value): kind = "album"; album = value
            case .playlist(var value): kind = "playlist"; value.videos = []; value.spotifyUnmatchedTracks = nil; value.spotifyImportSongIDs = nil; playlist = value
            case .publicPlaylist(let value): kind = "public"; publicPlaylist = value
            case .library: kind = "library"
            case .current: kind = "current"
            }
        }
        var value: MusicSiriTarget? {
            switch kind {
            case "song": return song.map(MusicSiriTarget.song)
            case "artist": return artist.map(MusicSiriTarget.artist)
            case "album": return album.map(MusicSiriTarget.album)
            case "playlist": return playlist.map(MusicSiriTarget.playlist)
            case "public": return publicPlaylist.map(MusicSiriTarget.publicPlaylist)
            case "library": return .library
            case "current": return .current
            default: return nil
            }
        }
    }
    var date: Date
    var requestKey: String
    var targets: [Target]
    var rankedSongs: [YouTubeVideo]
    var hasCatalogSongs: Bool
    private static var file: URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: WatchWidgetSnapshot.group)?.appendingPathComponent("WatchSiriHandoff.json") }
    static func save(_ resolution: MusicSiriResolution, defaults: UserDefaults = WatchEnvironment.defaults) {
        let value = Self(date: Date(), requestKey: resolution.request.cacheKey, targets: resolution.candidates.map(Target.init), rankedSongs: resolution.rankedSongs, hasCatalogSongs: resolution.hasCatalogSongs)
        let data = try? JSONEncoder().encode(value)
        if defaults === WatchEnvironment.defaults, let data, let file { try? data.write(to: file, options: .atomic) }
        defaults.set(data, forKey: "watch.siri.pending")
    }
    static func consume(_ intent: INPlayMediaIntent, defaults: UserDefaults = WatchEnvironment.defaults) -> MusicSiriResolution? {
        let sharedData = defaults === WatchEnvironment.defaults ? file.flatMap { try? Data(contentsOf: $0) } : nil
        guard let data = sharedData ?? defaults.data(forKey: "watch.siri.pending"), let value = try? JSONDecoder().decode(Self.self, from: data), abs(value.date.timeIntervalSinceNow) < 60 else { return nil }
        let request = MusicSiriRequest(intent), candidates = value.targets.compactMap(\.value)
        guard request.cacheKey == value.requestKey || request.identifier.map({ id in candidates.contains { $0.item.identifier == id } }) == true else { return nil }
        defaults.removeObject(forKey: "watch.siri.pending")
        if defaults === WatchEnvironment.defaults, let file { try? FileManager.default.removeItem(at: file) }
        return .init(request: request, candidates: candidates, rankedSongs: value.rankedSongs, hasCatalogSongs: value.hasCatalogSongs)
    }
}
@MainActor
extension YouTubeStore {
    func reloadWatchSiriLibrary() {
        func read<T: Decodable>(_ key: String, _ fallback: T) -> T { defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) } ?? fallback }
        playlists = read("youtube.playlists", [])
        likedSongs = read("youtube.likedSongs", []); saved = read("music.savedTracks", [])
        likedAlbums = read("youtube.likedAlbums", []); followedArtists = read("youtube.followedArtists", [])
        musicHistory = read("youtube.musicHistory", []); musicFolders = read("music.folders", [])
        artistReleaseSelections = read("music.artistReleaseSelections", [:]); artistDiscSelections = read("music.artistDiscSelections", [:])
        refreshSmartPlaylists(persist: false)
        if let retained: WatchRetainedPlayback = read("watch.playback", Optional<WatchRetainedPlayback>.none), retained.songs.indices.contains(retained.index) {
            player.musicTracks = Dictionary(retained.songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            player.currentVideoID = retained.songs[retained.index].id
        } else { player.currentVideoID = nil }
    }
}
