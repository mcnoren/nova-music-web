import Foundation
import AVFoundation
import WebKit
import MediaPlayer
import AppKit

struct MacAudioError: LocalizedError { let message:String; var errorDescription:String? { message } }
struct YouTubeStreamSource: Sendable {
 let url:URL
 var isLive:Bool? = nil
 var isHLS:Bool { url.pathExtension.lowercased()=="m3u8" || url.path.contains("hls") }
}
enum YouTubeStreamResolver {
    static func resolve(_ id: String, session: URLSession = .shared) async throws -> URL {
        try await source(id, session: session).url
    }
    static func source(_ id: String, session: URLSession = .shared, preferHLS: Bool = false) async throws -> YouTubeStreamSource {
        let data = try await response(id, session: session)
        // A catalog recording can be unsupported by one public player client.
        // Try the same recording with the alternate client on any unplayable
        // response, including non-OK status and malformed/missing streams.
        let primary: YouTubeStreamSource
        do { primary = try parseSource(data, preferHLS: preferHLS) }
        catch {
            try Task.checkCancellation()
            return try parseSource(await response(id, session: session, liveHLS: true), preferHLS: preferHLS)
        }
        if preferHLS && !primary.isHLS {
            do {
                let alternate = try parseSource(await response(id, session: session, liveHLS: true), preferHLS: true)
                if alternate.isHLS { return alternate }
            } catch { try Task.checkCancellation() }
        }
        return primary
    }

    static func durationLabel(_ id: String, session: URLSession = .shared) async throws -> String? {
        let root = try JSONSerialization.jsonObject(with: await response(id, session: session)) as? [String: Any] ?? [:]
        guard !isLiveBroadcast(root), let details = root["videoDetails"] as? [String: Any],
              let raw = details["lengthSeconds"] as? String, let seconds = Int(raw), seconds > 0 else { return nil }
        return seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
    private static func response(_ id: String, session: URLSession, liveHLS: Bool = false) async throws -> Data {
        guard id.range(of:"^[A-Za-z0-9_-]{11}$",options:.regularExpression) != nil else { throw MacAudioError(message: "Invalid video link.") }
        // Include the recording/client in the URL as well as the POST body so
        // caches cannot reuse another recording's player response.
        let clientName = liveHLS ? "ANDROID" : "IOS"
        let endpoint = "https://www.youtube.com/youtubei/v1/player?prettyPrint=false&videoId=\(id)&client=\(clientName)"
        var request = URLRequest(url: URL(string: endpoint)!, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "POST"; request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let version = liveHLS ? "20.10.38" : "21.03.4"
        request.setValue(liveHLS ? "com.google.android.youtube/20.10.38 (Linux; U; Android 11) gzip" : "com.google.ios.youtube/21.03.4 (iPhone16,2; U; CPU iOS 18_0 like Mac OS X;)", forHTTPHeaderField: "User-Agent")
        request.setValue(liveHLS ? "3" : "5", forHTTPHeaderField: "X-Youtube-Client-Name")
        request.setValue(version, forHTTPHeaderField: "X-Youtube-Client-Version")
        let client: [String: Any] = liveHLS
            ? ["clientName": "ANDROID", "clientVersion": version, "androidSdkVersion": 30, "hl": "en", "gl": "US"]
            : ["clientName": "IOS", "clientVersion": version, "deviceMake": "Apple", "deviceModel": "iPhone16,2", "osName": "iPhone", "osVersion": "18.0.0.22A3354", "hl": "en", "gl": "US"]
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "context": ["client": client],
            "videoId": id, "contentCheckOk": true, "racyCheckOk": true
        ])
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw MacAudioError(message: "YouTube could not connect. Check your connection and retry.")
        }
        let root = try JSONSerialization.jsonObject(with:data) as? [String:Any]
        if (root?["playabilityStatus"] as? [String:Any])?["status"] as? String == "OK" {
            guard (root?["videoDetails"] as? [String:Any])?["videoId"] as? String == id else {
                throw MacAudioError(message:"The music service returned a different recording. Please retry.")
            }
        }
        return data
    }

    static func parse(_ data: Data) throws -> URL {
        try parseSource(data).url
    }

    static func parseSource(_ data: Data, preferHLS: Bool = false) throws -> YouTubeStreamSource {
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let status = root?["playabilityStatus"] as? [String: Any]
        guard status?["status"] as? String == "OK" else {
            throw MacAudioError(message: status?["reason"] as? String ?? "This video is unavailable. Try another video or open it in YouTube.")
        }
        let streams = root?["streamingData"] as? [String: Any]
        let live = isLiveBroadcast(root ?? [:])
        if preferHLS, let raw = streams?["hlsManifestUrl"] as? String,
           let url = URL(string: raw), url.scheme == "https" {
            return YouTubeStreamSource(url: url, isLive: live)
        }
        if !live {
            let formats = streams?["formats"] as? [[String: Any]] ?? []
            for format in formats {
                let height = format["height"] as? Int
                let itag = format["itag"] as? Int
                guard height == 360 || (height == nil && itag == 18),
                      (format["mimeType"] as? String)?.contains("video/mp4") == true,
                      let raw = format["url"] as? String, let url = URL(string: raw), url.scheme == "https" else { continue }
                return YouTubeStreamSource(url: url, isLive: false)
            }
        }
        if let raw = streams?["hlsManifestUrl"] as? String, let url = URL(string: raw), url.scheme == "https" {
            return YouTubeStreamSource(url: url, isLive: live)
        }
        if live { throw MacAudioError(message: "This live broadcast hasn't provided a playable stream yet. Retry in a moment.") }
        throw MacAudioError(message: "YouTube did not return a playable stream. Retry or open this video in YouTube.")
    }

    private static func isLiveBroadcast(_ root: [String: Any]) -> Bool {
        let details = root["videoDetails"] as? [String: Any]
        let broadcast = ((root["microformat"] as? [String: Any])?["playerMicroformatRenderer"] as? [String: Any])?["liveBroadcastDetails"] as? [String: Any]
        // isLiveContent also describes archived broadcasts; those retain normal resume and seek behavior.
        return details?["isLive"] as? Bool == true || broadcast?["isLiveNow"] as? Bool == true ||
            (details?["isLiveContent"] as? Bool == true && broadcast?["startTimestamp"] != nil && broadcast?["endTimestamp"] == nil && broadcast?["isLiveNow"] as? Bool != false)
    }
}

/// Resolve the clicked/next recording while account delivery runs, without
/// starting audio. Signed URLs expire; keep only a small, short-lived cache.
@MainActor
final class MusicStreamCache {
    private var values: [String:(source:YouTubeStreamSource,at:Date)] = [:]
    private var pending: [String:Task<YouTubeStreamSource,Error>] = [:]
    private var warming = Set<String>()
    private let resolve: (String) async throws -> YouTubeStreamSource
    init(resolve: @escaping (String) async throws -> YouTubeStreamSource = { try await YouTubeStreamResolver.source($0) }) { self.resolve=resolve }
    func source(_ id:String) async throws -> YouTubeStreamSource {
        if let cached=values[id],Date().timeIntervalSince(cached.at)<300 { return cached.source }
        if let work=pending[id] { return try await work.value }
        let work=Task { try await resolve(id) };pending[id]=work
        do {
            let source=try await work.value;pending[id]=nil;values[id]=(source,Date())
            if values.count>4,let oldest=values.min(by:{$0.value.at<$1.value.at})?.key { values.removeValue(forKey:oldest) }
            return source
        } catch { pending[id]=nil;throw error }
    }
    func preload(_ id:String) {
        guard warming.count<2,pending[id]==nil,!warming.contains(id) else { return }
        warming.insert(id)
        Task { defer { warming.remove(id) }; _ = try? await source(id) }
    }
}

private let silentResolverScript = #"""
(() => {
  const play=HTMLMediaElement.prototype.play;
  HTMLMediaElement.prototype.play=function(...args){this.muted=true;return Reflect.apply(play,this,args)};
  try { navigator.mediaSession.setActionHandler=()=>{}; } catch (_) {}
})();
"""#
@MainActor
final class EmbeddedStreamBridge: NSObject, WKScriptMessageHandler {
    let webView: WKWebView
    private var continuation: CheckedContinuation<YouTubeStreamSource, Error>?
    private var timeout: Task<Void, Never>?
    private var requestID = UUID().uuidString

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        // The temporary URL resolver stays silent; AVPlayer owns Mac audio.
        config.allowsAirPlayForMediaPlayback = false
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.addUserScript(WKUserScript(source: Self.captureScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 360, height: 203), configuration: config)
        super.init()
        config.userContentController.add(StreamMessageProxy(self), name: "novaStream")
    }

    func resolve(_ id: String) async throws -> URL {
        try await source(id).url
    }

    func source(_ id: String, preferHLS: Bool = false) async throws -> YouTubeStreamSource {
        cancel()
        try Task.checkCancellation()
        requestID = UUID().uuidString
        let currentRequest = requestID
        webView.configuration.userContentController.removeAllUserScripts()
        let script = (HDYouTubeAdFilter.script + Self.captureScript).replacingOccurrences(of: "REQUEST_ID", with: currentRequest).replacingOccurrences(of: "VIDEO_ID", with: id).replacingOccurrences(of: "PREFER_HLS", with: preferHLS ? "true" : "false")
        webView.configuration.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        let origin = "https://\(Bundle.main.bundleIdentifier ?? "com.example.NovaBrowser")"
        if let rules = await HDYouTubeAdFilter.rules() { webView.configuration.userContentController.add(rules) }
        let html = """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body,#player{margin:0;width:100%;height:100%;background:#000;overflow:hidden}</style></head>
        <body><div id="player"></div><script>
        var player;
        function onYouTubeIframeAPIReady(){player=new YT.Player('player',{width:'100%',height:'100%',videoId:'\(id)',playerVars:{autoplay:1,playsinline:1,origin:'\(origin)'},events:{onReady:()=>{player.mute();player.playVideo()},onError:e=>window.webkit.messageHandlers.novaStream.postMessage({error:e.data,requestID:'\(currentRequest)'})}})}
        </script><script src="https://www.youtube.com/iframe_api"></script></body></html>
        """
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                webView.loadHTMLString(html, baseURL: URL(string: origin))
                timeout = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(15))
                    guard !Task.isCancelled, self?.requestID == currentRequest else { return }
                    self?.finish(.failure(MacAudioError(message: "This track could not connect. Try another track or open it in YouTube.")))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.requestID == currentRequest else { return }
                self?.cancel()
            }
        }
    }

    func cancel() { finish(.failure(CancellationError())) }
    private func finish(_ result: Result<YouTubeStreamSource, Error>) {
        guard let pending = continuation else { return }
        continuation = nil; timeout?.cancel()
        webView.loadHTMLString("", baseURL: nil)
        pending.resume(with: result)
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], body["requestID"] as? String == requestID else { return }
        if let raw = body["url"] as? String, var parts = URLComponents(string: raw), parts.scheme == "https",
           let host = parts.host, host == "googlevideo.com" || host.hasSuffix(".googlevideo.com") {
            parts.queryItems = parts.queryItems?.filter { !["range", "rn", "rbuf"].contains($0.name) }
            if let url = parts.url { finish(.success(YouTubeStreamSource(url: url, isLive: body["live"] as? Bool))) }
        } else if message.frameInfo.isMainFrame, let code = body["error"] as? Int {
            finish(.failure(MacAudioError(message: "YouTube could not play this track (\(code)). Try another track.")))
        }
    }

    private static let captureScript = silentResolverScript + #"""
    (() => {
      const seen = new Set();
      const preferHLS = PREFER_HLS;
      const started = Date.now();
      let knownLive;
      let verifiedRecording = false;
      try { window.MediaSource = undefined; window.ManagedMediaSource = undefined; } catch (_) {}
      function capture(raw) {
        try {
          const url = new URL(raw, location.href);
          const mime = url.searchParams.get('mime') || '';
          if (!verifiedRecording || !url.hostname.endsWith('.googlevideo.com') || seen.has(url.href)) return;
          const progressive = mime.includes('video/mp4') && url.searchParams.get('itag') === '18';
          const hls = url.pathname.includes('hls_playlist') || url.pathname.includes('hls_variant');
          if (preferHLS && (url.pathname.includes('hls_variant') || (progressive && Date.now() - started < 3000))) return;
          if (!(hls || (knownLive !== true && progressive))) return;
          if (document.querySelector('.ad-showing,.ad-interrupting')) return;
          seen.add(url.href);
          window.webkit.messageHandlers.novaStream.postMessage({url: url.href, live:knownLive, requestID: 'REQUEST_ID'});
        } catch (_) {}
      }
      function capturePlayerResponse(response) {
        if (response?.videoDetails?.videoId !== 'VIDEO_ID') return;
        verifiedRecording = true;
        knownLive = response.videoDetails.isLive === true || response?.microformat?.playerMicroformatRenderer?.liveBroadcastDetails?.isLiveNow === true;
        const master = response?.streamingData?.hlsManifestUrl;
        if (master && (preferHLS || knownLive)) capture(master);
        for (const format of response?.streamingData?.formats || []) {
          if (format.itag === 18 && format.url) capture(format.url);
        }
        if (master) capture(master);
      }
      const fetch = window.fetch;
      window.fetch = function(input, ...args) {
        const url = typeof input === 'string' ? input : input.url;
        capture(url);
        const pending = fetch.call(this, input, ...args);
        if (url.includes('/youtubei/v1/player')) {
          pending.then(response => response.clone().json()).then(capturePlayerResponse).catch(() => {});
        }
        return pending;
      };
      const open = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function(method, url, ...args) {
        capture(url);
        if (String(url).includes('/youtubei/v1/player')) {
          this.addEventListener('load', () => {
            try { capturePlayerResponse(this.responseType === 'json' ? this.response : JSON.parse(this.responseText)); } catch (_) {}
          }, {once: true});
        }
        return open.call(this, method, url, ...args);
      };
      setInterval(() => {
        capturePlayerResponse(window.ytInitialPlayerResponse);
        document.querySelectorAll('video,audio').forEach(v => capture(v.currentSrc));
        performance.getEntriesByType('resource').forEach(entry => capture(entry.name));
      }, 100);
    })();
    """#
}
private final class StreamMessageProxy: NSObject, WKScriptMessageHandler {
    weak var owner: EmbeddedStreamBridge?
    init(_ owner: EmbeddedStreamBridge) { self.owner = owner }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        owner?.userContentController(userContentController, didReceive: message)
    }
}

/// The website remains the UI/controller; AVPlayer alone owns audible music.
/// Clock samples are telemetry, never synchronization seeks or rate corrections.
@MainActor
final class NativeMusicAudio {
    let player = AVQueuePlayer()
    var emit: (([String:Any])->Void)?
    var remoteAction: ((String)->Void)?
    private let artworkSession: URLSession
    private let prepareItem: ((String) async throws -> AVPlayerItem)?
    private var resolver: EmbeddedStreamBridge?
    private let streamCache=MusicStreamCache()
    private var task: Task<Void,Never>?
    private var nextTask: Task<Void,Never>?
    private var nextItem: AVPlayerItem?
    private var nextMetadata: [String:Any]?
    private var nextRevision = UUID()
    private var queueObservation: NSKeyValueObservation?
    private var generation = UUID().uuidString
    private var videoID = ""
    private var loading = false
    private var requestedPlaying = false
    private var title = "", artist = "", album = ""
    private var artwork: MPMediaItemArtwork?
    private var artworkTask: Task<Void,Never>?
    private var clockObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var timeObservation: NSKeyValueObservation?
    private var itemObservation: NSKeyValueObservation?

    init(prepareItem: ((String) async throws -> AVPlayerItem)? = nil, artworkSession: URLSession = .shared) {
        self.artworkSession=artworkSession
        self.prepareItem=prepareItem
        player.automaticallyWaitsToMinimizeStalling = true
        player.defaultRate = 1
        player.actionAtItemEnd = .advance
        queueObservation = player.observe(\.currentItem, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.adoptQueuedItem() }
        }
        let remote=MPRemoteCommandCenter.shared()
        remote.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.systemTransport(playing:true) };return .success }
        remote.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.systemTransport(playing:false) };return .success }
        remote.togglePlayPauseCommand.addTarget { [weak self] _ in Task { @MainActor in guard let self else { return };self.systemTransport(playing:!self.requestedPlaying) };return .success }
        remote.nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.remoteAction?("next") };return .success }
        remote.previousTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.remoteAction?("previous") };return .success }
        clockObserver = player.addPeriodicTimeObserver(forInterval:CMTime(seconds:0.25,preferredTimescale:600),queue:.main) { [weak self] _ in
            Task { @MainActor in self?.publish() }
        }
        timeObservation = player.observe(\.timeControlStatus,options:[.new]) { [weak self] _,_ in
            Task { @MainActor in self?.publish() }
        }
    }
    private func systemTransport(playing:Bool) {
        guard !videoID.isEmpty else { return }
        handle(["command":playing ? "play" : "pause","request":UUID().uuidString,"generation":generation])
    }
    var snapshot:[String:Any] {
        let position = finite(player.currentTime().seconds), duration = finite(player.currentItem?.duration.seconds ?? 0)
        let state = loading ? 3 : (player.timeControlStatus == .playing ? 1 : (player.timeControlStatus == .waitingToPlayAtSpecifiedRate ? 3 : 2))
        return ["id":videoID,"generation":generation,"position":position,"duration":duration,"state":state,"rate":Double(player.rate == 0 ? 1 : player.rate),"volume":Double(player.volume)*100]
    }
    private func finite(_ value:Double)->Double { value.isFinite ? max(0,value) : 0 }
    private func publish() {
        guard !videoID.isEmpty else { return }
        emit?(["state":snapshot])
        let position=finite(player.currentTime().seconds)
        var info: [String:Any]=[MPMediaItemPropertyTitle:title,MPMediaItemPropertyArtist:artist,MPMediaItemPropertyPlaybackDuration:finite(player.currentItem?.duration.seconds ?? 0),MPNowPlayingInfoPropertyElapsedPlaybackTime:position,MPNowPlayingInfoPropertyPlaybackRate:player.timeControlStatus == .playing ? 1.0 : 0.0]
        info[MPMediaItemPropertyAlbumTitle]=album
        if let artwork { info[MPMediaItemPropertyArtwork]=artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo=info
        MPNowPlayingInfoCenter.default().playbackState = player.timeControlStatus == .playing ? .playing : .paused
    }
    func stop() {
        artworkTask?.cancel();artworkTask=nil;artwork=nil
        nextRevision = UUID(); nextTask?.cancel(); nextTask=nil; nextItem=nil; nextMetadata=nil
        task?.cancel(); task=nil; resolver?.cancel()
        player.pause();player.removeAllItems();itemObservation=nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver);self.endObserver=nil }
        videoID="";loading=false;requestedPlaying=false;generation=UUID().uuidString
        MPNowPlayingInfoCenter.default().nowPlayingInfo=nil
    }
    func handle(_ message:[String:Any]) {
        guard let request=message["request"] as? String, request.count<=80,
              let command=message["command"] as? String else { return }
        if command=="preload" {
            if let id=message["videoId"] as? String,id.range(of:"^[A-Za-z0-9_-]{11}$",options:.regularExpression) != nil { streamCache.preload(id) }
            return
        }
        if command=="queue-next" { prepareNext(message); reply(request); return }
        if command=="load" {
            guard let id=message["videoId"] as? String,id.range(of:"^[A-Za-z0-9_-]{11}$",options:.regularExpression) != nil,
                  let position=message["position"] as? Double,position.isFinite,position>=0,
                  let playing=message["playing"] as? Bool,let clientGeneration=message["generation"] as? String,clientGeneration.count<=80 else { return }
            stop();player.volume=Float(min(100,max(0,message["volume"] as? Double ?? 80))/100);videoID=id;generation=clientGeneration;loading=true;requestedPlaying=playing
            title=String((message["title"] as? String ?? "Nova Music").prefix(1000));artist=String((message["artist"] as? String ?? "").prefix(1000))
            album=String((message["album"] as? String ?? "").prefix(1000))
            let token=generation;publish()
            loadArtwork(message["artwork"] as? String, token: token)
            task=Task { [weak self] in
                guard let self else { return }
                do {
                    let item = try await makeItem(id)
                    try check(token)
                    item.preferredForwardBufferDuration=3
                    item.audioTimePitchAlgorithm = .spectral
                    player.replaceCurrentItem(with:item)
                    let deadline=Date().addingTimeInterval(20)
                    while item.status == .unknown && Date()<deadline { try await Task.sleep(for:.milliseconds(25));try check(token) }
                    guard item.status == .readyToPlay else { throw item.error ?? MacAudioError(message:"This recording could not prepare. Try another recording.") }
                    try await seek(position,token:token)
                    try check(token);loading=false
                    observeEnd(item, token: token)
                    observeFailure(item, token: token)
                    if requestedPlaying { player.play() }
                    publish();reply(request)
                } catch {
                    guard generation==token else { return }
                    loading=false;player.pause();publish();reply(request,error:error)
                }
            }
            return
        }
        guard message["generation"] as? String==generation else { reply(request,error:CancellationError());return }
        if command=="stop" { stop();reply(request);return }
        if command=="volume",let value=message["volume"] as? Double,value.isFinite { player.volume=Float(min(100,max(0,value))/100);reply(request);return }
        if command=="pause" { requestedPlaying=false;player.pause();publish();reply(request);return }
        if command=="play" { requestedPlaying=true;if !loading { player.play();publish() };reply(request);return }
        if command=="seek",let position=message["position"] as? Double,position.isFinite,position>=0 {
            let token=generation
            Task { [weak self] in
                guard let self else { return }
                do { try await seek(position,token:token);publish();reply(request) } catch { reply(request,error:error) }
            }
        }
    }
    private func loadArtwork(_ raw: String?, token: String) {
        artworkTask?.cancel(); artwork = nil
        guard let raw, raw.count <= 8000, let url = URL(string: raw), url.scheme == "https" else { return }
        let artworkID = videoID
        artworkTask = Task { [weak self] in
            do {
                guard let self else { return }
                let (data,response) = try await self.artworkSession.data(from: url)
                guard !Task.isCancelled, self.generation == token, self.videoID == artworkID,
                      (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 8_000_000,
                      let image = NSImage(data: data), image.size.width > 0, image.size.height > 0 else { return }
                self.artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                self.publish()
            } catch { /* Artwork never delays audio. */ }
        }
    }
    private func makeItem(_ id: String) async throws -> AVPlayerItem {
        if let prepareItem { return try await prepareItem(id) }
        let source: YouTubeStreamSource
        do { source = try await streamCache.source(id) }
        catch {
            try Task.checkCancellation()
            if resolver == nil { resolver = EmbeddedStreamBridge() }
            source = try await resolver!.source(id)
        }
        try Task.checkCancellation()
        return AVPlayerItem(url: source.url)
    }
    private func prepareNext(_ message: [String:Any]) {
        guard message["generation"] as? String == generation else { return }
        nextRevision = UUID(); let revision = nextRevision, token = generation
        nextTask?.cancel(); nextTask = nil
        if let nextItem, player.currentItem !== nextItem { player.remove(nextItem) }
        nextItem = nil; nextMetadata = nil
        guard let id = message["videoId"] as? String, id.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil else { return }
        nextTask = Task { [weak self] in
            guard let self else { return }
            do {
                let item = try await makeItem(id)
                try check(token)
                guard nextRevision == revision, let current = player.currentItem else { return }
                item.preferredForwardBufferDuration = 5
                item.audioTimePitchAlgorithm = .spectral
                guard player.canInsert(item, after: current) else { return }
                nextItem = item; nextMetadata = message
                player.insert(item, after: current)
            } catch { /* The regular next-track path retries if preparation fails. */ }
        }
    }
    private func observeFailure(_ item: AVPlayerItem, token: String) {
        itemObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor in
                guard let self, self.generation == token, self.player.currentItem === item else { return }
                self.player.pause(); self.emit?(["error":"The audio stream stopped. Try playing the song again.", "generation":token])
            }
        }
    }
    private func observeEnd(_ item: AVPlayerItem, token: String) {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                if self.nextItem != nil { self.adoptQueuedItem(); return }
                // A queued item may already have been adopted by currentItem KVO.
                guard self.player.currentItem === item || self.player.currentItem == nil else { return }
                var value = self.snapshot; value["state"] = 0; self.emit?(["state": value])
            }
        }
    }
    private func adoptQueuedItem() {
        guard let item = nextItem, player.currentItem === item, let metadata = nextMetadata,
              let id = metadata["videoId"] as? String else { return }
        nextItem = nil; nextMetadata = nil; loading = false
        videoID = id; title = metadata["title"] as? String ?? "Nova Music"
        artist = metadata["artist"] as? String ?? ""; album = metadata["album"] as? String ?? ""
        loadArtwork(metadata["artwork"] as? String, token: generation)
        observeEnd(item, token: generation)
        observeFailure(item, token: generation)
        emit?(["advanced": id, "state": snapshot])
        publish()
    }
    private func check(_ token:String) throws { try Task.checkCancellation();if generation != token { throw CancellationError() } }
    private func seek(_ seconds:Double,token:String) async throws {
        try check(token)
        let completed=await player.seek(to:CMTime(seconds:seconds,preferredTimescale:600),toleranceBefore:.zero,toleranceAfter:.zero)
        try check(token)
        guard completed else { throw MacAudioError(message:"Playback changed before seeking finished.") }
    }
    private func reply(_ request:String,error:Error?=nil) {
        var value:[String:Any]=["request":request,"state":snapshot]
        if let error { value["error"]=error.localizedDescription }
        emit?(value)
    }
}
