import Foundation

@main
struct NativeLocalSiteTests {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("<h1>Nova interface</h1>".utf8).write(to: root.appendingPathComponent("index.html"))
        try Data("export const bundled=true;".utf8).write(to: root.appendingPathComponent("app.js"))
        for input in ["/../outside", "/%2e%2e/outside", "/x/%2e%2e/outside", "//outside", "https://example.com/", "/%00", "/%5coutside"] {
            precondition(NativeLocalSite.relativePath(input) == nil, "Accepted unsafe path: \(input)")
        }
        precondition(NativeLocalSite.relativePath("/app.js?v=abc") == "app.js")
        let server = try NativeLocalSite(root: root, port: 47939)
        try await server.start()
        let session = URLSession(configuration: .ephemeral)
        let (page, response) = try await session.data(from: URL(string: "http://127.0.0.1:47939/")!)
        precondition((response as? HTTPURLResponse)?.statusCode == 200)
        precondition(String(decoding: page, as: UTF8.self).contains("Nova interface"))
        let (script, scriptResponse) = try await session.data(from: URL(string: "http://127.0.0.1:47939/app.js?v=abc")!)
        precondition(!script.isEmpty)
        precondition((scriptResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")?.contains("javascript") == true)
        let (_, missing) = try await session.data(from: URL(string: "http://127.0.0.1:47939/missing.js")!)
        precondition((missing as? HTTPURLResponse)?.statusCode == 404)
        var head = URLRequest(url: URL(string: "http://127.0.0.1:47939/app.js")!); head.httpMethod = "HEAD"
        let (headBody, headResponse) = try await session.data(for: head)
        precondition(headBody.isEmpty)
        precondition((headResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Length") == String(script.count))
        let duplicate = try NativeLocalSite(root: root, port: 47939)
        do { try await duplicate.start(); preconditionFailure("Duplicate listener should fail") } catch {}
        withExtendedLifetime(server) {}
        print("Native bundled interface: paths, GET, JS modules, HEAD, missing assets and port conflicts passed")
    }
}
