import Foundation
import AVFoundation
import MediaPlayer

private final class ResolverResponseProtocol: URLProtocol, @unchecked Sendable {
 static var fixture=Data()
 static var alternateFixture:Data?
 override class func canInit(with request:URLRequest)->Bool { true }
 override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
 override func startLoading() {
  let response=HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:"HTTP/1.1",headerFields:["Content-Type":"application/json"])!
  client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
  let alternate = URLComponents(url:request.url!,resolvingAgainstBaseURL:false)?.queryItems?.first { $0.name == "client" }?.value == "ANDROID"
  client?.urlProtocol(self,didLoad:alternate ? (Self.alternateFixture ?? Self.fixture) : Self.fixture)
  client?.urlProtocolDidFinishLoading(self)
 }
 override func stopLoading() {}
}

@main struct NativeMusicAudioTests {
 @MainActor static func main() async throws {
  var resolutions=0
  let cache=MusicStreamCache(resolve:{ _ in resolutions += 1;try await Task.sleep(for:.milliseconds(50));return YouTubeStreamSource(url:URL(string:"https://example.com/song.mp4")!) })
  cache.preload("abcdefghijk")
  try await Task.sleep(for:.milliseconds(10))
  _=try await cache.source("abcdefghijk");_=try await cache.source("abcdefghijk")
  precondition(resolutions==1);print("PASS preload, click and replay share one verified stream lookup")
  let file=FileManager.default.temporaryDirectory.appendingPathComponent("nova-mac-audio-\(UUID().uuidString).wav")
  var wav=Data()
  func text(_ s:String){wav.append(contentsOf:s.utf8)}
  func u32(_ value:UInt32){var n=value.littleEndian;withUnsafeBytes(of:&n){wav.append(contentsOf:$0)}}
  func u16(_ value:UInt16){var n=value.littleEndian;withUnsafeBytes(of:&n){wav.append(contentsOf:$0)}}
  let bytes:UInt32=44100*2*40
  text("RIFF");u32(bytes+36);text("WAVEfmt ");u32(16);u16(1);u16(1);u32(44100);u32(88200);u16(2);u16(16);text("data");u32(bytes);wav.append(Data(count:Int(bytes)))
  try wav.write(to:file);defer{try? FileManager.default.removeItem(at:file)}
  let artConfiguration=URLSessionConfiguration.ephemeral;artConfiguration.protocolClasses=[ResolverResponseProtocol.self]
  let artSession=URLSession(configuration:artConfiguration);defer { artSession.invalidateAndCancel() }
  ResolverResponseProtocol.fixture=Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a9WQAAAAASUVORK5CYII=")!
  let audio=NativeMusicAudio(prepareItem:{ _ in AVPlayerItem(url:file) },artworkSession:artSession)
  var replies:[String:[String:Any]]=[:]
  audio.emit={value in if let id=value["request"] as? String { replies[id]=value } }
  let generation=UUID().uuidString
  func command(_ name:String,_ extra:[String:Any]=[:])->String {
   let request=UUID().uuidString
   audio.handle(["command":name,"request":request,"generation":generation].merging(extra,uniquingKeysWith:{$1}));return request
  }
  func wait(_ request:String) async throws {
   for _ in 0..<800 { if let reply=replies[request] { if let error=reply["error"] as? String { throw MacAudioError(message:error) };return };try await Task.sleep(for:.milliseconds(25)) }
   throw MacAudioError(message:"Test timed out")
  }
  func near(_ expected:Double,_ tolerance:Double=0.08){let actual=audio.player.currentTime().seconds;precondition(abs(actual-expected)<tolerance,"Expected \(expected), got \(actual)")}
  let load=command("load",["videoId":"abcdefghijk","position":9.0,"playing":false,"volume":0.0,"title":"Track","artist":"Artist","album":"Album","artwork":"https://example.com/cover.png"]);try await wait(load)
  for _ in 0..<100 { if MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] != nil { break };try await Task.sleep(for:.milliseconds(10)) }
  precondition(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] is MPMediaItemArtwork)
  precondition(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyAlbumTitle] as? String == "Album")
  print("PASS native Now Playing includes the selected album cover and title")
  near(9);precondition(audio.player.rate==0);print("PASS exact paused load without preparation-time skip")
  let play=command("play");try await wait(play)
  for _ in 0..<200 {if audio.player.timeControlStatus == .playing {break};try await Task.sleep(for:.milliseconds(25))}
  try await Task.sleep(for:.milliseconds(750))
  let before=audio.player.currentTime().seconds,started=ProcessInfo.processInfo.systemUptime
  try await Task.sleep(for:.seconds(5))
  let elapsed=ProcessInfo.processInfo.systemUptime-started,advanced=audio.player.currentTime().seconds-before
  precondition(abs(advanced/elapsed-1)<0.04,"Native audio clock did not run at 1x: \(advanced)/\(elapsed)")
  precondition(audio.player.rate==1);print("PASS native clock advances at a steady 1x")
  try await wait(command("pause"));let paused=audio.player.currentTime().seconds
  try await Task.sleep(for:.milliseconds(350));near(paused)
  for _ in 0..<10 {try await wait(command("volume",["volume":0.0]));try await wait(command("pause"))};near(paused)
  print("PASS pause and non-seek controls preserve the actual clock")
  try await wait(command("seek",["position":2.0]));near(2);precondition(audio.player.rate==0)
  print("PASS explicit seek confirms the exact destination while paused")
  let stale=UUID().uuidString;audio.handle(["request":stale,"generation":"old-generation","command":"seek","position":20.0]);near(2)
  precondition(replies[stale]?["error"] != nil);print("PASS stale device commands cannot reposition the recording")
  audio.stop();precondition(audio.player.currentItem==nil);precondition(MPNowPlayingInfoCenter.default().nowPlayingInfo==nil)
  let data=Data(#"{"playabilityStatus":{"status":"OK"},"streamingData":{"adaptiveFormats":[{"mimeType":"audio/mp4","bitrate":128000,"url":"https://rr1.googlevideo.com/videoplayback?mime=audio%2Fmp4"}],"formats":[{"height":360,"mimeType":"video/mp4","url":"https://rr1.googlevideo.com/video"}]}}"#.utf8)
  let source=try YouTubeStreamResolver.parseSource(data)
  precondition(source.url.path=="/video");print("PASS music chooses the compatible full recording over adaptive audio")
  let configuration=URLSessionConfiguration.ephemeral;configuration.protocolClasses=[ResolverResponseProtocol.self]
  let session=URLSession(configuration:configuration);defer{session.invalidateAndCancel()}
  let root=try JSONSerialization.jsonObject(with:data) as! [String:Any]
  ResolverResponseProtocol.fixture=try JSONSerialization.data(withJSONObject:root.merging(["videoDetails":["videoId":"otherSongID0"]],uniquingKeysWith:{$1}))
  do { _=try await YouTubeStreamResolver.source("abcdefghijk",session:session);preconditionFailure("A mismatched recording was accepted") }
  catch {precondition(error.localizedDescription.contains("different recording"));print("PASS service responses for another recording are rejected")}
  ResolverResponseProtocol.fixture=try JSONSerialization.data(withJSONObject:root.merging(["videoDetails":["videoId":"abcdefghijk"]],uniquingKeysWith:{$1}))
  let verified=try await YouTubeStreamResolver.source("abcdefghijk",session:session)
  precondition(verified.url.path=="/video");print("PASS verified service responses prepare the selected recording")
  ResolverResponseProtocol.alternateFixture=ResolverResponseProtocol.fixture
  for primary in [
   #"{"playabilityStatus":{"status":"UNPLAYABLE","reason":"Unsupported client"}}"#,
   #"{"playabilityStatus":{"status":"OK"},"videoDetails":{"videoId":"abcdefghijk"},"streamingData":{"hlsManifestUrl":"invalid://manifest"}}"#,
   #"{"playabilityStatus":{"status":"OK"},"videoDetails":{"videoId":"abcdefghijk"}}"#
  ] {
   ResolverResponseProtocol.fixture=Data(primary.utf8)
   let recovered=try await YouTubeStreamResolver.source("abcdefghijk",session:session)
   precondition(recovered.url.path=="/video")
  }
  print("PASS alternate client recovers unsupported, malformed and missing primary streams")
  ResolverResponseProtocol.fixture=ResolverResponseProtocol.alternateFixture!
  ResolverResponseProtocol.alternateFixture=Data(#"{"playabilityStatus":{"status":"UNPLAYABLE"}}"#.utf8)
  let retained=try await YouTubeStreamResolver.source("abcdefghijk",session:session,preferHLS:true)
  precondition(retained.url.path=="/video")
  ResolverResponseProtocol.alternateFixture=nil
  print("PASS failed HLS lookup preserves a playable primary recording")
 }
}
