> **Local-network Now Playing (October 18, 2026):** Phone and native Mac playback controls, song/queue state, seeks, shared lyrics and display-opening requests now travel directly over persistent encrypted TCP connections discovered with Bonjour on the same Wi-Fi/local network. The playback path no longer reads or writes the private CloudKit connection record. iCloud remains responsible for the library and for provisioning a random private device-trust key once; cached trust restores local connectivity without waiting for iCloud. Allow Local Network access on both apps. The phone full-screen player uses the same Output Location selector as Home, with AirPlay/Bluetooth available inside it. Earlier iCloud playback notes below are historical.

> **Connected playback update (October 18, 2026):** Song, queue and transport changes and completed seeks now publish immediately; playback ticks use the existing heartbeat. Phone and Mac share one audio output and both can control it. A paused session without activity for 90 seconds no longer keeps a different device selected. A live output with fresh playing telemetry stays selected. Changes made during a CloudKit asset write are drained in the same exchange. Cloud delivery still depends on iCloud and network latency.

The iPhone **Output location → Lyrics on Mac** section offers **Show lyrics on Mac · Nova Music** for updated online Macs. This sends a separate display request and does not transfer audio. The Mac acknowledges the request, brings its window forward, and opens native full-screen lyrics. Requests expire after one minute and are consumed once, so reconnecting does not unexpectedly reopen an old request. Close the Mac window to leave Nova Music in the background; its menu-bar icon can reopen the window or lyrics. **Quit** stops the listener, and a sleeping Mac must be awakened first.

> **Verified working standalone build (October 18, 2026):** `~/Applications/Nova Music iCloud.app` is developer-signed, bundles the current website interface, and starts its own loopback-only interface server. It does not require the temporary preview server or a public CloudKit web token. Native library sync succeeded, the existing profile/playlists/folders/liked songs loaded, and the phone’s playback state appeared in the Mac UI. Apple’s earlier bundle/container rejection resolved after provisioning became active; the existing portal assignment was already correct. This build uses the shared **Development** CloudKit environment, matching the tested phone build. The older status notes below are historical.

## Standalone iCloud build

Signed builds without `--preview-url` embed the website by default. To reproduce the verified development configuration:

```sh
python3 mac/build.py --bundle-site --cloud-environment Development --cloud-profile /path/to/mac.provisionprofile --signing-identity 'Apple Development: Your Name (ID)' --display-name 'Nova Music iCloud' --output "$HOME/Applications/Nova Music iCloud.app"
```

The static interface is served only on `127.0.0.1:47937` (`47938` for the review App ID). Keeping a stable origin preserves WebKit’s local library/settings across relaunches. Signed bundled builds include sandbox permissions for the local listener, outbound network requests, and user-selected import/export files. The listener serves read-only bundled resources, rejects traversal, and exposes no library/credential API. Native bridge requests remain restricted to the app’s own main frame and its bound loopback origin. If another copy owns the port, startup reports an error instead of loading another server.

Run the bundled interface checks:

```sh
xcrun swiftc -swift-version 5 mac/Sources/NativeLocalSite.swift mac/Tests/NativeLocalSiteTests.swift -o /tmp/nova-local-site-tests
/tmp/nova-local-site-tests
```

> **Latest signed review:** `~/Applications/Nova Music iCloud Review.app` has native iCloud enabled using the Mac development profile. It reaches the Apple Account, but private-record requests currently fail with “Invalid bundle ID for container”; the review App ID/container association needs verification in the Apple Developer portal. Unsigned Mac builds show a native-signing explanation instead of falling back to browser auth. Use `--cloud-environment Development` or `Production` to override the default environment.

## iCloud support (October 18, 2026)

The website interface now uses iCloud. A properly provisioned Mac build uses the native CloudKit bridge, so no browser sign-in or public web token is needed. Build with:

```sh
python3 mac/build.py --cloud-profile /path/to/mac.provisionprofile --signing-identity 'Apple Development: Your Name (ID)'
```

The Mac App ID must be `com.nova.music.mac` (or `com.nova.music.mac.review` for a preview) and have access to `iCloud.com.example.NovaMusic`. The profile’s CloudKit environment must match the other clients. Ad-hoc builds remain usable for local music and web UI review; they do not advertise native iCloud access. Ordinary browsers require the public, origin-restricted token in `docs/sync-config.js`. Existing Mac installations need the rebuilt, provisioned app and the updated website to use native iCloud.

Device commands use a small private record separately from the library artwork asset. Transfers wait for acknowledgement; cloud delivery can take several seconds. A sleeping or closed app is not an available output. The Mac continues polling while its window is minimized and native audio is running, subject to macOS scheduling.

## Earlier build and playback notes

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

Installed 1.0.4 interface verification: the published output picker transferred a paused song from the unavailable phone to This Mac, confirmed readiness, and displayed its selected checkmark. Resuming the installed native player advanced continuously from 2.2 seconds to 75.8 seconds, beyond the reported 59-second cutoff. Playback was left paused at 78.1 seconds. The short-lived spinner is covered by matching-command/loading-state regression tests; the live transfer completed before the accessibility snapshot.

## Collection positions and native artwork (1.0.5)

The shared interface remembers the last song independently for each album or playlist and shows a small pin beside it. Collection origin survives connected-device commands and transfers. Unchanged playback telemetry now preserves the bottom-left image element.

AVPlayer's native Now Playing information includes the current album and cover. Artwork loads asynchronously, is retained through clock updates, and is cleared when stopping or changing tracks. A cancelled or superseded artwork request cannot set the next song's cover. This requires the matching shared website update.

## Provider-ordered live catalog and local review

`NativeMusicCatalog.swift` supports only validated search, autocomplete, browse, next/lyrics and LRCLIB metadata lookups at fixed HTTPS endpoints. The bridge accepts messages only from Nova's trusted main frame, tracks request IDs, cancels on navigation, and uses cookie-free ephemeral requests. The website chooses the bridge when `novaDesktop.nativeCatalog` is present. Older Mac builds and ordinary browsers keep their existing transport.

Build the production app normally. To review unpublished website changes locally, run:

```sh
python3 mac/build.py --preview-url http://127.0.0.1:4176/ --output '/tmp/Nova Music Review.app'
python3 -m http.server 4176 --bind 127.0.0.1 --directory docs
# In another terminal:
open '/tmp/Nova Music Review.app'
```

Review builds cannot use `--install`; they have a separate bundle identity and keychain account. Production builds continue to load the GitHub Pages site and require publication of the updated modules before the new ranking UI is available.

Run catalog transport checks and optional live integration checks:

```sh
xcrun swiftc -swift-version 5 mac/Sources/NativeMusicCatalog.swift mac/Tests/NativeMusicCatalogTests.swift -o /tmp/nova-native-catalog-tests
/tmp/nova-native-catalog-tests
xcrun swiftc -swift-version 5 mac/Sources/NativeMusicCatalog.swift mac/Tests/LiveCatalogSmoke.swift -o /tmp/nova-live-catalog
node scripts/check-live-search.mjs /tmp/nova-live-catalog
```

Live native search now preserves YouTube Music's own result order and uses one request per overview/filter. The autocomplete bridge supports only the fixed `music/get_search_suggestions` endpoint with a validated input string. Suggestions debounce for 250 ms, cancel old work, show up to eight results, and support arrow keys, Enter, Escape, and clicking. Selecting a search result keeps its recording ID during playback.
