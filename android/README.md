# ReelHouse for Android

The Android client for a ReelHouse server: Movies & TV, Music and Podcasts, with a shared audio
player, offline downloads, speakers, wake-up alarms, the Morning Briefing and Android Auto media
browsing. Kotlin + Jetpack Compose, package `com.reelhouse.android`.

It was extracted from the SentinelCore Android app and keeps that app's media features unchanged;
everything that was not media was removed (see "What was dropped").

## Build and run

Requirements: JDK 17+, the Android SDK (compileSdk 36). `local.properties` points at the SDK:

```
sdk.dir=/Users/<you>/Library/Android/sdk
```

```
./gradlew assembleDebug          # app/build/outputs/apk/debug/app-debug.apk
./gradlew testDebugUnitTest      # JVM unit tests
./gradlew installDebug           # onto a connected device or running emulator
./gradlew connectedDebugAndroidTest   # on-device Android Auto media-browsing test
```

On first launch the app looks for a server on the local network (mDNS service type
`_reelhouse._tcp`) and also takes an address typed by hand. A home-network address typed without
a port gets the server's HTTP port, **3350**; the HTTPS port is **3453**. If the phone does not
trust the server's own certificate authority, the app falls back to the same host's plain-HTTP
port, and only to a server that has proved its identity (`data/ServerIdentity.kt`).

Release signing is optional. With no `keystore.properties` in this folder, `assembleRelease` is
signed with the debug key. To sign with a real key, create `keystore.properties` (gitignored):

```
storeFile=path/to/upload.jks
storePassword=...
keyAlias=...
keyPassword=...
```

### Push notifications (Firebase)

Push needs the Firebase project's `google-services.json` for package `com.reelhouse.android` in
`app/` (it is gitignored). With it, the Google Services Gradle plugin is applied and the app gets
a Firebase Installation ID (`FirebaseMessaging.register()`), registers it with the server after sign-in (`POST /api/push/devices`) and
unregisters on sign-out. Without it everything still builds and runs; push is just off and
Settings → Notifications says "Push isn't set up in this build".

To get the file: Firebase console → the project the server uses → Project settings → Your apps →
Add app → Android → package `com.reelhouse.android` → download `google-services.json`.

Code: `push/PushNotifications.kt` (channels, the messaging service, tap routing),
`data/PushModels.kt`, the push calls in `data/ReelHouseRepository.kt`, and the Notifications
section of `ui/screens/SettingsScreen.kt`. Channels: `new_episodes`, `downloads`, `account`,
`general`. Server side: [../server/docs/PUSH.md](../server/docs/PUSH.md).

Debug and release are the same app: "+ Add", downloads, Import a list and Suggested for you are in
every build type.

## Layout

| Path (under `app/src/main/java/com/reelhouse/android`) | What |
| --- | --- |
| `ui/ReelHouseApp.kt`, `ui/AppSection.kt`, `ui/TabBar*.kt` | Root navigation: Movies, Music, Podcasts, Settings |
| `ui/ReelHouseViewModel.kt` | Connection, sign-in, and the Movies & TV passthroughs |
| `data/ReelHouseRepository.kt` | HTTP layer: cookie session, certificate handling, every non-audio route |
| `data/Media*Models.kt` | Movies & TV, downloads, imports: models and parsing |
| `ui/screens/Movie*.kt`, `Media*.kt` | Movies & TV screens, libraries, folder picker, "+ Add", imports |
| `audio/` | Audio API, player engine, playback service, offline downloads, speakers, Android Auto browse tree |
| `ui/audio`, `ui/music`, `ui/podcasts` | Music, Podcasts and the shared player's screens |
| `ui/screens/Settings*.kt`, `ServerSettingsScreen.kt`, `Account*.kt`, `DashboardLoginScreen.kt`, `SetupScreens.kt` | Settings, schema-driven server settings, accounts, login, first-run setup |
| `net/ServerDiscovery.kt` | mDNS discovery |

The Movies, Music and Podcasts tabs each appear only while the server has that section switched on
(`GET /api/media/enabled`, `GET /api/audio/enabled`); Settings is always there.

## Server API

Same paths and JSON as SentinelCore's web server for: `/api/health`, `/api/auth/*`,
`/api/accounts*`, `/api/settings` and `/api/settings/schema` (plus whatever section, lookup,
options and action endpoints the schema itself names), `/api/media/*`, `/api/music/*`,
`/api/podcasts/*`, `/api/audio/*`, and `ca.crt` for the certificate-trust check. One call falls
outside those groups: `POST /api/system/restart`, the "Restart" button server settings show for a
section whose fields need a restart.

## What was dropped vs SentinelCore

- Cameras: events feed, live view, recording timeline, triggers and the zone editor, PTZ, camera
  admin and discovery, known faces, known vehicles, prompt profiles, "use this phone as a camera"
  (and with it WebRTC, the camera and microphone permissions).
- Organizer, its home-screen widgets, Quick Add, voice capture, the share target and launcher
  shortcuts (and with them Glance, exact alarms and the boot receiver).
- Weather, the Device Hub and wall display, the home security alarm and its widget, schedules,
  the family Files library, HomeKit, backup, licensing and the unlicensed watermark.
- Push notifications: Firebase Messaging, the google-services plugin and `google-services.json`.
- The Android Auto IoT car app (`car/`): it showed the alarm, devices and alerts. Android Auto
  media browsing (`audio/AutoBrowse.kt`, through `AudioPlaybackService`) stays.
- Settings → Server health, AI speed, and the host-reboot panel in server settings.
- Podcast bookmarks' "Save to Note" (it wrote an Organizer note).
- The release-build switch that hid torrent downloads.
- `ui/screens/MediaScreens.kt`: despite its name it held the camera screens (activity detail, live
  grid, live player). The header helpers the media screens used from the events file now live in
  `ui/screens/ScreenChrome.kt`, and the confirm dialog from the Files library in
  `ui/components/ConfirmDialog.kt`.
- The Play upload script and release script.

Kept and adjusted: the audio wake-up alarms; the Morning Briefing, which now says the date and
plays podcast episodes (no weather or calendar); speaker announcements, which are messages sent
from another device.

The launcher icon is a placeholder vector (a house with a film reel) until there is real art.
