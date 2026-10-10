# Nova Music for the web

A browser adaptation of Nova Music’s Home, Classical, and Search experience. Home is the default page. Search combines full catalog search with browse tiles and the former Discover page’s recommendations, mixes, genres and fresh finds. The logo and Home button return to Home; existing Discover links open Search.

**Website:** https://mcnoren.github.io/nova-music-web/

## Features

- Spotify-style desktop panels, persistent global search, live results, Top result/Songs grouping, browse tiles, library filters and phone navigation.
- Live Discover and mood results, genres, listening-based recommendations and recent listening, with a bundled fallback when the live source is unavailable.
- Live YouTube Music search across songs, artists, albums and public playlists, spelling correction, lyric-fragment queries, filtered pagination and public playlist saving. No personal API key is required. Bundled metadata is only an offline fallback.
- Classical: 20 composers, the app’s portrait assets and attribution, 153 bundled works, category folders, introductions, and recordings.
- Persistent liked songs, saved songs and albums, followed artists, pins and artist ordering.
- Artist release selection and disc selection when confirmed disc metadata exists. An empty selection stays empty.
- Editable playlists, song ordering, smart playlists with source/artist/title/album/order/limit rules.
- Folders containing albums and playlists, independent pins, and combined deduplicated shuffle.
- A continuous player with play/pause, seeking, volume, queue editing, shuffle and repeat.
- Exact-recording LRCLIB lyric lookup, synced LRC lyrics when duration agrees, custom lyrics and timing offset.
- Artwork/lyrics display, song information, Wikipedia introductions with attribution, song sharing.
- Spotify PKCE connection, complete paginated playlist import, snapshot/total checks, Exportify CSV import, live per-song recording searches, and a shared Songs to review list across every imported playlist. Tap an unpaired entry to search the full music catalog and assign a recording to its original playlist; failure reasons and paired history persist and sync with the native app. Playlist Add songs uses the same live search popup, with pagination and retry. Import review groups suggestions and failures together before matched songs.
- Pasted song-list import and complete playback of imported audio files saved in IndexedDB.
- Library backup/restore, phone navigation, keyboard controls, installation manifest and offline app shell.
- Progressive WebMCP tools for catalog search, library readback and playlist creation when the browser supports them.

## Browser differences

This is a static GitHub Pages application, not an exact replacement for the native player.

- YouTube playback uses the official embedded player with its video hidden at the owner’s request. This is not an officially supported audio-only mode; behavior can vary by browser. Recordings can block embedding or vary by region; use the song’s YouTube Music link when unavailable. No audio extraction or ad bypass is used.
- Background playback, lock-screen controls, AirPlay and fullscreen behavior depend on the browser and source. Siri, Live Activities, native mirroring and the iOS library sandbox cannot be reproduced on GitHub Pages.
- Live search and browsing use the public YouTube Music metadata interface through a Supabase Edge Function. This is an unofficial provider interface, as in the native app, and can change or become unavailable. It does not guarantee every song, private playlist, region-locked release or Spotify-only collection. Lyrics queries use the provider’s search relevance, not a complete licensed lyrics index. Bundled metadata remains an offline fallback. Albums and public playlists load their tracks on demand and expose additional pages. Saving an album or playlist loads every returned page before saving the collection.
- Spotify import requires a configured Spotify developer client ID and user authorization. Short `spotify.link` redirects must first be opened to obtain the full playlist URL. Public preview scraping is not implemented. Provider eligibility and playlist access restrictions still apply.
- Lyric availability varies. No songwriter, popularity or disc metadata is guessed. Artist selection applies to the available catalog.
- Email/password account sync is configured for the website and native app. Without signing in, libraries remain device-local. Imported audio is never uploaded. Metadata backups omit API keys and do not include audio bytes.

## Provider setup

Open **Settings** in the website.

Live search is already connected to the existing Supabase project. No user setup is needed. Playlist CSV and pasted song-list imports use the existing live search service for each entry; no Spotify connection or additional API key is required. An optional YouTube Data API key remains available for other explicit YouTube imports; restrict it to the website and YouTube Data API. It stays in that browser and is never committed.

For Spotify, create an app in the Spotify developer dashboard and register exactly `https://mcnoren.github.io/nova-music-web/` as its redirect URI. Enter the public client ID in Settings, then choose Add music → Import from Spotify → Connect Spotify. No client secret is used; tokens and the PKCE verifier stay in session storage.

## Local preview and hosting

All public website files are in `docs/`. No build or package installation is required.

```sh
python3 -m http.server 4173 --directory docs
```

Open http://127.0.0.1:4173/. GitHub Pages publishes `main` → `/docs`. Routes use URL fragments so direct links work under the repository’s path.

To refresh the snapshot alongside the original Nova source:

```sh
NOVA_NATIVE_SOURCE=/path/to/NovaBrowser python3 scripts/build-catalog.py
```

The generator uses public catalog metadata only; no private library or credentials are included. The browser uses official YouTube embeds for playback.

## Validation

JavaScript syntax, catalog references, desktop and phone layout, browser console, search, playlists, folders, library persistence, audio import/playback, and valid/invalid WebMCP inputs were checked. Spotify and live YouTube API calls require provider credentials and could not be tested against a signed-in provider account. Live YouTube playback, the player’s synchronized controls, and YouTube’s embedding refusal were checked in the browser. GitHub Pages deployment succeeded, and every published website file was verified against its source.

Composer image licensing and original sources are retained in `docs/assets/composers/Credits.json`. Catalog art remains hosted by its provider.

## Email/password account sync

The website and native source use the same free Nova Music Supabase project. The database migration is applied, email authentication and confirmation are enabled, and the minimum password length is 12. Public connection settings are in `supabase/project.json`, `docs/sync-config.js` and `native/SyncConfiguration.xcconfig`. No secret keys are published.

GitHub hosts the public website and source. Supabase Auth handles passwords; its database stores each account's library. Row-level access rules restrict reads to the owner and the write function derives ownership from the authenticated user. This is private server-side storage, not end-to-end encryption. Do not commit personal libraries or secret keys to GitHub.

### First account

1. Open the website → Sign in → Create account. Choose your own password with at least 12 characters.
2. Confirm the email, then sign in with your email and password. Email confirmation links never automatically import a device library.
3. Rebuild the native app with the included public configuration. In Settings → Nova Music account, sign in with the same credentials.
4. Choose whether to add each device's existing library, then check a playlist or like appears on the other device.

**Email limitation:** Supabase's default email service only sends to project-team addresses and is limited to two emails per hour. Use the email associated with your Supabase project account for initial signup. Additional users require custom SMTP; see [Supabase email setup](https://supabase.com/docs/guides/auth/auth-smtp). Ordinary password sign-in sends no email. “Forgot password?” sends a reset link that opens the website; recovery tokens are kept only in memory, validated, removed from the URL immediately, and never used to activate or import a library.

For another project, apply `supabase/migrations/202610090001_nova_music_sync.sql`, enable email authentication and confirmation, set minimum password length to 12 and Site URL to the deployed website. Configure only the public project URL/publishable key in both clients. In xcconfig, write HTTPS as `https:/$()/PROJECT.supabase.co` to avoid a comment. Run `python3 scripts/version-assets.py` before publishing changed modules. Never put service-role/secret keys, database passwords or personal access tokens in client files.

### What syncs

Likes, saved songs/albums, followed artists and pins, playlist names/order/song order/smart rules, folders and their pins, chosen releases/discs, recent listening and genres share one account. Native-only artist folders and disc-to-artist links remain intact when a browser edits the library. Independent item edits merge; concurrent edits to the **same** playlist or folder choose one deterministic newer record. This is not collaborative simultaneous playlist editing. Deleted records are retained as tombstones to prevent an old offline device from bringing them back. The library is limited to 30,000 records and approximately 8 MB in the browser.

Each sign-in lets you choose whether to add the device's existing library. Guest and account libraries stay separate. Sign-out restores the guest library and clears that account's local browser cache; it waits for pending edits to sync first. Existing signed-in sessions save edits locally during network interruptions and retry when connected. A new sign-in requires internet access. Browser sessions last for the current tab session; native credentials use the iOS Keychain. Imported audio/photos and provider credentials remain on the originating device. There is no account-deletion screen yet.

### Native source and checks

The working Nova Music app in the parent workspace has already been integrated. Reusable Swift files and integration instructions are in `native/`; this repository does not duplicate the entire native app.

`npm test` exercises merging, deletions, account changes during requests, revision conflicts, in-flight edits, credentials exclusion and payload validation. `tests/sync-access.sql` exercises anonymous/account-isolation access against a **disposable** PostgreSQL database. Native `NovaMusicAccountSyncTests` checks shared-format persistence, validation, disc choices and exclusion of credentials. The browser sign-in, sign-out and two-session sync flow was tested with `tests/development-server.py`, a localhost-only fake service that sends no email. The real project now rejects anonymous reads/writes as expected; real signup email delivery and signed-in cross-device production sync still need verification with the owner’s own account. Password sign-in, failed login, confirmation-required signup, recovery isolation and credentials exclusion are covered by local tests. The native app must be rebuilt and installed to use these changes.

## Interface research and redesign (October 9, 2026)

The public [Spotify web search page](https://open.spotify.com/search) was inspected directly at desktop width. Nova follows its always-visible pill-shaped global search, home control, independent left library and central content panels, black/charcoal surfaces, green actions, round filters, colorful browse tiles, top-result/song split and persistent bottom transport. Nova retains its name, catalogs, classical works, imports and private account sync. Mobile search stays visible above scrolling results, and the profile menu exposes settings, account and imports.

Reference: [Spotify desktop/library/Now Playing overview](https://newsroom.spotify.com/2023-06-20/spotify-desktop-experience-redesign-your-library-now-playing-views-customize/) and [Your Library help](https://support.spotify.com/br-en/article/your-library/). Spotify changes its UI by account and experiment, so this reproduces the inspected layout rather than claiming every account screen is identical.

The owner explicitly requested that embedded video remain hidden while playback stays in Nova. Now Playing displays artwork and no longer opens automatically or pauses YouTube when closed. The public YouTube IFrame sample played with advancing progress in local browser QA; individual recordings can still refuse embedding. Search typing/submission/clearing, empty results, filters, saved collections, profile/settings and desktop/phone layouts were checked. Existing account/model tests still pass.

## Live search service (October 9, 2026)

`supabase/functions/music-search/index.js` is deployed as `music-search` in the existing project. Gateway JWT verification remains enabled; clients send the existing public publishable key in the `apikey` header. The function never accesses account libraries, database credentials, user sessions, cookies or audio/video streams. Only fixed public YouTube Music search/browse endpoints are allowed, with validated operations, collection IDs and input sizes. CORS allows the deployed site and local preview ports 4173–4176. Search has a 450 ms debounce, cancellation, five-minute bounded client/server caches, provider-order deduplication and per-instance request throttling. Throttling is best effort per running instance, not a global abuse-prevention guarantee. Free-project quotas and provider availability still apply; no paid plan was enabled.

To deploy this service to another project, deploy the checked-in function with `supabase/config.toml`, update the public project settings, and change the allowed website origin in the handler. No provider secret is required. The dashboard copy uses the same JavaScript in `index.ts`; dashboard deployment does not automatically follow GitHub commits.

Validation includes 25 unit tests covering typo fallback, Unicode, available lyrics, rank preservation, cache expiry, provider parsing, pagination and input/origin limits, alongside existing sync tests. Live tests checked misspelled artist queries, lyric phrases, songs and albums outside the bundled fallback, public playlists, complete album tracks, pagination and browser playback.


## Profiles, lyrics and search relevance (October 9, 2026)

The account picture opens Account directly. Edit profile provides a name, twelve icons, six colors and an optional center-cropped 256-pixel JPEG photo. The shared `profile:main` record stays in the private account document, and the app and browser use the same format. A default profile on a new device does not replace an existing account picture. Playlist artwork now syncs between devices. Imported audio remains device-local.

The website's Lyrics view uses the right sidebar with its view switcher fixed at the top. Highlighting follows the playback clock at 150 ms intervals, resets between songs and seeks, and scrolls only the lyric container. LRCLIB matches title, primary artist, recording version and duration before enabling timed cues; a plain exact response can fall back to a matching timed result. Playback-duration changes trigger a fresh match. Earlier/Later/Reset controls store a per-recording adjustment on the current device. Provider timing can still vary by recording. Song and album options use an anchored, keyboard-accessible menu; editing and account forms retain their dialogs.

Both clients rank across entity types. Exact title/artist matches, spelling tolerance, official recording status, provider relevance and bounded public play/view counts determine the top result. Unrequested lyric uploads, covers and alternate versions receive less weight. Popularity is used only when the provider supplies it; no numbers are invented or extra per-track requests made. The app shows a song, artist, album or playlist first and orders category sections by relevance. The website now supports album and playlist top results even when no songs are returned.

Validation: 38 JavaScript tests and four native profile/search tests, a successful simulator build, two browser-session profile syncing, independent-account isolation, anchored menu placement, real-provider metadata and synthetic timed-cue seek/scroll checks. Native source is updated in the sibling workspace and must be rebuilt and installed on the owner's devices. Actual lyric availability and embedded playback still depend on the providers.


## Direct provider search and recording-linked lyrics (October 9, 2026)

Website searches now request `providerOrder: true`: one public YouTube Music search is rendered in the provider's mixed order, including its featured result. Nova does not apply its relevance/popularity score or replace the overview's songs with a separately filtered song list. Category filters still query YouTube Music directly. Personal playlists appear separately. YouTube user profiles and podcasts are excluded from music artist/playlist results. Results are public, US/English provider results and can differ from a signed-in YouTube Music account. A link opens the actual YouTube Music search; the provider returns `X-Frame-Options: SAMEORIGIN` and its search page cannot be embedded in GitHub Pages. Older native clients retain their existing response mode.

Lyrics first resolve the public YouTube Music lyric endpoint linked to the selected video ID. The service requests its timed lyric data and preserves millisecond start/end ranges and provider attribution. Only verified official song audio receives these timed cues. A music-video result plays a strictly matching official audio version when one is available; other video edits receive readable lyrics rather than studio timing. LRCLIB is a fallback for duration-matched song audio, not video edits. The website ignores the prior video's playback clock during transitions, re-fetches lyrics when a previously unknown duration becomes available, and clears highlighting between explicit cue ranges. Open tabs detect newer website files and offer Refresh without interrupting playback.

Validation: 44 automated tests pass. Live service checks loaded 61 linked cues for the official `drop dead` audio and withheld those cues for its longer video edit. Browser checks verified source attribution, the resolved official audio ID, timed highlights at 65 seconds and after a backward seek to 15 seconds, and lyric-container-only scrolling. The actual song refused embedding in the local test browser; playback-clock checks used YouTube's public sample recording and controlled cues. Provider timing is not a guarantee of sample-accurate alignment for every recording.

## Playlist CSV imports

Choose **Add music → Import playlist CSV** on the website, or **Playlists → New → Import playlist / CSV → Import playlist CSV** in a rebuilt native app. Exportify column order is detected by headers. CSV parsing supports UTF-8 BOM, quoted commas and escaped quotes, multiline fields, CRLF, and comma/tab/semicolon separators. The whole file is read locally; only title/artist search queries leave the device. Up to 10,000 entries and 5 MB are supported. The import does not download Spotify audio or require the user's own Spotify developer app.

The website previously searched only metadata already loaded in the browser unless an optional API key was configured. It now searches every supported entry with bounded concurrency, preserving original order and sharing repeated queries. CSV duration, explicitness and album metadata help rank recordings; ISRCs are preserved without claiming an ISRC match when the provider exposes none. Different editions and non-official sources require manual selection. Failed searches are distinguished from absent matches and can be retried. Cancelling aborts outstanding searches and prevents a stale review from opening. Nothing is added until the review is saved. Repeated recordings are saved once; all original entries and unmatched metadata are retained.

CSV import uses the same existing provider interface as normal Nova search; it does not change or remove the provider-policy limitations documented above. The native app already performed live per-song searches; this update adds CSV selection and parsing to that flow.

## Connected playback

Sign into the same Nova Music account in the app and browser. **Output location** in the player selects the device that produces audio. Selecting a recording on another signed-in device keeps the current output and replaces its song/queue. Pause, skip, seek, shuffle/repeat and queue additions, removals and reordering control that output. Switching output carries the recording, ordered queue, position and pause state; the previous output stops when it receives the change.

Playback uses `connect:session`, `connect:status` and per-device presence records in the existing private account document and existing authenticated revision-checked RPC; no database migration or additional service is required. Commands and playback telemetry use separate records, so an older heartbeat cannot overwrite a song selection. Only matching command telemetry is used. Devices check for updates about every two seconds, send playback telemetry about every six seconds, and expire from the device list after 90 seconds without a heartbeat. Unchanged polls fetch only the library revision; playback-only updates do not reapply/redraw the library. Signed-out users retain ordinary local playback. Imported local audio cannot transfer between devices.

Keep the output browser open or the native app available. iOS can suspend an inactive app that is not playing audio; this implementation cannot wake a suspended app or closed browser. A browser that blocks autoplay needs one local Play gesture. Output changes depend on network delivery and are not simultaneous speaker playback. Validation uses a shared simulated authenticated backend, two browser sessions and native audio fixtures; physical-device testing is described below; broader background/network failure testing remains necessary. Both clients must run this version to share playback; older clients sync only their libraries.

The Search discovery content no longer includes the personalized For You section. Search provides a **Dismiss keyboard** button without leaving the page or clearing the query.


## Phone playback in the web player

The controller mirrors the output's current song, full queue, actual duration, playback timestamp and pause/buffering state. Its display advances from the shared timestamp between network updates. Native playback publishes the resolved audio recording ID, the exact lyric cues/provider and the offset/rate calibration; the browser uses those cues and clock instead of independently choosing different lyric timing. Older snapshots without shared lyrics retain provider lookup. Signing in with an already-playing song announces the existing output when there is no shared session.

Entering remote mode destroys any existing embedded player and unloads local audio, including guest audio that started before sign-in. Metadata and lyrics still display, and output transfer creates a player only on the selected output. This prevents local browser playback or embedded ads while controlling the phone. When the browser is the selected output, YouTube's embedded player can serve ads; its API has no switch to guarantee ad-free playback. Nova does not add advertising of its own.

Validation: 67 web tests and eight native connection/account tests pass. The signed iPhone build succeeds. A local browser fixture displays the phone's song at 1:05 / 3:00, the matching highlighted lyric and no embedded iframe. Tests cover existing playback on sign-in, joining a remote output with preexisting local audio, pause/seek/queue transfer, exact lyric timing, old telemetry, account isolation and malformed snapshots. These checks do not establish frame-accurate timing on every physical device or network.


Outputs reopen an expired session from matching telemetry, paused at the last confirmed position when the heartbeat is stale. Controllers likewise show stale playback paused instead of advancing a frozen clock by 90 seconds. Fresh sessions retain their current play state, and a paused browser recovery cues the video without starting it. An expired-output recovery regression is covered in both native and web tests.


The update was also checked on the deployed GitHub Pages website in Safari with the updated app installed on the paired iPhone. The browser received the phone's actual song and duration, resumed playback on the phone from a browser Play action, showed continuously advancing progress, and displayed the phone's timed provider cues. The output picker continued to identify the iPhone as the selected output. This confirms the live foreground handoff; it does not establish background wake-up or identical timing under every network condition.


## Artist pages and playlist artwork

Mac and web artist pages follow the phone layout: artist image and controls, Albums, Singles & EPs, attached playlists, Top songs and artist information. The release picker includes synced metadata before its tracks have loaded, follows the provider’s full album/single shelves, and preserves explicit empty selections and disc choices. Chosen release playback includes featured performers.

Playlist photos, icons and cover collages share a portable `collectionArtwork` field in the existing private playlist record. Photos use a bounded JPEG image; native clients recreate a local image file on import. Default artwork can be restored on either client. The constantly changing sync label was removed from the desktop sidebar; account status remains available in Account. Both clients need this update for custom artwork transfer.

Validation: 94 web tests and eight native account/sync tests passed, including selected releases with unloaded tracks, separate release kinds, image transfer without native file references, artwork reset, and malformed-image rejection. The live metadata service returned the full Olivia Rodrigo discography. The updated signed phone build was installed on the paired iPhone.

Playback sync preserves the loaded provider track list and completeness of an album when another device supplies a metadata-only release record. Reusing a cached album page also restores its loaded recordings before rendering, so starting playback cannot turn a full album into an empty “Selected recordings” view. A regression reproduced the empty-track overwrite before the fix; all 95 web tests now pass, including saved playlist entries through the same update.
