import XCTest
import SwiftUI
@testable import NovaMusic

@MainActor
final class FolderRedesignTests: XCTestCase {
    private var sampleReleases: [YouTubeMusicAlbum] {
        [YouTubeMusicAlbum(id: "album-a", title: "The Original", artist: "Artist", artwork: nil),
         YouTubeMusicAlbum(id: "album-b", title: "The Original (Deluxe)", artist: "Artist", artwork: nil),
         YouTubeMusicAlbum(id: "album-c", title: "A New Single", artist: "Artist", artwork: nil)]
    }
    func testFolderOrderAcceptsOnlyCompleteMembershipAndKeepsPins() throws {
        let suite = "NovaMusic.Reorder.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = YouTubeStore(defaults: defaults, musicOnly: true)
        defer { store.close() }
        let folder = try XCTUnwrap(store.createMusicFolder(named: "Collections"))
        let album = MusicFolderItem.album(sampleReleases[0])
        let playlist = MusicFolderItem.playlist(try XCTUnwrap(store.createPlaylist(named: "Mix")))
        for item in [album, playlist] { store.setFolder(folder, contains: item, included: true) }
        store.toggleFolderItemPin(playlist, in: folder)
        store.setFolderItemOrder([playlist, album], in: folder)
        XCTAssertEqual(store.folderItems(folder), [playlist, album])
        store.setFolderItemOrder([album], in: folder)
        XCTAssertEqual(store.folderItems(folder), [playlist, album], "A stale drag cannot drop folder members")
        XCTAssertTrue(store.isFolderItemPinned(playlist, in: folder))
        let restored = YouTubeStore(defaults: defaults, musicOnly: true)
        defer { restored.close() }
        XCTAssertEqual(restored.folderItems(folder), [playlist, album])
    }

    func testFolderGalleryAndListHaveNativeDragAndCompactHeaders() async throws {
        let suite = "NovaMusic.FolderRedesign.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = YouTubeStore(defaults: defaults, musicOnly: true)
        let folder = try XCTUnwrap(store.createMusicFolder(named: "Walt Disney Animation Studios"))
        let cover = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 300)).image { context in
            UIColor.systemIndigo.setFill(); context.fill(CGRect(x: 0, y: 0, width: 300, height: 300))
            let text = "Evening\nMix" as NSString
            text.draw(in: CGRect(x: 24, y: 140, width: 250, height: 150), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 48), .foregroundColor: UIColor.white])
        }
        let filename = try MusicArtworkFiles.save(try XCTUnwrap(cover.jpegData(compressionQuality: 0.8)))
        defer { if let url = MusicArtworkFiles.url(filename) { try? FileManager.default.removeItem(at: url) } }
        let playlist = try XCTUnwrap(store.createPlaylist(named: "A long playlist title stays on a single line"))
        store.setArtwork(.init(style: .photo, photoFile: filename), for: .playlist(playlist))
        store.setArtwork(.init(style: .photo, photoFile: filename), for: .folder(folder))
        for album in sampleReleases { store.setFolder(folder, contains: .album(album), included: true) }
        store.setFolder(folder, contains: .playlist(playlist), included: true)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first { $0.session.role == .windowApplication } as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; store.close() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NovaFolderRedesign")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func findCollection(_ view: UIView) -> UICollectionView? {
            if let collection = view as? UICollectionView { return collection }
            return view.subviews.compactMap(findCollection).first
        }
        for gallery in [false, true] {
            store.setFolderGallery(gallery, in: folder)
            let host = UIHostingController(rootView: NavigationStack { MusicFolderDetailView(store: store, folderID: folder) }.preferredColorScheme(.dark))
            window.rootViewController = host; window.makeKeyAndVisible(); host.view.frame = window.bounds; host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(500))
            let collection = try XCTUnwrap(findCollection(host.view))
            XCTAssertTrue(collection.dragInteractionEnabled)
            XCTAssertNotNil(collection.dragDelegate); XCTAssertNotNil(collection.dropDelegate)
            XCTAssertEqual(collection.numberOfItems(inSection: 1), sampleReleases.count + 1)
            let header = try XCTUnwrap(collection.cellForItem(at: IndexPath(item: 0, section: 0)))
            XCTAssertLessThan(header.bounds.height, 240, "The header leaves room for the collections")
            let image = UIGraphicsImageRenderer(size: host.view.bounds.size).image { _ in host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true) }
            let url = directory.appendingPathComponent(gallery ? "Gallery.png" : "List.png")
            try XCTUnwrap(image.pngData()).write(to: url)
            print("NOVA_FOLDER_REDESIGN=\(url.path)")
        }
    }
}
