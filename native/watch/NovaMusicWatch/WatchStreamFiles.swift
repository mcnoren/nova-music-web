import Foundation
import ImageIO
import CoreGraphics
import SwiftUI

/// Progressive sources that require provider range parameters are staged to a file.
/// These temporary playback files are never advertised as user downloads.
enum WatchAudioFileRequest {
    static func make(_ url: URL) -> URLRequest {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if let count = components?.queryItems?.first(where: { $0.name == "clen" })?.value.flatMap(Int64.init), count > 0 {
            let retained = (components?.queryItems ?? []).filter { $0.name != "range" }
            components?.queryItems = retained + [.init(name: "range", value: "0-\(count - 1)")]
        }
        var request = URLRequest(url: components?.url ?? url, timeoutInterval: 30)
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("com.google.ios.youtube/21.03.4 (iPhone16,2; U; CPU iOS 18_0 like Mac OS X;)", forHTTPHeaderField: "User-Agent")
        return request
    }
}
actor WatchStreamFileCache {
    static let shared = WatchStreamFileCache()
    private var files: [String: (url: URL, date: Date)] = [:]
    func file(_ source: YouTubeStreamSource, id: String, retaining: Set<String>) async throws -> URL {
        if let file = files[id]?.url, FileManager.default.fileExists(atPath: file.path) { return file }
        let (temporary, response) = try await URLSession.shared.download(for: WatchAudioFileRequest.make(source.url))
        try Task.checkCancellation()
        guard [200,206].contains((response as? HTTPURLResponse)?.statusCode ?? 0) else { throw URLError(.badServerResponse) }
        let expected = URLComponents(url: source.url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "clen" })?.value.flatMap(Int64.init)
        let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        if let expected, Int64(size) != expected { try? FileManager.default.removeItem(at: temporary); throw URLError(.cannotDecodeContentData) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NovaPlayback", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(UUID().uuidString + ".m4a")
        try FileManager.default.moveItem(at: temporary, to: destination)
        do { _ = try await WatchDownloadedAsset.duration(of: destination); try Task.checkCancellation() }
        catch { try? FileManager.default.removeItem(at: destination); throw error }
        files[id] = (destination, Date())
        for (key, value) in files where !retaining.contains(key) && key != id { try? FileManager.default.removeItem(at: value.url); files[key] = nil }
        return destination
    }
}
actor WatchArtworkPalette {
    static let shared = WatchArtworkPalette()
    private var cache: [URL: UInt32] = [:]
    func color(_ url: URL) async -> UInt32? {
        if let cached = cache[url] { return cached }
        do {
            let data: Data
            if url.isFileURL { data = try Data(contentsOf: url) } else { data = try await URLSession.shared.data(from: url).0 }
            guard data.count < 10_000_000, let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 32] as CFDictionary) else { return nil }
            var pixel: [UInt8] = [0,0,0,0]
            let rendered = pixel.withUnsafeMutableBytes { bytes -> Bool in
                guard let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1)); return true
            }
            guard rendered else { return nil }
            let value = UInt32(pixel[0]) << 16 | UInt32(pixel[1]) << 8 | UInt32(pixel[2])
            if cache.count >= 40 { cache.removeAll() }; cache[url] = value; return value
        } catch { return nil }
    }
}
struct WatchArtworkBackdrop: View {
    var url: URL?
    @State private var color: UInt32?
    var body: some View {
        let value = color ?? 0x173626
        LinearGradient(colors: [Color(red: Double(value >> 16 & 255) / 255, green: Double(value >> 8 & 255) / 255, blue: Double(value & 255) / 255).opacity(0.3), .black], startPoint: .topLeading, endPoint: .bottomTrailing)
            .task(id: url) { guard let url else { return }; let result = await WatchArtworkPalette.shared.color(url); guard !Task.isCancelled else { return }; color = result }
    }
}
