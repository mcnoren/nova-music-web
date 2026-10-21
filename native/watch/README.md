# Apple Watch integration — October 21, 2026

These are the Watch app, Siri/widget extensions, and tests from the full Nova Music Xcode workspace. They depend on the existing shared NovaMusicCore and native store sources and are not a standalone Xcode project. No target membership changes were necessary in the full workspace.

For a full project with the existing Watch implementation, apply `../patches/watch-experience.patch` from that project’s root. Copy `NovaMusicWatch/Assets.xcassets/AppIcon.appiconset/AppIcon.png` to the corresponding Watch asset folder (the patch contains the catalog metadata, but not this binary image). Copy the tests into their existing Watch/iPhone test targets. Alternatively, replace the matching Watch folders and `Shared/NovaMusicCore/MusicWatchConnectivity.swift` with these sources and `../MusicWatchConnectivity.swift`.

The changes add a complete-artwork player, tap-to-hide controls, large-text controls, native companion Now Playing launch, a packaged Watch icon, phone lyrics and song information, richer folder organization, and bounded phone queue snapshots. Existing independent streaming/downloads, search, playlists, smart playlists, Spotify import, Classical, Siri and widgets are retained.

Rebuild and install both the iPhone and Watch apps. Automatic presentation follows the user’s Watch Auto-Launch Audio Apps preference and requires live paired-device validation. The simulator verifies the launch callback and navigation, not delivery of the OS callback from a locked physical iPhone. Provider availability, Bluetooth audio, background downloads, Siri and sign-in also need device release checks.

Validation: 14 Watch unit tests, six iPhone WatchConnectivity tests, and five UI tests on each of the 40 mm SE and 49 mm Ultra simulators passed. Screenshots were inspected for full artwork and transport placement. The integration patch was applied to a clean copy of the previous sources and compared with the updated workspace. Unsigned generic Watch and iPhone simulator builds also passed.

## Startup crash with a spinning app icon (October 21, 2026)

The physical Watch debugger caught SIGABRT in `MusicAccountSync.save()`: the cloud library snapshot exceeded watchOS's 1 MB CFPreferences limit. Bulk library records now use atomic files in the shared app-group container. Existing preference records migrate before their old copies are removed; small settings and the widget snapshot remain in preferences. Collection caches, playback state, catalog caches, and cloud snapshots use the same file-backed data access.

Apply `../patches/watch-library-storage.patch` after `watch-experience.patch`, or copy the updated Watch sources. Rebuild the Watch app and its extensions. There are no new project memberships or account/library resets.

Validation: 17 Watch unit tests passed, including a >1 MB cloud startup snapshot, a >1 MB playlist surviving store relaunch, and migration/replacement/removal of old preference records. The signed Watch build was installed and cold-launched on the paired Series 8 running watchOS 26.6. The shared container contained 16 library record files, with the largest 1,555,055 bytes; the main app remained running and the screen displayed the current phone song’s artwork without the startup spinner. This verifies startup and live phone state, not every independent audio/download feature.
