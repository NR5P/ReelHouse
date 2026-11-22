# ReelHouse

A self-hosted home media server: your own **movies and TV, music and podcasts**, with
**torrent downloads** ("+ Add") through a VPN, streamed to every device in the house.

| Part | Folder | Built with |
|---|---|---|
| Server and web UI | [server/](server/README.md) | ASP.NET (.NET 10), plain JS |
| iPhone, iPad and Mac app | [ios/](ios/README.md) | SwiftUI |
| Apple TV app | [appletv/](appletv/README.md) | SwiftUI (tvOS) |
| Android app | [android/](android/README.md) | Kotlin, Jetpack Compose |

Every app connects to the same server. They find it on the local network by themselves
(Bonjour/mDNS `_reelhouse._tcp`), or you type its address: `http://<server>:3350`, or
`https://<server>:3453`.

Phones can get **push notifications**: a new podcast episode, a download that finished, a
failed sign-in. How to turn them on, and what the server and app builds need:
[server/docs/PUSH.md](server/docs/PUSH.md).

## Quick start

```bash
cd server/ReelHouse.Server && dotnet run
```

Then open http://localhost:3350, create the admin account, and add a Movies, TV or Music
library in Settings. For a permanent Linux install and the torrent download stack, see
[server/README.md](server/README.md).

ReelHouse is the media part of SentinelCore, split out into its own product. It has the same
API and features, minus everything that wasn't media.
