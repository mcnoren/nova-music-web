import Foundation

/// Public catalog metadata only. Callers supply a validated operation, never a URL.
enum NativeMusicCatalog {
    enum Operation: String { case search, browse, next, lyricSearch, suggestions }
    struct Request {
        let operation: Operation
        let body: [String: Any]
        let timedLyrics: Bool
        init(_ value: [String: Any]) throws {
            guard let name = value["operation"] as? String, let operation = Operation(rawValue: name),
                  let body = value["body"] as? [String: Any],
                  JSONSerialization.isValidJSONObject(body),
                  (try JSONSerialization.data(withJSONObject: body)).count <= 16_000 else { throw Failure.invalid }
            func matches(_ text: Any?, _ pattern: String) -> Bool {
                guard let text = text as? String else { return false }
                return text.range(of: pattern, options: .regularExpression) != nil
            }
            let cursor = body["continuation"]
            if cursor != nil {
                guard operation == .search || operation == .browse, Set(body.keys) == ["continuation"],
                      matches(cursor, #"^[A-Za-z0-9_=%+./-]{1,12000}$"#) else { throw Failure.invalid }
            } else {
                switch operation {
                case .suggestions:
                    guard Set(body.keys) == ["input"], let input = body["input"] as? String,
                          !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, input.count <= 200 else { throw Failure.invalid }
                case .search:
                    let filters = ["EgWKAQIIAWoKEAkQChAFEAMQBA==", "EgWKAQIgAWoKEAkQChAFEAMQBA==", "EgWKAQIYAWoKEAkQChAFEAMQBA==", "EgWKAQIoAWoKEAkQChAFEAMQBA=="]
                    guard Set(body.keys).isSubset(of: ["query", "params"]), let query = body["query"] as? String,
                          !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, query.count <= 200,
                          body["params"] == nil || filters.contains(body["params"] as? String ?? "") else { throw Failure.invalid }
                case .browse:
                    guard Set(body.keys).isSubset(of: ["browseId", "params"]),
                          matches(body["browseId"], #"^(?:(?:UC|MPRE|VL)[A-Za-z0-9_-]{1,150}|MPLY[A-Za-z0-9_-]{1,4000}|FEmusic_explore)$"#),
                          body["params"] == nil || matches(body["params"], #"^[A-Za-z0-9_=%+./-]{1,4000}$"#) else { throw Failure.invalid }
                case .next:
                    guard Set(body.keys) == ["videoId", "isAudioOnly"], matches(body["videoId"], #"^[A-Za-z0-9_-]{11}$"#),
                          body["isAudioOnly"] as? Bool == true else { throw Failure.invalid }
                case .lyricSearch:
                    guard Set(body.keys) == ["track_name", "artist_name"],
                          ["track_name", "artist_name"].allSatisfy({ key in
                              guard let text = body[key] as? String else { return false }
                              return !text.isEmpty && text.count <= 300
                          }) else { throw Failure.invalid }
                }
            }
            self.operation = operation; self.body = body
            timedLyrics = value["timedLyrics"] as? Bool ?? false
            guard !timedLyrics || operation == .browse else { throw Failure.invalid }
        }
        func urlRequest() throws -> URLRequest {
            if operation == .lyricSearch {
                var components = URLComponents(string: "https://lrclib.net/api/search")!
                components.queryItems = ["track_name", "artist_name"].map { URLQueryItem(name: $0, value: body[$0] as? String) }
                var request = URLRequest(url: components.url!); request.timeoutInterval = 4
                request.setValue("NovaMusic/1.0 (song search; https://lrclib.net)", forHTTPHeaderField: "User-Agent")
                return request
            }
            let endpoint = operation == .suggestions ? "music/get_search_suggestions" : operation.rawValue
            var request = URLRequest(url: URL(string: "https://music.youtube.com/youtubei/v1/\(endpoint)?prettyPrint=false")!)
            request.httpMethod = "POST"; request.timeoutInterval = operation == .suggestions ? 5 : 20
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            request.setValue("https://music.youtube.com", forHTTPHeaderField: "Origin")
            request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
            var payload = body
            payload["context"] = ["client": ["clientName": timedLyrics ? "ANDROID_MUSIC" : "WEB_REMIX",
                "clientVersion": timedLyrics ? "7.21.50" : "1.20240918.01.00", "hl": "en", "gl": "US"]]
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            return request
        }
    }
    enum Failure: LocalizedError {
        case invalid, unavailable
        var errorDescription: String? {
            switch self {
            case .invalid: return "Invalid catalog request."
            case .unavailable: return "Live music search is unavailable. Try again."
            }
        }
    }
    private final class RedirectPolicy: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            // Catalog operations never need a redirect to another service or host.
            completionHandler(nil)
        }
    }
    private static let publicSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForResource = 20
        return URLSession(configuration: config)
    }()
    static func fetch(_ request: Request, session: URLSession = publicSession) async throws -> Any {
        let (data, response) = try await session.data(for: request.urlRequest(), delegate: RedirectPolicy())
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              data.count <= 8_000_000 else { throw Failure.unavailable }
        return try JSONSerialization.jsonObject(with: data)
    }
}
