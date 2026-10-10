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
