import SwiftUI
import WatchKit
import AVFoundation

struct WatchPlayerView: View {
    @ObservedObject var store: YouTubeStore
    @ObservedObject var player: YouTubePlayer
    @ObservedObject private var phone = WatchPhoneBridge.shared
    @Environment(\.dismiss) private var dismiss
    @State private var page = 1
    @State private var options = false
    init(store: YouTubeStore) { self.store = store; player = store.player }
    var body: some View {
        NavigationStack {
            TabView(selection: $page) {
                WatchLyricsView(player: player).tag(0)
                WatchArtworkPlayerView(store: store, player: player, options: $options, showControls: { page = 2 }, close: { dismiss() }).tag(1)
                WatchTransportView(store: store, player: player, options: $options, active: page == 2).tag(2)
                WatchQueueView(store: store, player: player).tag(3)
            }.tabViewStyle(.page(indexDisplayMode: .automatic)).navigationTitle(phone.mode == .phone ? "iPhone" : "Now Playing")
                .toolbar(page == 1 ? .hidden : .visible, for: .navigationBar)
                .toolbar { ToolbarItem(placement: .topBarLeading) { Button { dismiss() } label: { Image(systemName: "chevron.down") }.accessibilityLabel("Return to Music") } }
                .sheet(isPresented: $options) { NavigationStack { WatchPlayerActions(store: store, player: player) } }
        }
    }
}
/// The square cover stays fully visible; tapping it removes the controls.
/// The following page keeps volume, scrubbing and large-text controls accessible.
struct WatchArtworkPlayerView: View {
    @ObservedObject var store: YouTubeStore
    @ObservedObject var player: YouTubePlayer
    @Binding var options: Bool
    var showControls: () -> Void
    var close: () -> Void
    @ObservedObject private var phone = WatchPhoneBridge.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isLuminanceReduced) private var dimmed
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var chrome = true
    private var song: YouTubeVideo? { phone.mode == .phone ? phone.snapshot?.song : store.current }
    private var playing: Bool { phone.mode == .phone ? phone.snapshot?.playing ?? false : player.intendsPlayback }
    private var artwork: URL? { song.flatMap { WatchDownloadStore.shared.cachedArtwork($0.id) ?? $0.thumbnail } }
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { chrome.toggle() }
                } label: {
                    Group {
                        if let artwork, artwork.isFileURL, let image = UIImage(contentsOfFile: artwork.path) {
                            Image(uiImage: image).resizable().scaledToFit()
                        } else {
                            AsyncImage(url: artwork) { image in image.resizable().scaledToFit() } placeholder: {
                                Image(systemName: "music.note").font(.system(size: 64, weight: .light)).foregroundStyle(.secondary)
                            }
                        }
                    }.frame(width: geometry.size.width, height: geometry.size.height).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(chrome ? "Hide artwork controls" : "Show artwork controls")
                    .accessibilityHint(song.map { "\($0.title), \($0.channel)" } ?? "Choose a song from Music")
                    .accessibilityIdentifier("watch.fullArtwork")
                if chrome && !dimmed {
                    VStack(spacing: 0) {
                        HStack {
                            Button(action: close) { Image(systemName: "chevron.down").frame(width: 36, height: 36).background(.black.opacity(0.6), in: Circle()) }.accessibilityLabel("Return to Music")
                            Spacer()
                            Button(action: showControls) { Image(systemName: phone.mode == .phone ? "iphone" : "applewatch").frame(width: 36, height: 36).background(.black.opacity(0.6), in: Circle()) }.accessibilityLabel("Playback controls")
                        }.padding(.horizontal, 8).padding(.top, 20)
                        Spacer(minLength: 0)
                        VStack(spacing: 6) {
                            Text(song?.title ?? "Choose Music").font(.caption.weight(.semibold)).lineLimit(1)
                            HStack(spacing: 8) {
                                Button { command("previous") { player.previous() } } label: { Image(systemName: "backward.end.fill").frame(width: 34, height: 38) }.accessibilityLabel("Previous song")
                                Button { command(playing ? "pause" : "play") { player.toggle() } } label: { Image(systemName: playing ? "pause.fill" : "play.fill").font(.title3.bold()).frame(width: 44, height: 40) }.accessibilityLabel(playing ? "Pause" : "Play").accessibilityIdentifier("watch.playPause")
                                Button { command("next") { player.next() } } label: { Image(systemName: "forward.end.fill").frame(width: 34, height: 38) }.accessibilityLabel("Next song")
                                Button { options = true } label: { Image(systemName: "ellipsis").frame(width: 28, height: 38) }.accessibilityLabel("Playback options")
                            }.disabled(song == nil || phone.mode == .phone && !phone.reachable)
                        }.padding(.top, 18).padding(.bottom, 16).frame(maxWidth: .infinity)
                            .background(LinearGradient(colors: [.clear, .black.opacity(0.92)], startPoint: .top, endPoint: .bottom))
                    }.buttonStyle(.plain).foregroundStyle(.white)
                }
            }.frame(width: geometry.size.width, height: geometry.size.height)
        }.ignoresSafeArea()
            .onChange(of: typeSize, initial: true) { _, value in if value >= .xxxLarge { showControls() } }
            .task(id: phone.mode) { if phone.mode == .phone { await phone.refresh(silent: true) } }
    }
    private func command(_ action: String, local: () -> Void) { if phone.mode == .phone { Task { await phone.control(action) } } else { local() } }
}

struct WatchTransportView: View {
    @ObservedObject var store: YouTubeStore
    @ObservedObject var player: YouTubePlayer
    @Binding var options: Bool
    var active: Bool
    @ObservedObject private var phone = WatchPhoneBridge.shared
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.isLuminanceReduced) private var dimmed
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var seeking = false
    private var song: YouTubeVideo? { phone.mode == .phone ? phone.snapshot?.song : store.current }
    private var playing: Bool { phone.mode == .phone ? phone.snapshot?.playing ?? false : player.intendsPlayback }
    private var failure: String? { phone.mode == .phone ? (phone.reachable ? phone.error : "iPhone unavailable") : player.error }
    private var time: Double { phone.mode == .phone ? phone.snapshot?.time ?? 0 : player.currentTime }
    private var duration: Double { phone.mode == .phone ? phone.snapshot?.duration ?? 0 : player.duration }
    var body: some View {
        GeometryReader { geometry in
            if dynamicTypeSize >= .xxxLarge { ScrollView { transportContent(geometry) } }
            else { transportContent(geometry) }
        }.sheet(isPresented: $seeking) { WatchSeekView(player: player) }.task(id: phone.mode) { if phone.mode == .phone { await phone.refresh(silent: true) } }
    }
    private func transportContent(_ geometry: GeometryProxy) -> some View {
            VStack(spacing: 5) {
                HStack(spacing: 9) {
                    WatchCover(url: song.flatMap { WatchDownloadStore.shared.cachedArtwork($0.id) ?? $0.thumbnail }, size: max(34, min(62, geometry.size.height * 0.31)))
                        .scaleEffect(playing && !reduceMotion && !dimmed ? 1 : 0.94)
                        .animation(reduceMotion ? .easeOut(duration: 0.18) : .spring(response: 0.36, dampingFraction: 0.86), value: playing)
                        .overlay { if player.loading && phone.mode == .watch { ProgressView().padding(6).background(.black.opacity(0.6), in: Circle()) } }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(song?.title ?? "Choose Music").font(.system(.headline, design: .rounded)).lineLimit(2)
                        Text(failure ?? song?.channel ?? "Your next favorite is waiting").font(.caption2).foregroundStyle(failure == nil ? Color.secondary : Color.orange).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
                }
                Button { seeking = true } label: { ProgressView(value: min(time, max(1,duration)), total: max(1,duration)).tint(.white.opacity(0.7)).padding(.vertical, 5) }.buttonStyle(.plain).accessibilityLabel("Seek, \(WatchTime.label(time)) of \(WatchTime.label(duration))")
                HStack(spacing: 12) {
                    Button { command("previous") { player.previous() } } label: { Image(systemName: "backward.end.fill").font(.title3).frame(width: 38, height: 38) }.accessibilityLabel("Previous song")
                    Button { command(playing ? "pause" : "play") { player.toggle() } } label: { Image(systemName: playing ? "pause.fill" : "play.fill").font(.system(size: 24, weight: .bold)).contentTransition(.symbolEffect(.replace)).frame(width: 48, height: 44).foregroundStyle(.black).background(Color(red: 0.4, green: 0.92, blue: 0.62), in: Circle()) }.accessibilityLabel(playing ? "Pause" : "Play").accessibilityIdentifier("watch.playPause")
                    Button { command("next") { player.next() } } label: { Image(systemName: "forward.end.fill").font(.title3).frame(width: 38, height: 38) }.accessibilityLabel("Next song")
                }.buttonStyle(.plain).disabled(song == nil || phone.mode == .phone && !phone.reachable)
                HStack(spacing: 3) {
                    WatchNativeVolume(origin: phone.mode == .phone ? .companion : .local, focused: active && !seeking && !options && dynamicTypeSize < .xxxLarge).id(phone.mode.rawValue).frame(height: 24)
                    Button { options = true } label: { Image(systemName: "ellipsis").frame(width: 30, height: 30) }.buttonStyle(.plain).accessibilityLabel("Playback options")
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(.horizontal, 8)
                .background(WatchArtworkBackdrop(url: song?.thumbnail))
    }
    private func command(_ action: String, local: () -> Void) { if phone.mode == .phone { Task { await phone.control(action) } } else { local() } }
}
struct WatchNativeVolume: WKInterfaceObjectRepresentable {
    var origin: WKInterfaceVolumeControl.Origin
    var focused: Bool
    func makeWKInterfaceObject(context: Context) -> WKInterfaceVolumeControl { WKInterfaceVolumeControl(origin: origin) }
    final class Coordinator { var focused: Bool? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func updateWKInterfaceObject(_ control: WKInterfaceVolumeControl, context: Context) {
        guard context.coordinator.focused != focused else { return }
        context.coordinator.focused = focused
        if focused { control.focus() } else { control.resignFocus() }
    }
}
struct WatchSeekView: View {
    @ObservedObject var player: YouTubePlayer
    @ObservedObject private var phone = WatchPhoneBridge.shared
    @Environment(\.dismiss) private var dismiss
    @State private var value: Double = 0
    private var duration: Double { max(1, phone.mode == .phone ? phone.snapshot?.duration ?? 1 : player.duration) }
    var body: some View {
        VStack(spacing: 18) {
            Text("Seek").font(.headline)
            Text(WatchTime.label(value)).font(.system(.title, design: .rounded, weight: .semibold)).monospacedDigit()
            ProgressView(value: min(value, duration), total: duration)
            Text("Turn the Digital Crown").font(.caption2).foregroundStyle(.secondary)
            Button("Done") { if phone.mode == .phone { Task { await phone.control("seek", value: value) } } else { player.seek(to: value) }; dismiss() }.buttonStyle(.borderedProminent)
            Button("Cancel") { dismiss() }
        }.padding().focusable().digitalCrownRotation($value, from: 0, through: duration, by: 1, sensitivity: .medium, isContinuous: false, isHapticFeedbackEnabled: true)
            .onAppear { value = phone.mode == .phone ? phone.snapshot?.time ?? 0 : player.currentTime }
            .accessibilityAdjustableAction { direction in value = min(duration, max(0, value + (direction == .increment ? 5 : -5))) }
    }
}
struct WatchLyricsView: View {
    @ObservedObject var player: YouTubePlayer
    @ObservedObject private var phone = WatchPhoneBridge.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var following = true
    private var remote: Bool { phone.mode == .phone }
    private var lyrics: TrackLyrics? { remote ? phone.snapshot?.lyrics : player.lyrics }
    private var calibration: LyricCalibration { remote ? phone.snapshot?.calibration ?? .init() : player.calibration }
    private var time: Double { remote ? phone.snapshot?.time ?? 0 : player.currentTime }
    private var playing: Bool { remote ? phone.snapshot?.playing ?? false : player.playing }
    var body: some View {
        Group {
            if !remote && player.lyricsLoading { ProgressView("Finding lyrics…") }
            else if let lyrics {
                if lyrics.instrumental { WatchEmptyState(title: "Instrumental", message: "Let the music speak.", symbol: "waveform") }
                else if !lyrics.lines.isEmpty {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 18) {
                                ForEach(lyrics.lines) { line in
                                    Button { let target = calibration.playbackTime(for: line.time); if remote { Task { await phone.control("seek", value: target) } } else { player.seek(to: target) } } label: {
                                        Group {
                                            if let range = lyrics.breakRange(for: line) {
                                                MusicInterludeDots(range: range, time: calibration.lyricTime(for: time), active: active == line.id,
                                                    playing: playing, scale: 0.6, reduceMotion: reduceMotion)
                                            } else { Text(line.text).font(.system(.title3, design: .rounded, weight: .bold)) }
                                        }.foregroundStyle(active == line.id ? .white : .white.opacity(0.35)).frame(maxWidth: .infinity, alignment: .leading)
                                    }.buttonStyle(.plain).id(line.id)
                                }
                                Text(lyrics.source).font(.caption2).foregroundStyle(.secondary)
                            }.padding(.horizontal, 10).padding(.vertical, 28)
                        }.simultaneousGesture(DragGesture().onChanged { _ in following = false })
                            .onChange(of: active) { _, id in if following, let id { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.32)) { proxy.scrollTo(id, anchor: .center) } } }
                            .overlay(alignment: .bottomTrailing) { if !following { Button { following = true; if let active { proxy.scrollTo(active, anchor: .center) } } label: { Image(systemName: "location.fill") }.accessibilityLabel("Follow lyrics") } }
                    }
                } else { ScrollView { Text(lyrics.plainText ?? "No lyrics available").font(.body).padding() } }
            } else { VStack { WatchEmptyState(title: "Lyrics unavailable", message: remote ? "Lyrics will appear when available on your iPhone." : player.lyricError ?? "This recording doesn’t have lyrics yet.", symbol: "text.quote"); Button("Try Again") { if remote { Task { await phone.refresh() } } else { player.loadLyrics() } } } }
        }
    }
    private var active: Int? { lyrics?.activeLine(at: calibration.lyricTime(for: time)) }
}
struct WatchQueueView: View {
    @ObservedObject var store: YouTubeStore
    @ObservedObject var player: YouTubePlayer
    @ObservedObject private var phone = WatchPhoneBridge.shared
    private var remote: Bool { phone.mode == .phone }
    private var songs: [YouTubeVideo] { if remote { return phone.snapshot?.queue ?? [] }; return player.queueEntries.map { player.musicTracks[$0.videoID] ?? store.knownVideo($0.videoID) ?? .placeholder($0.videoID) } }
    private var index: Int { remote ? phone.snapshot?.index ?? 0 : player.playlistIndex }
    var body: some View {
        List {
            Section("Playing Next") {
                if songs.count <= index + 1 { Text("Your queue is clear.").font(.caption).foregroundStyle(.secondary) }
                ForEach(Array(songs.enumerated()), id: \.offset) { position, song in
                    if position > index {
                        NavigationLink { List {
                            Text(song.title).font(.headline)
                            Button("Play Now") { command("entry", value: position + (phone.snapshot?.queueOffset ?? 0)) { player.playQueueEntry(player.queueEntries[position].id) } }
                            Button("Move Up") { command("moveUp", value: position-index-1) { player.moveUpcomingQueue(from: IndexSet(integer: position-index-1), to: max(0,position-index-2)) } }.disabled(position == index+1)
                            Button("Move Down") { command("moveDown", value: position-index-1) { player.moveUpcomingQueue(from: IndexSet(integer: position-index-1), to: position-index+1) } }.disabled(position == songs.count-1)
                            Button("Remove", role: .destructive) { command("remove", value: position-index-1) { player.removeUpcomingQueue(at: IndexSet(integer: position-index-1)) } }
                        }.navigationTitle("Queue") } label: { VStack(alignment: .leading) { Text(song.title).lineLimit(2); Text(song.channel).font(.caption2).foregroundStyle(.secondary) } }
                    }
                }
            }
            if remote, let total = phone.snapshot?.queueCount, let offset = phone.snapshot?.queueOffset, offset + songs.count < total {
                Text("Showing the next \(max(0, songs.count - index - 1)) songs. The rest stay queued on iPhone.").font(.caption2).foregroundStyle(.secondary)
            }
            if !remote { NavigationLink("Add Songs") { WatchSearchView(store: store, choose: { song in player.musicTracks[song.id] = song; player.enqueue([song.id], next: false) }) } }
            Button("Clear Upcoming", role: .destructive) { command("clear") { player.clearUpcomingQueue() } }.disabled(songs.count <= index+1)
        }
    }
    private func command(_ action: String, value: Int? = nil, local: () -> Void) { if remote { Task { await phone.control(action, value: value.map(Double.init)) } } else { local() } }
}
struct WatchPlayerActions: View {
    @ObservedObject var store: YouTubeStore
    @ObservedObject var player: YouTubePlayer
    @ObservedObject private var phone = WatchPhoneBridge.shared
    @State private var routeError: String?
    var body: some View {
        List {
            NavigationLink("Playback Device") { WatchPlaybackDeviceView() }
            if let error = player.error, phone.mode == .watch { WatchFailure(message: error) { player.play() } }
            if phone.mode == .watch {
                Button { player.toggleShuffle() } label: { Label(player.shuffled ? "Shuffle On" : "Shuffle Off", systemImage: "shuffle") }
                Button { player.repeatMode = player.repeatMode == .off ? .all : player.repeatMode == .all ? .one : .off } label: { Label("Repeat: " + player.repeatMode.rawValue.capitalized, systemImage: player.repeatMode == .one ? "repeat.1" : "repeat") }
                if let song = store.current { WatchSongActions(store: store, song: song, embedded: true) }
                NavigationLink("Calibrate Lyrics") { WatchCalibrationView(player: player) }
                NavigationLink("Audio Output") { WatchAudioOutputView() }
            } else {
                Button("Shuffle") { Task { await phone.control("shuffle") } }
                Button("Repeat") { Task { await phone.control("repeat") } }
                Button(phone.snapshot?.liked == true ? "Unlike Current Song" : "Like Current Song") { Task { await phone.control("like") } }
                if let song = phone.snapshot?.song { NavigationLink("Song Information") { WatchSongInfoView(song: song) } }
                NavigationLink("System Now Playing") { NowPlayingView() }
            }
        }.navigationTitle("Options")
    }
}
struct WatchPlaybackDeviceView: View {
    @ObservedObject private var phone = WatchPhoneBridge.shared
    var body: some View {
        List {
            ForEach(WatchPhoneBridge.Mode.allCases, id: \.rawValue) { mode in Button { phone.mode = mode; if mode == .phone { Task { await phone.refresh() } } } label: { HStack { Label(mode.rawValue, systemImage: mode == .watch ? "applewatch" : "iphone"); Spacer(); if phone.mode == mode { Image(systemName: "checkmark") } } } }
            Text(phone.reachable ? "iPhone is available. Switching devices changes which player you control." : "iPhone is unavailable. Your Watch can still play music independently.").font(.caption).foregroundStyle(.secondary)
        }.navigationTitle("Play On")
    }
}
enum WatchTime { static func label(_ seconds: Double) -> String { guard seconds.isFinite else { return "0:00" }; let value = max(0, Int(seconds)); return String(format: "%d:%02d", value / 60, value % 60) } }
