# Nova Music for Mac

A native AppKit application with the same interface as the hosted Nova Music website. WebKit loads the shared interface, so website updates also reach the Mac app. Music and account sync require an internet connection. macOS 14 or later; universal Apple Silicon / Intel executable.

## Build and install

With Xcode installed:

```sh
python3 mac/build.py --install
```

The build is locally signed and installed at `~/Applications/Nova Music.app`. Build without `--install` to leave the app in `mac/build/`. Public distribution would require Developer ID signing and notarization.

## Native integration

- Installs `HDYouTubeAdFilter` content rules before loading the website, and injects its document-start response filter into YouTube frames. This is the same policy used by the iPhone HD player; media segment hosts are not blocked. Keep `Sources/HDYouTubeAdFilter.swift` identical to `Shared/HDYouTubeAdFilter.swift` in the iOS workspace. Provider changes may require updating the shared filter.
- Account sessions are saved in this app's Keychain item. No browser credentials are imported. Sign-out clears the item and the restore script. Bridge messages are accepted only from the main frame at the Nova Music website's HTTPS origin and path.
- Native View menu: Home (Command–1), Search (Command–F), Full Screen Lyrics (Command–L), Output Location (Command–D), Reload (Command–R).
- Full-screen lyrics enters the native window's full-screen mode and returns to its previous mode when closed. Playback continues in the selected output.
- Native file picker supports music, playlist, and profile imports. External links open in the default browser.

The Mac output has its own stable device identity. Sign into the same Nova Music account on Mac and phone, then choose **Mac · Nova Music** in Output Location. Handoffs require the current output to confirm its paused clock before the new output starts.

## Validation (2026-10-09)

- Universal Mac app built and locally signature verified; launched on the user's Mac. Live YouTube Music search and playback succeeded with content rules installed. Native Command–L opened full-screen lyrics, timed highlighting followed playback, and Pause/Close returned to the shared interface.
- 71 website tests pass, including delayed song starts at zero, confirmed handoff positions, queue duplicates/order/modes, timeout without estimating a position, and cancellation when another device selects a newer song.
- Ten native connection/account tests pass, including a four-second-old new-song command with an additional 600 ms stream-loading delay starting at zero. The freeze check also verifies that projected UI progress cannot move the actual audio clock. Updated signed iPhone app installed on the paired iPhone.
- Website deployment verified against the generated app version at the public Pages URL.

Handoffs deliberately allow a brief loading pause while the destination prepares. They never advance the destination's requested position to compensate for network or preparation time.
