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

The Mac output has its own stable device identity. Sign into the same Nova Music account on Mac and phone, then choose **Mac · Nova Music** in Output Location. Responsive outputs confirm their paused clock before the new output starts. If an output has closed, explicitly choosing another device recovers from the last confirmed position.

## Validation (2026-10-09)

- Universal Mac app built and locally signature verified; launched on the user's Mac. Live YouTube Music search and playback succeeded with content rules installed. Native Command–L opened full-screen lyrics, timed highlighting followed playback, and Pause/Close returned to the shared interface.
- 71 website tests pass, including delayed song starts at zero, confirmed handoff positions, queue duplicates/order/modes, timeout without estimating a position, and cancellation when another device selects a newer song.
- Ten native connection/account tests pass, including a four-second-old new-song command with an additional 600 ms stream-loading delay starting at zero. The freeze check also verifies that projected UI progress cannot move the actual audio clock. Updated signed iPhone app installed on the paired iPhone.
- Website deployment verified against the generated app version at the public Pages URL.

Handoffs deliberately allow a brief loading pause while the destination prepares. They never advance the destination's requested position to compensate for network or preparation time.

## Audio stability update (2026-10-10)

Remote pause/resume and queue/mode changes now carry `positionIntent: preserve`. Previously every remote change sought the output to a controller's projected position, introducing jumps or rebuffering even when the user had not sought. Only explicit seeks and track selections reposition an already loaded recording. Initial loads and handoffs still use their exact requested position. The optional field remains compatible with older clients; update the phone app to send the new intent.

The native Mac bridge now holds one `userInitiatedAllowingIdleSystemSleep` activity while this Mac is audibly playing. It releases on pause, remote output ownership, navigation, web-process termination, and application termination. This keeps background playback work responsive without disabling system sleep globally. Ad filtering is unchanged.

Validation: 80 website tests, seven native playback tests (including the actual AVPlayer clock remaining at nine seconds when a controller sends a stale four-second transport position), and the Mac activity lifecycle test pass. Both Mac architectures build. Remote transport is covered by automated engine and account tests. The installed 1.0.1 app has a verified signature. After the user approved its macOS Keychain prompt, the account and library restored successfully. Live Mac verification confirmed that pause held the actual position at 38.0 seconds and resume continued at 38.2 seconds. After hiding/minimizing the app, playback progress advanced from 54.1 to 86.1 seconds; restoring the window showed continued playback. The output selector marked This Mac as Selected. Playback was left paused after verification. These checks observe player state and timing; system audio was not directly monitored.

Keychain reads and writes use a serial background queue. macOS credential-access prompts can no longer block the app main thread or prevent its window from opening. The credential item and access permissions are unchanged.

## Native audio update (2026-10-10)

The earlier web-player fixes did not resolve the user's audible glitches, including on built-in speakers. Instrumentation observed the embedded player advancing at 1.000× without repeated seeks, so progress-bar movement was insufficient evidence of audio quality. Mac 1.0.2 replaces audible YouTube iframe playback with AVPlayer; the shared website remains the interface and connected-device controller. The audible player is independent of WebKit layout, rendering, frame timers, and the visibility of the lyrics or queue panel.

The native path uses the iPhone player's public stream resolver and bounded media-range loading approach, preferring audio-only MP4 when available. The fallback web resolver is muted before any media can play, runs with the shared ad filter, and is discarded after resolving. Only AVPlayer produces the music output. It plays at normal rate, buffers ahead, and publishes its actual clock to the website and connected-device telemetry. No drift correction seeks or catch-up rate changes are used. New loads and explicit seeks await exact-position completion; pause acknowledges the stopped native clock. Generation tokens reject stale recording commands and samples. Native Now Playing and keyboard media controls use the same audio owner.

Settings → Playback status reports the actual engine, speed, measured clock, buffering events, and seek/load counts. Its bounded, in-memory history contains no audio or credentials.

Validation: 89 website/bridge tests pass. Six native checks pass against a real AVPlayer and a local WAV fixture: exact paused load, steady 1× clock over five seconds, preserved pause/control positions, exact explicit seek, rejection of stale commands, and preference for audio-only streams. The universal 1.0.2 app builds and its installed signature verifies. Live installed-app stream playback is checked separately below.
