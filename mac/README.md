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

The native path uses the iPhone player's public stream resolver and a compatible full-length MP4 stream, with AVFoundation handling HTTPS transport and byte ranges directly. Service responses must identify the requested recording; the silent web fallback also verifies the recording before accepting a stream. The fallback web resolver is muted before any media can play, runs with the shared ad filter, and is discarded after resolving. Only AVPlayer produces the music output. It plays at normal rate, buffers ahead, and publishes its actual clock to the website and connected-device telemetry. No drift correction seeks or catch-up rate changes are used. New loads and explicit seeks await exact-position completion; pause acknowledges the stopped native clock. Generation tokens reject stale recording commands and samples. Native Now Playing and keyboard media controls use the same audio owner.

Settings → Playback status reports the actual engine, speed, measured clock, buffering events, and seek/load counts. Its bounded, in-memory history contains no audio or credentials.

The initial 1.0.2 ten-second network check did not expose a later buffering failure. After the user cleared the Keychain prompt, live interface verification showed native playback stalling around one minute. Longer network tests reproduced HTTP 403 responses beyond the beginning of the adaptive audio rendition. Smaller custom ranges did not make the rest of that rendition accessible, and the custom loader could not prepare compatible progressive MP4 on macOS. Version 1.0.3 removes that loader and adaptive-rendition preference; native HTTPS playback of the compatible progressive recording passes the earlier failure point. No synchronization seeks or rate correction were added.

Validation: 89 website/bridge tests and eight native checks pass. Native checks cover exact paused load, steady 1× playback, preserved pause/control positions, exact explicit seek, rejection of stale commands, compatible stream selection, rejection of a mismatched recording response, and acceptance of a verified response. A real streamed recording loaded paused at exactly 110 seconds, played ten seconds at 1.000003×, held its position while paused, and sought back to zero. Two real network recordings then completed, including the affected all-american bitch video (165.916 seconds) and a second video (248.665 seconds), with native end-of-song delivery. Ten-second samples throughout both runs stayed within 0.000003× of normal speed; their overall measured speeds were 1.000001×. The universal 1.0.3 application was installed and its signature verifies. Installed-interface verification remains pending: the reopened app stays at its opening screen, and the user has been asked to check for another protected macOS Keychain prompt after the signature changed. These checks measure the native playback clock; system audio was not directly monitored.

## Faster playback and confirmed output selection (1.0.4)

The running project build was still version 1.0.2, using the stream loader that stalled near one minute; the separate Applications copy was 1.0.3. Both copies are now rebuilt and installed as 1.0.4 with native HTTPS progressive playback. Clicked recordings resolve while account delivery runs, repeated lookups share a short-lived cache, and the next queued recording is prepared in advance without starting audio. Native forward buffering is three seconds.

Connected clients check active playback and available peer devices every 750 ms. Transferring from the current output freezes its actual clock directly, avoiding a round trip to itself. Output selection shows a spinner immediately and waits for the destination's matching, ready playback status before showing its checkmark. Failures clear the pending selection and report an error.

Validation: 98 website tests, nine Mac engine/cache checks, and 15 phone account/connection tests pass. A real network recording prepared in 1.07 seconds and advanced past the reported cutoff to 90.75 seconds at normal rate (0.999× overall measured clock speed). These checks measure the player clock, not system audio. Both universal Mac copies have verified signatures. The signed phone build was installed on the paired iPhone. The updated Mac app opened and restored its signed-in account and library.
