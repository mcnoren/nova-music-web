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
