import Foundation

private final class CatalogProtocol: URLProtocol {
    static var blocked = false
    static var stops = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if Self.blocked { return }
        precondition(request.url?.host == "music.youtube.com" || request.url?.host == "lrclib.net")
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"contents\":[]}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { Self.stops += 1 }
}

@main struct NativeMusicCatalogTests {
    static func main() async throws {
        let inputs: [[String: Any]] = [
            ["operation": "search", "body": ["query": "Hello Adele"]],
            ["operation": "suggestions", "body": ["input": "adele he"]],
            ["operation": "search", "body": ["continuation": "next_page=="]],
            ["operation": "browse", "body": ["browseId": "MPREalbum"]],
            ["operation": "browse", "body": ["browseId": "FEmusic_explore"]],
            ["operation": "next", "body": ["videoId": "studio00001", "isAudioOnly": true]],
            ["operation": "lyricSearch", "body": ["track_name": "Hello", "artist_name": "Adele"]]
        ]
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [CatalogProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        for input in inputs {
            let request = try NativeMusicCatalog.Request(input)
            let urlRequest = try request.urlRequest()
            precondition(urlRequest.timeoutInterval == (request.operation == .lyricSearch ? 4 : request.operation == .suggestions ? 5 : 20))
            let result = try await NativeMusicCatalog.fetch(request, session: session) as! [String: Any]
            precondition(result["contents"] != nil)
        }
        let invalid: [[String: Any]] = [
            ["operation": "proxy", "body": ["url": "https://evil.test"]],
            ["operation": "suggestions", "body": ["input": "Hello", "url": "https://evil.test"]],
            ["operation": "search", "body": ["query": "Hello", "context": ["client": "evil"]]],
            ["operation": "search", "body": ["query": String(repeating: "a", count: 201)]],
            ["operation": "search", "body": ["query": "Hello", "params": "arbitrary"]],
            ["operation": "browse", "body": ["browseId": "https://evil.test"]],
            ["operation": "search", "body": ["continuation": "<script>"]],
            ["operation": "next", "body": ["videoId": "short", "isAudioOnly": true]],
            ["operation": "lyricSearch", "body": ["track_name": "Hello", "artist_name": "Adele", "url": "https://evil.test"]]
        ]
        for input in invalid {
            do { _ = try NativeMusicCatalog.Request(input); preconditionFailure("Invalid catalog operation accepted") }
            catch { precondition(error is NativeMusicCatalog.Failure) }
        }
        CatalogProtocol.blocked = true
        let pending = Task { try await NativeMusicCatalog.fetch(NativeMusicCatalog.Request(inputs[0]), session: session) }
        try await Task.sleep(for: .milliseconds(30)); pending.cancel()
        do { _ = try await pending.value; preconditionFailure("Cancelled catalog request returned") }
        catch { precondition(error is CancellationError || (error as? URLError)?.code == .cancelled) }
        precondition(CatalogProtocol.stops > 0)
        print("Native catalog: 7 operations, 9 rejected inputs, cancellation and request budgets passed")
    }
}
