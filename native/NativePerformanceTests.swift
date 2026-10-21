import XCTest
import SwiftUI
import UIKit
@testable import NovaMusic


@MainActor
final class NativePerformanceTests: XCTestCase {
    func testLargeSongListIndexesSectionsOnce() {
        let songs = (0..<2000).map { YouTubeVideo(id: String(format: "%011d", $0), title: "Song \($0)", channel: "Artist") }
        var sectionVisits = 0
        let rows = MusicNativeSelectionRows(items: songs, selecting: .constant(false), selected: .constant(Set<String>()), sectionTitle: { _ in
            sectionVisits += 1; return "Disc 1"
        }, activate: { _ in }) { Text($0.title) }
        let coordinator = rows.makeCoordinator()
        XCTAssertEqual(sectionVisits, 2000)
        for index in songs.indices { XCTAssertEqual(coordinator.item(at: IndexPath(row: index, section: 0))?.id, songs[index].id) }
        XCTAssertEqual(sectionVisits, 2000, "Configuring rows must not rebuild the full section index")
        XCTAssertEqual(coordinator.pathsByID[songs.last!.id], IndexPath(row: 1999, section: 0))
    }

    func testLargeEmbeddedSongListMountsOnlyViewportAndScrollsToEnd() async throws {
        let songs = (0..<2000).map { YouTubeVideo(id: String(format: "%011d", $0), title: "Song \($0)", channel: "Artist") }
        let rows = MusicNativeSelectionRows(items: songs, selecting: .constant(false), selected: .constant(Set<String>()), activate: { _ in }) { Text($0.title) }
        let host = UIHostingController(rootView: ScrollView { rows.frame(height: CGFloat(songs.count) * 76) })
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene); window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(300))
        func viewport(_ view: UIView) -> MusicSelectionViewport? {
            if let result = view as? MusicSelectionViewport { return result }
            return view.subviews.compactMap(viewport).first
        }
        let container = try XCTUnwrap(viewport(host.view)), table = container.table
        XCTAssertEqual(table.numberOfRows(inSection: 0), 2000)
        XCTAssertGreaterThan(table.visibleCells.count, 0)
        XCTAssertLessThan(table.visibleCells.count, 35)
        XCTAssertLessThan(table.bounds.height, 1500)
        var ancestor = container.superview
        while ancestor != nil && !(ancestor is UIScrollView) { ancestor = ancestor?.superview }
        let scroll = try XCTUnwrap(ancestor as? UIScrollView)
        scroll.setContentOffset(CGPoint(x: 0, y: max(0, scroll.contentSize.height - scroll.bounds.height)), animated: false)
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(table.indexPathsForVisibleRows?.last?.row, 1999)
        XCTAssertLessThan(table.visibleCells.count, 35)
        print("NOVA_PERFORMANCE songRows=2000 mounted=\(table.visibleCells.count) viewportHeight=\(table.bounds.height)")
    }

    func testLargeFolderRefreshTouchesOnlyMountedRows() async throws {
        let songs = (0..<2000).map { YouTubeVideo(id: String(format: "%011d", $0), title: "Song \($0)", channel: "Artist") }
        var configured = 0
        let collection = MusicReorderableCollection(items: songs, onMove: { _, _ in }) { Text("Folder") } row: { song in
            configured += 1; return Text(song.title)
        }
        let coordinator = collection.makeCoordinator()
        let layout = UICollectionViewFlowLayout(); layout.itemSize = CGSize(width: 300, height: 80)
        let view = UICollectionView(frame: CGRect(x: 0, y: 0, width: 340, height: 600), collectionViewLayout: layout)
        view.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "music")
        coordinator.configure(view); view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let before = configured
        coordinator.update(); view.layoutIfNeeded()
        XCTAssertEqual(view.numberOfItems(inSection: 1), 2000)
        XCTAssertGreaterThan(configured - before, 0)
        XCTAssertLessThan(configured - before, 30, "Refreshing playback/selection must not configure offscreen rows")
        XCTAssertNotNil(view.dragDelegate); XCTAssertNotNil(view.dropDelegate)
        print("NOVA_PERFORMANCE folderItems=2000 refreshRows=\(configured - before)")
    }

    func testPlaybackCheckpointDoesNotRewriteLargeQueueAndRestoresPosition() throws {
        let suite = "NovaMusic.Performance.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let songs = (0..<2000).map { YouTubeVideo(id: String(format: "%011d", $0), title: "Song \($0)", channel: "Artist") }
        let player = YouTubePlayer(defaults: defaults), store = YouTubeStore(defaults: defaults, musicOnly: true, player: player)
        defer { store.close() }
        store.current = songs[0]; store.queueVideos = songs
        player.restoreMusicSession(tracks: songs, entries: [], index: 0, position: 5, duration: 180, shuffle: false, repeatMode: .off)
        store.saveMusicSession()
        let queue = try XCTUnwrap(defaults.data(forKey: "music.lastPlaybackSession"))
        for position in 6...100 { player.currentTime = Double(position); store.saveMusicPosition() }
        XCTAssertEqual(defaults.data(forKey: "music.lastPlaybackSession"), queue)
        let checkpoint = try XCTUnwrap(defaults.data(forKey: "music.lastPlaybackPosition"))
        XCTAssertLessThan(checkpoint.count, 200)
        let reopened = YouTubeStore(defaults: defaults, musicOnly: true)
        XCTAssertEqual(reopened.player.currentTime, 100); XCTAssertEqual(reopened.player.playlistIDs.count, 2000)
        reopened.close()
        // A stale checkpoint from another song cannot move the restored clock.
        defaults.set(queue, forKey: "music.lastPlaybackSession")
        defaults.set(Data(#"{"songID":"zzzzzzzzzzz","position":120,"duration":180}"#.utf8), forKey: "music.lastPlaybackPosition")
        let stale = YouTubeStore(defaults: defaults, musicOnly: true)
        XCTAssertEqual(stale.player.currentTime, 5); stale.close()
        print("NOVA_PERFORMANCE sessionBytes=\(queue.count) checkpointBytes=\(checkpoint.count)")
    }

    func testFolderPhotoCacheDownsamplesAndReusesDecodedCover() throws {
        let original = UIGraphicsImageRenderer(size: CGSize(width: 768, height: 768)).image { context in
            UIColor.systemIndigo.setFill(); context.fill(CGRect(x: 0, y: 0, width: 768, height: 768))
        }
        let filename = try MusicArtworkFiles.save(try XCTUnwrap(original.jpegData(compressionQuality: 0.8)))
        defer { if let url = MusicArtworkFiles.url(filename) { try? FileManager.default.removeItem(at: url) } }
        let small = try XCTUnwrap(MusicFolderArtworkCache.image(filename, pixels: 120))
        let again = try XCTUnwrap(MusicFolderArtworkCache.image(filename, pixels: 120))
        XCTAssertTrue(small === again)
        let decoded = try XCTUnwrap(small.cgImage)
        XCTAssertLessThanOrEqual(decoded.width, 128)
        XCTAssertLessThan(decoded.bytesPerRow * decoded.height, 100_000)
        let large = try XCTUnwrap(MusicFolderArtworkCache.image(filename, pixels: 600))
        XCTAssertGreaterThan(large.size.width, small.size.width)
    }
}


@MainActor
extension NativePerformanceTests {
    func testSelectionViewportReleasesDragDisplayLinkOnRemoval() {
        let rows = MusicNativeSelectionRows(items: [YouTubeVideo.placeholder("aaaaaaaaaaa")], selecting: .constant(false), selected: .constant(Set<String>()), activate: { _ in }) { Text($0.title) }
        let coordinator = rows.makeCoordinator()
        let table = MusicSelectionTableView(), viewport = MusicSelectionViewport(table: table)
        table.dataSource = coordinator; table.delegate = coordinator
        let link = CADisplayLink(target: coordinator, selector: NSSelectorFromString("scrollAtEdge"))
        link.add(to: .main, forMode: .common); coordinator.edgeDisplayLink = link; coordinator.interacting = true
        type(of: rows).dismantleUIView(viewport, coordinator: coordinator)
        XCTAssertNil(coordinator.edgeDisplayLink); XCTAssertFalse(coordinator.interacting)
        XCTAssertNil(table.dataSource); XCTAssertNil(table.delegate)
    }
}
