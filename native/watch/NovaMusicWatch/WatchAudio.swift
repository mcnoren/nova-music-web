import Foundation
import AVFoundation
import MediaPlayer
import Combine
import WatchKit
import SwiftUI

/// Owns audio on the Watch. No phone or web view participates in source resolution.
@MainActor
final class YouTubePlayer: NSObject, ObservableObject {
    enum RepeatMode: String, CaseIterable { case off, all, one }
    @Published var currentVideoID: String?
    @Published var playlistIDs: [String] = []
    @Published var playlistIndex = 0
    @Published var queueEntries: [MusicPlaybackQueueEntry] = []
    @Published var intendsPlayback = false
    @Published var playing = false
    @Published var loading = false
    @Published var ready = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var error: String?
    @Published var shuffled = false
    @Published var repeatMode: RepeatMode = .off { didSet { prefetch() } }
    @Published var lyrics: TrackLyrics?
    @Published var lyricsLoading = false
    @Published var lyricError: String?
    @Published var calibration = LyricCalibration()
    var musicTracks: [String: YouTubeVideo] = [:]
    var currentSongIsLiked = false { didSet { publishNowPlaying() } }
    var musicQueueEdited = false
    var resumesPosition = false, prefersMusicAudio = true, audioOnly = true
    var onPlaybackEnded: ((String) -> Bool)?
    var onUserQueueEdit: (() -> Void)?
    var onLikeCurrentSong: (() -> Void)?
    var orderedPlaylistIDs: [String] { queueEntries.sorted { $0.order < $1.order }.map(\.videoID) }
    var currentQueueOrigin: String? { queueEntries.indices.contains(playlistIndex) ? queueEntries[playlistIndex].originContext : nil }
    var title: String { musicTracks[currentVideoID ?? ""]?.title ?? "Nova Music" }
    var artist: String { musicTracks[currentVideoID ?? ""]?.channel ?? "" }
    var hasStartedPlayback = false
    let nativePlayer = AVQueuePlayer()
    private let defaults: UserDefaults
    private let resolver: any MusicStreamResolving
    private var loadingTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    private var lyricsTask: Task<Void, Never>?
    private var generation = UUID()
    private var revision = UUID()
    private var tick: Any?
    private var itemObservation: NSKeyValueObservation?
    private var timeObservation: NSKeyValueObservation?
    private var observations = Set<AnyCancellable>()
    private var prepared: (id: UUID, item: AVPlayerItem)?
    private var itemEntries: [ObjectIdentifier: UUID] = [:]
    private var interruptedIntent = false
    private var restoredTime: Double = 0
    private var lastProgress = Date()
    private var lastClock: Double = 0
    private var recoveryUsed = false
    var downloads: WatchDownloadStore = .shared

    init(defaults: UserDefaults = .standard, resolver: any MusicStreamResolving = NativeMusicStreamResolver()) {
        self.resolver = resolver
        self.defaults = defaults
        super.init()
        nativePlayer.actionAtItemEnd = .advance
        tick = nativePlayer.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                let value = time.seconds
                if value.isFinite { self.currentTime = value }
                let length = self.nativePlayer.currentItem?.duration.seconds ?? 0
                if length.isFinite { self.duration = max(0, length) }
                self.playing = self.nativePlayer.rate > 0
                if self.playing && value > 0 { self.hasStartedPlayback = true }
                if value > self.lastClock + 0.05 { self.lastProgress = Date(); self.lastClock = value }
                if self.intendsPlayback, self.ready, Date().timeIntervalSince(self.lastProgress) > 25 {
                    if !self.recoveryUsed { self.loadCurrent(at: self.currentTime, retry: true) }
                    else { self.error = "Playback lost its connection. Press Play to retry."; self.pause() }
                }
            }
        }
        itemObservation = nativePlayer.observe(\.currentItem, options: [.new]) { [weak self] player, _ in
            Task { @MainActor in
                guard let self, let item = player.currentItem, let id = self.itemEntries[ObjectIdentifier(item)],
                      let index = self.queueEntries.firstIndex(where: { $0.id == id }) else { return }
                self.timeObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                    guard item.status == .failed else { return }
                    Task { @MainActor in
                        guard let self, self.nativePlayer.currentItem === item, self.intendsPlayback else { return }
                        if !self.recoveryUsed { self.loadCurrent(at: self.currentTime, retry: true) }
                        else { self.error = item.error?.localizedDescription ?? "The song could not play. Press Play to retry."; self.pause() }
                    }
                }
                if self.playlistIndex != index {
                    self.playlistIndex = index; self.currentVideoID = self.queueEntries[index].videoID
                    self.currentTime = 0; self.ready = true; self.prepared = nil; self.lastClock = 0; self.lastProgress = Date(); self.recoveryUsed = false
                    self.loadLyrics(); self.publishNowPlaying(); self.prefetch()
                }
            }
        }
        NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime).sink { [weak self] notice in
            Task { @MainActor in
                guard let self, let item = notice.object as? AVPlayerItem,
                      let id = self.itemEntries[ObjectIdentifier(item)] else { return }
                self.itemEntries[ObjectIdentifier(item)] = nil
                if self.repeatMode == .one { self.loadCurrent(at: 0); return }
                if self.prepared?.id != nil || self.nativePlayer.currentItem != nil && self.playlistIndex < self.queueEntries.count - 1 { return }
                if self.playlistIndex + 1 < self.queueEntries.count { self.next() }
                else if self.repeatMode == .all { self.playlistIndex = 0; self.loadCurrent(at: 0) }
                else if self.queueEntries.last?.id == id { self.pause(); self.currentTime = self.duration }
            }
        }.store(in: &observations)
        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification).sink { [weak self] note in
            Task { @MainActor in
                guard let self, let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                if type == .began { self.interruptedIntent = self.intendsPlayback; self.nativePlayer.pause(); self.playing = false }
                else if self.interruptedIntent, self.intendsPlayback,
                        (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0) & AVAudioSession.InterruptionOptions.shouldResume.rawValue != 0 { self.play() }
            }
        }.store(in: &observations)
        NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification).sink { [weak self] note in
            Task { @MainActor in
                if note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { self?.pause() }
            }
        }.store(in: &observations)
        let remote = MPRemoteCommandCenter.shared()
        remote.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.play() }; return .success }
        remote.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.pause() }; return .success }
        remote.togglePlayPauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.toggle() }; return .success }
        remote.nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.next() }; return .success }
        remote.previousTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.previous() }; return .success }
        remote.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(to: event.positionTime) }; return .success
        }
        remote.likeCommand.addTarget { [weak self] _ in Task { @MainActor in self?.onLikeCurrentSong?() }; return .success }
        if let data = defaults.data(forKey: "watch.playback"), let session = try? JSONDecoder().decode(WatchRetainedPlayback.self, from: data) {
            musicTracks = Dictionary(session.songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            queueEntries = session.songs.enumerated().map { .init(videoID: $0.element.id, manual: false, order: $0.offset, originContext: session.origin) }
            playlistIDs = queueEntries.map(\.videoID); playlistIndex = min(max(0, session.index), max(0, playlistIDs.count - 1))
            currentVideoID = playlistIDs.indices.contains(playlistIndex) ? playlistIDs[playlistIndex] : nil
            currentTime = session.time; restoredTime = session.time; shuffled = session.shuffle
        }
    }
    func load(_ id: String, startAt: Double? = nil) {
        queueEntries = [.init(videoID: id, manual: false, order: 0)]; playlistIDs = [id]; playlistIndex = 0
        musicQueueEdited = false; loadCurrent(at: startAt ?? 0)
    }
    func loadPlaylist(_ ids: [String], startAt index: Int = 0, keepingCurrentItem: Bool = false) {
        guard !ids.isEmpty else { return }
        queueEntries = ids.enumerated().map { .init(videoID: $0.element, manual: false, order: $0.offset) }
        playlistIDs = ids; playlistIndex = min(max(index, 0), ids.count - 1); musicQueueEdited = false
        if shuffled { let first = queueEntries.remove(at: playlistIndex); queueEntries.shuffle(); queueEntries.insert(first, at: 0); playlistIndex = 0; playlistIDs = queueEntries.map(\.videoID) }
        loadCurrent(at: 0)
    }
    func loadYouTubePlaylist(_ id: String, startAt: Int = 0, shuffleFirst: Bool = false) {
        loadingTask?.cancel()
        loadingTask = Task {
            do { let songs = try await YouTubeAPI.musicRankedSongs(id); try Task.checkCancellation()
                for song in songs { musicTracks[song.id] = song }; shuffled = shuffleFirst; loadPlaylist(songs.map(\.id), startAt: startAt)
            } catch { if !Task.isCancelled { self.error = error.localizedDescription; loading = false } }
        }
    }
    private func loadCurrent(at position: Double, retry: Bool = false) {
        guard queueEntries.indices.contains(playlistIndex) else { return }
        loadingTask?.cancel(); prefetchTask?.cancel(); prepared = nil; nativePlayer.removeAllItems(); itemEntries.removeAll()
        generation = UUID(); let request = generation; let id = queueEntries[playlistIndex].videoID
        lastClock = position; lastProgress = Date(); recoveryUsed = retry
        currentVideoID = id; currentTime = position; restoredTime = 0; error = nil; loading = true; ready = false; intendsPlayback = true; hasStartedPlayback = false
        loadingTask = Task {
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .default, policy: .longFormAudio, options: [])
                try await session.activate()
                let item = try await self.item(for: id)
                try Task.checkCancellation(); guard generation == request else { return }
                itemEntries[ObjectIdentifier(item)] = queueEntries[playlistIndex].id
                nativePlayer.insert(item, after: nil)
                if position > 0 { await nativePlayer.seek(to: CMTime(seconds: position, preferredTimescale: 600)) }
                guard generation == request, intendsPlayback else { return }
                nativePlayer.play(); loadLyrics(); publishNowPlaying()
                let deadline = ContinuousClock.now + .seconds(8)
                while ContinuousClock.now < deadline, generation == request, intendsPlayback {
                    try await Task.sleep(for: .milliseconds(100))
                    if item.status == .failed { throw item.error ?? URLError(.cannotDecodeContentData) }
                    if item.status == .readyToPlay { ready = true; loading = false }
                    if nativePlayer.currentTime().seconds > position + 0.1 { prefetch(); return }
                }
                guard generation == request, intendsPlayback else { return }
                throw YouTubeAPI.Failure(message: "The song did not start. Check your audio output and connection.")
            } catch {
                guard generation == request, !Task.isCancelled else { return }
                if !retry, intendsPlayback { await YouTubeStreamCache.shared.remove(id); loadCurrent(at: position, retry: true) }
                else { self.error = error.localizedDescription; loading = false; ready = false; pause() }
            }
        }
    }
    private func item(for id: String) async throws -> AVPlayerItem {
        if let file = downloads.localURL(id) { return AVPlayerItem(url: file) }
        guard !downloads.offlineOnly else { throw YouTubeAPI.Failure(message: "This song isn’t downloaded. Choose music in Downloads.") }
        let source = try await resolver.audio(id)
        if source.isHLS { return AVPlayerItem(url: source.url) }
        let keep = Set(queueEntries.dropFirst(playlistIndex).prefix(2).map(\.videoID))
        return AVPlayerItem(url: try await WatchStreamFileCache.shared.file(source, id: id, retaining: keep))
    }
    private func prefetch() {
        prefetchTask?.cancel(); prepared = nil
        let retained = nativePlayer.currentItem
        if let retained { for item in nativePlayer.items() where item !== retained { nativePlayer.remove(item) } }
        guard repeatMode != .one, queueEntries.indices.contains(playlistIndex + 1) else { return }
        let entry = queueEntries[playlistIndex + 1], request = generation, queueRevision = revision
        prefetchTask = Task {
            do {
                let item = try await self.item(for: entry.videoID); try Task.checkCancellation()
                guard generation == request, revision == queueRevision, nativePlayer.currentItem === retained else { return }
                itemEntries[ObjectIdentifier(item)] = entry.id; prepared = (entry.id, item)
                nativePlayer.insert(item, after: retained)
            } catch { /* Current audio continues; selecting Next can retry the unavailable source. */ }
        }
    }
    func play() { guard currentVideoID != nil else { return }; if !ready || nativePlayer.currentItem == nil { loadCurrent(at: max(restoredTime, currentTime)) } else { intendsPlayback = true; lastProgress = Date(); nativePlayer.play(); publishNowPlaying() } }
    func pause() { intendsPlayback = false; interruptedIntent = false; loadingTask?.cancel(); nativePlayer.pause(); playing = false; loading = false; save(); publishNowPlaying() }
    func toggle() { intendsPlayback ? pause() : play() }
    func stop() { pause(); generation = UUID(); prefetchTask?.cancel(); lyricsTask?.cancel(); nativePlayer.removeAllItems(); currentVideoID = nil; lyrics = nil; ready = false; currentTime = 0; duration = 0; MPNowPlayingInfoCenter.default().nowPlayingInfo = nil; defaults.removeObject(forKey: "watch.playback") }
    func next() { if playlistIndex + 1 < queueEntries.count { playlistIndex += 1; loadCurrent(at: 0) } else if repeatMode == .all { playlistIndex = 0; loadCurrent(at: 0) } }
    func previous() { if currentTime > 3 { seek(to: 0) } else if playlistIndex > 0 { playlistIndex -= 1; loadCurrent(at: 0) } }
    func seek(to seconds: Double) { guard seconds.isFinite else { return }; let value = min(max(0, seconds), max(0, duration)); nativePlayer.seek(to: CMTime(seconds: value, preferredTimescale: 600)); currentTime = value; lastClock = value; lastProgress = Date(); save(); publishNowPlaying() }
    func resumeFromBrowser(_ seconds: Double, videoID: String) { seek(to: seconds) }
    func setMetadata(_ song: YouTubeVideo) { musicTracks[song.id] = song; publishNowPlaying() }
    func setQueueOrigins(_ origins: [String?]) { for index in queueEntries.indices where origins.indices.contains(index) { queueEntries[index].originContext = origins[index] } }
    func enqueue(_ ids: [String], next: Bool, source: String? = nil, origin: String? = nil, automatic: Bool = false, shuffling: Bool = false) {
        guard currentVideoID != nil else { return }; if !automatic { onUserQueueEdit?() }
        let order = (queueEntries.map(\.order).max() ?? -1) + 1
        let entries = ids.enumerated().map { MusicPlaybackQueueEntry(videoID: $0.element, manual: !automatic, order: order + $0.offset, source: source, originContext: origin) }
        queueEntries.insert(contentsOf: shuffling ? entries.shuffled() : entries, at: next ? min(playlistIndex + 1, queueEntries.count) : queueEntries.count); changed(edited: !automatic)
    }
    func clearUpcomingQueue() { onUserQueueEdit?(); queueEntries = Array(queueEntries.prefix(playlistIndex + 1)); changed() }
    func removeUpcomingQueue(at offsets: IndexSet) { onUserQueueEdit?(); for offset in offsets.sorted(by: >) { let index = playlistIndex + 1 + offset; if queueEntries.indices.contains(index) { queueEntries.remove(at: index) } }; changed() }
    func moveUpcomingQueue(from offsets: IndexSet, to destination: Int) {
        var tail = Array(queueEntries.dropFirst(playlistIndex + 1)); guard offsets.allSatisfy({ tail.indices.contains($0) }), (0...tail.count).contains(destination) else { return }
        onUserQueueEdit?(); tail.move(fromOffsets: offsets, toOffset: destination); queueEntries = Array(queueEntries.prefix(playlistIndex + 1)) + tail; changed()
    }
    func playQueueEntry(_ id: UUID) { guard let index = queueEntries.firstIndex(where: { $0.id == id }) else { return }; playlistIndex = index; loadCurrent(at: 0) }
    func toggleShuffle() { shuffled.toggle(); let head = Array(queueEntries.prefix(playlistIndex + 1)); let tail = Array(queueEntries.dropFirst(playlistIndex + 1)); queueEntries = head + (shuffled ? tail.shuffled() : tail.sorted { $0.order < $1.order }); changed(edited: false) }
    private func changed(edited: Bool = true) { revision = UUID(); musicQueueEdited = edited || musicQueueEdited; playlistIDs = queueEntries.map(\.videoID); prefetch(); save() }
    func loadLyrics() {
        lyricsTask?.cancel(); lyrics = nil; lyricError = nil
        guard let id = currentVideoID, let song = musicTracks[id] else { return }
        calibration = defaults.data(forKey: "watch.calibration." + id).flatMap { try? JSONDecoder().decode(LyricCalibration.self, from: $0) } ?? .init()
        if let cached = downloads.cachedLyrics(id) { lyrics = cached; return }
        guard !downloads.offlineOnly else { return }
        lyricsLoading = true
        lyricsTask = Task {
            do { let result = try await MusicLyricsSource.shared.lyrics(for: song, duration: duration); try Task.checkCancellation(); guard currentVideoID == id else { return }; lyrics = result }
            catch { if currentVideoID == id && !Task.isCancelled { lyricError = error.localizedDescription } }
            if currentVideoID == id { lyricsLoading = false }
        }
    }
    func saveCalibration(_ value: LyricCalibration) { guard let id = currentVideoID, value.isValid else { return }; calibration = value; defaults.set(try? JSONEncoder().encode(value), forKey: "watch.calibration." + id) }
    func save() {
        let songs = queueEntries.compactMap { musicTracks[$0.videoID] }
        guard !songs.isEmpty else { return }
        defaults.set(try? JSONEncoder().encode(WatchRetainedPlayback(songs: songs, index: playlistIndex, time: currentTime, shuffle: shuffled, origin: currentQueueOrigin)), forKey: "watch.playback")
    }
    private func publishNowPlaying() {
        guard currentVideoID != nil else { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil; return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [MPMediaItemPropertyTitle: title, MPMediaItemPropertyArtist: artist, MPMediaItemPropertyPlaybackDuration: duration, MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime, MPNowPlayingInfoPropertyPlaybackRate: intendsPlayback ? 1 : 0, MPNowPlayingInfoPropertyExternalContentIdentifier: "song:" + (currentVideoID ?? "")]
        MPRemoteCommandCenter.shared().likeCommand.isActive = currentSongIsLiked
        if defaults === WatchEnvironment.defaults { WatchWidgetSnapshot.write(title: title, artist: artist, playing: intendsPlayback) }
    }
}
struct WatchRetainedPlayback: Codable { let songs: [YouTubeVideo]; let index: Int; let time: Double; let shuffle: Bool; let origin: String? }
