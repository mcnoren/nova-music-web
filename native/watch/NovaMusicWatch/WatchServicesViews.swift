import SwiftUI
import Intents
import AVFoundation

struct WatchDiscoverView: View {
    @ObservedObject var store: YouTubeStore
    @StateObject private var explore = MusicExploreModel()
    var body: some View {
        List {
            NavigationLink("Apple Music Top 100") { WatchChartView(store: store) }
            Section("New Releases") { ForEach(Array((explore.discovery?.releases ?? []).prefix(10))) { album in NavigationLink(album.title) { WatchAlbumView(store: store, album: album) } } }
            Section("Trending") { ForEach(Array((explore.discovery?.trending ?? []).prefix(10))) { song in WatchSongRow(store: store, song: song) } }
            if let failure = explore.discoveryError { WatchFailure(message: failure) { Task { await explore.load(refresh: true) } } }
            Section("Your Genres") { ForEach(store.discoverGenres, id: \.self) { genre in NavigationLink(genre) { WatchGenreView(store: store, definition: .init(name: genre, kind: .genre)) } }; NavigationLink("Customize Genres") { WatchGenreEditor(store: store) } }
            Section("Moods") { ForEach(MusicDiscovery.moods, id: \.self) { mood in NavigationLink(mood) { WatchGenreView(store: store, definition: .init(name: mood, kind: .mood)) } } }
            Section("Activities") { ForEach(MusicDiscovery.activities, id: \.self) { activity in NavigationLink(activity) { WatchGenreView(store: store, definition: .init(name: activity, kind: .activity)) } } }
        }.navigationTitle("Discover").task { await explore.load() }.refreshable { await explore.load(refresh: true) }
    }
}
struct WatchGenreView: View {
    @ObservedObject var store: YouTubeStore
    var definition: MusicGenreDefinition
    var body: some View { List { ForEach(definition.shelves) { shelf in NavigationLink(shelf.title) { WatchSearchView(store: store, startingQuery: shelf.query, kind: .playlists) } }; if !definition.decades.isEmpty { Section("By the Decade") { ForEach(definition.decades, id: \.self) { decade in NavigationLink(decade) { WatchSearchView(store: store, startingQuery: definition.decadeQuery(decade), kind: .playlists) } } } } }.navigationTitle(definition.name) }
}
struct WatchGenreEditor: View {
    @ObservedObject var store: YouTubeStore
    @State private var custom = ""
    var body: some View { List { TextField("Custom Genre", text: $custom); Button("Add Genre") { store.setDiscoverGenres(store.discoverGenres + [custom]); custom = "" }.disabled(custom.trimmingCharacters(in: .whitespaces).isEmpty); Section("Your Order") { ForEach(Array(store.discoverGenres.enumerated()), id: \.element) { index, genre in NavigationLink(genre) { List { Button("Move Up") { var values = store.discoverGenres; values.swapAt(index, index-1); store.setDiscoverGenres(values) }.disabled(index == 0); Button("Move Down") { var values = store.discoverGenres; values.swapAt(index, index+1); store.setDiscoverGenres(values) }.disabled(index == store.discoverGenres.count-1); Button("Remove", role: .destructive) { store.setDiscoverGenres(store.discoverGenres.filter { $0 != genre }) } } } } }; Section("Add Genres") { ForEach(MusicDiscovery.genres.filter { !store.discoverGenres.contains($0) }, id: \.self) { genre in Button(genre) { store.setDiscoverGenres(store.discoverGenres + [genre]) } } } }.navigationTitle("Your Genres") }
}
struct WatchChartView: View {
    @ObservedObject var store: YouTubeStore
    @State private var chart: MusicChartSnapshot?
    @State private var failure: String?
    @State private var selected: String?
    var body: some View {
        List {
            if let chart {
                Text("Apple Music US Top 100").font(.headline); Text("Updated " + chart.updated.formatted(date: .abbreviated, time: .omitted)).font(.caption2).foregroundStyle(.secondary)
                ForEach(chart.entries) { entry in Button {
                    selected = entry.id
                    Task { do { try await store.playChart(chart, entry: entry); WatchNavigation.shared.player = true; failure = nil } catch { failure = error.localizedDescription }; selected = nil }
                } label: { HStack { Text("\(entry.rank)").font(.caption).foregroundStyle(.secondary).frame(width: 22); WatchCover(url: entry.artwork, size: 32); VStack(alignment: .leading) { Text(entry.title); Text(entry.artist).font(.caption2).foregroundStyle(.secondary) }; if selected == entry.id { ProgressView() } } }.disabled(selected != nil) }
            } else if failure == nil { ProgressView() }
            if let failure { WatchFailure(message: failure) { Task { await load() } } }
        }.navigationTitle("Top 100").task { await load() }
    }
    private func load() async { chart = await MusicExploreService.shared.cachedChart(); do { chart = try await MusicExploreService.shared.chart(); failure = nil } catch { failure = error.localizedDescription } }
}
struct WatchClassicalView: View {
    @ObservedObject var store: YouTubeStore
    var body: some View {
        List { ForEach(ClassicalComposer.catalog) { composer in NavigationLink { WatchComposerView(store: store, composer: composer) } label: { VStack(alignment: .leading) { Text(composer.name).font(.headline); Text(composer.era).font(.caption2).foregroundStyle(.secondary) } } } }.navigationTitle("Classical")
    }
}
struct WatchComposerView: View {
    @ObservedObject var store: YouTubeStore
    var composer: ClassicalComposer
    var body: some View {
        List {
            if let url = Bundle.main.url(forResource: composer.portraitName, withExtension: "jpg", subdirectory: "ClassicalPortraits") { WatchCover(url: url, size: 104, symbol: "pianokeys").frame(maxWidth: .infinity).listRowBackground(Color.clear) }
            Text(composer.introduction).font(.caption).foregroundStyle(.secondary)
            ForEach(ClassicalLibrary.works.filter { $0.composer == composer.name }) { work in NavigationLink(work.title) { WatchClassicalWorkView(store: store, work: work) } }
            NavigationLink("All Works") { WatchComposerCatalogView(store: store, composer: composer) }
            NavigationLink("Find More Recordings") { WatchSearchView(store: store, startingQuery: composer.name, kind: .albums) }
        }.navigationTitle(composer.surname)
    }
}
struct WatchClassicalWorkView: View {
    @ObservedObject var store: YouTubeStore
    var work: ClassicalWork
    @State private var albums: [YouTubeMusicAlbum] = []
    @State private var failure: String?
    var body: some View { List { Text(work.title).font(.headline); Text(work.overview ?? work.detail).font(.caption); ForEach(albums) { album in NavigationLink(album.title + " · " + album.artist) { WatchAlbumView(store: store, album: album) } }; if let failure { WatchFailure(message: failure) { Task { await load() } } }; NavigationLink("Search Recordings") { WatchSearchView(store: store, startingQuery: work.composer + " " + work.title, kind: .albums) } }.navigationTitle("Recordings").task { await load() } }
    private func load() async { do { albums = try await ClassicalRecordingSource.shared.recordings(for: work).all; failure = nil } catch { failure = error.localizedDescription } }
}
struct WatchArtistUpdatesView: View {
    var artist: YouTubeChannel
    var releases: [YouTubeMusicAlbum]
    @State private var updates: MusicArtistUpdates?
    @State private var failure: String?
    var body: some View {
        List {
            Section("New Releases") { ForEach(MusicArtistReleaseOrder.latest(releases)) { album in Text(album.title + " · " + (album.year ?? "")) } }
            if let updates {
                Section("Upcoming Releases") { ForEach(updates.releases) { release in VStack(alignment: .leading) { Text(release.title); Text(release.date.label).font(.caption2).foregroundStyle(.secondary); Link("MusicBrainz", destination: release.source) } }; if let error = updates.releaseError { Text(error).font(.caption) } }
                Section("Dates") { ForEach(updates.events) { event in NavigationLink { List { Text(event.title).font(.headline); Text(event.dateLabel); if let time = event.time { Text(time) }; if let venue = event.venue { Text(venue) }; if let address = event.address { Text(address) }; if let location = event.location { Text(location) }; if event.cancelled || event.artistCancelled { Text("Cancelled").foregroundStyle(.orange) }; ForEach(event.credits) { credit in Text(credit.name + " · " + credit.role) }; if let setlist = event.setlist { Text(setlist) }; if let notes = event.notes { Text(notes) }; ForEach(event.links) { link in Link(link.title, destination: link.url) }; Link("MusicBrainz", destination: event.source) } } label: { VStack(alignment: .leading) { Text(event.title); Text(event.dateLabel).font(.caption2) }.foregroundStyle(event.isPast(relativeTo: .today()) ? .secondary : .primary) } }; if let error = updates.eventError { Text(error).font(.caption) } }
                if let site = updates.officialSite { Link("Official Website", destination: site) }
                Text("Listings from MusicBrainz. Missing dates do not mean no events are planned.").font(.caption2).foregroundStyle(.secondary)
            } else if failure == nil { ProgressView() }
            if let failure { WatchFailure(message: failure) { Task { await load() } } }
        }.navigationTitle("Artist Updates").task { await load() }
    }
    private func load() async { do { updates = try await MusicArtistUpdatesService.shared.updates(for: artist, catalog: releases); failure = nil } catch { failure = error.localizedDescription } }
}
struct WatchSettingsView: View {
    @ObservedObject var store: YouTubeStore
    @ObservedObject private var downloads = WatchDownloadStore.shared
    @State private var siriStatus = ""
    var body: some View {
        List {
            NavigationLink("Playback Device") { WatchPlaybackDeviceView() }
            NavigationLink("iCloud Sync") { WatchICloudSettings(account: store.musicAccount) }
            Toggle("Cellular Downloads", isOn: $downloads.allowCellular)
            Toggle("Offline Only", isOn: $downloads.offlineOnly)
            Button("Enable Siri") { WatchSiriAuthorization.request { status in Task { @MainActor in siriStatus = status == .authorized ? "Siri is enabled." : "Enable Nova Music in Siri settings on your Watch."; MusicSiriVocabulary.updateArtists(store.followedArtists); MusicSiriVocabulary.updatePlaylists(store.playlists) } } }
            if !siriStatus.isEmpty { Text(siriStatus).font(.caption) }
            Text("Try “Play my playlist in Nova Music.” Siri on Watch plays directly on Apple Watch.").font(.caption).foregroundStyle(.secondary)
            NavigationLink("Siri Diagnostics") { ScrollView { Text((store.defaults.stringArray(forKey: "watch.siriTrace") ?? []).joined(separator: "\n")).font(.caption2).padding() } }
            Text("Nova Music for Apple Watch").font(.caption2).foregroundStyle(.secondary)
        }.navigationTitle("Settings")
    }
}
struct WatchICloudSettings: View {
    @ObservedObject var account: MusicAccountSync
    @State private var mergeLibrary = true
    @State private var working = false
    var body: some View {
        List {
            Text(account.status).font(.caption)
            if account.cloudEnabled {
                Button("Sync Now") { Task { working = true; await account.sync(); working = false } }
                WatchDeleteButton(title: "Turn off iCloud") { account.disconnect() }
            } else {
                Text("Use the same Apple Account as your other devices. Your music stays available offline.").font(.caption)
                Toggle("Add local library", isOn: $mergeLibrary)
                Button("Enable iCloud") { Task { working = true; await account.enableICloud(mergeLibrary: mergeLibrary); working = false } }
            }
            if working { ProgressView() }; if let error = account.error { Text(error).font(.caption).foregroundStyle(.orange) }
            if let date = account.lastSynced { Text("Last synced " + date.formatted(date: .abbreviated, time: .shortened)).font(.caption2) }
        }.navigationTitle("Library Sync").disabled(working)
    }
}
struct WatchSpotifyImportView: View {
    @ObservedObject var store: YouTubeStore
    @StateObject private var access = SpotifyPlaylistAccess()
    @StateObject private var model = SpotifyPlaylistImportModel()
    @State private var link = ""
    @State private var work: Task<Void, Never>?
    var body: some View {
        List {
            TextField("Spotify Playlist Link", text: $link).textInputAutocapitalization(.never).autocorrectionDisabled()
            if access.isConfigured { Button(access.isConnected ? "Reconnect Spotify" : "Connect Spotify") { work = Task { await access.connect() } }.disabled(access.connecting) }
            else { Text("Full Spotify access isn’t configured for this build. Complete public playlists can still be imported; incomplete previews will ask for a configured connection.").font(.caption).foregroundStyle(.secondary) }
            if let error = access.error { Text(error).font(.caption) }
            Button("Find Songs") { work = Task { await model.load(link, fetch: { value in return try await SpotifyPlaylistImporter.fetch(value, accessToken: try await access.accessTokenIfConnected()) }) } }.disabled(link.isEmpty || model.loading)
            if model.loading { ProgressView(value: Double(model.completed), total: Double(max(1,model.total))); Text("Matched \(model.completed) of \(model.total)").font(.caption2); Button("Cancel") { work?.cancel() } }
            if let error = model.error { Text(error).font(.caption) }
            if let result = model.result {
                TextField("Playlist Name", text: $model.name)
                ForEach(result.matches) { match in VStack(alignment: .leading) { Text(match.track.title); Text(match.song?.title ?? match.explanation).font(.caption2).foregroundStyle(.secondary) } }
                Button("Create Playlist") { model.save(to: store) }.disabled(model.savedPlaylistID != nil)
                if let id = model.savedPlaylistID { NavigationLink("Open Playlist") { WatchPlaylistView(store: store, id: id) } }
            }
        }.navigationTitle("Spotify Import").onDisappear { work?.cancel() }
    }
}
struct WatchSpotifyReviewView: View {
    @ObservedObject var store: YouTubeStore
    var body: some View {
        List { if store.spotifySongsToReview.isEmpty { Text("No songs to review.") }; ForEach(store.spotifySongsToReview) { item in NavigationLink { List { Text(item.track.track.title).font(.headline); Text(item.track.track.artist); Text(item.playlistName).font(.caption); if let reason = item.track.failureDetail { Text(reason).font(.caption) }; if let matched = item.track.matchedSongID { Text("Paired: " + (store.knownVideo(matched)?.title ?? matched)) } else { NavigationLink("Find Recording") { WatchSearchView(store: store, startingQuery: item.track.track.title + " " + item.track.track.artist, kind: .songs, choose: { _ = store.pairSpotifyTrack(item.track.id, in: item.playlistID, with: $0) }) } } } } label: { VStack(alignment: .leading) { Text(item.track.track.title); Text(item.playlistName).font(.caption2).foregroundStyle(.secondary) } } } }.navigationTitle("Songs to Review")
    }
}
struct WatchCalibrationView: View {
    @ObservedObject var player: YouTubePlayer
    @State private var samples: [LyricCalibration.Sample] = []
    @State private var failure: String?
    var body: some View {
        List {
            Text("Choose a line when you hear it begin. Add a second point at least 15 seconds later to correct drift.").font(.caption).foregroundStyle(.secondary)
            ForEach(player.lyrics?.lines.filter { !$0.text.isEmpty } ?? []) { line in Button(line.text) { let sample = LyricCalibration.Sample(playback: player.currentTime, lyric: line.time); let points = samples.isEmpty ? [sample] : [samples[0], sample]; if let fit = LyricCalibration.fitted(points) { samples = points; player.saveCalibration(fit); failure = nil } else { failure = "Choose a later line, at least 15 seconds after the first point." } } }
            Text("\(samples.count) calibration points").font(.caption2)
            Button("Lyrics 0.1s Earlier") { var value = player.calibration; value.offset += 0.1; player.saveCalibration(value) }
            Button("Lyrics 0.1s Later") { var value = player.calibration; value.offset -= 0.1; player.saveCalibration(value) }
            Button("Reset Calibration") { samples = []; player.saveCalibration(.init()) }
            if let failure { Text(failure).font(.caption) }
        }.navigationTitle("Calibrate Lyrics")
    }
}

struct WatchComposerCatalogView: View {
    @ObservedObject var store: YouTubeStore
    var composer: ClassicalComposer
    @State private var query = ""
    @State private var works: [CataloguedClassicalWork] = []
    @State private var offset: Int?
    @State private var failure: String?
    @State private var loading = false
    var body: some View {
        List {
            TextField("Search Works", text: $query)
            ForEach(works) { work in NavigationLink { WatchClassicalWorkView(store: store, work: .init(composer: composer.name, title: work.title, detail: work.detail)) } label: { VStack(alignment: .leading) { Text(work.title); Text(work.detail).font(.caption2).foregroundStyle(.secondary) } } }
            if loading { ProgressView() }
            if offset != nil { Button("More Works") { Task { await load(more: true) } }.disabled(loading) }
            if let failure { WatchFailure(message: failure) { Task { await load() } } }
        }.navigationTitle("All Works").task(id: query) { do { try await Task.sleep(for: .milliseconds(300)); try Task.checkCancellation(); await load() } catch {} }
    }
    private func load(more: Bool = false) async {
        let requested = query; loading = true
        do { let page = try await ClassicalWorkCatalogSource.shared.works(for: composer, search: query, offset: more ? offset ?? 0 : 0); try Task.checkCancellation(); guard query == requested else { return }; if more { works += page.works } else { works = page.works }; offset = page.nextOffset; failure = nil }
        catch { if !Task.isCancelled { failure = error.localizedDescription } }; loading = false
    }
}
struct WatchAudioOutputView: View {
    @State private var output = ""
    @State private var failure: String?
    var body: some View {
        List {
            Text(output.isEmpty ? "No output connected" : output).font(.headline)
            Button("Connect Audio Output") { Task { do { try await AVAudioSession.sharedInstance().activate(); refresh() } catch { failure = error.localizedDescription } } }
            Text("Apple Watch selects headphones when playback starts. To change an existing connection, choose an audio output in Control Center.").font(.caption).foregroundStyle(.secondary)
            if let failure { Text(failure).font(.caption) }
        }.navigationTitle("Audio Output").onAppear { refresh() }
    }
    private func refresh() { output = AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portName).joined(separator: ", ") }
}
