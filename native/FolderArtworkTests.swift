import XCTest
import UIKit
@testable import NovaMusic

@MainActor
final class FolderArtworkTests: XCTestCase {
    func testFolderArtworkTransfersPhotoBytesWithoutNativeFileReferences() throws {
        let suite="NovaMusic.FolderArtworkSync.\(UUID())",defaults=UserDefaults(suiteName:suite)!
        defer{defaults.removePersistentDomain(forName:suite)}
        let store=YouTubeStore(defaults:defaults,musicOnly:true);defer{store.close()}
        let image=UIGraphicsImageRenderer(size:CGSize(width:24,height:24)).image { context in UIColor.red.setFill();context.fill(CGRect(x:0,y:0,width:24,height:24)) }
        let data=try XCTUnwrap(image.jpegData(compressionQuality:0.8))
        let filename=try MusicArtworkFiles.save(data),id=UUID(),key="folder:\(id.uuidString.lowercased())"
        defer{if let url=MusicArtworkFiles.url(filename){try? FileManager.default.removeItem(at:url)}}
        var folder=MusicLibraryFolder(name:"Photo folder");folder.id=id;folder.artwork = .init(style:.photo,photoFile:filename)
        store.musicFolders=[folder]
        var values=try MusicAccountLibrary.values(store)
        let shared=try XCTUnwrap(values[key]?["collectionArtwork"])
        XCTAssertEqual(shared["style"]?.string,"photo");XCTAssertTrue(shared["image"]?.string?.hasPrefix("data:image/jpeg;base64,")==true)
        XCTAssertNil(shared["photoFile"])
        var record=try XCTUnwrap(values[key]?.object);record.removeValue(forKey:"native");values[key] = .object(record)
        try MusicAccountLibrary.apply(values,to:store)
        let imported=try XCTUnwrap(store.musicFolders.first?.artwork?.photoFile),url=try XCTUnwrap(MusicArtworkFiles.url(imported))
        defer{try? FileManager.default.removeItem(at:url)}
        XCTAssertNotNil(UIImage(contentsOfFile:url.path));XCTAssertNotEqual(imported,filename)
        XCTAssertEqual(try MusicAccountLibrary.values(store,preserving:values)[key]?["collectionArtwork"],shared)
        record["collectionArtwork"] = .object(["style":.string("icon"),"symbol":.string("heart.fill")]);values[key] = .object(record)
        try MusicAccountLibrary.apply(values,to:store);XCTAssertEqual(store.musicFolders.first?.artwork?.symbol,"heart.fill")
        record["collectionArtwork"] = .null;values[key] = .object(record)
        try MusicAccountLibrary.apply(values,to:store);XCTAssertNil(store.musicFolders.first?.artwork)
    }
}
