# Push notifications

ReelHouse can put a notification on the lock screen of your iPhone or Android phone. It sends one when:

| What happened | Who gets it | Tapping it opens |
|---|---|---|
| A podcast you follow has a new episode | Everyone following that show with **Notify me of new episodes** on | The episode or show |
| A movie, TV episode or album you asked for (+ Add) finishes downloading | Whoever asked for it | The movie or show |
| Someone types a wrong password | Admins | The app |
| Something is wrong with the server (e.g. the download VPN's account is running out) | Admins | The app |
| Your wake-up alarm couldn't play on its speaker | Whoever set the alarm | The app |

With login turned off there is only one household, so every registered phone gets everything.

The Apple TV can't show notifications, so it never gets any.

---

## For everyone: turning it on in the app

**iPhone**
1. Open ReelHouse and sign in. The first time you do, it asks whether it may send notifications. Tap **Allow**.
2. To check it works, go to **Settings → Notifications → Send Test Notification**.
3. If you tapped **Don't Allow**, turn notifications back on in the iPhone's **Settings → ReelHouse → Notifications**. The same ReelHouse screen has a button that opens it.

**Android**
1. Open ReelHouse and sign in. On Android 13 and later it asks to send notifications. Tap **Allow**.
2. To check it works, go to **Settings → Notifications → Send test notification**.
3. Android files ReelHouse's notifications under four channels, and you can mute each one on its own in the phone's **Settings → Apps → ReelHouse → Notifications**:
   - New podcast episodes
   - Finished downloads
   - Sign-in alerts
   - General

**Per podcast:** on a show's page, **Notify me of new episodes** turns that show's notifications on or off for you. It is on by default when you follow a show.

**If nothing arrives:**
- The app's Notifications screen says why. The usual reasons:
  - **Off on the server:** an admin turned off **Enabled** (see below).
  - **No license / not set up:** the server has no ReelHouse license installed (Settings → LICENSE), and no Apple/Google keys of its own either.
  - **Notifications blocked on this phone:** allow them in the phone's settings.
- Notifications go to the account that was signed in on that phone. Sign in as yourself, not a shared account, if you want your own.
- A phone signs itself up again every time the app is opened. If it was off for a long time, open the app once.

---

## For the admin: setting it up

### If you bought ReelHouse: install your license, and you're done

Notifications to the ReelHouse apps from the App Store and Google Play go through the **ReelHouse push service** (`push.nr5p.com`). It holds the Apple and Google keys for those apps, so you don't need a developer account of your own. Your **license** is what proves your server may use it.

1. In the web page, go to **Settings → LICENSE** (under the Notifications heading).
2. Click **install license file** and pick the `.lic` file you were sent when you bought ReelHouse. It's checked before it's saved, so a wrong file can't replace a license that works. A SentinelCore license won't work here; it's a different product.
3. That's it. Push is on by default. To check, use **send test notification** in **PUSH NOTIFICATIONS**, or the test button in the app.

What passes through the push service: each notification's title and text, what it opens (an episode/show/movie id), and each phone's push address. Nothing else about your library, and nothing is kept: it's handed to Apple or Google straight away. The push service limits each license to 25 phones and to 200 notifications every 10 minutes.

### Settings → PUSH NOTIFICATIONS

In the web page, go to **Settings**. The **PUSH NOTIFICATIONS** section is under the Notifications heading.

| Field | What it does |
|---|---|
| **Enabled** | The master switch, on by default. Nothing is sent while it's off, except the test button. |
| **New Podcast Episodes, Finished Downloads, Failed Sign-ins, Server Problems, Missed Wake-up Alarms** | Turn each kind on or off for the whole server. All are on by default. |
| **Use ReelHouse Push Service, Push Service Address** | Send through the push service with your license (above). The address stays `https://push.nr5p.com`. |
| **Apple: Team ID, Key ID, Key File, Bundle ID** | Only if you build the iPhone app yourself: your own key for sending to iPhones (see below). Filled in, it takes over from the push service for iPhones. |
| **Firebase: Project ID, Service Account File** | Only if you build the Android app yourself: your own account for sending to Android phones (see below). Filled in, it takes over from the push service for Android. |
| **send test notification** | Sends a test to *your own* phones. It works while Enabled is off. |

The app's Notifications screen, and `GET /api/push/status`, show which way each kind of phone is reached: `direct` (your keys), `relay` (the push service) or `none`.

When you save, the page warns you if a key file it names isn't there, or if you filled in only part of a platform's keys.

**Failed sign-ins:** the push uses LOGIN ALERTS' **Cooldown**, so a burst of guesses from one address is one notification. It doesn't need LOGIN ALERTS' email switched on.

### Your own keys (only if you build the apps yourself)

An app you build and sign yourself has its own identity, which the push service can't send to. Then the server sends straight to Apple and Google with your keys. You need:

**Apple (for iPhones)**: an APNs key from the Apple Developer account that signs the iPhone app.
1. Go to developer.apple.com → Certificates, Identifiers & Profiles → **Keys** → **+**.
2. Tick **Apple Push Notifications service (APNs)**, then continue and download the `.p8` file. Apple only lets you download it once.
3. Copy the `.p8` to the server, readable only by the account ReelHouse runs as. For example:
   ```bash
   scp AuthKey_ABC123DEFG.p8 you@your-server:ReelHouse/server/ReelHouse.Server/data/
   ```
   ```bash
   ssh you@your-server chmod 600 ReelHouse/server/ReelHouse.Server/data/AuthKey_ABC123DEFG.p8
   ```
4. In the PUSH NOTIFICATIONS section, enter:
   - **Team ID:** shown under Membership.
   - **Key ID:** the 10 characters in the file's name.
   - **Key File:** the file's name, if it's in the data folder, or its full path.

One key works for every app in the team, so the same key can serve SentinelCore and ReelHouse. **Bundle ID** stays `com.reelhouse.client` unless you build the app under your own identifier.

Apple has two delivery systems:
- **sandbox**, for apps installed from Xcode;
- **production**, for apps from TestFlight or the App Store.

The app tells the server which one it is. If Apple disagrees, the server tries the other one and remembers the answer, so there is no switch for this.

**Google (for Android)**: a Firebase project that the Android app is registered in.
1. Go to console.firebase.google.com and open or create a project.
2. Go to **Project settings → General → Your apps → Add app → Android**. Enter the package name `com.reelhouse.android`, then download `google-services.json`. It's needed to *build* the Android app (see below); it isn't a server file.
3. Go to **Project settings → Service accounts → Generate new private key**. Copy that `.json` to the server, `chmod 600`, like the Apple key.
4. Enter the **Project ID** (Project settings → General) and the **Service Account File**.


### Issuing licenses (for the seller)

ReelHouse licenses are made with SentinelCore's license generator (`SentinelCore/core/LicenseGenerator.Gui`), with the same signing key. Set **Product** to `ReelHouse`: the ReelHouse server only accepts that product, and the push service uses it to send to the ReelHouse apps rather than SentinelCore's. A license is perpetual and works on any machine. To cut one off from the push service (leaked, refunded), add its id to the relay's `Relay:BlockedLicenseIds`.

---

## For whoever builds the apps

### Server
Nothing extra to install. The code:

| File | What's in it |
|---|---|
| `PushSenders.cs` | Apple (`ApnsSender`, HTTP/2 + ES256 JWT) and Google (`FcmSender`, FCM HTTP v1 + service-account OAuth). The message shape (`PushMessage`), the type names (`PushTypes`) and the Android channels. |
| `PushNotifications.cs` | The settings section (`PushNotificationSettingsDto`), the registered devices (`PushDeviceStore` → `data/push-devices.db`), and `PushNotifier`. `PushNotifier` decides who gets what, picks each platform's route (`RoutesAsync`: own keys → `Direct`, else license + push service → `Relay`, else `None`), and handles Apple's sandbox/production and dead tokens. |
| `PushRelay.cs` | `PushRelayClient`: the push service's API (`/v1/devices`, `/v1/devices/unregister`, `/v1/push`), with the license file base64 in the `X-Sentinel-License` header. A device the service doesn't know is registered and the push retried once. ReelHouse's fields go in the message's `data`, with `androidChannel` and `threadId` beside it. |
| `Licensing.cs` | `LicenseStore` (`data/license.lic`, verified with the embedded public key, Product must be `ReelHouse`) and `/api/license/status` + `/api/license/install`. |
| `PushEndpoints.cs` | The API below. |
| `PodcastService.cs` (`PodcastPushNotifier`), `MediaDownloadManager.cs` (`NotifyFinishedAsync`), `LoginAlertSender.cs`, `OwnerNotifier.cs`, `AudioAlarms.cs` (`AudioNotifier`) | Where each kind of notification starts. |

Tests are in `ReelHouse.Tests/PushNotificationTests.cs`. Apple and Google are faked, but the signing code runs with throwaway keys.

**API** (every route needs a signed-in session, or login off):

| Route | Body / answer |
|---|---|
| `POST /api/push/devices` | `{ platform: "apple"\|"android", token, deviceName, appVariant: "ios"\|"tvos"\|"android", apnsSandbox }`. Registers the phone to the signed-in user. Safe to repeat; apps call it on every launch. |
| `POST /api/push/devices/unregister` | `{ platform, token }`. Apps call it on sign-out. |
| `GET /api/push/status` | `{ enabled, appleConfigured, androidConfigured, appleRoute, androidRoute, licensed, myDevices, newEpisodes, downloads, loginAlerts, serverAlerts, wakeAlarms, problems[] }`. Routes are `direct`, `relay` or `none`. |
| `GET /api/license/status` | `{ valid, customerName, product, issuedAt }` (any signed-in user). |
| `POST /api/license/install` | The raw `.lic` contents (admin). 400 `{ error }` for anything that isn't a genuine ReelHouse license. |
| `POST /api/push/test` | Sends to the caller's own devices: `{ attempted, delivered, failed, removed, message }`, or 400 `{ error }`. |
| `PUT /api/settings/push` | The settings section (admin). |

**What a notification carries**

Apple: an `aps.alert` (title, body) plus three extra keys:
- `type`: `podcast`, `download`, `login`, `server`, `alarm` or `test`;
- `itemId`: the episode id, or the movie/show id in the library;
- `podcastId`: the show, for an episode.

Google: sent to the app's Firebase Installation ID (`message.fid`), with a `notification` block, the same three keys plus `title`/`body` in `data`, and `android.notification.channel_id`, which is one of:
- `new_episodes`
- `downloads`
- `account` (sign-in and server problems)
- `general`

**Logs:** `journalctl -u reelhouse | grep -i push` shows every send, for example `Push (Downloads) "Dune (2024)": 1/1 delivered`. It also shows Apple's or Google's reason for any refusal, and each dead registration it dropped.

### iPhone app (`ios/`)
- The push entitlement (`aps-environment`) is in `ReelHouse/ReelHouse-iOS.entitlements`. Xcode turns on the Push Notifications capability for `com.reelhouse.client` itself when it signs with automatic signing (`-allowProvisioningUpdates`). The signing team must be the one the server's APNs key belongs to.
- An Xcode/devicectl install registers a *sandbox* token, and a TestFlight/App Store build a production one. The app reads which from its provisioning profile, and the server corrects it if Apple disagrees.
- Push doesn't work in the Simulator unless you drag an `.apns` file onto it. Test on a real phone.

### Android app (`android/`)
- The app registers with FCM by Firebase Installation ID (`FirebaseMessaging.register()`, delivered to `onRegistered`), the same scheme as SentinelCore's app, and the server and push service send to it as `fid`.
- Put the project's `google-services.json` in `android/app/` before building. Without it the app still builds and runs, but push is off and its Settings screen says "Push isn't set up in this build". The file isn't secret; it identifies the Firebase project and isn't a key that can send.
- The Gradle plugin `com.google.gms.google-services` is applied only when the file is there, so CI and other machines build without it.
- The server's Firebase project must be the same project this file came from.

### Apple TV app (`appletv/`)
tvOS can't show notification banners, so the TV app doesn't sign up for push and has no push
entitlement (adding one would also need a TV provisioning profile with Push in it). The server
skips any device registered as `tvos` regardless.
