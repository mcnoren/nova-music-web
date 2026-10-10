import Foundation

@MainActor
enum MusicAccountLibrary {
    static func values(_ store: YouTubeStore, preserving old: [String: NovaSyncValue] = [:]) throws -> [String: NovaSyncValue] {
        var result: [String: NovaSyncValue] = [:]
        let tracks = store.likedSongs + store.saved + store.musicHistory + store.playlists.flatMap(\.videos)
        for track in tracks {
            var song = old["song:\(track.id)"]?.object ?? [:]
            song["id"] = .string(track.id); song["title"] = .string(track.title); song["artist"] = .string(track.channel)
            song["album"] = .string(track.albumTitle ?? ""); song["artwork"] = .string(track.thumbnail?.absoluteString ?? "")
            song["duration"] = .number(seconds(track.durationLabel)); song["source"] = .string("youtube")
            song["explicit"] = .bool(track.isExplicit ?? false); song["native"] = try .encoded(track)
            if let id = track.albumID { song["albumId"] = .string(id) }
            if let id = track.channelID { song["artistId"] = .string(id) }
            if let number = track.discNumber { song["discNumber"] = .number(Double(number)) }
            result["song:\(track.id)"] = .object(song)
        }
        func membership(_ prefix: String, _ ids: [String]) {
            for (order, id) in ids.enumerated() { result["\(prefix):\(id)"] = .object(["id": .string(id), "order": .number(Double(order))]) }
        }
        membership("liked",store.likedSongs.map(\.id)); membership("saved",store.saved.map(\.id))
        membership("savedAlbum",store.likedAlbums.map(\.id)); membership("followedArtist",store.sortedLibraryArtists.map(\.id))
        membership("artistPin",store.pinnedArtistIDs.sorted())
        let albums = store.likedAlbums + store.artistReleaseSelections.values.flatMap { $0 } + store.musicFolders.flatMap(\.albums)
        for album in albums {
            var value = old["album:\(album.id)"]?.object ?? [:]
            value["id"] = .string(album.id); value["title"] = .string(album.title); value["artist"] = .string(album.artist)
            value["artwork"] = .string(album.artwork?.absoluteString ?? ""); value["kind"] = .string(album.kind)
            value["year"] = album.year.map(NovaSyncValue.string) ?? .null; value["native"] = try .encoded(album)
            if value["tracks"] == nil { value["tracks"] = .array([]); value["complete"] = .bool(false) }
            result["album:\(album.id)"] = .object(value)
        }
        for artist in store.followedArtists {
            var value = old["artist:\(artist.id)"]?.object ?? [:]
            value["id"] = .string(artist.id); value["name"] = .string(artist.name)
            value["artwork"] = .string(artist.avatar?.absoluteString ?? ""); value["native"] = try .encoded(artist)
            result["artist:\(artist.id)"] = .object(value)
        }
        for (order,playlist) in store.playlists.enumerated() {
            let id = playlist.id.uuidString.lowercased()
            var value = old["playlist:\(id)"]?.object ?? [:]
            value["id"] = .string(id); value["name"] = .string(playlist.name); value["order"] = .number(Double(order))
            value["songs"] = .array(playlist.videos.map { .string($0.id) }); value["createdAt"] = .number(playlist.createdAt.timeIntervalSince1970 * 1000)
            value["artwork"] = .string(playlist.sourceArtwork?.absoluteString ?? ""); value["native"] = try .encoded(playlist)
            if let source = playlist.spotifySourceURL { value["sourceUrl"] = .string(source.absoluteString) }
            else if let source = playlist.youtubePlaylistID { value["sourceUrl"] = .string("https://www.youtube.com/playlist?list=\(source)") }
            if let unmatched = playlist.spotifyUnmatchedTracks {
                let previousUnmatched = Dictionary((value["unmatched"]?.array ?? []).compactMap { item in
                    item["position"]?.safeInt.map { ($0,item.object ?? [:]) }
                },uniquingKeysWith:{ _,last in last })
                value["unmatched"] = .array(unmatched.map { entry in
                    var item = previousUnmatched[entry.position - 1] ?? [:]
                    let fields: [String:NovaSyncValue] = ["id":.string(entry.id.uuidString.lowercased()), "position":.number(Double(entry.position - 1)),
                        "title":.string(entry.track.title), "artist":.string(entry.track.artist), "album":.string(entry.track.album ?? ""),
                        "uri":.string(entry.track.uri), "duration":entry.track.duration.map(NovaSyncValue.number) ?? .null,
                        "explicit":entry.track.isExplicit.map(NovaSyncValue.bool) ?? .null, "checked":.bool(entry.isChecked),
                        "status":.string(entry.reason.rawValue), "reason":.string(entry.failureDetail ?? SpotifyPlaylistImporter.Match(id:0,track:entry.track,song:nil,status:entry.reason).explanation)]
                    item.merge(fields) { _,new in new }
                    if let isrc = entry.track.isrc { item["isrc"] = .string(isrc) }
                    item["matchedSongId"] = entry.matchedSongID.map(NovaSyncValue.string) ?? .null
                    return .object(item)
                })
            }
            if let importedIDs = playlist.spotifyImportSongIDs {
                let previous = Dictionary((value["importEntries"]?.array ?? []).compactMap { item in
                    item["position"]?.safeInt.map { ($0,item.object ?? [:]) }
                },uniquingKeysWith:{ _,last in last })
                value["importEntries"] = .array(importedIDs.enumerated().map { position,songID in
                    var item = previous[position] ?? [:]
                    item["position"] = .number(Double(position)); item["matchedSongId"] = songID.map(NovaSyncValue.string) ?? .null
                    return .object(item)
                })
            }
            if let rules = playlist.smartRules {
                value["rules"] = .object(["source":.string(rules.source == .liked ? "liked" : "saved"), "artist":.string(rules.artists.joined(separator: ", ")), "artists":.array(rules.artists.map(NovaSyncValue.string)), "title":.string(rules.titleContains), "album":.string(rules.albumContains), "sort":.string(rules.sort == .newest ? "newest" : rules.sort == .title ? "title" : "artist"), "limit":rules.limit.map { .number(Double($0)) } ?? .null])
            } else { value.removeValue(forKey:"rules") }
            result["playlist:\(id)"] = .object(value)
        }
        for (order,folder) in store.musicFolders.enumerated() {
            let id = folder.id.uuidString.lowercased()
            var value = old["folder:\(id)"]?.object ?? [:]
            value["id"] = .string(id); value["name"] = .string(folder.name); value["order"] = .number(Double(order))
            value["items"] = .array(folder.albums.map { .object(["kind":.string("album"),"id":.string($0.id)]) } + folder.playlistIDs.map { .object(["kind":.string("playlist"),"id":.string($0.uuidString.lowercased())]) })
            value["pins"] = .array((folder.pinnedItemIDs ?? []).map { pin in .string(pin.hasPrefix("playlist:") ? pin.lowercased() : pin) })
            value["native"] = try .encoded(folder)
            result["folder:\(id)"] = .object(value)
        }
        for folder in store.artistFolders { result["artistFolder:\(folder.id.uuidString.lowercased())"] = try .encoded(folder) }
        for (artist, releases) in store.artistReleaseSelections { result["releases:\(artist)"] = .array(releases.map { .string($0.id) }) }
        for (artist, selections) in store.artistDiscSelections { for (album, discs) in selections {
            result["discs:\(album)"] = .array(discs.map { .number(Double($0)) })
            result["discArtist:\(album)"] = .string(artist)
        } }
        for (index, song) in store.musicHistory.enumerated() {
            result["recent:\(song.id)"] = old["recent:\(song.id)"] ?? .object(["id":.string(song.id),"at":.number(Date().timeIntervalSince1970 * 1000 - Double(index))])
        }
        if store.musicProfile != MusicAccountProfile() { result["profile:main"] = try .encoded(store.musicProfile.validated()) }
        result["preference:genres"] = .array(store.discoverGenres.map(NovaSyncValue.string))
        result.merge(old.filter { $0.key.hasPrefix("connect:") },uniquingKeysWith:{ _,new in new })
        return result
    }

    static func apply(_ values: [String: NovaSyncValue], to store: YouTubeStore) throws {
        func group(_ prefix: String) -> [NovaSyncValue] { values.filter { $0.key.hasPrefix(prefix + ":") }.sorted { $0.key < $1.key }.map(\.value) }
        func orderedIDs(_ prefix: String) -> [String] {
            group(prefix).sorted { ($0["order"]?.number ?? 0) < ($1["order"]?.number ?? 0) }.compactMap { $0["id"]?.string }
        }
        for prefix in ["liked","saved","savedAlbum","followedArtist","artistPin"] {
            for value in group(prefix) {
                guard let id = value["id"]?.string, NovaSyncDocument.validKey(prefix + ":" + id),
                      (prefix != "liked" && prefix != "saved") || YouTubeLink.validID(id) else { throw NovaSyncFailure.invalidDocument }
            }
        }
        var songs: [String: YouTubeVideo] = [:], albums: [String: YouTubeMusicAlbum] = [:], artists: [String: YouTubeChannel] = [:]
        for value in group("song") {
            guard let id = value["id"]?.string, YouTubeLink.validID(id), value["source"]?.string == "youtube",
                  let title = value["title"]?.string, let artist = value["artist"]?.string else { throw NovaSyncFailure.invalidDocument }
            var song = (try? value["native"]?.decoded(YouTubeVideo.self)) ?? .placeholder(id)
            song = YouTubeVideo(id:id,title:title,channel:artist,thumbnail:imageURL(value["artwork"]?.string),durationLabel:durationLabel(value["duration"]?.number ?? 0),views:song.views,published:song.published,channelID:value["artistId"]?.string ?? song.channelID,channelPath:song.channelPath,publishedAt:song.publishedAt,liveNow:song.liveNow,albumTitle:value["album"]?.string,albumID:value["albumId"]?.string ?? song.albumID,isClassical:song.isClassical,musicVideoType:song.musicVideoType,isExplicit:value["explicit"].flatMap { if case .bool(let flag) = $0 { return flag }; return nil },isPopular:song.isPopular,composer:song.composer,metadataSource:song.metadataSource,discNumber:value["discNumber"]?.safeInt ?? song.discNumber,trackNumber:song.trackNumber)
            songs[id] = song
        }
        for value in group("album") {
            guard let id = value["id"]?.string, let title = value["title"]?.string, let artist = value["artist"]?.string else { throw NovaSyncFailure.invalidDocument }
            albums[id] = YouTubeMusicAlbum(id:id,title:title,artist:artist,artwork:imageURL(value["artwork"]?.string),kind:value["kind"]?.string ?? "Album",year:value["year"]?.string,releaseDate:value["native"]?["releaseDate"]?.string)
        }
        for value in group("artist") {
            guard let id = value["id"]?.string, id.hasPrefix("UC"), let name = value["name"]?.string else { throw NovaSyncFailure.invalidDocument }
            artists[id] = YouTubeChannel(id:id,name:name,path:"/channel/\(id)",avatar:imageURL(value["artwork"]?.string))
        }
        var playlists: [YouTubePlaylist] = [], folders: [MusicLibraryFolder] = []
        for value in group("playlist").sorted(by: { ($0["order"]?.number ?? 0) < ($1["order"]?.number ?? 0) }) {
            guard let text = value["id"]?.string, let id = UUID(uuidString:text), let name = value["name"]?.string,
                  let songIDs = value["songs"]?.array, songIDs.allSatisfy({ $0.string != nil }) else { throw NovaSyncFailure.invalidDocument }
            var playlist = (try? value["native"]?.decoded(YouTubePlaylist.self)) ?? YouTubePlaylist(name:name)
            playlist.id = id; playlist.name = name; playlist.videos = songIDs.compactMap { $0.string }.map { songs[$0] ?? .placeholder($0) }
            let created = value["createdAt"]?.number ?? 0
            guard created >= 0, created < 8_640_000_000_000_000 else { throw NovaSyncFailure.invalidDocument }
            playlist.createdAt = Date(timeIntervalSince1970:created / 1000)
            playlist.sourceArtwork = imageURL(value["artwork"]?.string)
            if let unmatched = value["unmatched"]?.array {
                playlist.spotifyUnmatchedTracks = try unmatched.enumerated().map { index,item in
                    guard let title = item["title"]?.string, let artist = item["artist"]?.string else { throw NovaSyncFailure.invalidDocument }
                    let position = item["position"]?.safeInt ?? index
                    guard position >= 0 else { throw NovaSyncFailure.invalidDocument }
                    let uri = item["uri"]?.string ?? "", reason = item["reason"]?.string ?? ""
                    let track = SpotifyPlaylistTrack(uri:uri,title:title,artist:artist,duration:item["duration"]?.number,
                        isExplicit:item["explicit"].flatMap { if case .bool(let flag) = $0 { return flag }; return nil },album:item["album"]?.string,
                        isLocal:uri.hasPrefix("spotify:local:"))
                    let status = item["status"]?.string.flatMap(SpotifyPlaylistImporter.Match.Status.init(rawValue:)) ??
                        (reason.localizedCaseInsensitiveContains("fail") ? .searchFailed : reason.localizedCaseInsensitiveContains("local") || reason.localizedCaseInsensitiveContains("podcast") || reason.localizedCaseInsensitiveContains("unavailable") ? .unsupported : .notFound)
                    var entry = SpotifyUnmatchedTrack(position:position + 1,track:track,reason:status)
                    entry.id = item["id"]?.string.flatMap(UUID.init(uuidString:)) ?? playlist.spotifyUnmatchedTracks?.first(where: { $0.position == position + 1 && $0.track.uri == uri })?.id ?? entry.id
                    entry.isChecked = item["checked"] == .bool(true); entry.matchedSongID = item["matchedSongId"]?.string
                    entry.failureDetail = reason.isEmpty ? nil : reason
                    return entry
                }
            }
            if let imported = value["importEntries"]?.array, !imported.isEmpty {
                let positions = imported.compactMap { $0["position"]?.safeInt }
                guard positions.count == imported.count, positions.allSatisfy({ $0 >= 0 && $0 < imported.count }) else { throw NovaSyncFailure.invalidDocument }
                var ids = [String?](repeating:nil,count:(positions.max() ?? 0) + 1)
                for entry in imported { if let position = entry["position"]?.safeInt { ids[position] = entry["matchedSongId"]?.string } }
                playlist.spotifyImportSongIDs = ids
            }
            if let source = value["sourceUrl"]?.string, let url = URL(string:source), SpotifyPlaylistLink.accepts(url) { playlist.spotifySourceURL = url }
            if let rules = value["rules"]?.object {
                var smart = SmartPlaylistRules(); smart.source = rules["source"]?.string == "liked" ? .liked : .library
                smart.artists = rules["artists"]?.array?.compactMap(\.string) ?? (rules["artist"]?.string ?? "").split(separator:",").map { $0.trimmingCharacters(in:.whitespaces) }.filter { !$0.isEmpty }
                smart.titleContains = rules["title"]?.string ?? ""; smart.albumContains = rules["album"]?.string ?? ""
                smart.sort = rules["sort"]?.string == "title" ? .title : rules["sort"]?.string == "artist" ? .artist : .newest
                smart.limit = rules["limit"]?.safeInt.map { max(1,min(10000,$0)) }; playlist.smartRules = smart
            } else { playlist.smartRules = nil }
            playlists.append(playlist)
        }
        for value in group("folder").sorted(by: { ($0["order"]?.number ?? 0) < ($1["order"]?.number ?? 0) }) {
            guard let text = value["id"]?.string, let id = UUID(uuidString:text), let name = value["name"]?.string, let items = value["items"]?.array else { throw NovaSyncFailure.invalidDocument }
            var folder = (try? value["native"]?.decoded(MusicLibraryFolder.self)) ?? MusicLibraryFolder(name:name)
            folder.id = id; folder.name = name; folder.albums = []; folder.playlistIDs = []
            for item in items {
                guard let kind = item["kind"]?.string, let itemID = item["id"]?.string else { throw NovaSyncFailure.invalidDocument }
                if kind == "album" { guard let album = albums[itemID] else { throw NovaSyncFailure.invalidDocument }; folder.albums.append(album) }
                else if kind == "playlist" { guard let playlistID = UUID(uuidString:itemID) else { throw NovaSyncFailure.invalidDocument }; folder.playlistIDs.append(playlistID) }
                else { throw NovaSyncFailure.invalidDocument }
            }
            folder.pinnedItemIDs = value["pins"]?.array?.compactMap(\.string).map { pin in
                if pin.hasPrefix("playlist:"), let id = UUID(uuidString:String(pin.dropFirst(9))) { return "playlist:\(id.uuidString)" }; return pin
            }
            folders.append(folder)
        }
        let artistFolders = try group("artistFolder").map { try $0.decoded(MusicArtistFolder.self) }
        var releases: [String:[YouTubeMusicAlbum]] = [:], discs: [String:[String:[Int]]] = [:]
        for (key,value) in values where key.hasPrefix("releases:") {
            guard let ids = value.array, ids.allSatisfy({ $0.string != nil }) else { throw NovaSyncFailure.invalidDocument }
            let artist = String(key.dropFirst(9)); releases[artist] = ids.compactMap { $0.string }.compactMap { albums[$0] }
        }
        for (key,value) in values where key.hasPrefix("discs:") {
            let album = String(key.dropFirst(6))
            guard let selected = value.array, selected.allSatisfy({ ($0.safeInt ?? 0) > 0 && ($0.safeInt ?? 1000) < 1000 }) else { throw NovaSyncFailure.invalidDocument }
            let artist = values["discArtist:\(album)"]?.string ?? releases.first(where: { $0.value.contains(where: { $0.id == album }) })?.key
            if let artist { discs[artist,default:[:]][album] = selected.compactMap(\.safeInt) }
        }
        let profile = try values["profile:main"].map { try $0.decoded(MusicAccountProfile.self).validated() } ?? MusicAccountProfile()
        // Validate and decode every supported collection before changing any live state.
        store.musicProfile = profile
        store.defaults.set(try JSONEncoder().encode(profile),forKey:"music.account.profile")
        store.likedSongs = orderedIDs("liked").map { songs[$0] ?? .placeholder($0) }
        store.saved = orderedIDs("saved").map { songs[$0] ?? .placeholder($0) }
        store.likedAlbums = orderedIDs("savedAlbum").compactMap { albums[$0] }
        store.followedArtists = orderedIDs("followedArtist").compactMap { artists[$0] }
        store.playlists = playlists; store.musicFolders = folders; store.artistFolders = artistFolders
        store.artistReleaseSelections = releases; store.artistDiscSelections = discs
        store.musicHistory = group("recent").sorted { ($0["at"]?.number ?? 0) > ($1["at"]?.number ?? 0) }.prefix(100).compactMap { $0["id"]?.string }.compactMap { songs[$0] }
        if let genres = values["preference:genres"]?.array { store.discoverGenres = genres.compactMap(\.string) }
        store.defaults.set(orderedIDs("artistPin"),forKey:"music.pinnedArtists")
        store.defaults.set(orderedIDs("followedArtist"),forKey:"music.artistOrder")
        for (key,value) in [("youtube.likedSongs",try JSONEncoder().encode(store.likedSongs)),("music.savedTracks",try JSONEncoder().encode(store.saved)),("youtube.likedAlbums",try JSONEncoder().encode(store.likedAlbums)),("youtube.followedArtists",try JSONEncoder().encode(store.followedArtists)),("youtube.musicHistory",try JSONEncoder().encode(store.musicHistory)),("music.artistReleaseSelections",try JSONEncoder().encode(releases)),("music.artistDiscSelections",try JSONEncoder().encode(discs))] { store.defaults.set(value,forKey:key) }
        store.defaults.set(store.saved.map(\.id),forKey:"youtube.savedIDs")
        store.defaults.set(store.discoverGenres,forKey:"music.discoverGenres")
        store.persistPlaylists(); store.persistMusicFolders(); store.persistArtistFolders()
    }
    private static func seconds(_ label: String?) -> Double { (label ?? "").split(separator:":").reduce(0) { $0 * 60 + (Double($1) ?? 0) } }
    private static func durationLabel(_ seconds: Double) -> String? { guard seconds.isFinite, seconds > 0, seconds < 604800 else { return nil }; return "\(Int(seconds)/60):\(String(format:"%02d",Int(seconds)%60))" }
    private static func imageURL(_ text: String?) -> URL? { guard let text, let url = URL(string:text), url.scheme == "https" else { return nil }; return url }
}
