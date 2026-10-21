import XCTest
import Intents
@testable import NovaMusicWatch

@MainActor
final class WatchMusicTests: XCTestCase {
    private var domain = ""
    private var defaults: UserDefaults!
    override func setUp() { super.setUp(); domain = "NovaWatchTests." + UUID().uuidString; defaults = UserDefaults(suiteName: domain)! }
    override func tearDown() { defaults.removePersistentDomain(forName: domain); defaults = nil; super.tearDown() }
    private func song(_ id: String, title: String = "Test Song", artist: String = "Test Artist") -> YouTubeVideo { .init(id: id, title: title, channel: artist, thumbnail: nil) }
    func testPlaylistAndSmartRulesPersistAcrossIndependentStoreLaunches() throws {
        let store = YouTubeStore(defaults: defaults, musicOnly: true)
        let a = song("abcdefghijk", title: "First"), b = song("lmnopqrstuv", title: "Second", artist: "Another Artist")
        let playlist = try XCTUnwrap(store.createPlaylist(named: "Watch Favorites", videos: [a,b]))
        store.toggleLike(a)
        let smart = try XCTUnwrap(store.saveSmartPlaylist(name: "Test Artist Songs", rules: .init(artists: ["Test Artist"])))
        let restored = YouTubeStore(defaults: defaults, musicOnly: true)
        XCTAssertEqual(restored.playlist(playlist)?.videos.map(\.id), [a.id,b.id])
        XCTAssertEqual(restored.playlist(smart)?.videos.map(\.id), [a.id])
        restored.toggleLike(a)
        XCTAssertEqual(restored.playlist(smart)?.videos, [])
        store.player.stop(); restored.player.stop()
    }
    func testLibraryQueueEditsDoNotRewriteSavedPlaylist() throws {
        let store = YouTubeStore(defaults: defaults, musicOnly: true)
        let songs = [song("abcdefghijk"),song("lmnopqrstuv"),song("12345678901")]
        let id = try XCTUnwrap(store.createPlaylist(named: "Keep Order", videos: songs))
        let player = store.player
        player.currentVideoID = songs[0].id; player.playlistIndex = 0; player.playlistIDs = songs.map(\.id)
        player.queueEntries = songs.enumerated().map { .init(videoID: $0.element.id, manual: false, order: $0.offset) }
        player.moveUpcomingQueue(from: IndexSet(integer: 1), to: 0)
        XCTAssertEqual(player.playlistIDs, [songs[0].id,songs[2].id,songs[1].id])
        XCTAssertEqual(store.playlist(id)?.videos.map(\.id), songs.map(\.id))
        player.enqueue([songs[1].id], next: true)
        XCTAssertEqual(player.playlistIDs.filter { $0 == songs[1].id }.count, 2)
        player.clearUpcomingQueue(); XCTAssertEqual(player.playlistIDs, [songs[0].id]); player.stop()
    }
    func testFolderMembershipPinsAndEmptyReleaseChoiceSurviveRelaunch() throws {
        let store = YouTubeStore(defaults: defaults, musicOnly: true)
        let folder = try XCTUnwrap(store.createMusicFolder(named: "Travel"))
        let album = YouTubeMusicAlbum(id: "MPREb_test", title: "Album", artist: "Artist", artwork: nil)
        store.setFolder(folder, contains: .album(album), included: true); store.toggleFolderItemPin(.album(album), in: folder)
        store.setReleaseSelection(for: "UC_artist", releases: [])
        let restored = YouTubeStore(defaults: defaults, musicOnly: true)
        XCTAssertTrue(restored.folder(folder, contains: .album(album))); XCTAssertTrue(restored.isFolderItemPinned(.album(album), in: folder))
        XCTAssertTrue(restored.hasReleaseSelection(for: "UC_artist")); XCTAssertEqual(restored.selectedReleases(for: "UC_artist", from: [album]), [])
        store.player.stop(); restored.player.stop()
    }
    func testDownloadPauseRemoveAndManifestRecoveryDoNotClaimMissingAudio() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let downloads = WatchDownloadStore(directory: directory, defaults: defaults)
        let track = song("abcdefghijk")
        downloads.add([track,track]); XCTAssertEqual(downloads.records.count, 1)
        XCTAssertNil(downloads.localURL(track.id)); XCTAssertTrue(downloads.songs.isEmpty)
        let transfer = downloads.records[0].transfer
        downloads.pause(track.id); XCTAssertEqual(downloads.records[0].state, .paused); XCTAssertNotEqual(downloads.records[0].transfer, transfer)
        let restored = WatchDownloadStore(directory: directory, defaults: defaults)
        XCTAssertEqual(restored.records.first?.state, .paused)
        restored.add([track]); XCTAssertEqual(restored.records.first?.state, .queued)
        restored.remove(track.id); XCTAssertTrue(restored.records.isEmpty)
    }
    func testOfflineSettingIsIndependentOfLibraryAndPersists() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let downloads = WatchDownloadStore(directory: directory, defaults: defaults)
        XCTAssertFalse(downloads.allowCellular); XCTAssertFalse(downloads.offlineOnly)
        downloads.offlineOnly = true
        XCTAssertTrue(WatchDownloadStore(directory: directory, defaults: defaults).offlineOnly)
        XCTAssertNil(defaults.data(forKey: "youtube.likedSongs"))
    }
    func testWatchSiriResolvesNamedSmartPlaylistWithoutNetwork() async throws {
        let store = YouTubeStore(defaults: defaults, musicOnly: true)
        let track = song("abcdefghijk"); store.toggleLike(track)
        let playlist = try XCTUnwrap(store.saveSmartPlaylist(name: "Walking Mix", rules: .init()))
        let intent = INPlayMediaIntent(mediaItems: nil, mediaContainer: nil, playShuffled: true, playbackRepeatMode: .all, resumePlayback: false, playbackQueueLocation: .now, playbackSpeed: 1, mediaSearch: INMediaSearch(mediaType: .playlist, sortOrder: .unknown, mediaName: "Walking Mix", artistName: nil, albumName: nil, genreNames: nil, moodNames: nil, releaseDate: nil, reference: .unknown, mediaIdentifier: nil))
        let result = try await MusicSiriResolver(store: store).targets(for: intent, search: { _,_ in XCTFail("Personal playlists must resolve locally"); return .init() })
        XCTAssertEqual(result.first?.item.identifier, "playlist:" + playlist.uuidString)
        store.player.stop()
    }
    func testSiriHandoffRetainsRemoteMetadataAndIsConsumedOnlyOnce() throws {
        let track = song("abcdefghijk", title: "A Catalog Recording")
        let original = INPlayMediaIntent(mediaItems: nil, mediaContainer: nil, playShuffled: false, playbackRepeatMode: .none, resumePlayback: false, playbackQueueLocation: .now, playbackSpeed: nil, mediaSearch: INMediaSearch(mediaType: .song, sortOrder: .unknown, mediaName: track.title, artistName: nil, albumName: nil, genreNames: nil, moodNames: nil, releaseDate: nil, reference: .unknown, mediaIdentifier: nil))
        let resolution = MusicSiriResolution(request: MusicSiriRequest(original), candidates: [.song(track)], rankedSongs: [track], hasCatalogSongs: true)
        WatchSiriHandoff.save(resolution, defaults: defaults)
        let resolved = INPlayMediaIntent(mediaItems: [MusicSiriTarget.song(track).item], mediaContainer: nil, playShuffled: false, playbackRepeatMode: .none, resumePlayback: false, playbackQueueLocation: .now, playbackSpeed: nil, mediaSearch: nil)
        let received = try XCTUnwrap(WatchSiriHandoff.consume(resolved, defaults: defaults))
        XCTAssertEqual(received.candidates.first?.item.identifier, "song:" + track.id)
        XCTAssertEqual(received.candidates.first?.item.title, track.title)
        XCTAssertEqual(received.rankedSongs, [track]); XCTAssertTrue(received.hasCatalogSongs)
        XCTAssertNil(WatchSiriHandoff.consume(resolved, defaults: defaults))
    }
    func testLyricsCalibrationAndPauseAtExplicitCueEnd() throws {
        let fit = try XCTUnwrap(LyricCalibration.fitted([.init(playback: 10, lyric: 12), .init(playback: 30, lyric: 32.2)]))
        XCTAssertEqual(fit.lyricTime(for: 30), 32.2, accuracy: 0.001)
        let lyrics = TrackLyrics(lines: [.init(id: 0, time: 1, text: "Line", endTime: 3)], plainText: nil, instrumental: false)
        XCTAssertEqual(lyrics.activeLine(at: 2), 0); XCTAssertNil(lyrics.activeLine(at: 3))
        XCTAssertEqual(try JSONDecoder().decode(TrackLyrics.self, from: JSONEncoder().encode(lyrics)), lyrics)
    }
    func testGitHubMergePreservesConcurrentRecordsAndDeletion() throws {
        let left = try NovaSyncDocument().updating(previous: [:], next: ["liked:abcdefghijk": .bool(true)], actor: UUID())
        let right = try NovaSyncDocument().updating(previous: [:], next: ["playlist:test": .string("Travel")], actor: UUID())
        let merged = try left.merging(right); XCTAssertEqual(merged.values.count, 2)
        let deleted = try merged.updating(previous: merged.values, next: ["playlist:test": .string("Travel")], actor: UUID())
        XCTAssertNil(try deleted.merging(left).values["liked:abcdefghijk"])
    }
    func testDownloadedAssetAcceptsCompleteAudioAndRejectsCorruptFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var wave = Data()
        func ascii(_ text: String) { wave.append(Data(text.utf8)) }
        func number<T: FixedWidthInteger>(_ value: T) { var little = value.littleEndian; withUnsafeBytes(of: &little) { wave.append(contentsOf: $0) } }
        ascii("RIFF"); number(UInt32(16036)); ascii("WAVEfmt "); number(UInt32(16)); number(UInt16(1)); number(UInt16(1)); number(UInt32(8000)); number(UInt32(16000)); number(UInt16(2)); number(UInt16(16)); ascii("data"); number(UInt32(16000)); wave.append(Data(repeating: 0, count: 16000))
        let file = directory.appendingPathComponent("complete.wav"); try wave.write(to: file)
        let duration = try await WatchDownloadedAsset.duration(of: file)
        XCTAssertEqual(duration, 1, accuracy: 0.01)
        let invalid = directory.appendingPathComponent("corrupt.m4a"); try Data("not audio".utf8).write(to: invalid)
        do { _ = try await WatchDownloadedAsset.duration(of: invalid); XCTFail("Invalid audio must never be marked downloaded") } catch {}
    }
    func testPhoneCommandsPreserveRevisionAndReceiptAcrossEncoding() throws {
        let command = WatchPhoneCommand(action: "remove", revision: UUID(), value: 2)
        let restored = try JSONDecoder().decode(WatchPhoneCommand.self, from: JSONEncoder().encode(command))
        XCTAssertEqual(restored.id, command.id); XCTAssertEqual(restored.revision, command.revision); XCTAssertEqual(restored.value, 2)
    }
}

@MainActor
extension WatchMusicTests {
    func testRemoteNowPlayingLaunchSelectsPhoneAndPresentsPlayer() {
        let bridge = WatchPhoneBridge.shared, navigation = WatchNavigation.shared
        let previousMode = bridge.mode, presented = navigation.player
        defer { bridge.mode = previousMode; navigation.player = presented }
        WatchApplicationDelegate().handleRemoteNowPlayingActivity()
        XCTAssertEqual(bridge.mode, .phone); XCTAssertTrue(navigation.player)
    }
    func testWatchIconAndAutoLaunchArePresentInPackagedApp() throws {
        let icons = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any])
        let primary = try XCTUnwrap(icons["CFBundlePrimaryIcon"] as? [String: Any])
        XCTAssertEqual(primary["CFBundleIconName"] as? String, "AppIcon")
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "PUICAutoLaunchAudioOptOut") as? Bool, false)
    }
    func testPhoneLyricsSnapshotRetainsCalibrationAndRejectsStaleUpdates() {
        let bridge = WatchPhoneBridge(session: nil)
        let song = song("abcdefghijk"), now = Date()
        let lyrics = TrackLyrics(lines: TrackLyrics.parseLRC("[00:00.00]First line\n[00:10.00]Second line"), plainText: nil, instrumental: false)
        var value = WatchPhoneSnapshot(revision: UUID(), song: song, playing: true, time: 12, duration: 120, queue: [song], index: 0, shuffle: false, repeatMode: "off", updated: now)
        value.lyrics = lyrics; value.calibration = .init(offset: 2, rate: 1)
        bridge.accept(value)
        value.time = 1; value.updated = now.addingTimeInterval(-10); bridge.accept(value)
        XCTAssertEqual(bridge.snapshot?.time, 12)
        XCTAssertEqual(bridge.snapshot?.lyrics, lyrics)
        XCTAssertEqual(bridge.snapshot?.calibration?.offset, 2)
    }
}

@MainActor
private final class WatchLargeLibraryCloud: NovaCloudStorage {
    var document = NovaSyncDocument()
    func accountID() async throws -> String { "large-watch-library" }
    func load(_ name: String) async throws -> NovaCloudSnapshot { .init(document: document, revision: "1") }
    func save(_ document: NovaSyncDocument, named: String, revision: String?) async throws { self.document = document }
}

@MainActor
extension WatchMusicTests {
    func testLibraryFilesMigratePreferencesAndSurviveReplacementAndRemoval() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = Data("existing saved playlists".utf8)
        defaults.set(original, forKey: "youtube.playlists"); defaults.set(true, forKey: "watch.icloud.enabled")
        let files = WatchLibraryDefaults(suiteName: domain, directory: directory)
        XCTAssertEqual(files.data(forKey: "youtube.playlists"), original)
        XCTAssertNil(defaults.data(forKey: "youtube.playlists"), "Migrated bulk records must leave preferences")
        XCTAssertTrue(files.bool(forKey: "watch.icloud.enabled"))
        let large = Data(repeating: 42, count: 1_200_000)
        files.set(large, forKey: "youtube.playlists")
        let relaunched = WatchLibraryDefaults(suiteName: domain, directory: directory)
        XCTAssertEqual(relaunched.data(forKey: "youtube.playlists"), large)
        XCTAssertEqual(relaunched.object(forKey: "youtube.playlists") as? Data, large)
        XCTAssertNil(defaults.data(forKey: "youtube.playlists"))
        relaunched.removeObject(forKey: "youtube.playlists")
        XCTAssertNil(files.data(forKey: "youtube.playlists"))
        files.set(original, forKey: "watch.collection.fixture"); files.set(nil, forKey: "watch.collection.fixture")
        XCTAssertNil(files.data(forKey: "watch.collection.fixture"))
    }
    func testLargePlaylistSurvivesStoreRelaunchOutsidePreferences() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = WatchLibraryDefaults(suiteName: domain, directory: directory)
        let store = YouTubeStore(defaults: files, musicOnly: true)
        let tracks = (0..<1000).map { song(String(format: "%011d", $0), title: String(repeating: "Long title ", count: 120) + String($0)) }
        let id = try XCTUnwrap(store.createPlaylist(named: "Large library", videos: tracks))
        XCTAssertGreaterThan(try XCTUnwrap(files.data(forKey: "youtube.playlists")).count, 1_048_576)
        XCTAssertNil(defaults.data(forKey: "youtube.playlists"))
        let restored = YouTubeStore(defaults: WatchLibraryDefaults(suiteName: domain, directory: directory), musicOnly: true)
        XCTAssertTrue(restored.playlist(id)?.videos == tracks, "Large playlist must reopen unchanged")
        store.player.stop(); restored.player.stop()
    }
    func testICloudStartupSavesLargeDocumentWithoutWatchPreferenceLimit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = WatchLibraryDefaults(suiteName: domain, directory: directory)
        let store = YouTubeStore(defaults: files, musicOnly: true), cloud = WatchLargeLibraryCloud()
        cloud.document = try NovaSyncDocument().updating(previous: [:], next: ["setting:largeFixture": .string(String(repeating: "library", count: 180_000))], actor: UUID())
        let account = MusicAccountSync(store: store, cloud: cloud)
        await account.bootstrap()
        XCTAssertTrue(account.cloudEnabled); XCTAssertNil(account.error); XCTAssertNotNil(account.lastSynced)
        let key = "watch.icloud.document.large-watch-library"
        let data = try XCTUnwrap(files.data(forKey: key))
        XCTAssertGreaterThan(data.count, 1_048_576)
        XCTAssertNil(defaults.data(forKey: key), "The cloud snapshot must never reach CFPreferences")
        XCTAssertEqual(try JSONDecoder().decode(NovaSyncDocument.self, from: data).values["setting:largeFixture"], cloud.document.values["setting:largeFixture"])
        account.disconnect(); store.player.stop()
    }
}
