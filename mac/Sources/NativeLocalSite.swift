import Foundation
import Network

/// Serves only the app's bundled, read-only interface on the loopback address.
/// A stable origin keeps WebKit's device library and settings available after relaunch.
final class NativeLocalSite {
    static func port(bundleID: String) -> UInt16 { bundleID.hasSuffix(".review") ? 47938 : 47937 }
    private let root: URL
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.nova.music.local-interface")
    init(root: URL, port: UInt16) throws {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        listener = try NWListener(using: parameters)
    }
    func start() async throws {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            connection.start(queue: self.queue)
            self.receive(connection, bytes: Data())
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let startup = Startup(continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: startup.finish(.success(()))
                case .failed(let error), .waiting(let error): startup.finish(.failure(error))
                case .cancelled: startup.finish(.failure(CancellationError()))
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }
    private func receive(_ connection: NWConnection, bytes: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, complete, error in
            guard let self, error == nil else { connection.cancel(); return }
            var bytes = bytes
            if let data { bytes.append(data) }
            guard bytes.count <= 16384 else { self.reply(connection, status: "413 Content Too Large", contentType: "text/plain", body: Data()); return }
            if bytes.range(of: Data("\r\n\r\n".utf8)) != nil { self.respond(connection, request: bytes) }
            else if complete { connection.cancel() }
            else { self.receive(connection, bytes: bytes) }
        }
    }
    private func respond(_ connection: NWConnection, request: Data) {
        guard let header = String(data: request, encoding: .utf8), let line = header.components(separatedBy: "\r\n").first else { connection.cancel(); return }
        let parts = line.split(separator: " ")
        guard parts.count == 3, ["GET", "HEAD"].contains(parts[0]) else { reply(connection, status: "405 Method Not Allowed", contentType: "text/plain", body: Data()); return }
        guard let path = Self.relativePath(String(parts[1])) else { reply(connection, status: "400 Bad Request", contentType: "text/plain", body: Data()); return }
        let file = root.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        guard file.path.hasPrefix(root.path + "/"), let data = try? Data(contentsOf: file), data.count <= 30_000_000 else { reply(connection, status: "404 Not Found", contentType: "text/plain", body: Data()); return }
        let types = ["html":"text/html; charset=utf-8", "js":"text/javascript; charset=utf-8", "css":"text/css; charset=utf-8", "json":"application/json", "webmanifest":"application/manifest+json", "png":"image/png", "jpg":"image/jpeg", "jpeg":"image/jpeg", "svg":"image/svg+xml", "ico":"image/x-icon", "woff2":"font/woff2"]
        reply(connection, status: "200 OK", contentType: types[file.pathExtension.lowercased()] ?? "application/octet-stream", body: data, head: parts[0] == "HEAD")
    }
    static func relativePath(_ target: String) -> String? {
        guard target.hasPrefix("/"), !target.hasPrefix("//"),
              let path = String(target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0]).removingPercentEncoding,
              !path.contains("\\"), !path.contains("\0"), !path.contains("\r"), !path.contains("\n") else { return nil }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.contains(".."), !components.contains(".") else { return nil }
        return components.isEmpty ? "index.html" : components.joined(separator: "/")
    }
    private func reply(_ connection: NWConnection, status: String, contentType: String, body: Data, head: Bool = false) {
        let header = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nCache-Control: no-cache\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n"
        var response = Data(header.utf8)
        if !head { response.append(body) }
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
    private final class Startup: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Error>?
        init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }
        func finish(_ result: Result<Void, Error>) {
            lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
            pending?.resume(with: result)
        }
    }
    deinit { listener.cancel() }
}
