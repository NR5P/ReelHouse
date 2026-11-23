' Unit tests for the channel's pure helpers (components/lib/Util.brs and Mappers.brs).
' Runs off-device under the brs interpreter - see scripts/test.sh:
'   npx -y brs components/lib/Util.brs components/lib/Mappers.brs tests/run_tests.brs
' Prints one line per failure and a summary; the last line is "ALL PASSED" when clean.

sub Main()
    m.passed = 0
    m.failed = 0

    testNormalizeServer()
    testSubnet()
    testUrls()
    testCookies()
    testErrors()
    testFormatting()
    testMediaMapping()
    testMusicMapping()
    testPodcastMapping()
    testHomeRows()

    print "passed: "; m.passed; "  failed: "; m.failed
    if m.failed = 0 then print "ALL PASSED" else print "FAILURES"
end sub

sub check(name as string, actual as dynamic, expected as dynamic)
    if type(actual) = type(expected) or (rh_isNumber(actual) and rh_isNumber(expected)) or (rh_isString(actual) and rh_isString(expected)) then
        if actual = expected then
            m.passed = m.passed + 1
            return
        end if
    end if
    m.failed = m.failed + 1
    print "FAIL "; name; ": expected ["; expected; "] got ["; actual; "]"
end sub

sub testNormalizeServer()
    check("bare ip", rh_normalizeServer("192.168.1.20"), "http://192.168.1.20:3350")
    check("ip spaces", rh_normalizeServer("  192.168.1.20  "), "http://192.168.1.20:3350")
    check("ip port", rh_normalizeServer("192.168.1.20:8080"), "http://192.168.1.20:8080")
    check("http no port", rh_normalizeServer("http://NAS.local"), "http://nas.local:3350")
    check("http port path", rh_normalizeServer("http://192.168.1.20:3350/movies?x=1"), "http://192.168.1.20:3350")
    check("https own port", rh_normalizeServer("https://192.168.1.20:3453"), "http://192.168.1.20:3350")
    check("https no port", rh_normalizeServer("HTTPS://192.168.1.20/"), "http://192.168.1.20:3350")
    check("https proxy", rh_normalizeServer("https://media.example.com:443"), "https://media.example.com:443")
    check("empty", rh_normalizeServer(""), "")
    check("junk", rh_normalizeServer("hello world"), "")
    check("bad port", rh_normalizeServer("192.168.1.20:99999"), "")
    check("other scheme", rh_normalizeServer("ftp://x"), "")
    check("double dot", rh_normalizeServer("192..1"), "")
    check("invalid", rh_normalizeServer(invalid), "")
    check("display", rh_displayServer("http://192.168.1.20:3350"), "192.168.1.20:3350")
end sub

sub testSubnet()
    hosts = rh_subnetCandidates("192.168.1.50", 3350)
    check("subnet count", hosts.Count(), 253)
    check("subnet first", hosts[0], "http://192.168.1.1:3350")
    check("subnet last", hosts[252], "http://192.168.1.254:3350")
    found = false
    for each h in hosts
        if h = "http://192.168.1.50:3350" then found = true
    end for
    check("subnet skips self", found, false)
    check("subnet loopback", rh_subnetCandidates("127.0.0.1", 3350).Count(), 0)
    check("subnet link-local", rh_subnetCandidates("169.254.3.4", 3350).Count(), 0)
    check("subnet junk", rh_subnetCandidates("fe80::1", 3350).Count(), 0)
    check("prefix", rh_subnetPrefix("10.0.0.7"), "10.0.0.")
end sub

sub testUrls()
    s = "http://192.168.1.20:3350"
    check("abs rel", rh_absUrl(s, "/api/media/home"), "http://192.168.1.20:3350/api/media/home")
    check("abs noslash", rh_absUrl(s, "api/x"), "http://192.168.1.20:3350/api/x")
    check("abs passthrough", rh_absUrl(s, "https://image.tmdb.org/a.jpg"), "https://image.tmdb.org/a.jpg")
    check("abs empty", rh_absUrl(s, ""), "")
    check("abs invalid", rh_absUrl(s, invalid), "")
    check("query sorted", rh_queryString({ sort: "title", kind: "movie", limit: 60, offset: 0 }), "kind=movie&limit=60&offset=0&sort=title")
    check("query skips empty", rh_queryString({ q: "", kind: "show" }), "kind=show")
    check("query bool", rh_queryString({ list: true }), "list=true")
    check("encode", rh_urlEncode("Fleetwood Mac & co/x"), "Fleetwood%20Mac%20%26%20co%2Fx")
    check("encode utf8", rh_urlEncode("Beyoncé"), "Beyonc%C3%A9")
    check("encode csv", rh_urlEncode("h264,hevc"), "h264%2Chevc")
    check("build", rh_buildUrl(s, "/api/media/items", { kind: "movie" }), "http://192.168.1.20:3350/api/media/items?kind=movie")
    check("build existing query", rh_buildUrl(s, "/api/x?a=1", { b: "2" }), "http://192.168.1.20:3350/api/x?a=1&b=2")
    check("build no query", rh_buildUrl(s, "/api/health", invalid), "http://192.168.1.20:3350/api/health")
    check("withParam", rh_withParam("http://h/a", "size", "400"), "http://h/a?size=400")
    check("withParam amp", rh_withParam("http://h/a?x=1", "size", "400"), "http://h/a?x=1&size=400")
    check("withParam keeps", rh_withParam("http://h/a?size=100", "size", "400"), "http://h/a?size=100")
end sub

sub testCookies()
    name = "reelhouse_session"
    headers = [
        { "content-type": "application/json" }
        { "set-cookie": "other=1; path=/" }
        { "Set-Cookie": "reelhouse_session=CfDJ8abc-_x; expires=Tue, 22 Dec 2026 10:00:00 GMT; path=/; samesite=lax; httponly" }
    ]
    check("cookie found", rh_sessionCookieFromHeaders(headers, name), "reelhouse_session=CfDJ8abc-_x")
    check("cookie absent", rh_sessionCookieFromHeaders([{ "content-type": "text/plain" }], name), invalid)
    check("cookie deleted", rh_sessionCookieFromHeaders([{ "set-cookie": "reelhouse_session=; expires=Thu, 01 Jan 1970 00:00:00 GMT; path=/" }], name), "")
    check("cookie max-age 0", rh_parseSetCookie("reelhouse_session=abc; Max-Age=0", name), "")
    check("cookie other", rh_parseSetCookie("x=1", name), invalid)
    check("cookie headers invalid", rh_sessionCookieFromHeaders(invalid, name), invalid)
end sub

sub testErrors()
    check("error field", rh_errorMessage(404, { error: "Movies & TV is turned off in Settings." }, ""), "Movies & TV is turned off in Settings.")
    check("errors list", rh_errorMessage(400, { errors: ["a", "b"] }, ""), "a" + Chr(10) + "b")
    check("401", rh_errorMessage(401, invalid, ""), "This server requires you to sign in.")
    check("unreachable", rh_errorMessage(-7, invalid, "Couldn't connect to server"), "Can't reach the server: Couldn't connect to server")
    check("generic", rh_errorMessage(500, invalid, ""), "Server request failed (HTTP 500).")
end sub

sub testFormatting()
    check("clock m:ss", rh_formatClock(245), "4:05")
    check("clock h", rh_formatClock(3723.9), "1:02:03")
    check("clock invalid", rh_formatClock(invalid), "0:00")
    check("minutes", rh_minutesLabel(102), "1h 42m")
    check("minutes short", rh_minutesLabel(48), "48m")
    check("minutes zero", rh_minutesLabel(0), "")
    check("decimal", rh_oneDecimal(6.19999), "6.2")
    check("decimal whole", rh_oneDecimal(7), "7.0")
    check("numStr int", rh_numStr(12), "12")
    check("numStr float", rh_numStr(6.5), "6.5")
    ' Str() turns these into "1.226835e+08" on a real Roku.
    check("numStr big int", rh_numStr(122683500), "122683500")
    check("intStr big int", rh_intStr(122683500), "122683500")
    check("intStr big double", rh_intStr(7200000.0#), "7200000")
    check("join", rh_join(["a", "", "b", invalid], " · "), "a · b")
    check("shortDate", rh_shortDate("2026-03-04T10:00:00Z"), "Mar 4, 2026")
end sub

sub testMediaMapping()
    movie = ParseJson("{""id"":""m1"",""kind"":""movie"",""title"":""17 Again"",""year"":2009,""rating"":6.2,""certification"":""PG-13"",""runtimeMinutes"":102,""posterUrl"":""/api/media/items/m1/poster"",""backdropUrl"":""/api/media/items/m1/backdrop"",""thumbUrl"":null,""progress"":{""positionSeconds"":1200,""durationSeconds"":6120,""percent"":19.6,""watched"":false}}")
    t = rh_mediaTile(movie, "poster")
    check("movie kind", t.kind, "movie")
    check("movie art", t.art, "/api/media/items/m1/poster?size=400")
    check("movie subtitle", t.subtitle, "2009")
    check("movie progress", Int(t.progress * 1000), 196)
    check("movie meta", rh_mediaMetaLine(movie), "2009 · 1h 42m · 6.2/10 · PG-13")
    check("movie resume", rh_mediaResumeSeconds(movie), 1200)
    w = rh_mediaTile(movie, "wide")
    check("wide art falls back to backdrop", w.art, "/api/media/items/m1/backdrop?size=600")

    ep = ParseJson("{""id"":""e1"",""kind"":""episode"",""title"":""The National Anthem"",""showId"":""s1"",""showTitle"":""Black Mirror"",""seasonNumber"":1,""episodeNumber"":1,""thumbUrl"":""/api/media/items/e1/thumb"",""posterUrl"":""/api/media/items/s1/poster"",""progress"":null,""runtimeMinutes"":44}")
    t = rh_mediaTile(ep, "wide")
    check("episode headline", t.title, "Black Mirror")
    check("episode sub", t.subtitle, "S1 · E1 · The National Anthem")
    check("episode thumb", t.art, "/api/media/items/e1/thumb?size=600")
    check("episode no progress", t.progress, -1)
    row = rh_episodeRow(ep)
    check("episode row title", row.title, "E1 · The National Anthem")
    check("episode row right", row.right, "44m")

    watched = ParseJson("{""id"":""m2"",""kind"":""movie"",""title"":""X"",""progress"":{""positionSeconds"":0,""percent"":100,""watched"":true}}")
    check("watched no bar", rh_mediaTile(watched, "poster").progress, -1)
    check("watched flag", rh_mediaTile(watched, "poster").watched, true)
    check("watched no resume", rh_mediaResumeSeconds(watched), 0)

    show = ParseJson("{""id"":""s1"",""kind"":""show"",""title"":""Black Mirror"",""year"":2011,""seasonCount"":2,""episodeCount"":10,""watchedEpisodeCount"":3,""seasons"":[{""number"":2,""episodes"":[{""id"":""e9"",""kind"":""episode"",""title"":""B"",""episodeNumber"":1}]},{""number"":1,""name"":""Season One"",""episodes"":[{""id"":""e1"",""kind"":""episode"",""title"":""A"",""episodeNumber"":1}]},{""number"":0,""episodes"":[]}]}")
    check("show meta", rh_mediaMetaLine(show), "2011 · 2 seasons")
    check("show unwatched", rh_mediaTile(show, "poster").subtitle, "2011 · 7 unwatched")
    seasons = rh_seasonList(show)
    check("seasons sorted", seasons[0].title, "Specials")
    check("season named", seasons[1].title, "Season One")
    check("season default", seasons[2].title, "Season 2")
    check("season of episode", rh_seasonIndexOf(seasons, "e9"), 2)

    q = rh_playbackQuery(-1, "h264,hevc", "aac,ac3")
    check("playback resume has no start", q.DoesExist("start"), false)
    q = rh_playbackQuery(0, "h264", "aac")
    check("playback start over", q.start, 0)
    check("playback qs", rh_queryString(rh_playbackQuery(95.7, "h264", "aac")), "audio=aac&segments=ts&start=95&video=h264")

    hls = { mode: "hls", url: "/api/media/hls/abc/master.m3u8", startSeconds: 1200 }
    direct = { mode: "direct", url: "/api/media/stream/m1/video.mp4", startSeconds: 1200 }
    check("hls format", rh_videoStreamFormat(hls), "hls")
    check("direct format", rh_videoStreamFormat(direct), "mp4")
    check("hls offset", rh_playbackOffset(hls), 1200)
    check("direct offset", rh_playbackOffset(direct), 0)
end sub

sub testMusicMapping()
    s = "http://10.0.0.2:3350"
    album = ParseJson("{""id"":""a1"",""title"":""Rumours"",""artist"":""Fleetwood Mac"",""year"":1977,""artUrl"":""/api/music/albums/a1/art""}")
    t = rh_albumTile(album)
    check("album sub", t.subtitle, "Fleetwood Mac · 1977")
    check("album art sized", t.art, "/api/music/albums/a1/art?size=400")
    track = ParseJson("{""id"":""t1"",""title"":""Dreams"",""artist"":""Fleetwood Mac"",""album"":""Rumours"",""trackNumber"":2,""durationSeconds"":257.8,""codec"":""flac"",""artUrl"":""/api/music/albums/a1/art"",""streamUrl"":""/api/music/tracks/t1/stream""}")
    q = rh_trackQueueItem(track, s, "mp3,aac,flac")
    check("track url", q.url, "http://10.0.0.2:3350/api/music/tracks/t1/stream?codecs=mp3%2Caac%2Cflac")
    check("track flac kept", q.format, "flac")
    check("track art", q.art, "http://10.0.0.2:3350/api/music/albums/a1/art?size=600")
    check("track subtitle", q.subtitle, "Fleetwood Mac · Rumours")
    q = rh_trackQueueItem(track, s, "mp3,aac")
    check("track transcoded", q.format, "mp4")
    check("mp3 format", rh_trackStreamFormat("MP3", "mp3,aac"), "mp3")
    row = rh_trackRow(track, false)
    check("track row index", row.index, "2")
    check("track row time", row.right, "4:17")
    pl = ParseJson("{""id"":""p1"",""name"":""Road Trip"",""trackCount"":42,""mine"":false,""ownerName"":""morgan"",""artUrls"":[""/api/music/albums/x/art""]}")
    t = rh_playlistTile(pl)
    check("playlist sub", t.subtitle, "42 tracks · morgan")
    check("playlist art", t.art, "/api/music/albums/x/art?size=400")
end sub

sub testPodcastMapping()
    s = "http://10.0.0.2:3350"
    ep = ParseJson("{""id"":""p9"",""podcastTitle"":""The Daily"",""title"":""Ep"",""publishedAt"":""2026-11-20T05:00:00Z"",""durationSeconds"":1800,""mimeType"":""audio/mpeg"",""audioUrl"":""/api/podcasts/episodes/p9/audio"",""artUrl"":""/api/podcasts/episodes/p9/art"",""progress"":{""positionSeconds"":600,""durationSeconds"":1800,""played"":false}}")
    q = rh_episodeQueueItem(ep, s)
    check("ep url", q.url, "http://10.0.0.2:3350/api/podcasts/episodes/p9/audio")
    check("ep format", q.format, "mp3")
    check("ep resume", q.resume, 600)
    row = rh_podEpisodeRow(ep)
    check("ep row sub", row.subtitle, "Nov 20, 2026 · 20m left")
    check("ep row right", row.right, "30m")
    check("m4a", rh_episodeStreamFormat("audio/x-m4a"), "mp4")
    played = ParseJson("{""id"":""p8"",""progress"":{""positionSeconds"":1700,""played"":true}}")
    check("played no resume", rh_episodeQueueItem(played, s).resume, 0)
    pod = ParseJson("{""id"":""c1"",""title"":""The Daily"",""author"":""NYT"",""unplayedCount"":3,""artUrl"":""/api/podcasts/c1/art""}")
    check("podcast sub", rh_podcastTile(pod).subtitle, "3 new")
end sub

sub testHomeRows()
    data = {
        mediaEnabled: true
        musicEnabled: false
        podcastsEnabled: true
        mediaHome: ParseJson("{""continueWatching"":[{""id"":""m1"",""kind"":""movie"",""title"":""A""}],""recentMovies"":[],""myList"":null}")
        movies: ParseJson("{""items"":[{""id"":""m1"",""kind"":""movie"",""title"":""A""}],""total"":1}")
        shows: invalid
        podcastHome: invalid
        podcasts: ParseJson("[{""id"":""c1"",""title"":""Pod""}]")
    }
    rows = rh_homeRows(data)
    titles = []
    for each r in rows
        titles.Push(r.title)
    end for
    check("home rows", rh_join(titles, "|"), "Continue Watching|Movies|Your Podcasts|Browse")
    check("movies see-all", rows[1].tiles[1].id, "allMovies")
    browse = rows[3].tiles
    check("browse first", browse[0].id, "allMovies")
    check("browse last", browse[browse.Count() - 1].id, "settings")
    check("health yes", rh_isReelHouseHealth({ status: "ok", product: "ReelHouse" }), true)
    check("health no", rh_isReelHouseHealth({ status: "ok" }), false)
    check("build display", rh_buildLabel(ParseJson("{""build"":{""version"":""1.4.0"",""display"":""1.4.0 (abc123)""}}")), "1.4.0 (abc123)")
    check("build missing", rh_buildLabel({ product: "ReelHouse" }), "")
end sub
