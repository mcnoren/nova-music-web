import Foundation
import AVFoundation

@main struct NativeMusicAudioTests {
 @MainActor static func main() async throws {
  let file=FileManager.default.temporaryDirectory.appendingPathComponent("nova-mac-audio-\(UUID().uuidString).wav")
  var wav=Data()
  func text(_ s:String){wav.append(contentsOf:s.utf8)}
  func u32(_ value:UInt32){var n=value.littleEndian;withUnsafeBytes(of:&n){wav.append(contentsOf:$0)}}
  func u16(_ value:UInt16){var n=value.littleEndian;withUnsafeBytes(of:&n){wav.append(contentsOf:$0)}}
  let bytes:UInt32=44100*2*40
  text("RIFF");u32(bytes+36);text("WAVEfmt ");u32(16);u16(1);u16(1);u32(44100);u32(88200);u16(2);u16(16);text("data");u32(bytes);wav.append(Data(count:Int(bytes)))
  try wav.write(to:file);defer{try? FileManager.default.removeItem(at:file)}
  let audio=NativeMusicAudio(prepareItem:{ _ in AVPlayerItem(url:file) })
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
  let load=command("load",["videoId":"abcdefghijk","position":9.0,"playing":false,"volume":0.0]);try await wait(load)
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
  audio.stop();precondition(audio.player.currentItem==nil)
  let data=Data(#"{"playabilityStatus":{"status":"OK"},"streamingData":{"adaptiveFormats":[{"mimeType":"audio/mp4","bitrate":128000,"url":"https://rr1.googlevideo.com/videoplayback?mime=audio%2Fmp4"}],"formats":[{"height":360,"mimeType":"video/mp4","url":"https://rr1.googlevideo.com/video"}]}}"#.utf8)
  let source=try YouTubeStreamResolver.parseSource(data)
  precondition(source.url.path=="/videoplayback");print("PASS music prefers an audio-only stream")
 }
}
