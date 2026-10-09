import XCTest
@testable import NovaMusic

@MainActor
final class NovaMusicAccountSyncTests: XCTestCase {
    func testWebLibraryRoundTripAndPersistence() throws {
        let suite = "NovaMusic.SyncInterop.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = YouTubeStore(defaults: defaults, musicOnly: true)
        defer { store.close() }
        let playlistID = "00000000-0000-4000-8000-000000000001", folderID = "00000000-0000-4000-8000-000000000002"
        let json = #"{"song:abcdefghijk":{"id":"abcdefghijk","title":"A recording","artist":"A musician","album":"An album","source":"youtube","duration":120},"liked:abcdefghijk":{"id":"abcdefghijk","order":0},"saved:abcdefghijk":{"id":"abcdefghijk","order":0},"album:MPRE_test":{"id":"MPRE_test","title":"An album","artist":"A musician","tracks":["abcdefghijk"]},"savedAlbum:MPRE_test":{"id":"MPRE_test","order":0},"playlist:00000000-0000-4000-8000-000000000001":{"id":"00000000-0000-4000-8000-000000000001","name":"Web playlist","songs":["abcdefghijk"],"createdAt":1700000000000},"folder:00000000-0000-4000-8000-000000000002":{"id":"00000000-0000-4000-8000-000000000002","name":"Web folder","items":[{"kind":"playlist","id":"00000000-0000-4000-8000-000000000001"},{"kind":"album","id":"MPRE_test"}],"pins":["playlist:00000000-0000-4000-8000-000000000001"]},"releases:UCartist":[],"preference:genres":["Jazz"]}"#
        let values = try JSONDecoder().decode([String:NovaSyncValue].self,from:Data(json.utf8))
        try MusicAccountLibrary.apply(values,to:store)
        XCTAssertEqual(store.likedSongs.first?.title,"A recording")
        XCTAssertEqual(store.saved.first?.channel,"A musician")
        XCTAssertEqual(store.playlist(UUID(uuidString:playlistID)!)?.videos.first?.id,"abcdefghijk")
        XCTAssertEqual(store.musicFolder(UUID(uuidString:folderID)!)?.albums.first?.id,"MPRE_test")
        XCTAssertTrue(store.isFolderItemPinned(.playlist(UUID(uuidString:playlistID)!),in:UUID(uuidString:folderID)!))
        XCTAssertEqual(store.artistReleaseSelections["UCartist"],[])
        let exported = try MusicAccountLibrary.values(store,preserving:values)
        XCTAssertEqual(exported["playlist:"+playlistID]?["name"]?.string,"Web playlist")
        XCTAssertEqual(exported["folder:"+folderID]?["items"]?.array?.count,2)
        let restored = YouTubeStore(defaults:defaults,musicOnly:true)
        defer { restored.close() }
        XCTAssertEqual(restored.likedSongs.first?.id,"abcdefghijk")
        XCTAssertEqual(restored.playlists.first?.name,"Web playlist")
        XCTAssertEqual(restored.musicFolders.first?.name,"Web folder")
    }
    func testDiscSelectionSurvivesWithoutReleaseSelection() throws {
        let suite = "NovaMusic.SyncDiscs.\(UUID())", defaults = UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        let store = YouTubeStore(defaults:defaults,musicOnly:true)
        defer { store.close() }
        store.artistDiscSelections = ["UCfixture":["MPREfixture":[2],"MPREempty":[]]]
        let values = try MusicAccountLibrary.values(store)
        store.artistDiscSelections = [:]
        try MusicAccountLibrary.apply(values,to:store)
        XCTAssertEqual(store.artistDiscSelections["UCfixture"]?["MPREfixture"],[2])
        XCTAssertEqual(store.artistDiscSelections["UCfixture"]?["MPREempty"],[])
        XCTAssertNil(store.artistReleaseSelections["UCfixture"])
    }
    func testMalformedRemoteLibraryDoesNotReplaceExistingLibrary() throws {
        let suite = "NovaMusic.SyncValidation.\(UUID())", defaults = UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        let store = YouTubeStore(defaults:defaults,musicOnly:true)
        defer { store.close() }
        store.toggleLike(.placeholder("abcdefghijk"))
        let bad: [String:NovaSyncValue] = ["playlist:bad":.object(["id":.string("invalid"),"name":.string("Bad"),"songs":.array([])])]
        XCTAssertThrowsError(try MusicAccountLibrary.apply(bad,to:store))
        XCTAssertEqual(store.likedSongs.map(\.id),["abcdefghijk"])
    }
    func testOfflineEditsConvergeAndTombstonesPreventResurrection() throws {
        let a = UUID(uuidString:"00000000-0000-4000-8000-000000000001")!, b = UUID(uuidString:"00000000-0000-4000-8000-000000000002")!
        let base = try NovaSyncDocument().updating(previous:[:],next:["playlist:test":.string("Original")],actor:a)
        let deleted = try base.updating(previous:base.values,next:[:],actor:b)
        XCTAssertNil(try deleted.merging(base).values["playlist:test"])
        let left = try base.updating(previous:base.values,next:base.values.merging(["folder:left":.string("Left")],uniquingKeysWith:{_,new in new}),actor:a)
        let right = try base.updating(previous:base.values,next:base.values.merging(["folder:right":.string("Right")],uniquingKeysWith:{_,new in new}),actor:b)
        XCTAssertEqual(try left.merging(right),try right.merging(left))
        XCTAssertEqual(try left.merging(right).values.count,3)
    }
    func testNativeExportDoesNotContainProviderCredentials() throws {
        let suite = "NovaMusic.SyncSecrets.\(UUID())", defaults = UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        defaults.set("do-not-upload",forKey:"spotify.refreshToken")
        let store = YouTubeStore(defaults:defaults,musicOnly:true)
        defer { store.close() }
        let values = try MusicAccountLibrary.values(store)
        let text = String(data:try JSONEncoder().encode(values),encoding:.utf8)!
        XCTAssertFalse(text.contains("do-not-upload"))
        XCTAssertFalse(text.contains("refreshToken"))
    }
}
