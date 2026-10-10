import XCTest
import AVFoundation
import UIKit
@testable import NovaMusic

private final class ConnectedPlaybackURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var server: ConnectedPlaybackTestServer?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let request = request
        Task {
            do {
                let data = try await Self.server!.response(request)
                client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed)
                client?.urlProtocol(self,didLoad:data); client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self,didFailWithError:error) }
        }
    }
    override func stopLoading() {}
}
private actor ConnectedPlaybackTestServer {
    let mac = "00000000-0000-4000-8000-000000000002"
    var document: NovaSyncDocument
    var revision = 1
    init(expired: Bool = false, age: Double = 0, position: Double = 4, playing: Bool = false) throws {
        let now = Date().timeIntervalSince1970 * 1000 - (expired ? 300000 : age * 1000)
        let song = MusicConnectedSong(YouTubeVideo(id:"abcdefghijk",title:"Mac recording",channel:"An artist",thumbnail:nil,durationLabel:"0:20"))
        let lyrics = MusicConnectedLyrics(songID:song.id,recordingID:"lmnopqrstuv",loaded:true,plain:"First\nSecond",lines:[.init(time:0,text:"First",endTime:5),.init(time:5,text:"Second",endTime:20)],instrumental:false,source:"Mac provider",sourceURL:"https://lrclib.net",offset:1.25,rate:1.02)
        let snapshot = MusicConnectedSnapshot(queue:[song],position:position,playing:playing || expired,at:now,lyrics:lyrics)
        let session = MusicConnectedSession(owner:mac,command:UUID().uuidString.lowercased(),at:now,snapshot:snapshot)
        document = try NovaSyncDocument().updating(previous:[:],next:["connect:session":.encoded(session),"connect:device."+mac:.encoded(MusicConnectedDevice(id:mac,name:"Mac browser",at:now))],actor:UUID(uuidString:mac)!)
    }
    func session() throws -> MusicConnectedSession { try document.values["connect:session"]!.decoded(MusicConnectedSession.self) }
    func confirmPlayback(_ playing: Bool, loading: Bool = false) throws {
        let current = try session()
        var status = current.snapshot; status.owner = current.owner; status.command = current.command; status.playing = playing; status.loading = loading
        let old = document.values; var next = old; next["connect:status"] = try .encoded(status)
        document = try document.updating(previous:old,next:next,actor:UUID(uuidString:mac)!); revision += 1
    }
    func sendPositionCommand(_ position: Double, playing: Bool, intent: String) throws {
        var current = try session(); current.command = UUID().uuidString.lowercased(); current.at = Date().timeIntervalSince1970 * 1000
        current.snapshot.position = position; current.snapshot.playing = playing; current.snapshot.positionIntent = intent
        let old = document.values; var next = old; next["connect:session"] = try .encoded(current)
        document = try document.updating(previous:old,next:next,actor:UUID(uuidString:mac)!); revision += 1
    }
    func response(_ request: URLRequest) throws -> Data {
        let path = request.url!.path
        if path == "/auth/v1/token" {
            return Data(#"{"access_token":"test-access","refresh_token":"test-refresh","expires_in":3600,"user":{"id":"00000000-0000-4000-8000-000000000001","email":"test@example.com"}}"#.utf8)
        }
        if path == "/rest/v1/nova_music_libraries" { return try JSONEncoder().encode(NovaSyncValue.array([.object(["document":.encoded(document),"revision":.number(Double(revision))])])) }
        if path == "/rest/v1/rpc/save_nova_music_library" {
            var body = request.httpBody ?? Data()
            if body.isEmpty, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating:0,count:4096)
                while stream.hasBytesAvailable { let count = stream.read(&buffer,maxLength:buffer.count); if count <= 0 { break }; body.append(buffer,count:count) }
            }
            let input = try JSONDecoder().decode(NovaSyncValue.self,from:body)
            if input["expected_revision"]?.safeInt != revision { return Data("{\"conflict\":true,\"revision\":\(revision)}".utf8) }
            document = try input["library_document"]!.decoded(NovaSyncDocument.self); revision += 1
            let current = try session()
            if current.owner == mac, let handoff = current.snapshot.handoff {
                var status = current.snapshot; status.owner = mac; status.command = current.command; status.handoff = handoff; status.playing = false
                let old = document.values; var next = old; next["connect:status"] = try .encoded(status)
                document = try document.updating(previous:old,next:next,actor:UUID(uuidString:mac)!)
            }
            return Data("{\"conflict\":false,\"revision\":\(revision)}".utf8)
        }
        return Data("{}".utf8)
    }
}

@MainActor
final class MusicConnectedPlaybackTests: XCTestCase {
    private func makeAudioFixture(seconds: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MusicQueue-\(UUID()).caf")
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false])
        let length = AVAudioFrameCount(seconds * 44100)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: length))
        buffer.frameLength = length
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<Int(length) { samples[index] = Float(sin(Double(index) * 2 * .pi * 440 / 44100) * 0.1) }
        try file.write(from: buffer)
        return url
    }
    func testConnectedPlaybackRoutesPhoneSelectionToMacAndTransfersQueueBack() async throws {
        let file = try makeAudioFixture(seconds:20)
        defer { try? FileManager.default.removeItem(at:file) }
        let suite = "NovaMusic.Connect.\(UUID())", defaults = UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        let player = YouTubePlayer(defaults:defaults,streamSourceProvider:{ _,_ in .init(url:file,isLive:false) })
        let store = YouTubeStore(defaults:defaults,musicOnly:true,player:player)
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [ConnectedPlaybackURLProtocol.self]
        let network = URLSession(configuration:configuration)
        let server = try ConnectedPlaybackTestServer(); ConnectedPlaybackURLProtocol.server = server
        var credentials: Data?
        let storage = MusicAccountCredentialStorage(read:{ credentials },save:{ credentials = $0 },delete:{ credentials = nil })
        let account = MusicAccountSync(store:store,network:network,credentialService:suite,credentialStorage:storage)
        store.musicAccount = account
        try await account.signIn(email:"test@example.com",password:"Fixture-password-123!",mergeGuest:false)
        XCTAssertTrue(account.controlsRemoteOutput)
        XCTAssertEqual(store.current?.title,"Mac recording")
        XCTAssertEqual(player.trackLyrics?.source,"Mac provider")
        XCTAssertEqual(player.lyricCalibration,LyricCalibration(offset:1.25,rate:1.02))
        XCTAssertEqual(player.trackLyrics?.activeLine(at:player.lyricTime),1)
        XCTAssertEqual(player.currentTime,4,accuracy:0.05)
        XCTAssertNil(player.nativePlayer.currentItem,"Mirroring must not start audio on the phone")
        player.play()
        XCTAssertEqual(player.connectedPendingPlaying,true)
        XCTAssertFalse(player.playing)
        for _ in 0..<100 { if try await server.session().snapshot.playing { break }; try await Task.sleep(for:.milliseconds(20)) }
        try await server.confirmPlayback(false); await account.sync()
        XCTAssertEqual(player.connectedPendingPlaying,true,"Loading is not a Play acknowledgement")
        try await server.confirmPlayback(true); await account.sync()
        XCTAssertNil(player.connectedPendingPlaying); XCTAssertTrue(player.playing)
        player.pause(); XCTAssertEqual(player.connectedPendingPlaying,false)
        for _ in 0..<100 { if try await !server.session().snapshot.playing { break }; try await Task.sleep(for:.milliseconds(20)) }
        try await server.confirmPlayback(false); await account.sync()
        XCTAssertNil(player.connectedPendingPlaying); XCTAssertFalse(player.playing)
        let song = YouTubeVideo(id:"lmnopqrstuv",title:"Phone selection",channel:"Another artist",thumbnail:nil,durationLabel:"0:20")
        store.play(song,music:true,queue:[song,.placeholder("abcdefghijk")])
        for _ in 0..<100 { if try await server.session().snapshot.queue.first?.id == song.id { break }; try await Task.sleep(for:.milliseconds(20)) }
        var session = try await server.session()
        XCTAssertEqual(session.owner,"00000000-0000-4000-8000-000000000002")
        XCTAssertEqual(session.snapshot.queue.map(\.id),[song.id,"abcdefghijk"])
        XCTAssertNil(player.nativePlayer.currentItem)
        player.seek(to:7); player.pause()
        for _ in 0..<100 { let next = try await server.session(); if abs(next.snapshot.position - 7) < 0.1 && !next.snapshot.playing { break }; try await Task.sleep(for:.milliseconds(20)) }
        session = try await server.session()
        XCTAssertEqual(session.snapshot.position,7,accuracy:0.1); XCTAssertFalse(session.snapshot.playing)
        let phone = defaults.string(forKey:"music.sync.device")!.lowercased()
        account.selectOutput(phone)
        XCTAssertEqual(account.pendingOutputID,phone,"Speaker selection must show loading immediately")
        for _ in 0..<150 { if player.ready && !account.controlsRemoteOutput { break }; try await Task.sleep(for:.milliseconds(20)) }
        try await server.confirmPlayback(false,loading:true); await account.sync()
        XCTAssertEqual(account.pendingOutputID,phone,"A buffering output must not show a completion checkmark")
        try await server.confirmPlayback(false); await account.sync()
        XCTAssertNil(account.pendingOutputID)
        XCTAssertFalse(account.controlsRemoteOutput)
        XCTAssertEqual(player.playlistIDs,[song.id,"abcdefghijk"])
        XCTAssertEqual(player.currentVideoID,song.id)
        XCTAssertFalse(player.intendsPlayback)
        XCTAssertEqual(player.currentTime,7,accuracy:0.5)
        try await account.signOut(); store.close(); network.invalidateAndCancel()
        ConnectedPlaybackURLProtocol.server = nil
    }
    func testConnectedPlaybackIntentIsImmediateAndClosedOutputCanBeReplaced() async throws {
        let file = try makeAudioFixture(seconds:20)
        defer { try? FileManager.default.removeItem(at:file) }
        let suite = "NovaMusic.ConnectIntent.\(UUID())", defaults = UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        let player = YouTubePlayer(defaults:defaults,streamSourceProvider:{ _,_ in .init(url:file,isLive:false) })
        let store = YouTubeStore(defaults:defaults,musicOnly:true,player:player)
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [ConnectedPlaybackURLProtocol.self]
        let network = URLSession(configuration:configuration)
        let server = try ConnectedPlaybackTestServer(expired:true,position:8)
        ConnectedPlaybackURLProtocol.server = server
        var credentials: Data?
        let storage = MusicAccountCredentialStorage(read:{ credentials },save:{ credentials = $0 },delete:{ credentials = nil })
        let account = MusicAccountSync(store:store,network:network,credentialService:suite,credentialStorage:storage)
        store.musicAccount = account
        try await account.signIn(email:"test@example.com",password:"Fixture-password-123!",mergeGuest:false)
        player.play()
        XCTAssertEqual(player.connectedPendingPlaying,true)
        XCTAssertTrue(player.displayedPlaybackIntent)
        XCTAssertFalse(player.playing,"An intent must not start the remote playback clock")
        player.toggle()
        XCTAssertEqual(player.connectedPendingPlaying,false)
        for _ in 0..<100 { if account.outputError != nil && player.connectedPendingPlaying == nil { break }; try await Task.sleep(for:.milliseconds(20)) }
        XCTAssertNil(player.connectedPendingPlaying,"Rejected offline commands must stop loading")
        let phone = defaults.string(forKey:"music.sync.device")!.lowercased()
        account.selectOutput(phone)
        XCTAssertEqual(account.pendingOutputID,phone,"Speaker selection must show loading immediately")
        for _ in 0..<150 { if player.ready && !account.controlsRemoteOutput { break }; try await Task.sleep(for:.milliseconds(20)) }
        try await server.confirmPlayback(false,loading:true); await account.sync()
        XCTAssertEqual(account.pendingOutputID,phone,"A buffering output must not show a completion checkmark")
        try await server.confirmPlayback(false); await account.sync()
        XCTAssertNil(account.pendingOutputID)
        XCTAssertEqual(account.outputID,phone)
        XCTAssertFalse(account.controlsRemoteOutput)
        XCTAssertEqual(player.currentTime,8,accuracy:0.5)
        XCTAssertFalse(player.playing)
        XCTAssertNil(account.outputError)
        try await account.signOut();store.close();network.invalidateAndCancel();ConnectedPlaybackURLProtocol.server = nil
    }
    func testConnectedPlaybackReopensAnExpiredOutputAtItsConfirmedPositionPaused() async throws {
        let file = try makeAudioFixture(seconds:20)
        defer { try? FileManager.default.removeItem(at:file) }
        let suite = "NovaMusic.ConnectRecovery.\(UUID())", defaults = UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        defaults.set("00000000-0000-4000-8000-000000000002",forKey:"music.sync.device")
        let player = YouTubePlayer(defaults:defaults,streamSourceProvider:{ _,_ in .init(url:file,isLive:false) })
        let store = YouTubeStore(defaults:defaults,musicOnly:true,player:player)
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [ConnectedPlaybackURLProtocol.self]
        let network = URLSession(configuration:configuration)
        ConnectedPlaybackURLProtocol.server = try ConnectedPlaybackTestServer(expired:true)
        var credentials: Data?
        let storage = MusicAccountCredentialStorage(read:{ credentials },save:{ credentials = $0 },delete:{ credentials = nil })
        let account = MusicAccountSync(store:store,network:network,credentialService:suite,credentialStorage:storage)
        store.musicAccount = account
        try await account.signIn(email:"test@example.com",password:"Fixture-password-123!",mergeGuest:false)
        for _ in 0..<150 { if player.ready { break }; try await Task.sleep(for:.milliseconds(20)) }
        XCTAssertFalse(account.controlsRemoteOutput)
        XCTAssertEqual(store.current?.id,"abcdefghijk")
        XCTAssertEqual(player.currentTime,4,accuracy:0.5)
        XCTAssertFalse(player.intendsPlayback)
        try await account.signOut(); store.close(); network.invalidateAndCancel()
        ConnectedPlaybackURLProtocol.server = nil
    }
    func testConnectedPlaybackTransportAndQueueEditsPreserveAudibleClock() async throws {
        let file = try makeAudioFixture(seconds:20)
        defer { try? FileManager.default.removeItem(at:file) }
        let suite = "NovaMusic.ConnectTransport.\(UUID())", defaults = UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        defaults.set("00000000-0000-4000-8000-000000000002",forKey:"music.sync.device")
        var loads = 0
        let player = YouTubePlayer(defaults:defaults,streamSourceProvider:{ _,_ in loads += 1; return .init(url:file,isLive:false) })
        let store = YouTubeStore(defaults:defaults,musicOnly:true,player:player)
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [ConnectedPlaybackURLProtocol.self]
        let network = URLSession(configuration:configuration)
        let server = try ConnectedPlaybackTestServer()
        ConnectedPlaybackURLProtocol.server = server
        var credentials: Data?
        let storage = MusicAccountCredentialStorage(read:{ credentials },save:{ credentials = $0 },delete:{ credentials = nil })
        let account = MusicAccountSync(store:store,network:network,credentialService:suite,credentialStorage:storage)
        store.musicAccount = account
        try await account.signIn(email:"test@example.com",password:"Fixture-password-123!",mergeGuest:false)
        for _ in 0..<150 { if player.ready { break }; try await Task.sleep(for:.milliseconds(20)) }
        player.pause(); player.seek(to:9)
        for _ in 0..<100 { if abs(player.nativePlayer.currentTime().seconds - 9) < 0.02 { break }; try await Task.sleep(for:.milliseconds(10)) }
        try await server.sendPositionCommand(4,playing:false,intent:"preserve"); await account.sync()
        XCTAssertEqual(player.nativePlayer.currentTime().seconds,9,accuracy:0.02,"Pause must not seek to a stale estimate")
        try await server.sendPositionCommand(4,playing:true,intent:"preserve"); await account.sync()
        try await Task.sleep(for:.milliseconds(150))
        XCTAssertGreaterThanOrEqual(player.nativePlayer.currentTime().seconds,9)
        try await server.sendPositionCommand(4,playing:true,intent:"preserve"); await account.sync()
        XCTAssertGreaterThanOrEqual(player.nativePlayer.currentTime().seconds,9,"Queue changes must leave audible audio alone")
        XCTAssertEqual(loads,1)
        try await server.sendPositionCommand(2,playing:false,intent:"seek"); await account.sync()
        for _ in 0..<100 { if abs(player.nativePlayer.currentTime().seconds - 2) < 0.02 { break }; try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertEqual(player.nativePlayer.currentTime().seconds,2,accuracy:0.02)
        try await account.signOut();store.close();network.invalidateAndCancel();ConnectedPlaybackURLProtocol.server = nil
    }
    func testConnectedPlaybackFreezeUsesActualAudioClockInsteadOfProjectedProgress() async throws {
        let file = try makeAudioFixture(seconds:20)
        defer { try? FileManager.default.removeItem(at:file) }
        let suite = "NovaMusic.ConnectFreeze.\(UUID())", defaults = UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        let player = YouTubePlayer(defaults:defaults,streamSourceProvider:{ _,_ in .init(url:file,isLive:false) })
        let store = YouTubeStore(defaults:defaults,musicOnly:true,player:player)
        defer { store.close() }
        store.play(.placeholder("abcdefghijk"),music:true)
        for _ in 0..<150 { if player.ready { break }; try await Task.sleep(for:.milliseconds(20)) }
        XCTAssertTrue(player.ready); player.pause(); player.seek(to:6.375)
        for _ in 0..<100 { if abs(player.nativePlayer.currentTime().seconds - 6.375) < 0.02 { break }; try await Task.sleep(for:.milliseconds(10)) }
        player.currentTime = 9 // A controller's projected progress can be ahead of audible audio.
        let frozen = try await player.freezeConnectedClock()
        XCTAssertEqual(frozen,6.375,accuracy:0.02)
        XCTAssertEqual(player.nativePlayer.currentTime().seconds,6.375,accuracy:0.02)
        XCTAssertFalse(player.intendsPlayback)
    }
    func testConnectedPlaybackDelayedNewSongStartsAtZero() async throws {
        let file = try makeAudioFixture(seconds:20)
        defer { try? FileManager.default.removeItem(at:file) }
        let suite = "NovaMusic.ConnectStart.\(UUID())", defaults = UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        defaults.set("00000000-0000-4000-8000-000000000002",forKey:"music.sync.device")
        let player = YouTubePlayer(defaults:defaults,streamSourceProvider:{ _,_ in
            try await Task.sleep(for:.milliseconds(600)); return .init(url:file,isLive:false)
        })
        let store = YouTubeStore(defaults:defaults,musicOnly:true,player:player)
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [ConnectedPlaybackURLProtocol.self]
        let network = URLSession(configuration:configuration)
        ConnectedPlaybackURLProtocol.server = try ConnectedPlaybackTestServer(age:4,position:0,playing:true)
        var credentials: Data?
        let storage = MusicAccountCredentialStorage(read:{ credentials },save:{ credentials = $0 },delete:{ credentials = nil })
        let account = MusicAccountSync(store:store,network:network,credentialService:suite,credentialStorage:storage)
        store.musicAccount = account
        try await account.signIn(email:"test@example.com",password:"Fixture-password-123!",mergeGuest:false)
        for _ in 0..<150 { if player.ready { break }; try await Task.sleep(for:.milliseconds(20)) }
        XCTAssertTrue(player.ready); XCTAssertTrue(player.intendsPlayback)
        XCTAssertLessThan(player.currentTime,0.5,"Transport and loading delay must never seek past the opening")
        XCTAssertEqual(player.currentVideoID,"abcdefghijk")
        try await account.signOut(); store.close(); network.invalidateAndCancel()
        ConnectedPlaybackURLProtocol.server = nil
    }
    func testConnectedPlaybackSchemaAndLibraryPreserveWebSession() throws {
        let json = #"{"owner":"00000000-0000-4000-8000-000000000002","command":"00000000-0000-4000-8000-000000000003","at":1000,"snapshot":{"queue":[{"id":"abcdefghijk","title":"A song","artist":"Artist","duration":180,"source":"youtube"}],"index":0,"position":12,"playing":true,"shuffle":false,"repeat":0,"at":1000}}"#
        let session = try JSONDecoder().decode(MusicConnectedSession.self,from:Data(json.utf8))
        XCTAssertTrue(session.valid); XCTAssertEqual(session.snapshot.advancedPosition(now:5000),16)
        let suite = "NovaMusic.ConnectSchema.\(UUID())", defaults = UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        let store = YouTubeStore(defaults:defaults,musicOnly:true); defer { store.close() }
        let value = try NovaSyncValue.encoded(session)
        let values = try MusicAccountLibrary.values(store,preserving:["connect:session":value])
        XCTAssertEqual(values["connect:session"],value)
        var invalid = session.snapshot; invalid.index = 2; XCTAssertFalse(invalid.valid)
        invalid = session.snapshot; invalid.position = .infinity; XCTAssertFalse(invalid.valid)
    }
}
