import XCTest
@testable import NovaMusic

@MainActor
final class FolderOrganizationTests: XCTestCase {
    func testFolderDragAndReplacementPreserveMixedOrderAndSync() throws {
        let sampleReleases = [
            YouTubeMusicAlbum(id: "album-a", title: "First", artist: "Artist", artwork: nil),
            YouTubeMusicAlbum(id: "album-b", title: "Second", artist: "Artist", artwork: nil),
            YouTubeMusicAlbum(id: "album-c", title: "Replacement", artist: "Artist", artwork: nil)
        ]
        let suite = "NovaMusic.FolderOrder.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = YouTubeStore(defaults: defaults, musicOnly: true)
        defer { store.close() }
        let folder = try XCTUnwrap(store.createMusicFolder(named: "Order"))
        let playlist = MusicFolderItem.playlist(try XCTUnwrap(store.createPlaylist(named: "Mix")))
        let a = MusicFolderItem.album(sampleReleases[0]), b = MusicFolderItem.album(sampleReleases[1])
        for item in [a, playlist, b] { store.setFolder(folder, contains: item, included: true) }
        store.moveFolderItem(playlist, to: b, in: folder)
        XCTAssertEqual(store.folderItems(folder), [a, playlist, b])
        store.toggleFolderItemPin(b, in: folder)
        let replacement = MusicFolderItem.album(sampleReleases[2])
        store.replaceFolderItem(b, with: replacement, in: folder)
        XCTAssertEqual(store.folderItems(folder), [a, playlist, replacement])
        XCTAssertTrue(store.isFolderItemPinned(replacement, in: folder))
        store.setFolderGallery(true, in: folder)
        let restored = YouTubeStore(defaults: defaults, musicOnly: true)
        defer { restored.close() }
        XCTAssertEqual(restored.folderItems(folder), [a, playlist, replacement])
        XCTAssertEqual(restored.musicFolder(folder)?.gallery, true)
        let cloud = try MusicAccountLibrary.values(store)
        let record = try XCTUnwrap(cloud["folder:\(folder.uuidString.lowercased())"])
        XCTAssertEqual(record["items"]?.array?.compactMap { $0["id"]?.string }, [sampleReleases[0].id, playlist.id.replacingOccurrences(of: "playlist:", with: "").lowercased(), sampleReleases[2].id])
        try MusicAccountLibrary.apply(cloud, to: restored)
        XCTAssertEqual(restored.folderItems(folder), [a, playlist, replacement])
        store.replaceFolderItem(replacement, with: a, in: folder)
        XCTAssertEqual(store.folderItems(folder), [a, playlist, replacement], "An existing member cannot replace another slot")
    }

}
