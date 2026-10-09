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
- Web libraries are device-local and do not automatically sync with the iPhone app. Imported audio is never uploaded. Metadata backups omit API keys and do not include audio bytes.

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

JavaScript syntax, catalog references, desktop and phone layout, browser console, search, playlists, folders, library persistence, audio import/playback, and valid/invalid WebMCP inputs were checked. Spotify and live YouTube API calls require provider credentials and could not be tested against a signed-in provider account. YouTube’s embedding refusal was checked as a real error state.

Composer image licensing and original sources are retained in `docs/assets/composers/Credits.json`. Catalog art remains hosted by its provider.
