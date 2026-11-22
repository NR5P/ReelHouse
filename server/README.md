# ReelHouse server

One ASP.NET (.NET 10) process that holds the libraries and serves the web UI and the API every
ReelHouse app talks to.

- **Movies & TV**: folders on this machine or shared from another computer over SMB, TMDB
  artwork and details, direct play or HLS (ffmpeg repackages or transcodes), subtitles, resume,
  My List, imports of an IMDb/Letterboxd/Trakt list. See [docs/MOVIES.md](docs/MOVIES.md).
- **"+ Add" (torrent downloads)**: search with Prowlarr, download with qBittorrent, both inside
  a VPN-only network namespace that ReelHouse starts when someone searches and stops when idle;
  finished downloads are renamed into the right library. Works for movies, TV and music. See
  [docs/MOVIE_DOWNLOADS.md](docs/MOVIE_DOWNLOADS.md).
- **Music and Podcasts**: tags and cover art, playlists, loves, ratings, lyrics, radio and
  suggestions; podcast following from Apple's directory or a feed, auto-downloads, transcripts
  (whisper.cpp, optional), clips, bookmarks; one shared player with resume across devices,
  speakers, wake-up alarms, a morning briefing, listening stats and ListenBrainz. See
  [docs/MUSIC_AND_PODCASTS.md](docs/MUSIC_AND_PODCASTS.md).
- **Push notifications**: new podcast episodes, finished downloads, failed sign-ins and server
  problems on the iPhone and Android apps' lock screens. A licensed install sends through the
  ReelHouse push service (Settings → LICENSE); a self-built one can use its own Apple/Google keys
  (Settings → PUSH NOTIFICATIONS). See [docs/PUSH.md](docs/PUSH.md).
- **Accounts**: admin and viewer roles, cookie sign-in, an optional internet-facing port that
  always requires login, an HTTPS certificate made on first start, and LAN discovery
  (`_reelhouse._tcp`) so the apps find the server without typing an address.

## Ports and files

| | |
|---|---|
| HTTP | 3350 (`Urls` in `appsettings.json`, or Settings → SERVER ADDRESS) |
| HTTPS | 3453 (`Https:Port`), certificate authority downloadable at `/api/certificate-authority` |
| Internet exposed (off by default) | 3454 |
| Data | `data/` beside the program (`DataDirectory`): `media.db`, `music.db`, `podcasts.db`, `audio.db`, `accounts.db`, `push-devices.db`, `license.lic`, caches, `certs/`, `keys/` |
| Settings edited in the UI | `data/settings.json`, layered over `appsettings.json` |

Back up by stopping the server and copying `data/`.

## Running it

Requirements: the .NET 10 SDK and ffmpeg (`brew install dotnet ffmpeg` on a Mac,
`sudo apt install dotnet-sdk-10.0 ffmpeg` on Debian/Ubuntu).

```bash
cd server/ReelHouse.Server && dotnet run
```

Open http://localhost:3350 and create the admin account. The first account can only be
created from the local network.

On Linux, run it as a service, rebuilt and restarted with one command:

```bash
./scripts/install-linux.sh
```

Torrent downloads need Linux (they use systemd and a network namespace). They are a one-time
extra step that installs the VPN tunnel, qBittorrent and Prowlarr:

```bash
sudo ./downloads/install-downloads.sh
```

After that, turn on Settings → MOVIE DOWNLOADS and add torrent sites from the Movies tab's Downloads pane. On macOS and Windows everything else works, and "+ Add" can point at a qBittorrent and
Prowlarr you run yourself (Settings → MOVIE DOWNLOADS → Start And Stop The Services off).

## Tests

```bash
dotnet test server/ReelHouse.Tests
```

## Layout

- `ReelHouse.Server/`: the server; `wwwroot/` is the web UI.
- `ReelHouse.Tests/`: xUnit tests, including end-to-end ones against a real host.
- `downloads/`: the torrent stack installer and its systemd units.
- `systemd/`, `scripts/`: the service unit, the Linux installer, the icon generator.
- `docs/`: how each feature works and its API.
