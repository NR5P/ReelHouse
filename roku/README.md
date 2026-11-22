# ReelHouse for Roku

A Roku channel for ReelHouse: your movies and TV, music and podcasts on a Roku. It is written
in plain BrightScript and SceneGraph XML, with no build step, so this folder is the channel.
It uses the same server API as the Apple TV app, which it follows screen by screen.

**Status:** first version. It passes static checks and its logic tests, but it has **not run on
a real Roku yet**. [What to check on a Roku](#what-to-check-on-a-real-roku) lists what only a
device can confirm.

## What it does

- **Connect.** It can scan the Roku's own network for ReelHouse servers, or you can type the
  address on the on-screen keyboard (`192.168.1.20` becomes `http://192.168.1.20:3350`). The
  chosen server is remembered.
- **Sign in.** You sign in with a username and password. Only the session cookie is kept, never
  the password. It works with Viewer accounts and with servers where sign-in is turned off.
- **Home** has these rows: Continue Watching, Continue Listening, My List, Recently Added Movies
  and TV, New Episodes, Movies, TV Shows, Recently Added Music, Mixes, Playlists, Your Podcasts
  and New Podcast Episodes. A Browse row lists every section, Now Playing and Settings. Rows for
  sections the server has turned off, and empty rows, are not shown.
- **Movies & TV.** Each title has a detail screen. A movie offers Resume and Play from
  Beginning, plus cast and file info. A show offers seasons, episodes and Play Next Episode. You
  can mark titles watched or unwatched and add or remove them from My List. There are grids of
  every movie and show, sortable with `*`.
  - Playback uses the server's direct-play MP4 or its ffmpeg HLS session. It resumes where you
    left off and reports progress every 10 s, on pause and on exit. When an episode ends, the
    next one starts.
- **Music.** You can browse albums, artists (top tracks, their albums and Artist Radio),
  playlists and mixes, and use Shuffle All. You can play a list from any track or shuffle it.
  The channel reports plays and skips back to the server.
- **Podcasts.** You can browse the shows you follow and their episodes. You can play the latest
  episode or any episode, and playback resumes where you stopped. Progress is reported every
  15 s, on pause and on exit.
- **Now Playing** works for music and podcasts. It has Previous/Next for music and Back 15 s /
  Ahead 30 s for podcasts. Audio keeps playing while you browse, and a "now playing" pill shows
  at the top of the screen. Press PLAY on any screen to go back to Now Playing. The channel also
  reports to `/api/audio/now-playing`, so your other devices can show "Playing on Living Room
  Roku".
- **Settings** shows the server, the account and the codecs this Roku can play. From there you
  can change server or sign out.

### Remote

| Button | Does |
|---|---|
| OK | Open a tile, choose a button, play a track or episode |
| PLAY/PAUSE | On a tile: start it right away (resume a movie, play an album). In the players: pause and resume. Anywhere else: open Now Playing while audio plays |
| `*` (Options) | Home: Settings. Grids: change the sort. Show episodes: mark watched/unwatched |
| REW / FF | Now Playing: previous/next track (music), back 15 s / ahead 30 s (podcasts) |
| Back | Go back one screen. Audio keeps playing. In the video player: stop, and save your place |

## What's in this folder

```
manifest                  channel name, version, art, FHD (1920x1080) layout
source/main.brs           entry point: global state (server, cookie, codecs), the event loop
components/
  MainScene.xml/.brs      sign-in flow, navigation stack, the now-playing pill
  screens/                ServerSetup, Login, Home, Grid, MediaDetail, VideoPlayer,
                          Collection (album/artist/playlist/mix/podcast), NowPlaying, Settings
  player/AudioPlayer      the one Audio node for music and podcasts, queue and reporting
  tasks/ApiTask           one HTTP request off the render thread (cookie in, cookie out)
  tasks/ScanTask          the LAN scan
  items/                  PosterItem (RowList/MarkupGrid tiles), ListRowItem (MarkupList rows)
  widgets/BrandHeader     the REELHOUSE header
  lib/Util.brs            pure helpers: addresses, URLs, cookies, formatting
  lib/Mappers.brs         pure: server JSON -> tiles, rows, queue entries, playback parameters
  lib/Net.brs Ui.brs Store.brs   requests, look and feel, registry
images/                   channel art and UI pieces (generated, see below)
scripts/                  package, sideload, keypress, screenshot, discover, lint, test, make_images
tests/run_tests.brs       unit tests for lib/Util.brs and lib/Mappers.brs (run off-device)
bsconfig.json             BrighterScript config, used for static checks only
```

## Developer mode

You can only install a channel from a zip file ("sideloading") after turning on developer mode,
once per Roku:

1. With the Roku remote, press **Home ×3, Up ×2, Right, Left, Right, Left, Right**.
   - Or from a computer on the same network: `scripts/keypress.sh <roku-ip> devmode`.
2. The Developer Settings screen shows the Roku's IP address. Choose **Enable installer and
   restart**, accept the agreement and set a **developer password**. The user name is always
   `rokudev`.
3. After the restart, `http://<roku-ip>/` is the Development Application Installer.

To find the Roku's IP address, look in Settings > Network > About, or run
`scripts/discover.sh`.

## Build, install, test

Everything runs from `roku/`.

```bash
python3 scripts/make_images.py            # (re)draws images/ - needs Pillow
scripts/test.sh                           # logic tests under the brs interpreter (Node.js)
scripts/lint.sh                           # BrighterScript static checks (Node.js); --next adds the 1.0 checker
scripts/package.sh                        # -> out/reelhouse-roku.zip   (--lint to check first)
scripts/sideload.sh 192.168.1.40 <pw>     # install on the Roku and launch it (re-packages if stale)
scripts/keypress.sh 192.168.1.40 Down Down Select
scripts/keypress.sh 192.168.1.40 --text "192.168.1.20"    # type into the on-screen keyboard
scripts/screenshot.sh 192.168.1.40 <pw> shot.png          # while the channel is running
scripts/discover.sh                        # SSDP: every Roku on the network, and its dev-mode state
```

- `sideload.sh` and `screenshot.sh` also read the password from `ROKU_DEV_PASSWORD`. They pass
  it to curl on stdin, so it doesn't show up in `ps`.
- `keypress.sh` uses ECP on port 8060, which has no password. If the Roku answers 403, set
  Settings > System > Advanced system settings > Control by mobile apps > Network access to
  *Default* or *Permissive*.
- Debug output (`print`, crashes and the BrightScript debugger) is on `telnet <roku-ip> 8085`.
  Watch it while you test. The SceneGraph inspector is on port 8080.

Static checks use the BrighterScript compiler only as a validator: the shipped files are the
plain `.brs` and `.xml` in this folder. A quick manual smoke test after `sideload.sh`:

1. Connect: scan, then select the server (or enter its address).
2. Sign in.
3. Home loads its rows and posters.
4. Play a movie: it resumes, Back saves your place, and Continue Watching updates.
5. Play a TV episode to the end: the next episode starts.
6. Play an album, then press Back: the now-playing pill shows.
7. Play a podcast episode, then quit and reopen the channel: the episode resumes.
8. Settings > Sign Out: you're back at sign-in.

## How it works

### Finding the server

A Roku has no mDNS or Bonjour API, so the channel cannot see the `_reelhouse._tcp` adverts the
other apps use. Instead, `ScanTask` does it the long way:

1. It reads the Roku's own IPv4 addresses (`roDeviceInfo.GetIPAddrs()`).
2. For each one, it asks the other 253 hosts on that /24 for `GET http://<host>:3350/api/health`.
3. It sends 32 requests at a time, each batch with a 1.5 s deadline. Hosts that are switched
   off never answer, so whatever hasn't answered by the deadline is cancelled.
4. It keeps the hosts that answer `"product": "ReelHouse"`.

A full /24 takes about 10–12 s. Servers appear in the list as they answer.

If the server is on another subnet, a bigger network than a /24, or a port other than 3350,
type its address instead. A typed address is checked against `/api/health` before it is saved.

The chosen address is saved in the registry (section `ReelHouse`, key `serverUrl`).

### HTTP, not HTTPS

The server's HTTPS port (3453) uses a certificate authority the server made itself, and a Roku
has no way to trust one. The channel therefore talks to the server's plain-HTTP port, 3350,
which the server keeps open on the LAN for exactly this kind of client. If you type
`https://host` or `https://host:3453`, the channel turns it into `http://host:3350`.

An `https://` address on any other port is kept as it is. That covers a reverse proxy with a
real certificate, which the Roku's CA bundle can verify.

### Signing in

The server uses a cookie session (`reelhouse_session`).

1. `GET /api/auth/status` decides where the channel starts:
   - `enabled: false`: sign-in is off on the server, so the channel goes straight to Home.
     Settings says so, and there is no Sign Out.
   - `authenticated: true`: Home.
   - Anything else: the sign-in screen. When `configured` is false, the screen says to create
     the admin account on the web dashboard first.
2. `POST /api/auth/login` sends `{ username, password }`.
3. `ApiTask` reads `Set-Cookie` from that response and from any later response, because the
   server renews the cookie on a sliding expiration. Each new cookie is saved to:
   - `m.global.cookie`, which every later request sends as a `Cookie` header;
   - the registry (`cookie`), for the next launch.

   The password is dropped as soon as the request is sent.
4. Any later 401 means the session has ended. The channel goes back to the sign-in screen.
5. `POST /api/auth/logout` clears the session. The cookie is forgotten whatever the server
   answers.

Streams and artwork need the cookie too:

- **Video and Audio nodes** get it in their content's `HttpHeaders`. Each has its own empty
  `roHttpAgent`, so the cookie is sent only once.
- **Posters and other artwork** get it from a header on the Scene's shared `roHttpAgent`.

### Playback

- **Video.** `GET /api/media/items/{id}/playback` asks for:
  - `video=h264`, plus `hevc` when `roDeviceInfo.CanDecodeVideo` says the Roku decodes it;
  - `audio=aac,mp3`, plus `ac3`/`eac3` when `CanDecodeAudio` says it can.

  Direct-play MP4s start at `startSeconds` (`PlayStart`). HLS sessions start at their own
  time 0, which is `startSeconds` in the film. Progress is always reported as
  `startSeconds + position`, as MOVIES.md requires. Direct-play WebVTT subtitles are added as
  side tracks; HLS sessions carry them in the master playlist. Captions follow the Roku's own
  caption setting.
- **Music.** Each track is `/api/music/tracks/{id}/stream?codecs=mp3,aac[,flac,alac,wav]`, with
  the list built from what `CanDecodeAudio` reports. The server converts anything else to AAC.
- **Podcasts.** Each episode is `/api/podcasts/episodes/{id}/audio`. Playback seeks to the saved
  position once it starts.

## Not in this version (compared with the Apple TV app)

- **Search:** none yet, for movies, music or podcasts.
- **Downloads and library management:**
  - no "+ Add" (torrent downloads) and no download lists;
  - no library and folder admin;
  - no podcast subscribe/unsubscribe or directory.

  Use the web dashboard or another app for these. The channel never calls admin routes.
- **Speakers and alarms:**
  - no "Play on…" speaker control;
  - the Roku doesn't register as a speaker, so other devices can't play to it;
  - no "Continue from another device" banner;
  - no wake alarms, morning briefing or listening stats.
- **Now Playing extras:** no lyrics, chapters, transcripts, bookmarks, sleep timer, playback
  speed or Sound Check.
- **Queue and repeat:** no repeat modes (shuffle is a one-time shuffle of the list) and no
  podcast Up Next queue.
- **Video tracks:** no audio-track or subtitle picker of its own (the server's default audio
  track is used). Captions come from the Roku's settings.
- **Connection:**
  - no mDNS, and no automatic HTTPS-to-HTTP fallback with certificate pinning. The channel
    simply never uses the self-signed port;
  - no advisory when the server is older than the channel expects.
- **Grid sorting:** `*` changes the sort order only; there are no genre or unwatched filters.

## What to check on a real Roku

None of this can be checked without a device. The likely fix is given for each item.

1. **Artwork shows up.**
   - Posters fetch from `/api/media/...` and `/api/music/...` routes, which need the session
     cookie. It is set on the Scene's shared HTTP agent (`MainScene.brs` `applyCookie`), and
     RowList and MarkupGrid item posters are expected to inherit it.
   - If tiles stay as text cards on a server with sign-in on, the agent isn't reaching them.
     Give each `Poster` an agent in `PosterItem`/`ListRowItem` instead.
2. **HLS plays from the start and can seek.**
   - The server's HLS playlist is an EVENT playlist. It grows until ffmpeg finishes and has
     `EXT-X-START:TIME-OFFSET=0`.
   - The Roku may treat it as live and start near the newest segment. The channel seeks back
     to 0 if the first position it sees is past 3 s.
   - Check that seeking works within what has been produced, and that the trick-play bar shows
     a sensible length (`content.Length` is set from the server's duration).
3. **fMP4 HLS with HEVC.** The server's segments are fMP4 (`init.mp4` + `.m4s`), and its master
   playlist has no `CODECS` or `RESOLUTION`. Recent Rokus play fMP4/CMAF HLS. Check H.264 on
   any Roku, and HEVC on a 4K model. If HEVC sessions fail, drop `hevc` in `source/main.brs`
   `VideoCodecs`; the server then transcodes to H.264.
4. **The cookie reaches HLS segments** through `content.HttpHeaders`. A 401 shows up as a
   playback error shortly after start.
5. **The keyboard dialogs.**
   - `StandardKeyboardDialog` needs Roku OS 10 or later; older firmware falls back to the
     classic `KeyboardDialog`.
   - Check that the password field masks input (`textEditBox.secureMode`).
6. **RowList layout.** Check the row heights and label spacing with the mixed tile shapes
   (poster, 16:9, square), and the gold focus frame.
7. **The LAN scan.**
   - Check how long it takes on Wi-Fi.
   - Check that 32 transfers at once is not too many for low-end models. Lower `batchSize` in
     `ScanTask.xml` if they struggle.
8. **The audio formats each model plays.** Check FLAC and ALAC originals, AAC `.m4a`
   conversions, and podcast MP3s relayed from their publisher.

### Server changes

None were needed for this version. The channel sends the session cookie as an ordinary header.
It uses HTTP on the LAN, where the server already serves everything. It asks for exactly the
codecs the Roku reports, and the server already converts the rest (AAC audio inside HLS, AAC
`.m4a` for music).

If item 1 or 3 above fails on hardware, these server changes would help:

- **For item 1:** an artwork URL that doesn't need the cookie, such as a signed query
  parameter.
- **For item 3:** `CODECS`/`RESOLUTION` on the master playlist's `EXT-X-STREAM-INF`.
