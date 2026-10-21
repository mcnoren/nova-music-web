# Watch startup crash fix (October 21, 2026)

A real Watch crash exposed the 1 MB watchOS preference limit during iCloud library sync. Watch bulk data now persists in atomic app-group files and migrates existing saved records. Apply `patches/watch-library-storage.patch` after the Watch experience update, or copy the refreshed Watch sources. Seventeen Watch unit tests passed, including migration, a large playlist reopening, and a cloud snapshot over 1 MB.

# Apple Watch experience (October 21, 2026)

The Watch app now presents complete cover artwork with controls that hide on tap, includes the app icon, and handles Apple’s companion Now Playing launch to select iPhone playback. Phone lyrics, calibrated seeking, song information, bounded queue updates, and richer folder list/gallery/replacement controls are included. Large text uses the scrollable transport screen.

See [Watch integration](watch/README.md) for source, patch, tests and installation instructions. This repository publishes native integration source; both native apps must be rebuilt and installed. Automatic opening honors the Watch’s Auto-Launch Audio Apps system setting. Real paired-device audio/launch verification remains required.

# Song backgrounds and background CPU fix (October 21, 2026)

Apply `patches/song-info-and-background-cpu.patch` after the prior native integrations, and copy the updated `MusicAccountSync.swift` adapter into the full app. Add `BackgroundCPUAndSongInfoTests.swift` and `PlaybackSyncEfficiencyTests.swift` to its test target. The local full Xcode project already contains these changes.

A physical iPhone 12 diagnostic reported that iOS killed Nova Music for excessive background CPU: 48 CPU seconds over approximately 56 seconds, an 85% average. This explains audio stopping with an empty Now Playing display. The playback watchdog repeatedly assigned identical published loading/startup states every 250 ms. Device sync observed those assignments and repeatedly encoded playback status and the library. The fix publishes those states only when changed, deduplicates sync subscriptions, keeps ephemeral iCloud/LAN connection status out of the library disk cache, and removes library recapture triggered by unrelated UserDefaults checkpoint/cache writes. Background UI clock updates are limited to approximately one per second; native audio and queue timing continue independently. See [Apple's background CPU guidance](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/EnergyGuide-iOS/WorkLessInTheBackground.html).

Song Info on iPhone/iPad and the shared Mac/web interface now retrieves detailed, attributed Wikipedia prose beyond the lead paragraph. The lookup verifies the song title, performer, subject and source, tries search when title lookup fails, caches results, omits chart/reference tables and formula-heavy sections, and handles unavailable articles with Retry and a web-search link. It does not generate facts or substitute an unrelated artist biography. Article availability varies by recording. Uploaded local audio sends only its displayed title/artist for the requested lookup.

Validation: 184 web tests and the complete 19-test selected native run passed, including the full iCloud suite and one minute of continuous native playback. During that minute there were zero repeated loading/startup publications and 58 background UI clock updates. Four additional native regression cases and the Song Info rendering case reported passing; their Xcode runners stalled during teardown. iPhone and web screenshots were inspected, and a live lookup returned the detailed Creep/Radiohead article. Signed iPhone and Mac builds succeeded. These checks do not establish a physical lock-screen endurance result; install the rebuilt iPhone app and verify playback with the phone locked.

# Lock-screen buffering recovery (October 21, 2026)

Apply `patches/lock-screen-buffering.patch` after `background-playback.patch` in the full Xcode project, and add `LockScreenPlaybackTests.swift` to the test target. The local full project already contains the fix. Installed iPhone apps require a new signed build.

A stream that stalls after playback has started now acquires a finite background assertion immediately on the native stall/waiting signal or a stopped audio clock. The assertion ends when the clock advances or the user pauses. Background recovery reconnects the same recording at its current position after five seconds of no progress, instead of waiting for the foreground 25-second timeout. Current-item identity and playback intent guard stale notifications. The background-task expiration handler now ends its assertion synchronously before returning, as required by [UIKit's expiration handling](https://developer.apple.com/documentation/uikit/uiapplication/beginbackgroundtask(expirationhandler:)).

Seven distinct focused simulator tests passed on iPhone SE (3rd generation), iOS 18.6: real HTTP audio buffer exhaustion and same-song recovery, assertion cleanup after progress/Pause, stale-item notifications, 32-second continuous background playback, native-audio retry, prepared queue advancement and interruption handling. The HTTP regression withholds the remaining audio bytes after initial playback starts; recovery resumed from the stalled position in approximately 5.6 seconds after waiting began. This exercises real AVFoundation network buffering, but simulator background requests do not reproduce physical iOS lock-screen suspension. The user's reported roughly 30-second cutoff still needs confirmation on the rebuilt signed iPhone app.

# iPhone performance (October 21, 2026)

Apply `patches/iphone-performance.patch` after the folder-redesign and background-playback integrations in the full Xcode project. Add `NativePerformanceTests.swift` to its test target. The local full project already contains these changes; do not apply the patch there again.

Embedded song tables now render only a viewport plus a small overscan region, while the containing SwiftUI scroll view keeps the full list height. This preserves native selection, direct dragging and edge scrolling without mounting every song's artwork and subscriptions. Section indexes are built once per content change, selection updates touch changed rows, folder/queue collection updates refresh mounted cells with constant-time item lookup, and drag display links are invalidated on removal. Custom folder/playlist photos use display-sized decoded thumbnails in a 16 MB NSCache.

Playback saves debounce structural queue changes. A five-second progress checkpoint stores only the current song identity, position and duration instead of re-encoding the entire queue every second. Backgrounding and playback state changes still save the complete session, and restoration rejects checkpoints from another song. Foreground animation cadence and the native gapless playback path are unchanged.

Validation: 13 distinct focused simulator tests passed on the iPhone SE (3rd generation), iOS 18.6, including 32-second background playback, prepared queue advancement, session restoration, selection/gesture ownership, gallery/list rendering and drag cleanup. With 2,000 items, the song table mounted 13 rows and a folder refresh configured six visible rows. The test queue snapshot was 313,897 bytes; its progress checkpoint was 54 bytes. Cover-cache tests confirmed decoded 120-pixel requests stay within 128 pixels and reuse the decoded image. These are simulator regression results, not physical-device frame-rate or battery measurements. The installed iPhone app requires rebuilding and a signed-device check.

# iPhone background playback (October 20, 2026)

Apply `patches/background-playback.patch` to the full Xcode project. Prepared music items now advance through AVQueuePlayer instead of pausing until Nova's end notification runs. Outgoing recording identities remain available so truncated streams reconnect the original song even after native advancement. Explicit skips, queue edits and cancellation discard stale transitions. Native audio remains the first retry path in the background; a suspended WebKit resolver is never required there. Startup/reconnection background grants last until an advancing audio clock is observed, and stale grant expirations cannot cancel a newer connection.

Add `BackgroundPlaybackTests.swift` to the native test target. Seven focused simulator regressions passed, covering 32 seconds of continuous playback and pause, native-audio retry, delayed queue-event delivery, legitimate completion, premature endings before/after native advancement, and official-audio selection for the prepared next song. This validates the native playback paths in the simulator; a signed iPhone build and a physical lock-screen/background check are still required. This repository publishes the integration source, not an installed iPhone update.

# Folder redesign and direct reordering (October 20, 2026)

The iPhone/iPad folder screen now has compact controls, single-line collection titles, actual album/playlist artwork, folder badges, no type filter and no arrangement mode. A shared native UICollectionView handles long-press drag previews, insertion gaps, drops and edge scrolling in folder list/gallery views, the queue, playlist song management and layout ordering. Editable playlist pages also support direct song dragging with the existing selection table and continuous scrolling of its containing view. The genre list no longer needs an Edit button.

The Mac/web interface uses the same long-press gesture in folders, editable playlists, artist lists and the queue. Loaded pages update in place, preserving image elements and focus rather than showing an intermediate loading screen. The sidebar has separate labeled sections, independent Show more controls, visible pins and folder badges over custom covers. Playback resolves official audio even when incoming metadata has no video type, on both web and Mac, and prepares that edition for the next native queued song. Album/live/remix distinctions remain protected.

For a full app that already contains the previous folder and playlist-membership integrations, apply `patches/folder-redesign.patch` from the Xcode project root. Add `FolderRedesignTests.swift` to the test target. The refreshed `folder-ui.patch` contains the complete folder views for integrations from the original baseline; do not apply it on top of `folder-redesign.patch`. When integrating from that original baseline, apply `folder-ui.patch` and `playlist-membership.patch`, then apply only the `MusicLibrarySelection.swift`, `YouTubeView.swift`, and `MusicCatalog.swift` portions of `folder-redesign.patch`.

Validation: 178 web tests, browser DOM preservation checks, four focused iPhone tests, the iPad folder rendering/drag configuration test, and the Mac build. Native simulator tests require live iCloud bootstrap disabled when code signing is off. Source is published here; installed native apps require rebuilding with the full Xcode project.

# Playlist library membership and smooth folder dragging (October 20, 2026)

Removing a playlist from the library now preserves its identity, songs, artwork, folder slots and folder pins whenever a folder still references it. Folder-only playlists can be added back to the library. The shared Mac/web interface animates a lifted drag preview, live insertion slots, neighboring cards and the final drop, with edge scrolling, Escape cancellation and reduced-motion support.

For the full iPhone project, apply `patches/playlist-membership.patch` after the existing folder UI integration; use the refreshed `patches/folder-ui.patch` when integrating those views from scratch. Copy the updated `MusicAccountLibrary.swift` adapter and add `PlaylistMembershipTests.swift` to the test target. The optional native `folderOnly` field reads existing libraries without migration and synchronizes with Mac/web membership.

# Folder cover art (October 20, 2026)

Mac and web folders support uploaded photos, album-cover collages, icons, and removing custom art. Open a folder and click its cover or choose **Folder settings → Edit cover art**. The selected image appears in the folder header, Home, and sidebar.

The MusicAccount library adapter now exports folder `collectionArtwork` using the same portable image-byte format as playlists. It imports photos into native artwork files, preserving compatibility with the iPhone's existing folder artwork editor. `FolderArtworkTests.swift` covers photo transfer, icon changes, and removal.

# Folder and output updates (October 20, 2026)

The full iPhone Xcode project lives beside this repository. Apply `patches/folder-ui.patch` from that project's root (`git apply /path/to/nova-music-web/native/patches/folder-ui.patch`) to update `NovaBrowser/MusicLibraryOrganization.swift` and `NovaBrowser/MusicLibraryViews.swift`. Copy the updated MusicAccount integration files from this directory into the corresponding app target. Add `FolderOrganizationTests.swift` to its test target.

Folders now support mixed-item drag ordering, gallery/list views, and replacement sheets that preserve the item's slot and pin. The MusicAccount adapters preserve this order and view through native/web sync. The output button uses device/route icons and green for remote output.

The shared web and Mac interface contains the corresponding folder controls. The Mac engine queues the next AVPlayerItem before the current track ends. Browser handoff and guaranteed gapless browser playback remain open: the browser cannot use the native LAN transport. Website CloudKit authentication also requires a working container API token.

Browser library and imported-audio data now stay in tab memory until cloud sync. Unsynced browser changes and imported audio are lost when the tab closes. Existing browser library data is read for migration and is not deleted.

Validation: 159 web tests, three focused iOS tests (including folder serialization), and iOS/Mac builds passed. A native AVFoundation test confirmed advancement to a prepared next item without a page load command.

---

> **Local-network Now Playing (October 18, 2026):** Phone and native Mac playback controls, song/queue state, seeks, shared lyrics and display-opening requests now travel directly over persistent encrypted TCP connections discovered with Bonjour on the same Wi-Fi/local network. The playback path no longer reads or writes the private CloudKit connection record. iCloud remains responsible for the library and for provisioning a random private device-trust key once; cached trust restores local connectivity without waiting for iCloud. Allow Local Network access on both apps. The phone full-screen player uses the same Output Location selector as Home, with AirPlay/Bluetooth available inside it. Earlier iCloud playback notes below are historical.

# Nova Music iCloud integration

The current native app defaults to iCloud. Include `MusicLocalPlayback.swift` and `NovaCloudLibrary.swift` alongside `MusicAccountSync.swift`, `MusicAccountSyncCore.swift`, and `MusicAccountLibrary.swift`. All participating native apps must be provisioned for the same `iCloud.com.example.NovaMusic` CloudKit container.

Library metadata, custom artwork, profiles and collection positions use the private `nova-library` record. Device presence, playback commands, queue state and shared lyrics use the separate private `nova-connection` record. Both use the `NovaDocument` record type with a `document` Asset field. Local playback never waits for cloud sync. Imported audio stays local. Remote playback requires both apps to be running and may take a few seconds. Transfers require a matching clock acknowledgement from the previous reachable output.

See `../../outputs/nova-music-icloud-sync/README.md` for provisioning and release steps. Legacy GitHub and Supabase implementations remain for migration/reference and tests; they are not the app default.

## Historical GitHub integration notes

# Nova Music native GitHub library integration

The helper now defaults to private GitHub repository library sync. Add the MusicAccount*.swift files to the NovaMusic target, retain YouTubeStore.musicAccount and its bootstrap task, and show MusicAccountSyncSection in Account/Settings. It uses existing app models and the system AirPlay picker; these are integration helpers, not a standalone app.

No Supabase project configuration is required by the default provider. Open Account, create a private repository and a fine-grained token restricted to it with Contents: Read and write, and enter owner/repository plus the token. Keep Add this device’s library enabled to merge existing music. Tokens stay in device Keychain; library metadata/custom artwork goes to nova-library.json. Imported audio stays local. Disconnect preserves current music and cached unsent edits. GitHub library sync never routes Play through the network. Live device controls and presence polling are disabled. The retired provider remains for compatibility tests only.

The parent Nova Music app additionally has bounded native playback-stall recovery in YouTubePlayer.swift. Existing applications must update their player separately to get that behavior. The website uses docs/github-sync-client.js with the same library record format.
