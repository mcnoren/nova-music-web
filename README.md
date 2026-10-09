# Nova Music for the web

A browser adaptation of Nova Music’s Discover, Classical, and Library experience.

**Website:** https://mcnoren.github.io/nova-music-web/

## Features

- Discover with moods, genres, listening-based recommendations, recent listening, and a public YouTube Music catalog snapshot.
- Search included songs, albums, and artists; paste any YouTube song link; optionally enable live YouTube Data API search and public playlist import.
- Classical: 20 composers, the app’s portrait assets and attribution, 153 bundled works, category folders, introductions, and recordings.
- Persistent liked songs, saved songs and albums, followed artists, pins and artist ordering.
- Artist release selection and disc selection when confirmed disc metadata exists. An empty selection stays empty.
- Editable playlists, song ordering, smart playlists with source/artist/title/album/order/limit rules.
- Folders containing albums and playlists, independent pins, and combined deduplicated shuffle.
- A continuous player with play/pause, seeking, volume, queue editing, shuffle and repeat.
- Exact-recording LRCLIB lyric lookup, synced LRC lyrics when duration agrees, custom lyrics and timing offset.
- Artwork/lyrics display, song information, Wikipedia introductions with attribution, song sharing.
- Spotify PKCE connection, complete paginated playlist import, snapshot/total checks, recording match review and persistent unmatched-song checklists.
- Pasted song-list import and complete playback of imported audio files saved in IndexedDB.
- Library backup/restore, phone navigation, keyboard controls, installation manifest and offline app shell.
- Progressive WebMCP tools for catalog search, library readback and playlist creation when the browser supports them.

## Browser differences

This is a static GitHub Pages application, not an exact replacement for the native player.

- YouTube playback uses its **visible official embedded player**. Recordings can block embedding or vary by region; use the song’s YouTube Music link when unavailable. No audio extraction, hidden video player or ad bypass is used.
- Background playback, lock-screen controls, AirPlay and fullscreen behavior depend on the browser and source. Siri, Live Activities, native mirroring and the iOS library sandbox cannot be reproduced on GitHub Pages.
- The starting catalog is a dated snapshot, not the full live YouTube Music catalog. Live search and YouTube playlist imports require a user-provided YouTube Data API key. There is no proxy or server here. Some bundled albums contain selected recordings; these are explicitly labeled. Complete fetched albums are marked separately.
- Spotify import requires a configured Spotify developer client ID and user authorization. Short `spotify.link` redirects must first be opened to obtain the full playlist URL. Public preview scraping is not implemented. Provider eligibility and playlist access restrictions still apply.
- Lyric availability varies. No songwriter, popularity or disc metadata is guessed. Artist selection applies to the available catalog.
- Account sync is implemented for the website and native app, but needs the Supabase project configuration below before it becomes available. Without it, libraries remain device-local. Imported audio is never uploaded. Metadata backups omit API keys and do not include audio bytes.

## Provider setup

Open **Settings** in the website.

For live YouTube search, enable YouTube Data API v3 in a Google Cloud project, create a browser API key, and restrict it to `https://mcnoren.github.io/*` and the YouTube Data API. Enter the key in Settings; it stays in that browser and is never committed to this repository.

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

## Account sync: activation required

The private database has been provisioned in the free Nova Music Supabase project. The library migration has been applied, and live anonymous reads and writes were verified as denied. Public project connection details are in `supabase/project.json`. Authentication is not configured yet: the free default email service locks template editing, so email codes require custom SMTP or a different sign-in method. The published site deliberately keeps sign-in disabled while `docs/sync-config.js` is blank. Real account sign-in and email delivery have not been tested.

GitHub hosts the public website and source. Supabase Auth handles sign-in; its database stores each account's library. The database is protected by row-level access rules and writes derive ownership from the signed-in user, not a caller-supplied user ID. This is private server-side storage, not end-to-end encryption. Do not commit personal libraries or secret keys to GitHub.

### Activate

1. Sign in to [the Supabase dashboard](https://supabase.com/dashboard), then create or select a project. No Codex plugin is required; setup can be completed in the browser. Use the same project for the app and browser.
2. Apply `supabase/migrations/202610090001_nova_music_sync.sql` through the project's SQL editor or migrations. It creates the table, ownership policy and revision-checked write function. No anonymous library access or direct client table writes are granted.
3. Finish the chosen sign-in method. For the implemented email-code flow, configure custom SMTP first; new free projects cannot edit the default email templates without it. Then include the one-time code `{{ .Token }}` in Auth's **Magic Link** email template. The default test mail service is limited to project-team addresses and two emails per hour. The site URL has already been set to `https://mcnoren.github.io/nova-music-web/`. See [Supabase's email setup](https://supabase.com/docs/guides/auth/auth-smtp). GitHub sign-in or email/password would require corresponding client UI and provider configuration before enabling the website.
4. Put the project HTTPS URL and its **publishable key** in `docs/sync-config.js`. An older `anon` key is also supported. Never put a `service_role`, secret key, database password or personal access token in client files.
5. Put the same public values in `NovaMusic/SyncConfiguration.xcconfig` in the native workspace and rebuild the app. For an HTTPS URL in an xcconfig file, use `https:/$()/PROJECT.supabase.co` so `//` is not treated as a comment.
6. Run `python3 scripts/version-assets.py`, commit, and publish the website. Verify real email sign-in, two-device edits and sign-out against the connected project before calling activation complete.

### What syncs

Likes, saved songs/albums, followed artists and pins, playlist names/order/song order/smart rules, folders and their pins, chosen releases/discs, recent listening and genres share one account. Native-only artist folders and disc-to-artist links remain intact when a browser edits the library. Independent item edits merge; concurrent edits to the **same** playlist or folder choose one deterministic newer record. This is not collaborative simultaneous playlist editing. Deleted records are retained as tombstones to prevent an old offline device from bringing them back. The library is limited to 30,000 records and approximately 8 MB in the browser.

Each sign-in lets you choose whether to add the device's existing library. Guest and account libraries stay separate. Sign-out restores the guest library and clears that account's local browser cache; it waits for pending edits to sync first. Existing signed-in sessions save edits locally during network interruptions and retry when connected. A new sign-in requires internet access. Browser sessions last for the current tab session; native credentials use the iOS Keychain. Imported audio/photos and provider credentials remain on the originating device. There is no account-deletion screen yet.

### Native source and checks

The working Nova Music app in the parent workspace has already been integrated. Reusable Swift files and integration instructions are in `native/`; this repository does not duplicate the entire native app.

`npm test` exercises merging, deletions, account changes during requests, revision conflicts, in-flight edits, credentials exclusion and payload validation. `tests/sync-access.sql` exercises anonymous/account-isolation access against a **disposable** PostgreSQL database. Native `NovaMusicAccountSyncTests` checks shared-format persistence, validation, disc choices and exclusion of credentials. The browser sign-in, sign-out and two-session sync flow was tested with `tests/development-server.py`, a localhost-only fake service that sends no email. The real project now rejects anonymous reads/writes as expected; signed-in production activation remains unverified until authentication is configured.
