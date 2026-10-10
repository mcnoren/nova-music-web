import XCTest
import UIKit
@testable import NovaMusic

@MainActor
final class NovaMusicAccountSyncTests: XCTestCase {
    func testPlaylistArtworkTransfersPhotoBytesWithoutNativeFileReferences() throws {
        let suite="NovaMusic.ArtworkSync.\(UUID())",defaults=UserDefaults(suiteName:suite)!
        defer{defaults.removePersistentDomain(forName:suite)}
        let store=YouTubeStore(defaults:defaults,musicOnly:true);defer{store.close()}
        let image=UIGraphicsImageRenderer(size:CGSize(width:24,height:24)).image { context in UIColor.red.setFill();context.fill(CGRect(x:0,y:0,width:24,height:24)) }
        let data=try XCTUnwrap(image.jpegData(compressionQuality:0.8))
        let filename=try MusicArtworkFiles.save(data),id=UUID(),key="playlist:\(id.uuidString.lowercased())"
        defer{if let url=MusicArtworkFiles.url(filename){try? FileManager.default.removeItem(at:url)}}
        var playlist=YouTubePlaylist(name:"Photo playlist");playlist.id=id;playlist.customArtwork = .init(style:.photo,photoFile:filename)
        store.playlists=[playlist]
        var values=try MusicAccountLibrary.values(store)
        let shared=try XCTUnwrap(values[key]?["collectionArtwork"])
        XCTAssertEqual(shared["style"]?.string,"photo");XCTAssertTrue(shared["image"]?.string?.hasPrefix("data:image/jpeg;base64,")==true)
        XCTAssertNil(shared["photoFile"])
        var record=try XCTUnwrap(values[key]?.object);record.removeValue(forKey:"native");values[key] = .object(record)
        try MusicAccountLibrary.apply(values,to:store)
        let imported=try XCTUnwrap(store.playlists.first?.customArtwork?.photoFile),url=try XCTUnwrap(MusicArtworkFiles.url(imported))
        defer{try? FileManager.default.removeItem(at:url)}
        XCTAssertNotNil(UIImage(contentsOfFile:url.path));XCTAssertNotEqual(imported,filename)
        XCTAssertEqual(try MusicAccountLibrary.values(store,preserving:values)[key]?["collectionArtwork"],shared)
        record["collectionArtwork"] = .object(["style":.string("icon"),"symbol":.string("heart.fill")]);values[key] = .object(record)
        try MusicAccountLibrary.apply(values,to:store);XCTAssertEqual(store.playlists.first?.customArtwork?.symbol,"heart.fill")
        record["collectionArtwork"] = .null;values[key] = .object(record)
        try MusicAccountLibrary.apply(values,to:store);XCTAssertNil(store.playlists.first?.customArtwork)
    }
    func testChosenReleaseMetadataAndArtistPlaylistIdentitySurviveSync() throws {
        let suite="NovaMusic.ReleaseArtworkSync.\(UUID())",defaults=UserDefaults(suiteName:suite)!
        defer{defaults.removePersistentDomain(forName:suite)}
        let store=YouTubeStore(defaults:defaults,musicOnly:true);defer{store.close()}
        let artist=YouTubeChannel(id:"UCartist",name:"Artist",path:"/channel/UCartist")
        let album=YouTubeMusicAlbum(id:"MPREchosen",title:"Chosen EP",artist:"Artist",artwork:nil,kind:"EP")
        store.artistReleaseSelections[artist.id]=[album]
        var playlist=YouTubePlaylist(name:"Artist playlist");playlist.artist=artist;playlist.customArtwork = .init(style:.collage);store.playlists=[playlist]
        let values=try MusicAccountLibrary.values(store),key="playlist:\(playlist.id.uuidString.lowercased())"
        XCTAssertEqual(values["album:MPREchosen"]?["artistId"]?.string,artist.id)
        XCTAssertEqual(values[key]?["artistId"]?.string,artist.id)
        XCTAssertNotNil(values["artist:UCartist"])
        try MusicAccountLibrary.apply(values,to:store)
        XCTAssertEqual(store.artistReleaseSelections[artist.id]?.first?.kind,"EP")
        XCTAssertEqual(store.playlists.first?.artist?.id,artist.id);XCTAssertEqual(store.playlists.first?.customArtwork?.style,.collage)
    }
    func testMalformedSharedArtworkDoesNotReplaceTheLibrary() throws {
        let suite="NovaMusic.InvalidArtwork.\(UUID())",defaults=UserDefaults(suiteName:suite)!
        defer{defaults.removePersistentDomain(forName:suite)}
        let store=YouTubeStore(defaults:defaults,musicOnly:true);defer{store.close()}
        let playlist=YouTubePlaylist(name:"Keep me");store.playlists=[playlist]
        var values=try MusicAccountLibrary.values(store),key="playlist:\(playlist.id.uuidString.lowercased())",record=values["playlist:\(playlist.id.uuidString.lowercased())"]!.object!
        record["collectionArtwork"] = .object(["style":.string("photo"),"image":.string("file:///private/photo.jpg")]);values[key] = .object(record)
        XCTAssertThrowsError(try MusicAccountLibrary.apply(values,to:store));XCTAssertEqual(store.playlists,[playlist])
    }
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
