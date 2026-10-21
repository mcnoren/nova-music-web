import SwiftUI
import PhotosUI
import Intents

struct WatchPlaylistsView: View {
    @ObservedObject var store: YouTubeStore
    var body: some View {
        List {
            NavigationLink("New Playlist") { WatchPlaylistEditor(store: store) }
            NavigationLink("New Smart Playlist") { WatchSmartPlaylistEditor(store: store) }
            NavigationLink("Import from Spotify") { WatchSpotifyImportView(store: store) }
            ForEach(store.libraryPlaylists) { playlist in NavigationLink { WatchPlaylistView(store: store, id: playlist.id) } label: { HStack { WatchCover(url: playlist.artwork, size: 38, choice: playlist.customArtwork); VStack(alignment: .leading) { Text(playlist.name); Text("\(playlist.videos.count) songs").font(.caption2).foregroundStyle(.secondary) } } } }
        }.navigationTitle("Playlists")
    }
}
struct WatchPlaylistView: View {
    @ObservedObject var store: YouTubeStore
    var id: UUID
    @State private var loading = false
    @State private var failure: String?
    private var playlist: YouTubePlaylist? { store.playlist(id) }
    var body: some View {
        List {
            if let playlist {
                VStack { WatchCover(url: playlist.artwork, size: 104, choice: playlist.customArtwork); Text(playlist.name).font(.system(.title3, design: .rounded, weight: .bold)).multilineTextAlignment(.center) }.frame(maxWidth: .infinity).listRowBackground(Color.clear)
                WatchPlayActions(store: store, songs: playlist.videos, context: "playlist:" + id.uuidString.lowercased())
                if playlist.canEditSongs {
                    NavigationLink("Add Songs") { WatchSearchView(store: store, choose: { store.add($0, to: id) }) }
                    NavigationLink("Edit Playlist") { WatchPlaylistEditor(store: store, id: id) }
                } else if playlist.smartRules != nil { NavigationLink("Edit Rules") { WatchSmartPlaylistEditor(store: store, id: id) } }
                else { Button("Make Editable Copy") { _ = store.createPlaylist(named: playlist.name + " Copy", videos: playlist.videos) } }
                NavigationLink("Edit Artwork") { WatchArtworkEditor(store: store, target: .playlist(id)) }
                NavigationLink("Add to Folder") { WatchFolderPicker(store: store, item: .playlist(id)) }
                NavigationLink("Add to Artist Page") { WatchPlaylistArtistPicker(store: store, playlistID: id) }
                if loading { ProgressView() }; if let failure { WatchFailure(message: failure) { Task { await hydrate() } } }
                ForEach(Array(playlist.videos.enumerated()), id: \.offset) { _, song in WatchSongRow(store: store, song: song, queue: playlist.videos, context: "playlist:" + id.uuidString.lowercased()) }
            } else { WatchEmptyState(title: "Playlist Unavailable", message: "It may have been removed from your library.", symbol: "music.note.list") }
        }.navigationTitle("Playlist").task { await hydrate() }
    }
    private func hydrate() async {
        store.refreshSmartPlaylists()
        guard let remote = playlist?.youtubePlaylistID else { return }; loading = playlist?.videos.isEmpty ?? true
        do { let songs = try await YouTubeAPI.musicRankedSongs(remote); try Task.checkCancellation(); if let index = store.playlists.firstIndex(where: { $0.id == id }) { store.playlists[index].videos = songs; store.persistPlaylists() }; failure = nil }
        catch { if !Task.isCancelled { failure = error.localizedDescription } }; loading = false
    }
}
struct WatchPlaylistEditor: View {
    @ObservedObject var store: YouTubeStore
    var id: UUID? = nil
    @State private var name = ""
    @State private var failure: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        List {
            TextField("Playlist Name", text: $name)
            Button(id == nil ? "Create Playlist" : "Save Name") {
                if let id { store.renamePlaylist(id, to: name); dismiss() }
                else if store.createPlaylist(named: name) != nil { dismiss() }
                else { failure = "Enter a playlist name." }
            }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if let failure { Text(failure).font(.caption) }
            if let id, let playlist = store.playlist(id) {
                ForEach(Array(playlist.videos.enumerated()), id: \.offset) { index, song in
                    NavigationLink(song.title) {
                        List {
                            Text(song.title).font(.headline)
                            Button("Move Up") { store.movePlaylistSongs(id, from: IndexSet(integer: index), to: max(0,index-1)) }.disabled(index == 0)
                            Button("Move Down") { store.movePlaylistSongs(id, from: IndexSet(integer: index), to: index+2) }.disabled(index == playlist.videos.count-1)
                            Button("Remove Song", role: .destructive) { store.remove(song, from: id) }
                        }.navigationTitle("Edit Song")
                    }
                }
                WatchDeleteButton(title: "Delete Playlist") { store.deletePlaylist(id); dismiss() }
            }
        }.navigationTitle(id == nil ? "New Playlist" : "Edit Playlist").onAppear { if let id { name = store.playlist(id)?.name ?? "" } }
    }
}
struct WatchSmartPlaylistEditor: View {
    @ObservedObject var store: YouTubeStore
    var id: UUID? = nil
    @State private var name = ""
    @State private var rules = SmartPlaylistRules()
    @State private var artists = ""
    @State private var limit = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        List {
            TextField("Name", text: $name)
            Picker("Source", selection: $rules.source) { ForEach(SmartPlaylistRules.Source.allCases, id: \.rawValue) { Text($0.rawValue).tag($0) } }
            TextField("Artists, separated by commas", text: $artists)
            TextField("Song title contains", text: $rules.titleContains)
            TextField("Album title contains", text: $rules.albumContains)
            Picker("Order", selection: $rules.sort) { ForEach(SmartPlaylistRules.Sort.allCases, id: \.rawValue) { Text($0.rawValue).tag($0) } }
            TextField("Song limit (optional)", text: $limit)
            Text("\(store.smartPlaylistSongs(currentRules).count) matching songs").font(.caption).foregroundStyle(.secondary)
            NavigationLink("Preview Songs") { WatchSongList(store: store, title: "Preview", songs: store.smartPlaylistSongs(currentRules)) }
            Button("Save Smart Playlist") { if store.saveSmartPlaylist(id: id, name: name, rules: currentRules) != nil { dismiss() } }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !limit.isEmpty && Int(limit) == nil)
        }.navigationTitle("Smart Playlist").onAppear { if let id, let playlist = store.playlist(id), let value = playlist.smartRules { name = playlist.name; rules = value; artists = value.artists.joined(separator: ", "); limit = value.limit.map(String.init) ?? "" } }
    }
    private var currentRules: SmartPlaylistRules { var value = rules; value.artists = artists.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }; value.limit = Int(limit); return value }
}
struct WatchSongActions: View {
    @ObservedObject var store: YouTubeStore
    var song: YouTubeVideo
    var embedded = false
    var body: some View {
        Group {
            if !embedded { Text(song.title).font(.headline); Text(song.channel).font(.caption).foregroundStyle(.secondary) }
            Button { store.toggleLike(song) } label: { Label(store.isLiked(song) ? "Unlike Song" : "Like Song", systemImage: store.isLiked(song) ? "heart.fill" : "heart") }
            Button { store.toggleSaved(song) } label: { Label(store.saved.contains(where: { $0.id == song.id }) ? "Remove Saved Song" : "Save Song", systemImage: "plus.circle") }
            Button("Download") { WatchDownloadStore.shared.add([song]) }
            Button("Play Next") { Task { if WatchPhoneBridge.shared.mode == .phone { await WatchPhoneBridge.shared.enqueue([song], next: true) } else { await store.queueMusicAddition(.tracks([song], nil), next: true).value } } }
            Button("Add to Queue") { Task { if WatchPhoneBridge.shared.mode == .phone { await WatchPhoneBridge.shared.enqueue([song], next: false) } else { await store.queueMusicAddition(.tracks([song], nil), next: false).value } } }
            NavigationLink("Add to Playlist") { List { ForEach(store.playlists.filter(\.canEditSongs)) { playlist in Button(playlist.name) { store.add(song, to: playlist.id) } } }.navigationTitle("Add to Playlist") }
            NavigationLink("Go to Album") { WatchSongAlbumView(store: store, song: song) }
            NavigationLink("Song Information") { WatchSongInfoView(song: song) }
        }.navigationTitle("Song Options")
    }
}
struct WatchSongAlbumView: View {
    @ObservedObject var store: YouTubeStore
    var song: YouTubeVideo
    @State private var album: YouTubeMusicAlbum?
    @State private var failure: String?
    var body: some View { Group { if let album { WatchAlbumView(store: store, album: album) } else if let failure { WatchFailure(message: failure) { Task { await load() } } } else { ProgressView() } }.task { await load() } }
    private func load() async { do { album = try await YouTubeAPI.musicAlbum(for: song); if album == nil { failure = "No album was found for this recording." } } catch { failure = error.localizedDescription } }
}
struct WatchSongInfoView: View {
    var song: YouTubeVideo
    @State private var description: MusicDescription?
    @State private var loading = true
    @State private var attempt = 0
    var body: some View {
        List {
            Text(song.title).font(.headline); Text(song.channel).foregroundStyle(.secondary)
            if let title = song.albumTitle { Text(title) }
            if let duration = song.durationLabel { Text(duration) }
            if let composer = song.composer { Text("Written by " + composer) }
            Section("About this song") {
                if let description { Text(description.text); Link(description.sourceName, destination: description.source) }
                else if loading { ProgressView("Finding background…") }
                else { Text("No verified background is available for this song yet."); Button("Try Again") { attempt += 1 } }
            }
        }.navigationTitle("Song Info").task(id: song.id + String(attempt)) {
            loading = true
            let result = await MusicDescriptions.shared.songBackground(title: song.title, artist: MusicLyricsSource.cleanArtist(song.channel), refresh: attempt > 0)
            guard !Task.isCancelled else { return }; description = result; loading = false
        }
    }
}
struct WatchAlbumPlaylistPicker: View {
    @ObservedObject var store: YouTubeStore
    var album: YouTubeMusicAlbum
    @State private var added = Set<UUID>()
    var body: some View { List { ForEach(store.playlists.filter(\.canEditSongs)) { playlist in Button(added.contains(playlist.id) ? "Added to " + playlist.name : playlist.name) { Task { await store.addAlbum(album, to: playlist.id); if store.musicActionError == nil { added.insert(playlist.id) } } }.disabled(added.contains(playlist.id)) } }.navigationTitle("Add Album") }
}
struct WatchArtistsView: View {
    @ObservedObject var store: YouTubeStore
    var body: some View {
        List {
            NavigationLink("Artist Folders") { WatchArtistFoldersView(store: store) }
            ForEach(store.sortedLibraryArtists) { artist in NavigationLink { WatchArtistView(store: store, artist: artist) } label: { HStack { WatchCover(url: artist.avatar, size: 42, symbol: "person.fill"); Text(artist.name); if store.isArtistPinned(artist) { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary) } } } }
        }.navigationTitle("Artists")
    }
}
struct WatchArtistView: View {
    @ObservedObject var store: YouTubeStore
    var artist: YouTubeChannel
    @State private var page: YouTubeAPI.MusicArtistPage?
    @State private var failure: String?
    private var releases: [YouTubeMusicAlbum] { (page?.albums ?? []) + (page?.singles ?? []) }
    var body: some View {
        List {
            VStack { WatchCover(url: page?.artist.avatar ?? artist.avatar, size: 100, symbol: "person.fill"); Text(artist.name).font(.system(.title3, design: .rounded, weight: .bold)).multilineTextAlignment(.center) }.frame(maxWidth: .infinity).listRowBackground(Color.clear)
            HStack { Button("Play") { play(false) }; Button { play(true) } label: { Image(systemName: "shuffle") }.accessibilityLabel("Shuffle artist") }.buttonStyle(.borderedProminent)
            Button(store.isFollowingArtist(artist) ? "Unfollow Artist" : "Follow Artist") { store.toggleFollowArtist(artist) }
            Button(store.isArtistPinned(artist) ? "Unpin Artist" : "Pin Artist") { store.toggleArtistPin(artist) }
            Button("Move to Front") { store.moveArtistToFront(artist) }
            Button("Move Up") { store.moveArtist(artist, direction: -1) }
            Button("Move Down") { store.moveArtist(artist, direction: 1) }
            NavigationLink("Artist Folders") { WatchArtistFolderPicker(store: store, artist: artist) }
            NavigationLink("Choose Releases") { WatchReleasePicker(store: store, artist: artist, releases: releases) }
            if let page { Section("Top Songs") { ForEach(Array(page.songs.prefix(10))) { song in WatchSongRow(store: store, song: song, queue: page.songs) } } }
            Section("Discography") { ForEach(store.selectedReleases(for: artist.id, from: releases)) { album in WatchAlbumLink(store: store, album: album, artistID: artist.id) } }
            NavigationLink("All Releases") { WatchAlbumsView(store: store, albums: releases, title: "All Releases") }
            Section("Your Playlists") { ForEach(store.playlists(for: artist)) { playlist in NavigationLink(playlist.name) { WatchPlaylistView(store: store, id: playlist.id) } }; NavigationLink("Add Playlist") { List { ForEach(store.playlists) { playlist in Button(playlist.name) { store.setArtist(artist, forPlaylist: playlist.id) } } } } }
            NavigationLink("Artist Updates") { WatchArtistUpdatesView(artist: artist, releases: releases) }
            if let failure { WatchFailure(message: failure) { Task { await load() } } }
        }.navigationTitle("Artist").task { await load() }
    }
    private func play(_ shuffle: Bool) { Task { do { try await store.playArtist(artist, shuffle: shuffle); WatchNavigation.shared.player = true } catch { failure = error.localizedDescription } } }
    private func load() async {
        page = WatchCatalogStorage.read("artist:" + artist.id)
        do {
            var loaded = try await YouTubeAPI.musicArtistPage(artist)
            if !WatchCatalogStorage.offline {
                if let more = loaded.albumsMore { loaded.albums = try await YouTubeAPI.musicAlbums(more, artist: artist.name) }
                if let more = loaded.singlesMore { loaded.singles = try await YouTubeAPI.musicAlbums(more, artist: artist.name) }
                WatchCatalogStorage.save(loaded, key: "artist:" + artist.id)
            }
            page = loaded
            store.cachedMusicArtistPages[artist.id] = .init(date: Date(), page: loaded, rankedTracks: loaded.songs)
            failure = nil
        } catch { failure = error.localizedDescription }
    }
}
struct WatchReleasePicker: View {
    @ObservedObject var store: YouTubeStore
    var artist: YouTubeChannel
    var releases: [YouTubeMusicAlbum]
    var body: some View {
        List {
            Button("Use All Releases Automatically") { store.useAllReleases(for: artist.id) }
            Button("Select None") { store.setReleaseSelection(for: artist.id, releases: []) }
            ForEach(releases) { album in
                Toggle(album.title, isOn: Binding(get: { !store.hasReleaseSelection(for: artist.id) || store.isChosenRelease(album, for: artist.id) }, set: { included in
                    if !store.hasReleaseSelection(for: artist.id) { store.setReleaseSelection(for: artist.id, releases: releases) }
                    if included { store.addChosenRelease(album, for: artist.id) } else { store.removeChosenRelease(album, for: artist.id) }
                }))
                NavigationLink("Discs · " + album.title) { WatchAlbumDiscLoader(store: store, artistID: artist.id, album: album) }
            }
        }.navigationTitle("Choose Releases")
    }
}
struct WatchAlbumDiscLoader: View {
    @ObservedObject var store: YouTubeStore
    var artistID: String
    var album: YouTubeMusicAlbum
    @State private var songs: [YouTubeVideo]?
    @State private var failure: String?
    var body: some View { Group { if let songs { WatchDiscPicker(store: store, artistID: artistID, album: album, songs: songs) } else if let failure { WatchFailure(message: failure) { Task { await load() } } } else { ProgressView() } }.task { await load() } }
    private func load() async { do { songs = try await MusicAlbumLibrary.shared.page(for: album).tracks } catch { failure = error.localizedDescription } }
}
struct WatchDiscPicker: View {
    @ObservedObject var store: YouTubeStore
    var artistID: String
    var album: YouTubeMusicAlbum
    var songs: [YouTubeVideo]
    private var discs: [Int] { Array(Set(songs.compactMap(\.discNumber))).sorted() }
    var body: some View {
        List {
            if discs.count < 2 { Text("This release has no confirmed multiple-disc layout.").font(.caption) }
            ForEach(discs, id: \.self) { disc in Toggle("Disc \(disc)", isOn: Binding(get: { store.selectedDiscs(for: artistID, albumID: album.id)?.contains(disc) ?? true }, set: { included in var all = store.artistDiscSelections[artistID] ?? [:]; var selected = all[album.id] ?? discs; selected.removeAll { $0 == disc }; if included { selected.append(disc) }; all[album.id] = selected; store.setDiscSelections(for: artistID, selections: all) })) }
        }.navigationTitle("Choose Discs")
    }
}
struct WatchPlaylistArtistPicker: View {
    @ObservedObject var store: YouTubeStore
    var playlistID: UUID
    var body: some View { List { ForEach(store.sortedLibraryArtists) { artist in Button(artist.name) { store.setArtist(artist, forPlaylist: playlistID) } }; Button("Remove from Artist Page") { store.setArtist(nil, forPlaylist: playlistID) } }.navigationTitle("Artist Page") }
}
struct WatchFoldersView: View {
    @ObservedObject var store: YouTubeStore
    var body: some View { List { NavigationLink("Create Folder") { WatchFolderEditor(store: store) }; ForEach(store.musicFolders) { folder in NavigationLink { WatchFolderView(store: store, id: folder.id) } label: { HStack { WatchCover(url: folder.albums.first?.artwork, size: 40, symbol: "folder.fill", choice: folder.artwork).overlay(alignment: .bottomTrailing) { Image(systemName: "folder.fill").font(.system(size: 9)).padding(3).background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 4)) }; Text(folder.name).lineLimit(1) } } } }.navigationTitle("Folders") }
}
struct WatchFolderView: View {
    @ObservedObject var store: YouTubeStore
    var id: UUID
    @State private var failure: String?
    @State private var actions: MusicFolderItem?
    private var items: [MusicFolderItem] { store.folderItems(id) }
    var body: some View {
        List {
            if let folder = store.musicFolder(id) {
                HStack {
                    Button { Task { do { let songs = try await MusicFolderQueue.tracks(albums: folder.albums, playlists: folder.playlistIDs.compactMap { store.playlist($0) }); store.shufflePlaylist(songs, music: true); WatchNavigation.shared.player = true } catch { failure = error.localizedDescription } } } label: { Image(systemName: "shuffle").frame(width: 38, height: 38) }.accessibilityLabel("Shuffle folder")
                    Spacer()
                    Button { store.setFolderGallery(folder.gallery != true, in: id) } label: { Image(systemName: folder.gallery == true ? "list.bullet" : "square.grid.2x2").frame(width: 38, height: 38) }.accessibilityLabel(folder.gallery == true ? "List view" : "Gallery view")
                    NavigationLink { List {
                        NavigationLink("Add or Remove Items") { WatchFolderContentsEditor(store: store, id: id) }
                        NavigationLink("Rename Folder") { WatchFolderEditor(store: store, id: id) }
                        NavigationLink("Edit Artwork") { WatchArtworkEditor(store: store, target: .folder(id)) }
                    }.navigationTitle("Folder Options") } label: { Image(systemName: "ellipsis").frame(width: 30, height: 38) }.accessibilityLabel("Folder options")
                }.buttonStyle(.plain)
                if folder.gallery == true {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                        ForEach(items) { item in collection(item, gallery: true) }
                    }.listRowBackground(Color.clear)
                } else { ForEach(items) { item in collection(item, gallery: false) } }
                if items.isEmpty { Text("Add albums and playlists using Folder options.").font(.caption) }
                if let failure { Text(failure).font(.caption) }
            } else { Text("Folder Unavailable") }
        }.navigationTitle(store.musicFolder(id)?.name ?? "Folder")
            .sheet(item: $actions) { item in NavigationStack {
                List {
                    NavigationLink("Replace") { WatchFolderReplacementView(store: store, folderID: id, old: item) }
                    NavigationLink("Move") {
                        List {
                            Text("Move \(title(item)) before:").font(.caption)
                            ForEach(items.filter { $0.id != item.id }) { target in Button(title(target)) {
                                var order = items; order.removeAll { $0.id == item.id }
                                if let index = order.firstIndex(where: { $0.id == target.id }) { order.insert(item, at: index); store.setFolderItemOrder(order, in: id) }
                                actions = nil
                            } }
                            Button("Move to End") { var order = items; order.removeAll { $0.id == item.id }; order.append(item); store.setFolderItemOrder(order, in: id); actions = nil }
                        }.navigationTitle("Move Item")
                    }
                    Button(store.isFolderItemPinned(item, in: id) ? "Unpin" : "Pin") { store.toggleFolderItemPin(item, in: id); actions = nil }
                    Button("Remove from Folder", role: .destructive) { store.setFolder(id, contains: item, included: false); actions = nil }
                }.navigationTitle(title(item))
            } }
    }
    private func title(_ item: MusicFolderItem) -> String { switch item { case .album(let a): a.title; case .playlist(let p): store.playlist(p)?.name ?? "Playlist" } }
    @ViewBuilder private func collection(_ item: MusicFolderItem, gallery: Bool) -> some View {
        HStack(spacing: 2) {
            NavigationLink {
                switch item { case .album(let album): WatchAlbumView(store: store, album: album); case .playlist(let playlist): WatchPlaylistView(store: store, id: playlist) }
            } label: {
                if gallery { VStack(alignment: .leading, spacing: 5) { cover(item, size: 60); Text(title(item)).font(.caption2).lineLimit(1) } }
                else { HStack { cover(item, size: 40); Text(title(item)).lineLimit(1); Spacer(minLength: 0); if store.isFolderItemPinned(item, in: id) { Image(systemName: "pin.fill").font(.caption2) } } }
            }
            Button { actions = item } label: { Image(systemName: "ellipsis").font(.caption2).frame(width: gallery ? 20 : 26, height: 38) }.buttonStyle(.plain).accessibilityLabel("Options for " + title(item))
        }
    }
    @ViewBuilder private func cover(_ item: MusicFolderItem, size: CGFloat) -> some View {
        switch item {
        case .album(let album): WatchCover(url: album.artwork, size: size)
        case .playlist(let id): WatchCover(url: store.playlist(id)?.artwork, size: size, symbol: "music.note.list", choice: store.playlist(id)?.customArtwork)
        }
    }
}
struct WatchFolderReplacementView: View {
    @ObservedObject var store: YouTubeStore
    var folderID: UUID
    var old: MusicFolderItem
    @State private var query = ""
    @State private var catalog = YouTubeAPI.MusicCatalog()
    @State private var loading = false
    @State private var failure: String?
    @Environment(\.dismiss) private var dismiss
    private var albums: [YouTubeMusicAlbum] { query.isEmpty ? store.albumsAvailableForFolders : catalog.albums }
    var body: some View {
        List {
            TextField("Search online", text: $query)
            if loading { ProgressView() }
            if let failure { Text(failure).font(.caption) }
            Section("Albums") { ForEach(albums.filter { !store.folder(folderID, contains: .album($0)) }) { album in
                Button { replace(.album(album)) } label: { HStack { WatchCover(url: album.artwork, size: 36); VStack(alignment: .leading) { Text(album.title).lineLimit(1); Text(album.artist).font(.caption2).foregroundStyle(.secondary).lineLimit(1) } } }
            } }
            Section("Playlists") { ForEach(store.playlists.filter { !store.folder(folderID, contains: .playlist($0.id)) && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) }) { playlist in Button(playlist.name) { replace(.playlist(playlist.id)) } } }
            if !query.isEmpty { Section("Online Playlists") { ForEach(catalog.playlists.filter { source in !store.playlists.contains { $0.youtubePlaylistID == source.id && store.folder(folderID, contains: .playlist($0.id)) } }) { source in Button(source.title) {
                if let existing = store.playlists.first(where: { $0.youtubePlaylistID == source.id }) { replace(.playlist(existing.id)) }
                else {
                    let playlist = YouTubePlaylist(name: source.title, youtubePlaylistID: source.id, sourceArtwork: source.artwork, author: source.author, folderOnly: true)
                    store.playlists.append(playlist); replace(.playlist(playlist.id)); store.persistPlaylists()
                }
            } } } }
        }.navigationTitle("Replace Item").task(id: query) {
            guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { loading = false; failure = nil; catalog = .init(); return }
            do {
                try await Task.sleep(for: .milliseconds(350)); try Task.checkCancellation(); loading = true; failure = nil
                let result = try await NativeMusicCatalog().search(query, kind: .all)
                try Task.checkCancellation(); catalog = result; loading = false
            } catch { if !Task.isCancelled { loading = false; failure = error.localizedDescription } }
        }
    }
    private func replace(_ replacement: MusicFolderItem) { store.replaceFolderItem(old, with: replacement, in: folderID); dismiss() }
}
struct WatchFolderContentsEditor: View {
    @ObservedObject var store: YouTubeStore
    var id: UUID
    var body: some View { List { Section("Albums") { ForEach(store.albumsAvailableForFolders) { album in membership(album.title, .album(album)) } }; Section("Playlists") { ForEach(store.playlists) { playlist in membership(playlist.name, .playlist(playlist.id)) } } }.navigationTitle("Folder Contents") }
    private func membership(_ name: String, _ item: MusicFolderItem) -> some View { Toggle(name, isOn: Binding(get: { store.folder(id, contains: item) }, set: { store.setFolder(id, contains: item, included: $0) })) }
}
struct WatchFolderPicker: View {
    @ObservedObject var store: YouTubeStore
    var item: MusicFolderItem
    var body: some View { List { ForEach(store.musicFolders) { folder in Toggle(folder.name, isOn: Binding(get: { store.folder(folder.id, contains: item) }, set: { store.setFolder(folder.id, contains: item, included: $0) })) }; NavigationLink("Create Folder") { WatchFolderEditor(store: store) } }.navigationTitle("Add to Folders") }
}
struct WatchFolderEditor: View {
    @ObservedObject var store: YouTubeStore
    var id: UUID? = nil
    @State private var name = ""
    @State private var failure: String?
    @State private var created: UUID?
    @Environment(\.dismiss) private var dismiss
    var body: some View { List { TextField("Folder Name", text: $name); Button(id == nil ? "Create" : "Save") { if let id { if store.renameMusicFolder(id, to: name) { dismiss() } else { failure = "Choose a unique folder name." } } else { created = store.createMusicFolder(named: name); if created == nil { failure = "Choose a unique folder name." } } }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || created != nil); if let failure { Text(failure).font(.caption) }; if let created { NavigationLink("Choose Contents") { WatchFolderContentsEditor(store: store, id: created) } }; if let id { WatchDeleteButton(title: "Delete Folder") { store.deleteMusicFolder(id); dismiss() } } }.navigationTitle(id == nil ? "New Folder" : "Rename Folder").onAppear { if let id { name = store.musicFolder(id)?.name ?? "" } } }
}
struct WatchArtistFoldersView: View {
    @ObservedObject var store: YouTubeStore
    @State private var name = ""
    var body: some View {
        List {
            TextField("New Folder Name", text: $name); Button("Create Artist Folder") { if store.createArtistFolder(named: name) != nil { name = "" } }.disabled(name.isEmpty)
            ForEach(store.artistFolders) { folder in NavigationLink(folder.name) { WatchArtistFolderDetail(store: store, id: folder.id) } }
        }.navigationTitle("Artist Folders")
    }
}
struct WatchArtistFolderDetail: View {
    @ObservedObject var store: YouTubeStore
    var id: UUID
    @State private var name = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View { List { TextField("Folder Name", text: $name); Button("Rename") { _ = store.renameArtistFolder(id, to: name) }; NavigationLink("Edit Artwork") { WatchArtworkEditor(store: store, target: .artistFolder(id)) }; Section("Artists") { ForEach(store.sortedLibraryArtists) { artist in Toggle(artist.name, isOn: Binding(get: { store.artistFolder(id)?.artistIDs.contains(artist.id) == true }, set: { store.setArtistFolder(id, artists: [artist], included: $0) })) } }; Section("Browse") { ForEach(store.artists(in: id)) { artist in NavigationLink(artist.name) { WatchArtistView(store: store, artist: artist) } } }; WatchDeleteButton(title: "Delete Folder") { store.deleteArtistFolder(id); dismiss() } }.navigationTitle("Artist Folder").onAppear { name = store.artistFolder(id)?.name ?? "" } }
}
struct WatchArtistFolderPicker: View {
    @ObservedObject var store: YouTubeStore
    var artist: YouTubeChannel
    var body: some View { List { ForEach(store.artistFolders) { folder in Toggle(folder.name, isOn: Binding(get: { folder.artistIDs.contains(artist.id) }, set: { store.setArtistFolder(folder.id, artists: [artist], included: $0) })) }; NavigationLink("New Artist Folder") { WatchArtistFoldersView(store: store) } }.navigationTitle("Artist Folders") }
}
struct WatchArtworkEditor: View {
    @ObservedObject var store: YouTubeStore
    var target: MusicArtworkTarget
    @State private var photo: PhotosPickerItem?
    @State private var failure: String?
    private let symbols = ["folder.fill", "music.note", "music.note.list", "star.fill", "heart.fill", "sparkles", "moon.fill", "sun.max.fill", "pianokeys", "guitars.fill"]
    var body: some View { List { PhotosPicker("Choose Photo", selection: $photo, matching: .images); Button("Use Collage") { store.setArtwork(.init(style: .collage), for: target) }; ForEach(symbols, id: \.self) { symbol in Button { store.setArtwork(.init(symbol: symbol), for: target) } label: { Image(systemName: symbol).frame(maxWidth: .infinity).padding(6) }.accessibilityLabel(symbol.replacingOccurrences(of: ".fill", with: "")) }; Button("Default Artwork") { store.setArtwork(nil, for: target) }; if let failure { Text(failure).font(.caption) } }.navigationTitle("Artwork").task(id: photo) { guard let photo else { return }; do { if let data = try await photo.loadTransferable(type: Data.self) { try store.setPhoto(data, for: target) } } catch { failure = error.localizedDescription } } }
}
struct WatchDeleteButton: View {
    var title: String
    var action: () -> Void
    @State private var confirm = false
    var body: some View { Button(title, role: .destructive) { confirm = true }.confirmationDialog(title + "?", isPresented: $confirm) { Button(title, role: .destructive, action: action); Button("Cancel", role: .cancel) {} } }
}

struct WatchBulkSongsView: View {
    @ObservedObject var store: YouTubeStore
    var songs: [YouTubeVideo]
    @State private var selected = Set<String>()
    @State private var notice: String?
    private var tracks: [YouTubeVideo] { songs.filter { selected.contains($0.id) } }
    var body: some View {
        List {
            Button(selected.count == Set(songs.map(\.id)).count ? "Clear Selection" : "Select All") { selected = selected.count == Set(songs.map(\.id)).count ? [] : Set(songs.map(\.id)) }
            NavigationLink("Actions · \(selected.count) Songs") {
                List {
                    Button("Like Selected") { for song in tracks where !store.isLiked(song) { store.toggleLike(song) }; notice = "Songs liked" }
                    Button("Download Selected") { WatchDownloadStore.shared.add(tracks); notice = "Downloads added" }
                    Button("Play Next") { enqueue(true) }; Button("Add to Queue") { enqueue(false) }
                    NavigationLink("Add to Playlist") { List { ForEach(store.playlists.filter(\.canEditSongs)) { playlist in Button(playlist.name) { Task { do { try await store.addSelection(tracks.map(MusicSelectionItem.song), toPlaylist: playlist.id); notice = "Added to " + playlist.name } catch { notice = error.localizedDescription } } } } } }
                    if let notice { Text(notice).font(.caption) }
                }.navigationTitle("Selected Songs")
            }.disabled(selected.isEmpty)
            ForEach(Array(songs.enumerated()), id: \.offset) { _, song in Toggle(song.title, isOn: Binding(get: { selected.contains(song.id) }, set: { if $0 { selected.insert(song.id) } else { selected.remove(song.id) } })) }
        }.navigationTitle("Select Songs")
    }
    private func enqueue(_ next: Bool) { Task { if WatchPhoneBridge.shared.mode == .phone { await WatchPhoneBridge.shared.enqueue(tracks, next: next) } else { await store.queueMusicAddition(.tracks(tracks, nil), next: next).value }; notice = "Queue updated" } }
}
