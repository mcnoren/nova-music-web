import Foundation
import AVFoundation
import WebKit
import MediaPlayer

struct MacAudioError: LocalizedError { let message:String; var errorDescription:String? { message } }
struct YouTubeStreamSource: Sendable {
 let url:URL
 var isLive:Bool? = nil
 var isHLS:Bool { url.pathExtension.lowercased()=="m3u8" || url.path.contains("hls") }
}
enum MediaRangeFailurePolicy {
    static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || ((error as NSError).domain == NSURLErrorDomain && (error as NSError).code == NSURLErrorCancelled)
    }
    static func canRetry(_ error: Error) -> Bool {
        if let http = error as? MediaRangeHTTPError { return http.status == 408 || http.status == 429 || (500...599).contains(http.status) }
        guard (error as NSError).domain == NSURLErrorDomain else { return false }
        return [NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorCannotConnectToHost, NSURLErrorNotConnectedToInternet].contains((error as NSError).code)
    }
}

struct MediaRangeHTTPError: Error { let status: Int }

/// Receive bounded network buffers in bulk, sharing connections across tracks.
final class MediaRangeClient: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = MediaRangeClient()
    private let lock = NSLock()
    private var transfers: [Int: Transfer] = [:]
    private var session: URLSession!
    init(configuration: URLSessionConfiguration = .ephemeral) {
        super.init()
        configuration.httpMaximumConnectionsPerHost = 6
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }

    func data(for request: URLRequest, limit: Int) async throws -> (Data, HTTPURLResponse) {
        for attempt in 0..<3 {
            do { return try await transferData(for: request, limit: limit) }
            catch {
                guard !Task.isCancelled, MediaRangeFailurePolicy.canRetry(error), attempt < 2 else { throw error }
                try await Task.sleep(for: .milliseconds(250 * (attempt + 1)))
            }
        }
        throw URLError(.networkConnectionLost)
    }

    private func transferData(for request: URLRequest, limit: Int) async throws -> (Data, HTTPURLResponse) {
        let transfer = Transfer(limit: limit)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request)
                guard transfer.begin(task, continuation: continuation) else { return }
                lock.withLock { transfers[task.taskIdentifier] = transfer }
                task.resume()
            }
        } onCancel: { transfer.finish(URLError(.cancelled), cancel: true) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse, ![200, 206].contains(http.statusCode) {
            lock.withLock { transfers[dataTask.taskIdentifier] }?.finish(MediaRangeHTTPError(status: http.statusCode))
            completionHandler(.cancel); return
        }
        guard let transfer = lock.withLock({ transfers[dataTask.taskIdentifier] }),
              let http = response as? HTTPURLResponse, [200, 206].contains(http.statusCode),
              response.expectedContentLength <= Int64(transfer.limit) else {
            lock.withLock { transfers[dataTask.taskIdentifier] }?.finish(URLError(.badServerResponse))
            completionHandler(.cancel); return
        }
        transfer.setResponse(http)
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.withLock { transfers[dataTask.taskIdentifier] }?.append(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let transfer = lock.withLock { transfers.removeValue(forKey: task.taskIdentifier) }
        transfer?.finish(error)
    }

    private final class Transfer: @unchecked Sendable {
        let limit: Int
        private let lock = NSLock()
        private var task: URLSessionDataTask?
        private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
        private var response: HTTPURLResponse?
        private var buffer = Data()
        private var finished = false
        init(limit: Int) { self.limit = limit; buffer.reserveCapacity(limit) }
        func begin(_ task: URLSessionDataTask, continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>) -> Bool {
            let active = lock.withLock {
                guard !finished else { return false }
                self.task = task; self.continuation = continuation; return true
            }
            if !active { task.cancel(); continuation.resume(throwing: URLError(.cancelled)) }
            return active
        }
        func setResponse(_ response: HTTPURLResponse) { lock.withLock { self.response = response } }
        func append(_ data: Data) {
            let overflow = lock.withLock {
                guard !finished else { return false }
                guard buffer.count + data.count <= limit else { return true }
                buffer.append(data); return false
            }
            if overflow { finish(URLError(.dataLengthExceedsMaximum), cancel: true) }
        }
        func finish(_ error: Error?, cancel: Bool = false) {
            let result: (CheckedContinuation<(Data, HTTPURLResponse), Error>?, URLSessionDataTask?, Data, HTTPURLResponse?)? = lock.withLock {
                guard !finished else { return nil }
                finished = true
                let result = (continuation, task, buffer, response)
                continuation = nil; task = nil; buffer = Data()
                return result
            }
            guard let (continuation, task, data, response) = result else { return }
            if cancel { task?.cancel() }
            if let error { continuation?.resume(throwing: error) }
            else if let response { continuation?.resume(returning: (data, response)) }
            else { continuation?.resume(throwing: URLError(.badServerResponse)) }
        }
    }
}

/// YouTube's media servers reject AVFoundation's unbounded requests for some MP4
/// tracks. Serve bounded byte ranges through the public AVAsset resource loader.
@MainActor
final class NativeMediaRangeLoader: NSObject, @preconcurrency AVAssetResourceLoaderDelegate {
    let url: URL
    var onFailure: ((Error) -> Void)?
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    init(url: URL) { self.url = url; super.init() }
    func asset() -> AVURLAsset {
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        parts.scheme = "nova-media"
        let asset = AVURLAsset(url: parts.url!)
        asset.resourceLoader.setDelegate(self, queue: .main)
        return asset
    }
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        let key = ObjectIdentifier(request)
        tasks[key] = Task { [weak self] in
            guard let self else { return }
            defer { self.tasks[key] = nil }
            do {
                let parts = URLComponents(url: self.url, resolvingAgainstBaseURL: false)
                var length = parts?.queryItems?.first { $0.name == "clen" }?.value.flatMap(Int64.init) ?? 0
                let mime = parts?.queryItems?.first { $0.name == "mime" }?.value ?? "video/mp4"
                let dataRequest = request.dataRequest
                var offset = dataRequest.map { max($0.requestedOffset, $0.currentOffset) } ?? 0
                let requestedEnd = dataRequest.map { $0.requestedOffset + Int64($0.requestedLength) } ?? 2
                var end = length > 0 ? min(requestedEnd, length) : requestedEnd
                if dataRequest?.requestsAllDataToEndOfResource == true && length > 0 { end = length }
                repeat {
                    try Task.checkCancellation()
                    let upper = min(offset + 1_048_576, end) - 1
                    guard upper >= offset else { break }
                    var components = URLComponents(url: self.url, resolvingAgainstBaseURL: false)!
                    components.queryItems = (components.queryItems ?? []).filter { $0.name != "range" } + [URLQueryItem(name: "range", value: "\(offset)-\(upper)")]
                    var http = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
                    // Use the media endpoint's range parameter alone. Applying
                    // HTTP Range to that already bounded response causes 416
                    // errors as soon as playback requests a nonzero offset.
                    http.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                    http.setValue("com.google.ios.youtube/21.03.4 (iPhone16,2; U; CPU iOS 18_0 like Mac OS X;)", forHTTPHeaderField: "User-Agent")
                    let (data, response) = try await MediaRangeClient.shared.data(for: http, limit: Int(upper - offset + 1))
                    if length == 0, let total = response.value(forHTTPHeaderField: "Content-Range")?.split(separator: "/").last.flatMap({ Int64($0) }) {
                        length = total
                        end = dataRequest?.requestsAllDataToEndOfResource == true ? total : min(requestedEnd, total)
                    }
                    if let information = request.contentInformationRequest {
                        information.contentType = mime.hasPrefix("audio/") ? "public.mpeg-4-audio" : "public.mpeg-4"
                        information.contentLength = length
                        information.isByteRangeAccessSupported = true
                    }
                    try Task.checkCancellation()
                    guard !data.isEmpty else { throw MacAudioError(message: "The video stream ended unexpectedly.") }
                    dataRequest?.respond(with: data)
                    offset += Int64(data.count)
                    if dataRequest == nil { break }
                } while offset < end
                if !request.isCancelled { request.finishLoading() }
            } catch {
                if !request.isCancelled && !Task.isCancelled && !MediaRangeFailurePolicy.isCancellation(error) {
                    request.finishLoading(with: error)
                    self.onFailure?(error)
                }
            }
        }
        return true
    }
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        tasks.removeValue(forKey: ObjectIdentifier(loadingRequest))?.cancel()
    }

}

enum YouTubeStreamResolver {
    static func resolve(_ id: String, session: URLSession = .shared) async throws -> URL {
        try await source(id, session: session).url
    }
    static func source(_ id: String, session: URLSession = .shared, preferHLS: Bool = false) async throws -> YouTubeStreamSource {
        let data = try await response(id, session: session)
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let streams = root["streamingData"] as? [String: Any]
        let playable = (root["playabilityStatus"] as? [String: Any])?["status"] as? String == "OK"
        var alternateData: Data?
        if preferHLS, playable, streams?["hlsManifestUrl"] == nil {
            // Give the alternate client a chance to supply HLS before settling
            // for a muxed SD response. A valid old source survives lookup failure.
            alternateData = try? await response(id, session: session, liveHLS: true)
            try Task.checkCancellation()
            if let alternate = alternateData,
               let source = try? parseSource(alternate, preferHLS: true), source.isHLS { return source }
        }
        // Some recordings and broadcasts expose only SABR to the iOS client.
        // The alternate public client can supply native 360p MP4 or live HLS.
        if playable, streams?["hlsManifestUrl"] == nil {
            if let source = try? parseSource(data, preferHLS: preferHLS) { return source }
            if let alternateData { return try parseSource(alternateData, preferHLS: preferHLS) }
            return try parseSource(await response(id, session: session, liveHLS: true))
        }
        return try parseSource(data, preferHLS: preferHLS)
    }
    static func durationLabel(_ id: String, session: URLSession = .shared) async throws -> String? {
        let root = try JSONSerialization.jsonObject(with: await response(id, session: session)) as? [String: Any] ?? [:]
        guard !isLiveBroadcast(root), let details = root["videoDetails"] as? [String: Any],
              let raw = details["lengthSeconds"] as? String, let seconds = Int(raw), seconds > 0 else { return nil }
        return seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
    private static func response(_ id: String, session: URLSession, liveHLS: Bool = false) async throws -> Data {
        guard id.range(of:"^[A-Za-z0-9_-]{11}$",options:.regularExpression) != nil else { throw MacAudioError(message: "Invalid video link.") }
        var request = URLRequest(url: URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")!)
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
            let audio = (streams?["adaptiveFormats"] as? [[String:Any]] ?? []).filter { ($0["mimeType"] as? String)?.hasPrefix("audio/mp4") == true }.sorted { ($0["bitrate"] as? Int ?? 0) > ($1["bitrate"] as? Int ?? 0) }
            for format in audio {
                if let raw = format["url"] as? String, let url = URL(string:raw), url.scheme == "https", url.host?.hasSuffix(".googlevideo.com") == true { return YouTubeStreamSource(url:url,isLive:false) }
            }
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
        // The temporary 360p URL resolver must never become the TV's player.
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
      try { window.MediaSource = undefined; window.ManagedMediaSource = undefined; } catch (_) {}
      function capture(raw) {
        try {
          const url = new URL(raw, location.href);
          const mime = url.searchParams.get('mime') || '';
          if (!url.hostname.endsWith('.googlevideo.com') || seen.has(url.href)) return;
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
        knownLive = response.videoDetails.isLive === true || response?.microformat?.playerMicroformatRenderer?.liveBroadcastDetails?.isLiveNow === true;
        const master = response?.streamingData?.hlsManifestUrl;
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
    let player = AVPlayer()
    var emit: (([String:Any])->Void)?
    var remoteAction: ((String)->Void)?
    private let prepareItem: ((String) async throws -> AVPlayerItem)?
    private var resolver: EmbeddedStreamBridge?
    private var loader: NativeMediaRangeLoader?
    private var task: Task<Void,Never>?
    private var generation = UUID().uuidString
    private var videoID = ""
    private var loading = false
    private var requestedPlaying = false
    private var title = "", artist = ""
    private var clockObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var timeObservation: NSKeyValueObservation?
    private var itemObservation: NSKeyValueObservation?

    init(prepareItem: ((String) async throws -> AVPlayerItem)? = nil) {
        self.prepareItem=prepareItem
        player.automaticallyWaitsToMinimizeStalling = true
        player.defaultRate = 1
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
        MPNowPlayingInfoCenter.default().nowPlayingInfo=[MPMediaItemPropertyTitle:title,MPMediaItemPropertyArtist:artist,MPMediaItemPropertyPlaybackDuration:finite(player.currentItem?.duration.seconds ?? 0),MPNowPlayingInfoPropertyElapsedPlaybackTime:position,MPNowPlayingInfoPropertyPlaybackRate:player.timeControlStatus == .playing ? 1.0 : 0.0]
        MPNowPlayingInfoCenter.default().playbackState = player.timeControlStatus == .playing ? .playing : .paused
    }
    func stop() {
        task?.cancel(); task=nil; resolver?.cancel()
        player.pause();player.replaceCurrentItem(with:nil);loader=nil;itemObservation=nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver);self.endObserver=nil }
        videoID="";loading=false;requestedPlaying=false;generation=UUID().uuidString
        MPNowPlayingInfoCenter.default().nowPlayingInfo=nil
    }
    func handle(_ message:[String:Any]) {
        guard let request=message["request"] as? String, request.count<=80,
              let command=message["command"] as? String else { return }
        if command=="load" {
            guard let id=message["videoId"] as? String,id.range(of:"^[A-Za-z0-9_-]{11}$",options:.regularExpression) != nil,
                  let position=message["position"] as? Double,position.isFinite,position>=0,
                  let playing=message["playing"] as? Bool,let clientGeneration=message["generation"] as? String,clientGeneration.count<=80 else { return }
            stop();player.volume=Float(min(100,max(0,message["volume"] as? Double ?? 80))/100);videoID=id;generation=clientGeneration;loading=true;requestedPlaying=playing
            title=String((message["title"] as? String ?? "Nova Music").prefix(1000));artist=String((message["artist"] as? String ?? "").prefix(1000))
            let token=generation;publish()
            task=Task { [weak self] in
                guard let self else { return }
                do {
                    let item:AVPlayerItem
                    if let prepareItem { item=try await prepareItem(id) } else {
                    let source:YouTubeStreamSource
                    do { source=try await YouTubeStreamResolver.source(id) }
                    catch {
                        try Task.checkCancellation()
                        if resolver==nil { resolver=EmbeddedStreamBridge() }
                        source=try await resolver!.source(id)
                    }
                    try check(token)
                    if source.isHLS { item=AVPlayerItem(url:source.url) }
                    else {
                        let rangeLoader=NativeMediaRangeLoader(url:source.url);loader=rangeLoader
                        item=AVPlayerItem(asset:rangeLoader.asset())
                    }
                    }
                    try check(token)
                    item.preferredForwardBufferDuration=8
                    item.audioTimePitchAlgorithm = .spectral
                    player.replaceCurrentItem(with:item)
                    let deadline=Date().addingTimeInterval(20)
                    while item.status == .unknown && Date()<deadline { try await Task.sleep(for:.milliseconds(25));try check(token) }
                    guard item.status == .readyToPlay else { throw item.error ?? MacAudioError(message:"This recording could not prepare. Try another recording.") }
                    try await seek(position,token:token)
                    try check(token);loading=false
                    endObserver=NotificationCenter.default.addObserver(forName:.AVPlayerItemDidPlayToEndTime,object:item,queue:.main) { [weak self] _ in
                        Task { @MainActor in guard let self,self.generation==token else { return };var value=self.snapshot;value["state"]=0;self.emit?(["state":value]); }
                    }
                    itemObservation=item.observe(\.status,options:[.new]) { [weak self] item,_ in
                        guard item.status == .failed else { return }
                        Task { @MainActor in guard let self,self.generation==token else { return };self.player.pause();self.emit?(["error":"The audio stream stopped. Try playing the song again.","generation":token]); }
                    }
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
