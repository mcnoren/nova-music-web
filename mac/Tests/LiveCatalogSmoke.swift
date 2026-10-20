import Foundation

/// Optional integration helper: one validated public operation, JSON response on stdout.
@main struct LiveCatalogSmoke {
    static func main() async throws {
        guard CommandLine.arguments.count == 2,
              let input = try JSONSerialization.jsonObject(with: Data(CommandLine.arguments[1].utf8)) as? [String: Any] else {
            throw NativeMusicCatalog.Failure.invalid
        }
        let response = try await NativeMusicCatalog.fetch(NativeMusicCatalog.Request(input))
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: response))
    }
}
