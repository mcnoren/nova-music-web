import XCTest
@testable import NovaMusic

@MainActor
final class PlaylistMembershipTests: XCTestCase {
    private var sampleReleases: [YouTubeMusicAlbum] {
        [YouTubeMusicAlbum(id: "album-a", title: "First", artist: "Artist", artwork: nil)]
    }

    func testFoldersPersistAlbumsAndPlaylistReferencesWithoutDeletingTheirContents() throws {
        let suite = "NovaMusic.Folders.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = YouTubeStore(defaults: defaults, musicOnly: true)
        defer { store.close() }
        XCTAssertNil(store.createMusicFolder(named: "   "))
        let first = try XCTUnwrap(store.createMusicFolder(named: " Road trips "))
        let second = try XCTUnwrap(store.createMusicFolder(named: "Favorites"))
        XCTAssertNil(store.createMusicFolder(named: "road TRIPS"))
        let playlist = try XCTUnwrap(store.createPlaylist(named: "Driving"))
        store.setFolder(first, contains: .album(sampleReleases[0]), included: true)
        store.setFolder(first, contains: .album(sampleReleases[0]), included: true)
        store.setFolder(first, contains: .playlist(playlist), included: true)
        store.setFolder(second, contains: .playlist(playlist), included: true)
        XCTAssertEqual(store.musicFolder(first)?.albums.count, 1)
        XCTAssertFalse(store.renameMusicFolder(first, to: "favorites"))
        XCTAssertTrue(store.renameMusicFolder(first, to: "Travel"))
        let restored = YouTubeStore(defaults: defaults, musicOnly: true)
        defer { restored.close() }
        XCTAssertEqual(restored.musicFolder(first)?.name, "Travel")
        XCTAssertTrue(restored.folder(first, contains: .album(sampleReleases[0])))
        XCTAssertTrue(restored.folder(first, contains: .playlist(playlist)))
        restored.renamePlaylist(playlist, to: "Driving mix")
        XCTAssertEqual(restored.playlist(restored.musicFolder(first)!.playlistIDs[0])?.name, "Driving mix")
        restored.setFolder(first, contains: .album(sampleReleases[0]), included: false)
        XCTAssertFalse(restored.folder(first, contains: .album(sampleReleases[0])))
        restored.deleteMusicFolder(first)
        XCTAssertNotNil(restored.playlist(playlist), "Deleting a folder leaves its playlist in the library")
        XCTAssertTrue(restored.folder(second, contains: .playlist(playlist)))
        restored.deletePlaylist(playlist)
        XCTAssertEqual(restored.musicFolder(second)!.playlistIDs, [playlist], "Removing library membership keeps folder references")
        XCTAssertNotNil(restored.playlist(playlist))
        XCTAssertTrue(restored.libraryPlaylists.isEmpty)
        let cloud = try MusicAccountLibrary.values(restored)
        XCTAssertEqual(cloud["playlist:\(playlist.uuidString.lowercased())"]?["folderOnly"], .bool(true))
        try MusicAccountLibrary.apply(cloud, to: store)
        XCTAssertTrue(store.libraryPlaylists.isEmpty)
        XCTAssertTrue(store.folder(second, contains: .playlist(playlist)))
        store.savePlaylistToLibrary(playlist)
        XCTAssertEqual(store.libraryPlaylists.map(\.id), [playlist])
    }

    func testFolderPinsAreLocalPersistAndSurviveLegacyFolderData() throws {
        let suite = "NovaMusic.FolderPins.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = YouTubeStore(defaults: defaults, musicOnly: true)
        let folder = try XCTUnwrap(store.createMusicFolder(named: "Mix"))
        let other = try XCTUnwrap(store.createMusicFolder(named: "Other"))
        let playlist = try XCTUnwrap(store.createPlaylist(named: "Favorites"))
        for id in [folder, other] {
            store.setFolder(id, contains: .album(sampleReleases[0]), included: true)
            store.setFolder(id, contains: .playlist(playlist), included: true)
        }
        let item = MusicFolderItem.playlist(playlist)
        store.toggleFolderItemPin(item, in: folder)
        XCTAssertEqual(store.folderItems(folder).map(\.id), [item.id, MusicFolderItem.album(sampleReleases[0]).id])
        XCTAssertFalse(store.isFolderItemPinned(item, in: other))
        let restored = YouTubeStore(defaults: defaults, musicOnly: true)
        defer { store.close(); restored.close() }
        XCTAssertTrue(restored.isFolderItemPinned(item, in: folder))
        restored.setFolder(folder, contains: item, included: false)
        XCTAssertFalse(restored.isFolderItemPinned(item, in: folder))
        restored.setFolder(folder, contains: item, included: true)
        XCTAssertFalse(restored.isFolderItemPinned(item, in: folder), "Readding an item does not revive an old pin")
        restored.toggleFolderItemPin(item, in: folder)
        restored.deletePlaylist(playlist)
        XCTAssertTrue(restored.isFolderItemPinned(item, in: folder))
        XCTAssertNotNil(restored.playlist(playlist))
        let legacy = Data("{\"id\":\"\(UUID())\",\"name\":\"Older folder\",\"albums\":[],\"playlistIDs\":[]}".utf8)
        let decoded = try JSONDecoder().decode(MusicLibraryFolder.self, from: legacy)
        XCTAssertEqual(decoded.name, "Older folder")
        XCTAssertNil(decoded.pinnedItemIDs)
    }
}
