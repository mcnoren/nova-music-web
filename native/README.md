# Nova Music native account integration

These files are copies of the implementation integrated into the Nova Music app in the parent workspace. Configure the same public Supabase URL/key as the website before rebuilding. See the repository README for the database migration and email/password setup.

For another copy of the native app:

1. Add the three `MusicAccount*.swift` files to the **NovaMusic** target's Sources. They use existing `YouTubeStore`, `YouTubeVideo`, `YouTubeMusicAlbum`, `YouTubeChannel`, playlist and folder models; they are not standalone applications.
2. Add `SyncConfiguration.xcconfig` beside the app's existing configuration, and include it with `#include? "SyncConfiguration.xcconfig"` in `SpotifyConfiguration.xcconfig`.
3. Add Info.plist strings `NovaSyncURL` = `$(NOVA_SYNC_URL)` and `NovaSyncPublishableKey` = `$(NOVA_SYNC_PUBLISHABLE_KEY)`.
4. In `YouTubeStore`, under `#if NOVA_MUSIC`, add `lazy var musicAccount = MusicAccountSync(store: self)`.
5. Add `MusicAccountSyncSection(account: store.musicAccount)` to the music Settings form under `#if NOVA_MUSIC` and `if musicOnly`.
6. In `NovaMusicApp`'s main view, add `.task { await MusicPlaybackSession.store.musicAccount.bootstrap() }`.
7. Add `MusicAccountSyncTests.swift` to the NovaMusicTests target to run the account-format tests.

The app stores access/refresh tokens in Keychain with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. Library metadata and offline pending changes are cached in app preferences. This does not encrypt library metadata end to end. Reauthentication uses the current account and retains its pending changes; sign-out restores the saved guest library after successful sync.

The configured project is shared with the live website. Email confirmation/reset links open the website; afterward sign into the native app with your email and password. The built-in mail service is limited to project-team addresses until custom SMTP is configured.
