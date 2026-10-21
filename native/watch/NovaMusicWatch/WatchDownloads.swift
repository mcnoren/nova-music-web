import Foundation
import AVFoundation
import Combine
import Network

struct WatchDownload: Codable, Identifiable, Equatable {
    enum State: String, Codable { case queued, resolving, downloading, validating, downloaded, failed, paused }
    var song: YouTubeVideo
    var state: State = .queued
    var progress: Double = 0
    var file: String?
    var failure: String?
    var transfer = UUID()
    var retries = 0
    var bytes: Int64 = 0
    var id: String { song.id }
}

@MainActor
final class WatchDownloadStore: NSObject, ObservableObject {
    static let shared = WatchDownloadStore()
    @Published private(set) var records: [WatchDownload] = []
    @Published var offlineOnly: Bool { didSet { defaults.set(offlineOnly, forKey: "watch.offlineOnly") } }
    @Published var allowCellular: Bool { didSet { defaults.set(allowCellular, forKey: "watch.cellularDownloads") } }
    @Published private(set) var storageError: String?
    let directory: URL
    private let defaults: UserDefaults
    private var resolving: [String: Task<Void, Never>] = [:]
    private var tasks: [String: URLSessionTask] = [:]
    private var progressObservations: [String: NSKeyValueObservation] = [:]
    private var recovered = false
    private lazy var wifi = makeSession(cellular: false)
    private lazy var cellular = makeSession(cellular: true)
    private lazy var hlsWifi = makeAssetSession(cellular: false)
    private lazy var hlsCellular = makeAssetSession(cellular: true)
    var backgroundCompletions: [String: [() -> Void]] = [:]
    private var finishedSessions = Set<String>()
    private var validations = 0
    var usedBytes: Int64 { records.reduce(0) { $0 + $1.bytes } }
    var songs: [YouTubeVideo] { records.filter { $0.state == .downloaded && localURL($0.id) != nil }.map(\.song) }
    init(directory: URL? = nil, defaults: UserDefaults = WatchEnvironment.defaults) {
        self.defaults = defaults
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("WatchDownloads", isDirectory: true)
        offlineOnly = defaults.bool(forKey: "watch.offlineOnly"); allowCellular = defaults.bool(forKey: "watch.cellularDownloads")
        super.init()
        do {
            try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
            var url = self.directory; var values = URLResourceValues(); values.isExcludedFromBackup = true; try url.setResourceValues(values)
            if let data = try? Data(contentsOf: self.directory.appendingPathComponent("manifest.json")) { records = try JSONDecoder().decode([WatchDownload].self, from: data) }
        } catch { storageError = error.localizedDescription }
    }
    func recover() async {
        guard !recovered else { return }; recovered = true
        for session in [wifi, cellular, hlsWifi, hlsCellular] {
            for task in await session.allTasks {
                guard let token = task.taskDescription, let index = records.firstIndex(where: { $0.transfer.uuidString == token && $0.state != .paused && $0.state != .downloaded }) else { task.cancel(); continue }
                tasks[records[index].id] = task; records[index].state = .downloading
            }
        }
        let interrupted = records.filter { $0.state == .validating && $0.file != nil }
        for entry in interrupted {
            if let file = entry.file { await complete(token: entry.transfer.uuidString, url: URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(file)) }
        }
        for index in records.indices {
            if records[index].state == .downloaded, localURL(records[index].id) == nil { records[index].state = .failed; records[index].failure = "The downloaded file is missing. Download it again." }
            if [.queued, .resolving, .downloading, .validating].contains(records[index].state), tasks[records[index].id] == nil { records[index].state = .queued }
        }
        persist(); schedule()
    }
    private func configuration(_ name: String, cellular: Bool) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.background(withIdentifier: "com.example.NovaMusic.watch." + directory.lastPathComponent + "." + name + (cellular ? ".cellular" : ".wifi"))
        config.allowsCellularAccess = cellular; config.allowsExpensiveNetworkAccess = cellular
        config.isDiscretionary = false; config.sessionSendsLaunchEvents = true; config.waitsForConnectivity = true
        return config
    }
    private func makeSession(cellular: Bool) -> URLSession { URLSession(configuration: configuration("files", cellular: cellular), delegate: self, delegateQueue: nil) }
    private func makeAssetSession(cellular: Bool) -> AVAssetDownloadURLSession { AVAssetDownloadURLSession(configuration: configuration("hls", cellular: cellular), assetDownloadDelegate: self, delegateQueue: nil) }
    func add(_ songs: [YouTubeVideo]) {
        for song in songs where YouTubeLink.validID(song.id) {
            if let index = records.firstIndex(where: { $0.id == song.id }) {
                guard records[index].state == .failed || records[index].state == .paused else { continue }
                records[index].state = .queued; records[index].failure = nil; records[index].transfer = UUID(); records[index].retries = 0
            } else { records.append(.init(song: song)) }
        }
        persist(); schedule()
    }
    func pause(_ id: String) {
        guard let index = records.firstIndex(where: { $0.id == id && $0.state != .downloaded }) else { return }
        records[index].state = .paused; records[index].transfer = UUID(); resolving[id]?.cancel(); resolving[id] = nil; tasks[id]?.cancel(); tasks[id] = nil
        persist(); schedule()
    }
    func remove(_ id: String) {
        guard let record = records.first(where: { $0.id == id }) else { return }
        pause(id)
        if let path = record.file {
            let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(path).standardizedFileURL
            if url.path.hasPrefix(NSHomeDirectory() + "/") { try? FileManager.default.removeItem(at: url) }
        }
        for suffix in [".lyrics", ".jpg", ".m4a"] { try? FileManager.default.removeItem(at: directory.appendingPathComponent(record.transfer.uuidString + suffix)) }
        records.removeAll { $0.id == id }; persist()
    }
    private func finishBackgroundEvents() {
        guard validations == 0 else { return }
        for identifier in finishedSessions {
            guard let callbacks = backgroundCompletions.removeValue(forKey: identifier) else { continue }
            callbacks.forEach { $0() }
        }
        finishedSessions.removeAll()
    }
    func registerBackgroundTask(identifier: String, completion: @escaping () -> Void) {
        backgroundCompletions[identifier, default: []].append(completion)
        finishBackgroundEvents()
    }
    func localURL(_ id: String) -> URL? {
        guard let record = records.first(where: { $0.id == id && $0.state == .downloaded }), let path = record.file else { return nil }
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(path).standardizedFileURL
        guard url.path.hasPrefix(NSHomeDirectory() + "/"), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
    func cachedLyrics(_ id: String) -> TrackLyrics? {
        guard let entry = records.first(where: { $0.id == id }), let data = try? Data(contentsOf: directory.appendingPathComponent(entry.transfer.uuidString + ".lyrics")) else { return nil }
        return try? JSONDecoder().decode(TrackLyrics.self, from: data)
    }
    func cachedArtwork(_ id: String) -> URL? {
        guard let entry = records.first(where: { $0.id == id }) else { return nil }
        let url = directory.appendingPathComponent(entry.transfer.uuidString + ".jpg")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    private func schedule() {
        guard recovered else { return }
        for record in records where record.state == .queued && resolving.count + tasks.count < 2 {
            let id = record.id, transfer = record.transfer
            guard let index = records.firstIndex(where: { $0.id == id }) else { continue }
            records[index].state = .resolving
            resolving[id] = Task {
                do {
                    let source = try await YouTubeStreamResolver.audioSource(id)
                    try Task.checkCancellation()
                    guard let index = records.firstIndex(where: { $0.id == id && $0.transfer == transfer }) else { return }
                    let capacity = try directory.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity ?? 0
                    guard capacity > 40_000_000 else { throw YouTubeAPI.Failure(message: "Not enough storage. Remove some downloads and try again.") }
                    let task: URLSessionTask
                    if source.isHLS {
                        let configuration = AVAssetDownloadConfiguration(asset: AVURLAsset(url: source.url), title: record.song.title)
                        task = (allowCellular ? hlsCellular : hlsWifi).makeAssetDownloadTask(downloadConfiguration: configuration)
                    } else {
                        var request = WatchAudioFileRequest.make(source.url); request.allowsCellularAccess = allowCellular
                        task = (allowCellular ? cellular : wifi).downloadTask(with: request)
                    }
                    task.taskDescription = transfer.uuidString; tasks[id] = task; records[index].state = .downloading
                    progressObservations[id] = task.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] progress, _ in
                        let fraction = progress.fractionCompleted
                        Task { @MainActor in if let self, let index = self.records.firstIndex(where: { $0.transfer == transfer }) { self.records[index].progress = min(0.99, max(0, fraction)) } }
                    }
                    resolving[id] = nil; persist(); task.resume()
                } catch {
                    if !Task.isCancelled, let index = records.firstIndex(where: { $0.id == id && $0.transfer == transfer }) { records[index].state = .failed; records[index].failure = error.localizedDescription }
                    resolving[id] = nil; persist(); schedule()
                }
            }
        }
        persist()
    }
    private func persist() {
        defaults.set(try? JSONEncoder().encode(songs), forKey: "watch.downloadedSongs")
        do { try JSONEncoder().encode(records).write(to: directory.appendingPathComponent("manifest.json"), options: .atomic); storageError = nil }
        catch { storageError = "Downloads couldn’t be saved: " + error.localizedDescription }
    }
    private func complete(token: String, url: URL) async {
        validations += 1; defer { validations -= 1; finishBackgroundEvents() }
        guard let index = records.firstIndex(where: { $0.transfer.uuidString == token && $0.state != .paused }) else { try? FileManager.default.removeItem(at: url); return }
        records[index].state = .validating; let id = records[index].id
        if url.path.hasPrefix(NSHomeDirectory() + "/") { records[index].file = String(url.path.dropFirst(NSHomeDirectory().count + 1)); persist() }
        do {
            let length = try await WatchDownloadedAsset.duration(of: url)
            guard let index = records.firstIndex(where: { $0.transfer.uuidString == token && $0.state == .validating }) else { try? FileManager.default.removeItem(at: url); return }
            let path = url.path; guard path.hasPrefix(NSHomeDirectory() + "/") else { throw URLError(.badURL) }
            records[index].file = String(path.dropFirst(NSHomeDirectory().count + 1)); records[index].state = .downloaded; records[index].progress = 1
            let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])?.allObjects as? [URL] ?? [url]
            records[index].bytes = files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            tasks[id] = nil; progressObservations[id] = nil; persist(); schedule()
            let song = records[index].song
            Task {
                if let lyrics = try? await MusicLyricsSource.shared.lyrics(for: song, duration: length), let data = try? JSONEncoder().encode(lyrics), records.contains(where: { $0.transfer.uuidString == token }) { try? data.write(to: directory.appendingPathComponent(token + ".lyrics"), options: .atomic) }
                if let artwork = song.thumbnail, let (data, _) = try? await URLSession.shared.data(from: artwork), let jpeg = try? MusicImageData.jpeg(data, maximumDimension: 300), records.contains(where: { $0.transfer.uuidString == token }) { try? jpeg.write(to: directory.appendingPathComponent(token + ".jpg"), options: .atomic) }
            }
        } catch { try? FileManager.default.removeItem(at: url); fail(token: token, error: error) }
    }
    private func fail(token: String, error: Error) {
        guard let index = records.firstIndex(where: { $0.transfer.uuidString == token && ![.downloaded, .paused].contains($0.state) }) else { return }
        let id = records[index].id; tasks[id] = nil; progressObservations[id] = nil
        if records[index].retries == 0 { records[index].retries += 1; records[index].state = .queued; records[index].transfer = UUID(); Task { await YouTubeStreamCache.shared.remove(id); schedule() } }
        else { records[index].state = .failed; records[index].failure = error.localizedDescription; schedule() }
        persist()
    }
}
extension WatchDownloadStore: URLSessionDownloadDelegate, AVAssetDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let token = downloadTask.taskDescription else { return }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(token + ".m4a")
        do {
            guard [200, 206].contains((downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0) else { throw URLError(.badServerResponse) }
            let expected = downloadTask.originalRequest?.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "clen" })?.value.flatMap(Int64.init) }
            let size = try location.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            if let expected, expected != Int64(size) { throw URLError(.cannotDecodeContentData) }
            try FileManager.default.moveItem(at: location, to: temp)
            Task { @MainActor in
                let destination = directory.appendingPathComponent(token + ".m4a")
                do { try FileManager.default.moveItem(at: temp, to: destination); await complete(token: token, url: destination) } catch { fail(token: token, error: error) }
            }
        } catch { Task { @MainActor in fail(token: token, error: error) } }
    }
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let token = downloadTask.taskDescription, totalBytesExpectedToWrite > 0 else { return }
        Task { @MainActor in if let index = records.firstIndex(where: { $0.transfer.uuidString == token }) { records[index].progress = min(0.99, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) } }
    }
    nonisolated func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, willDownloadTo location: URL) {
        guard let token = assetDownloadTask.taskDescription else { return }
        Task { @MainActor in if let index = records.firstIndex(where: { $0.transfer.uuidString == token }) { records[index].file = String(location.path.dropFirst(NSHomeDirectory().count + 1)); persist() } }
    }
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let token = task.taskDescription else { return }
        Task { @MainActor in
            if let error { fail(token: token, error: error) }
            else if task is AVAssetDownloadTask, let record = records.first(where: { $0.transfer.uuidString == token }), let file = record.file { await complete(token: token, url: URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(file)) }
        }
    }
    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) { Task { @MainActor in if let identifier = session.configuration.identifier { finishedSessions.insert(identifier); finishBackgroundEvents() } } }
}

/// Both completion and recovery use AVFoundation to verify a usable local asset.
enum WatchDownloadedAsset {
    static func duration(of url: URL) async throws -> Double {
        let asset = AVURLAsset(url: url)
        guard try await asset.load(.isPlayable) else { throw URLError(.cannotDecodeContentData) }
        let value = try await asset.load(.duration).seconds
        guard value.isFinite, value > 0 else { throw URLError(.cannotDecodeContentData) }
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
           (try FileManager.default.contentsOfDirectory(atPath: url.path)).isEmpty { throw YouTubeAPI.Failure(message: "This stream did not finish downloading. Try again.") }
        return value
    }
}
