> **iCloud migration (October 18, 2026):** Current sources default to private CloudKit library sync. Native iPhone and website/Mac sources restore device discovery, remote playback controls, queue sharing, handoff and lyrics mirroring. Watch library sync uses the same private iCloud library; Watch-to-phone controls continue through WatchConnectivity. Imported audio remains local. Apple container/profile setup and production schema deployment are required before live iCloud testing or release. The public website has not been deployed by this change. See `outputs/nova-music-icloud-sync/README.md` at the workspace root. Older provider notes below are historical.

# Nova Music for Apple Watch

Open `NovaMusic.xcodeproj` and select **NovaMusicWatch**. The independent app targets watchOS 26+, embeds a Siri media extension and a WidgetKit extension, and is also embedded in the iPhone app. It can launch, browse, search, edit its library, and play without the iPhone app installed.

## Interaction

Music is a native hierarchical menu. An active session opens Now Playing when the app returns from the background; closing the player preserves the browsing stack. Now Playing has Lyrics, full Artwork, Controls, and Playing Next pages. The complete artwork fits on screen without cropping; tap it to hide or restore the transport overlay. Large text opens the scrollable Controls page. The Crown controls system volume on the player and time only inside the explicit Seek screen. Collection artwork uses native zoom transitions. Playing indicators stop when paused, inactive, dimmed, or Reduce Motion is enabled.

Watch library editing includes regular and smart playlists, song ordering, folders and pins, artist folders and ordering, release/disc selection, photo/icon/collage artwork, Spotify import and manual pairing, genres and decades, Classical works and recordings, and lyric calibration. Selection uses explicit controls suited to the Watch.

Starting playback on iPhone selects the phone player when watchOS delivers its companion Now Playing launch callback. Enable Auto-Launch Audio Apps in the Watch system settings; Nova Music cannot override that preference. Opening the app also recognizes a fresh phone playback snapshot without repeatedly interrupting browsing. The app icon is packaged in the Watch asset catalog.

Phone playback includes available synchronized lyrics, calibration-aware seeking, current-song likes and song information. Queue snapshots carry the current song and up to 30 upcoming songs, with absolute positions and a total count, instead of repeatedly sending an entire library-sized queue. Folder pages offer list/gallery layouts, cover art and a folder badge, pinning, replacement in place, and position selection. Online replacement playlists can belong only to a folder.

**Apple Watch** is the default playback device. Selecting **iPhone** changes the player being controlled; it does not automatically move or start audio. Phone commands require reachability, carry receipts and queue revisions, and reject expired or stale edits. Larger messages transfer in bounded chunks and execute only when assembled completely.

## Shared music code

`Shared/NovaMusicCore` contains the extracted models, catalog/parser/search behavior, queue entry identity, lyrics, Classical data, Spotify matching, artwork processing and Siri resolver/vocabulary. Existing library operations remain source-shared with the iPhone store. The core is compiled into each executable target rather than exported as a separate public Swift framework; this preserves existing internal symbols and test access. `MusicCatalogAccess`, `MusicStreamResolving`, `MusicPlaybackControlling`, and `MusicLibraryPersisting` define the service boundaries.

Watch owns its AVQueuePlayer, audio session, local persistence, downloads and account connection. GitHub sync reuses `NovaSyncDocument` and `MusicAccountLibrary`, including record clocks, tombstones and artwork. The existing file format is unchanged. Tokens stay in the Watch Keychain. Account setup and sync never gate playback. No new hosted service is required.

## Streaming and downloads

watchOS lacks the iPhone player's AVAssetResourceLoader API. Watch playback therefore prefers direct audio HLS. Progressive AAC sources that need the provider's range parameter are staged into temporary local playback files before native playback; those sources may take longer to start. Temporary playback files are not presented as downloaded music. The current and next tracks are retained while older temporary playback files are removed.

Persistent downloads use background URLSession transfers for AAC and AVAssetDownloadURLSession for HLS. Wi-Fi is the default; cellular is opt-in. A successful native transfer, expected length when supplied, and local AVFoundation validation are required before showing Downloaded. Interrupted validation is retried on launch. Downloaded artwork and available lyrics are cached separately. Offline Only never falls back to streaming an unavailable recording. Cached collection metadata supports offline browsing and Siri.

The provider may reject requests or omit a compatible source; those recordings show a retryable error. Catalog availability and live Siri recognition are not guaranteed by simulator tests. Audio output selection follows watchOS: session activation can present the system output chooser; an existing connection can be changed in Control Center.

## Signing and configuration

Use one signing team for the app, Siri extension, widget extension and iPhone app. The Watch targets require the `group.com.example.NovaMusic.watch` App Group. Enable Siri on the Watch application. Provision the extensions for their group, and keep the Watch app's companion identifier aligned with the iPhone app identifier.

Spotify uses the existing `NovaMusic/SpotifyConfiguration.xcconfig` public client ID and HTTPS redirect. Register the redirect with Spotify and authorize the callback domain for the Watch app as required by Authentication Services. Blank configuration is explained in the import screen; incomplete public previews cannot be imported as complete playlists.

GitHub setup accepts an existing active private repository and a fine-grained token with Contents read/write. Disconnecting keeps the local library.

`scripts/configure-watch.rb` maintains source memberships, target dependencies, embedding and the shared Watch scheme using the installed `xcodeproj` Ruby library. It is not required to open or build the checked-in project.

## Verification

Select the **NovaMusicWatch** scheme to run Watch unit/UI tests. Run UI tests on both the 40 mm SE and 49 mm Ultra. Tests use a separate library domain. The player layout fixture is enabled only by an explicit debug preview launch argument; it does not play audio or seed production libraries.

Device release checks still require valid signing, real audio output, Siri voice routing, background/airplane-mode downloads, Spotify sign-in, and a paired iPhone for live remote controls. See `outputs/nova-watch/VALIDATION.md` for the checks performed and current limitations.
