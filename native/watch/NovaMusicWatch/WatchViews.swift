import SwiftUI
import WatchKit
import PhotosUI

private let novaGreen = Color(red: 0.4, green: 0.92, blue: 0.62)

struct WatchRootView: View {
    @ObservedObject var store: YouTubeStore
    @ObservedObject private var navigation = WatchNavigation.shared
    @ObservedObject private var phone = WatchPhoneBridge.shared
    @ObservedObject private var player: YouTubePlayer
    @State private var launched = false
    init(store: YouTubeStore) { self.store = store; player = store.player }
    var body: some View {
        NavigationStack {
            List {
                if player.currentVideoID != nil || phone.mode == .phone && phone.snapshot?.song != nil {
                    Button { navigation.player = true } label: {
                        HStack(spacing: 9) {
                            WatchCover(url: phone.mode == .phone ? phone.snapshot?.song?.thumbnail : store.current?.thumbnail, size: 42)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("NOW PLAYING").font(.system(size: 9, weight: .bold, design: .rounded)).tracking(1.2).foregroundStyle(novaGreen)
                                Text(phone.mode == .phone ? phone.snapshot?.song?.title ?? "iPhone" : store.current?.title ?? player.title).font(.headline).lineLimit(1)
                                Text(phone.mode.rawValue).font(.caption2).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 4)
                    }.listRowBackground(novaGreen.opacity(0.09)).accessibilityIdentifier("watch.nowPlaying")
                }
                NavigationLink { WatchSongList(store: store, title: "Recently Played", songs: store.musicHistory) } label: { WatchMenuRow(title: "Recently Played", symbol: "clock.arrow.circlepath") }
                NavigationLink { WatchLibraryView(store: store) } label: { WatchMenuRow(title: "Library", symbol: "square.stack.fill") }.accessibilityIdentifier("watch.library")
                NavigationLink { WatchSearchView(store: store) } label: { WatchMenuRow(title: "Search", symbol: "magnifyingglass") }.accessibilityIdentifier("watch.search")
                NavigationLink { WatchDiscoverView(store: store) } label: { WatchMenuRow(title: "Discover", symbol: "sparkles") }
                NavigationLink { WatchDownloadsView(store: store) } label: { WatchMenuRow(title: "Downloads", symbol: "arrow.down.circle.fill") }.accessibilityIdentifier("watch.downloads")
                NavigationLink { WatchSettingsView(store: store) } label: { WatchMenuRow(title: "Settings", symbol: "gearshape.fill") }.accessibilityIdentifier("watch.settings")
            }.navigationTitle("Music").listStyle(.carousel)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Image(systemName: "music.note").foregroundStyle(novaGreen).accessibilityHidden(true) } }
        }
        .sheet(isPresented: $navigation.player) { WatchPlayerView(store: store) }
        .alert("Nova Music", isPresented: Binding(get: { store.musicActionError != nil || phone.error != nil }, set: { if !$0 { store.musicActionError = nil; phone.error = nil } })) { Button("OK") { store.musicActionError = nil; phone.error = nil } } message: { Text(store.musicActionError ?? phone.error ?? "") }
        .onChange(of: phone.snapshot?.playing, initial: true) { _, playing in
            guard playing == true, let snapshot = phone.snapshot, snapshot.song != nil,
                  abs(snapshot.updated.timeIntervalSinceNow) < 90, !player.intendsPlayback else { return }
            navigation.presentPhonePlayback()
        }
        .onAppear { guard !launched else { return }; launched = true; if player.intendsPlayback || ProcessInfo.processInfo.arguments.contains("-nova-watch-preview-player") { navigation.player = true } }
    }
}
struct WatchMenuRow: View {
    var title: String
    var symbol: String
    var detail: String? = nil
    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: symbol).font(.system(size: 18, weight: .medium)).foregroundStyle(novaGreen).frame(width: 23)
            VStack(alignment: .leading, spacing: 2) { Text(title).font(.system(.body, design: .rounded, weight: .semibold)); if let detail { Text(detail).font(.caption2).foregroundStyle(.secondary) } }
        }.padding(.vertical, 7)
    }
}
struct WatchCover: View {
    var url: URL?
    var size: CGFloat
    var symbol = "music.note"
    var choice: MusicCollectionArtworkChoice? = nil
    var body: some View {
        Group {
            if choice?.style == .icon { placeholder(symbol: choice?.symbol ?? symbol) }
            else if let file = choice?.photoFile, let path = MusicArtworkFiles.url(file), let image = UIImage(contentsOfFile: path.path) { Image(uiImage: image).resizable().scaledToFill() }
            else if let url, url.isFileURL, let image = UIImage(contentsOfFile: url.path) { Image(uiImage: image).resizable().scaledToFill() }
            else { AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { placeholder(symbol: symbol) } }
        }.frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: size > 65 ? 17 : 9, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: size > 65 ? 17 : 9).strokeBorder(.white.opacity(0.08), lineWidth: 0.5) }.accessibilityHidden(true)
    }
    private func placeholder(symbol: String) -> some View {
        ZStack { LinearGradient(colors: [Color(red: 0.15, green: 0.27, blue: 0.22), Color(white: 0.08)], startPoint: .topLeading, endPoint: .bottomTrailing); Image(systemName: symbol).font(.system(size: max(15, size * 0.32), weight: .light)).foregroundStyle(novaGreen) }
    }
}
struct WatchLibraryView: View {
    @ObservedObject var store: YouTubeStore
    var body: some View {
        List {
            NavigationLink { WatchPlaylistsView(store: store) } label: { WatchMenuRow(title: "Playlists", symbol: "music.note.list", detail: "\(store.libraryPlaylists.count)") }
            NavigationLink { WatchArtistsView(store: store) } label: { WatchMenuRow(title: "Artists", symbol: "person.2.fill", detail: "\(store.followedArtists.count)") }
            NavigationLink { WatchAlbumsView(store: store, albums: store.likedAlbums) } label: { WatchMenuRow(title: "Albums", symbol: "square.stack", detail: "\(store.likedAlbums.count)") }
            NavigationLink { WatchSongList(store: store, title: "Liked Songs", songs: store.likedSongs) } label: { WatchMenuRow(title: "Liked Songs", symbol: "heart.fill", detail: "\(store.likedSongs.count)") }
            NavigationLink { WatchSongList(store: store, title: "Saved Songs", songs: store.saved) } label: { WatchMenuRow(title: "Saved Songs", symbol: "music.note") }
            NavigationLink { WatchFoldersView(store: store) } label: { WatchMenuRow(title: "Folders", symbol: "folder.fill") }
            NavigationLink { WatchClassicalView(store: store) } label: { WatchMenuRow(title: "Classical", symbol: "pianokeys") }
            NavigationLink { WatchSpotifyReviewView(store: store) } label: { WatchMenuRow(title: "Songs to Review", symbol: "checkmark.circle") }
        }.navigationTitle("Library")
    }
}
struct WatchSongRow: View {
    @ObservedObject var store: YouTubeStore
    var song: YouTubeVideo
    var queue: [YouTubeVideo] = []
    var context: String? = nil
    @State private var options = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 7) {
            Button {
                withAnimation(reduceMotion ? .easeOut(duration: 0.18) : .spring(response: 0.35, dampingFraction: 0.87)) {
                    store.play(song, music: true, queue: queue, shuffle: false, context: context); WatchNavigation.shared.player = true
                }
            } label: {
                HStack(spacing: 8) {
                    WatchCover(url: WatchDownloadStore.shared.cachedArtwork(song.id) ?? song.thumbnail, size: 33)
                        .overlay(alignment: .bottomTrailing) { if store.current?.id == song.id { WatchPlayingGlyph(player: store.player).padding(3).background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 5)) } }
                    VStack(alignment: .leading, spacing: 2) { Text(song.title).font(.system(.body, design: .rounded, weight: .medium)).lineLimit(2); Text(song.channel).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                    Spacer(minLength: 0)
                    if song.isExplicit == true { Text("E").font(.system(size: 8, weight: .bold)).padding(2).background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 2)).accessibilityLabel("Explicit") }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            Button { options = true } label: { Image(systemName: "ellipsis").frame(width: 25, height: 44) }.buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Options for \(song.title)")
        }.padding(.vertical, 2).sheet(isPresented: $options) { NavigationStack { List { WatchSongActions(store: store, song: song) } } }
    }
}
struct WatchSongList: View {
    @ObservedObject var store: YouTubeStore
    var title: String
    var songs: [YouTubeVideo]
    var context: String? = nil
    var body: some View {
        List {
            if songs.isEmpty { WatchEmptyState(title: "No songs yet", message: "Find music in Search and add it to your library.", symbol: "music.note") }
            else {
                WatchPlayActions(store: store, songs: songs, context: context)
                NavigationLink("Select Songs") { WatchBulkSongsView(store: store, songs: songs) }
                ForEach(Array(songs.enumerated()), id: \.offset) { _, song in WatchSongRow(store: store, song: song, queue: songs, context: context) }
            }
        }.navigationTitle(title)
    }
}
struct WatchPlayActions: View {
    @ObservedObject var store: YouTubeStore
    var songs: [YouTubeVideo]
    var context: String?
    var body: some View {
        HStack {
            Button { guard let first = songs.first else { return }; store.play(first, music: true, queue: songs, shuffle: false, context: context); WatchNavigation.shared.player = true } label: { Label("Play", systemImage: "play.fill") }.tint(novaGreen)
            Button { store.shufflePlaylist(songs, music: true, context: context); WatchNavigation.shared.player = true } label: { Image(systemName: "shuffle") }.accessibilityLabel("Shuffle")
        }.buttonStyle(.borderedProminent).disabled(songs.isEmpty).listRowBackground(Color.clear)
        Button { WatchDownloadStore.shared.add(songs) } label: { Label("Download", systemImage: "arrow.down.circle") }.disabled(songs.isEmpty)
    }
}
struct WatchEmptyState: View {
    var title: String
    var message: String
    var symbol: String
    var body: some View { VStack(spacing: 10) { Image(systemName: symbol).font(.largeTitle).foregroundStyle(novaGreen); Text(title).font(.headline); Text(message).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center) }.frame(maxWidth: .infinity).padding(.vertical, 18).listRowBackground(Color.clear) }
}
struct WatchFailure: View {
    var message: String
    var retry: () -> Void
    var body: some View { VStack(alignment: .leading, spacing: 8) { Text(message).font(.caption).foregroundStyle(.secondary); Button("Try Again", action: retry) }.padding(.vertical, 5) }
}
struct WatchAlbumsView: View {
    @ObservedObject var store: YouTubeStore
    var albums: [YouTubeMusicAlbum]
    var title = "Albums"
    var body: some View {
        List {
            if albums.isEmpty { WatchEmptyState(title: "No albums yet", message: "Find an album in Search and tap Like.", symbol: "square.stack") }
            ForEach(albums) { album in WatchAlbumLink(store: store, album: album) }
        }.navigationTitle(title)
    }
}
struct WatchAlbumView: View {
    @ObservedObject var store: YouTubeStore
    var album: YouTubeMusicAlbum
    var artistID: String? = nil
    @State private var songs: [YouTubeVideo] = []
    @State private var failure: String?
    @State private var loading = false
    @State private var description: String?
    private var selected: [YouTubeVideo] { guard let artistID, let discs = store.selectedDiscs(for: artistID, albumID: album.id) else { return songs }; return (try? MusicDiscLayout.filtered(songs, discs: discs)) ?? [] }
    var body: some View {
        List {
            VStack(spacing: 10) { WatchCover(url: album.artwork, size: 112); Text(album.title).font(.system(.title3, design: .rounded, weight: .bold)).multilineTextAlignment(.center); Text(album.artist).font(.caption).foregroundStyle(.secondary); Text(album.subtitle).font(.caption2).foregroundStyle(.secondary) }.frame(maxWidth: .infinity).listRowBackground(Color.clear)
            WatchPlayActions(store: store, songs: selected, context: "album:" + album.id)
            Button { store.toggleLike(album) } label: { Label(store.isLiked(album) ? "Unlike Album" : "Like Album", systemImage: store.isLiked(album) ? "heart.fill" : "heart") }
            NavigationLink("Add to Folder") { WatchFolderPicker(store: store, item: .album(album)) }
            NavigationLink("Add to Playlist") { WatchAlbumPlaylistPicker(store: store, album: album) }
            if let artistID { NavigationLink("Choose Discs") { WatchDiscPicker(store: store, artistID: artistID, album: album, songs: songs) } }
            if loading { ProgressView() }
            if let failure { WatchFailure(message: failure) { Task { await load() } } }
            ForEach(Array(selected.enumerated()), id: \.offset) { _, song in WatchSongRow(store: store, song: song, queue: selected, context: "album:" + album.id) }
            if let description { NavigationLink("About this Album") { ScrollView { Text(description).padding() }.navigationTitle("About") } }
        }.navigationTitle("Album").task { await load() }
    }
    private func load() async {
        songs = WatchContentCache.read(album.id) ?? []; loading = songs.isEmpty
        do { let page = try await MusicAlbumLibrary.shared.page(for: album); try Task.checkCancellation(); songs = page.tracks; description = page.description; WatchContentCache.save(songs, id: album.id); failure = nil }
        catch { if !Task.isCancelled { failure = error.localizedDescription } }; loading = false
    }
}
struct WatchSearchView: View {
    @ObservedObject var store: YouTubeStore
    var startingQuery = ""
    var kind: YouTubeAPI.MusicSearchKind = .all
    var choose: ((YouTubeVideo) -> Void)? = nil
    private let catalog: any MusicCatalogAccess = NativeMusicCatalog()
    @State private var query = ""
    @State private var result = YouTubeAPI.MusicCatalog()
    @State private var suggestions: [String] = []
    @State private var failure: String?
    @State private var loading = false
    @State private var filter: YouTubeAPI.MusicSearchKind = .all
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        List {
            TextField("Song, artist or lyrics", text: $query).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("watch.searchField")
            if !query.isEmpty { Picker("Show", selection: $filter) { ForEach(YouTubeAPI.MusicSearchKind.allCases, id: \.rawValue) { Text($0.rawValue).tag($0) } } }
            if query.isEmpty {
                if !store.recentMusicSearches.isEmpty { Button("Clear Recent Searches") { store.removeMusicSearch() } }
                ForEach(store.recentMusicSearches, id: \.self) { value in Button { query = value } label: { Label(value, systemImage: "clock") }.swipeActions { Button(role: .destructive) { store.removeMusicSearch(value) } label: { Image(systemName: "trash") } } }
            } else {
                if loading { ProgressView() }
                if let failure { WatchFailure(message: failure) { Task { await search() } } }
                if !suggestions.isEmpty { ForEach(Array(suggestions.prefix(3)), id: \.self) { value in Button(value) { query = value } } }
                if !loading && failure == nil && result.songs.isEmpty && result.albums.isEmpty && result.artists.isEmpty && result.playlists.isEmpty { Text("No matches. Try another name or lyric.").font(.caption).foregroundStyle(.secondary) }
                if !result.songs.isEmpty { Section("Songs") { ForEach(result.songs) { song in if let choose { Button { choose(song); dismiss() } label: { VStack(alignment: .leading) { Text(song.title); Text(song.channel).font(.caption2).foregroundStyle(.secondary) } } } else { WatchSongRow(store: store, song: song) } } } }
                Section { ForEach(result.artists) { artist in NavigationLink { WatchArtistView(store: store, artist: artist) } label: { WatchMenuRow(title: artist.name, symbol: "person.fill", detail: "Artist") } } }
                Section { ForEach(result.albums) { album in WatchAlbumLink(store: store, album: album) } }
                Section { ForEach(result.playlists) { playlist in NavigationLink { WatchPublicPlaylistView(store: store, playlist: playlist) } label: { HStack { WatchCover(url: playlist.artwork, size: 36); Text(playlist.title) } } } }
                if result.continuation != nil { Button("More Results") { Task { await more() } }.disabled(loading) }
            }
        }.navigationTitle("Search")
            .onAppear { if query.isEmpty { query = startingQuery; filter = kind } }
            .task(id: query + filter.rawValue) {
                guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                do { try await Task.sleep(for: .milliseconds(300)); try Task.checkCancellation(); await search() } catch {}
            }
    }
    private func search() async {
        let text = query; loading = true; failure = nil
        do {
            async let suggested = catalog.suggestions(text)
            let fetched = try await catalog.search(text, kind: filter); try Task.checkCancellation(); guard query == text else { return }
            result = fetched; suggestions = (try? await suggested.map(\.text)) ?? []; store.rememberMusicSearch(text)
        } catch { if !Task.isCancelled { failure = "Live search is unavailable. Saved matches are shown below. " + error.localizedDescription; result = .init(songs: (store.likedSongs + store.saved).filter { MusicSearchRelevance.matchesMetadata(title: $0.title, artist: $0.channel, query: text) }) } }
        if !Task.isCancelled { loading = false }
    }
    private func more() async {
        guard let token = result.continuation else { return }; let text = query, category = filter; loading = true
        do { let next = try await YouTubeAPI.musicSearchMore(token); try Task.checkCancellation(); guard query == text, filter == category else { return }; result = YouTubeAPI.mergingMusicSearchPage(next, into: result, query: query, kind: filter) }
        catch { if !Task.isCancelled { failure = error.localizedDescription } }; loading = false
    }
}
struct WatchPublicPlaylistView: View {
    @ObservedObject var store: YouTubeStore
    var playlist: YouTubePublicPlaylist
    @State private var songs: [YouTubeVideo] = []
    @State private var failure: String?
    @State private var loading = true
    var body: some View {
        List {
            VStack { WatchCover(url: playlist.artwork, size: 100); Text(playlist.title).font(.headline); Text(playlist.author).font(.caption2).foregroundStyle(.secondary) }.frame(maxWidth: .infinity).listRowBackground(Color.clear)
            WatchPlayActions(store: store, songs: songs, context: "public-playlist:" + playlist.id)
            Button("Save to Library") { _ = store.save(playlist, videos: songs) }
            if loading { ProgressView() }; if let failure { WatchFailure(message: failure) { Task { await load() } } }
            ForEach(Array(songs.enumerated()), id: \.offset) { _, song in WatchSongRow(store: store, song: song, queue: songs, context: "public-playlist:" + playlist.id) }
        }.navigationTitle("Playlist").task { await load() }
    }
    private func load() async { songs = WatchContentCache.read(playlist.id) ?? []; do { songs = try await YouTubeAPI.musicRankedSongs(playlist.id); WatchContentCache.save(songs, id: playlist.id); store.rememberPublicPlaybackSource(playlist); failure = nil } catch { failure = error.localizedDescription }; loading = false }
}
struct WatchDownloadsView: View {
    @ObservedObject var store: YouTubeStore
    @ObservedObject private var downloads = WatchDownloadStore.shared
    var body: some View {
        List {
            Toggle("Offline Only", isOn: $downloads.offlineOnly)
            Text(ByteCountFormatter.string(fromByteCount: downloads.usedBytes, countStyle: .file) + " on Apple Watch").font(.caption2).foregroundStyle(.secondary)
            if let error = downloads.storageError { Text(error).font(.caption) }
            if downloads.records.isEmpty { WatchEmptyState(title: "Take music with you", message: "Download a song, album or playlist from its options.", symbol: "arrow.down.circle") }
            if !downloads.songs.isEmpty { NavigationLink("Play Downloaded Music") { WatchSongList(store: store, title: "Downloaded", songs: downloads.songs) } }
            ForEach(downloads.records) { entry in
                VStack(alignment: .leading, spacing: 7) {
                    Text(entry.song.title).font(.headline); Text(entry.song.channel).font(.caption2).foregroundStyle(.secondary)
                    if entry.state == .downloaded { Label("Downloaded", systemImage: "checkmark.circle.fill").font(.caption2).foregroundStyle(novaGreen); Button("Play") { downloads.offlineOnly = true; store.play(entry.song, music: true); WatchNavigation.shared.player = true } }
                    else if entry.state == .failed || entry.state == .paused { Text(entry.failure ?? "Paused").font(.caption2).foregroundStyle(.secondary); Button("Retry Download") { downloads.add([entry.song]) } }
                    else { ProgressView(value: entry.progress); Text(entry.state == .downloading ? "Downloading · \(Int(entry.progress * 100))%" : entry.state.rawValue.capitalized).font(.caption2); Button("Pause") { downloads.pause(entry.id) } }
                    Button("Remove Download", role: .destructive) { downloads.remove(entry.id) }
                }.padding(.vertical, 5)
            }
        }.navigationTitle("Downloads")
    }
}
enum WatchContentCache {
    static func read(_ id: String) -> [YouTubeVideo]? { WatchEnvironment.defaults.data(forKey: "watch.collection." + id).flatMap { try? JSONDecoder().decode([YouTubeVideo].self, from: $0) } }
    static func save(_ songs: [YouTubeVideo], id: String) { WatchEnvironment.defaults.set(try? JSONEncoder().encode(songs), forKey: "watch.collection." + id) }
}

/// The cover is the navigation origin, preserving the collection's identity as it opens.
struct WatchAlbumLink: View {
    @ObservedObject var store: YouTubeStore
    var album: YouTubeMusicAlbum
    var artistID: String? = nil
    @Namespace private var coverTransition
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        NavigationLink {
            WatchAlbumView(store: store, album: album, artistID: artistID)
                .modifier(WatchCoverTransition(source: album.id, namespace: coverTransition, enabled: !reduceMotion))
        } label: {
            HStack(spacing: 9) {
                WatchCover(url: album.artwork, size: 42).matchedTransitionSource(id: album.id, in: coverTransition)
                VStack(alignment: .leading, spacing: 2) { Text(album.title).lineLimit(2); Text(album.artist).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
            }
        }
    }
}
struct WatchCoverTransition: ViewModifier {
    var source: String
    var namespace: Namespace.ID
    var enabled: Bool
    @ViewBuilder func body(content: Content) -> some View { if enabled { content.navigationTransition(.zoom(sourceID: source, in: namespace)) } else { content } }
}

struct WatchPlayingGlyph: View {
    @ObservedObject var player: YouTubePlayer
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isLuminanceReduced) private var dimmed
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var frozen = Date().timeIntervalSinceReferenceDate
    private var animating: Bool { player.playing && scenePhase == .active && !dimmed && !reduceMotion }
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animating)) { context in
            let phase = animating ? context.date.timeIntervalSinceReferenceDate : frozen
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<4) { index in
                    Capsule().fill(Color(red: 0.4, green: 0.92, blue: 0.62)).frame(width: 2, height: reduceMotion ? 6 + CGFloat(index % 2) * 5 : 4 + CGFloat((sin(phase * 5 + Double(index) * 1.7) + 1) / 2) * 11)
                }
            }.frame(width: 15, height: 17)
        }.onChange(of: player.playing) { _, _ in frozen = Date().timeIntervalSinceReferenceDate }.accessibilityHidden(true)
    }
}
