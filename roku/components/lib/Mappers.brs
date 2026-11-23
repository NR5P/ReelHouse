' ReelHouse for Roku - the server's JSON (MOVIES.md, MUSIC_AND_PODCASTS.md) turned into what the
' screens draw: tiles, list rows, Home's rows, audio queue entries and playback parameters.
'
' Pure functions over plain objects (needs Util.brs); Ui.brs turns the results into ContentNodes.
' tests/run_tests.brs runs these under the brs interpreter.
'
' A tile is { kind, id, title, subtitle, art, progress, shape, watched, raw }:
'   kind     movie | show | episode | album | artist | playlist | mix | podcast | podEpisode |
'            track | action
'   art      a server path ("/api/...") or absolute URL; "" draws a text card
'   progress 0..1 of the way through, or -1 for no bar
'   shape    poster (2:3) | wide (16:9) | square
'   raw      the JSON object it came from

' Server art always comes sized (rh_sizedArt), which also gets a baseline JPEG: Roku can't draw
' progressive JPEGs, and many posters and podcast covers are progressive. A size the caller
' already put on the URL is kept.
function rh_tile(kind as string, id as string, title as string, subtitle as string, art as string, shape as string) as object
    size = 400
    if shape = "wide" then size = 600
    return { kind: kind, id: id, title: title, subtitle: subtitle, art: rh_sizedArt(art, size), progress: -1, shape: shape, watched: false, raw: invalid }
end function

' ---------------------------------------------------------------- Movies & TV

' 0..1 through an item, or -1 when watched or never started (MediaModels.swift MediaProgress).
function rh_mediaFraction(progress as dynamic) as dynamic
    if not rh_isAA(progress) then return -1
    if rh_getBool(progress, "watched") then return -1
    percent = rh_getNum(progress, "percent", 0)
    if percent > 0 then
        f = percent / 100
        if f > 1 then f = 1
        return f
    end if
    position = rh_getNum(progress, "positionSeconds", 0)
    duration = rh_getNum(progress, "durationSeconds", 0)
    if duration > 0 and position > 0 then
        f = position / duration
        if f > 1 then f = 1
        return f
    end if
    return -1
end function

function rh_mediaIsWatched(item as dynamic) as boolean
    return rh_getBool(rh_get(item, "progress"), "watched")
end function

' Started and not finished: there is a place to resume from.
function rh_mediaResumeSeconds(item as dynamic) as dynamic
    progress = rh_get(item, "progress")
    if not rh_isAA(progress) or rh_getBool(progress, "watched") then return 0
    return rh_getNum(progress, "positionSeconds", 0)
end function

' "S1 · E3"
function rh_episodeCode(item as dynamic) as string
    season = rh_get(item, "seasonNumber")
    episode = rh_get(item, "episodeNumber")
    if not rh_isNumber(season) or not rh_isNumber(episode) then return ""
    return "S" + rh_intStr(season) + " · E" + rh_intStr(episode)
end function

' "2009 · 1h 42m · 6.2/10 · PG-13" (a show says its seasons instead of a runtime).
function rh_mediaMetaLine(item as dynamic) as string
    parts = []
    year = rh_get(item, "year")
    if rh_isNumber(year) then
        if year > 0 then parts.Push(rh_intStr(year))
    end if
    kind = rh_getStr(item, "kind")
    seasons = rh_getNum(item, "seasonCount", 0)
    if kind = "show" and seasons > 0 then
        if seasons = 1 then
            parts.Push("1 season")
        else
            parts.Push(rh_intStr(seasons) + " seasons")
        end if
    else
        runtime = rh_getNum(item, "runtimeMinutes", 0)
        if runtime <= 0 then runtime = rh_getNum(item, "durationSeconds", 0) / 60
        parts.Push(rh_minutesLabel(runtime))
    end if
    rating = rh_getNum(item, "rating", 0)
    if rating > 0 then parts.Push(rh_oneDecimal(rating) + "/10")
    parts.Push(rh_getStr(item, "certification"))
    return rh_join(parts, " · ")
end function

' An ItemSummary as a tile. `shape` wide draws the episode still or backdrop (Continue Watching).
function rh_mediaTile(item as dynamic, shape as string) as object
    kind = rh_getStr(item, "kind", "movie")
    title = rh_getStr(item, "title")
    subtitle = ""
    if kind = "episode" then
        title = rh_getStr(item, "showTitle", title)
        subtitle = rh_join([rh_episodeCode(item), rh_getStr(item, "title")], " · ")
    else
        year = rh_get(item, "year")
        if rh_isNumber(year) then
            if year > 0 then subtitle = rh_intStr(year)
        end if
        if kind = "show" then
            remaining = rh_getNum(item, "episodeCount", 0) - rh_getNum(item, "watchedEpisodeCount", 0)
            if remaining > 0 and rh_getNum(item, "watchedEpisodeCount", 0) > 0 then subtitle = rh_join([subtitle, rh_intStr(remaining) + " unwatched"], " · ")
        end if
    end if
    art = rh_getStr(item, "posterUrl")
    if shape = "wide" then
        art = rh_getStr(item, "thumbUrl", rh_getStr(item, "backdropUrl", art))
    end if
    t = rh_tile(kind, rh_getStr(item, "id"), title, subtitle, art, shape)
    t.progress = rh_mediaFraction(rh_get(item, "progress"))
    t.watched = rh_mediaIsWatched(item)
    t.raw = item
    return t
end function

' An episode under its season on a show's page: "E3 · Title", with its still and progress.
function rh_episodeRow(ep as dynamic) as object
    number = rh_get(ep, "episodeNumber")
    title = rh_getStr(ep, "title")
    if rh_isNumber(number) then title = "E" + rh_intStr(number) + " · " + title
    runtime = rh_getNum(ep, "runtimeMinutes", 0)
    if runtime <= 0 then runtime = rh_getNum(ep, "durationSeconds", 0) / 60
    status = ""
    if rh_mediaIsWatched(ep) then
        status = "Watched"
    else if rh_mediaResumeSeconds(ep) > 0 then
        status = "Resume at " + rh_formatClock(rh_mediaResumeSeconds(ep))
    end if
    row = rh_tile("episode", rh_getStr(ep, "id"), title, rh_join([rh_getStr(ep, "airDate"), status], " · "), rh_getStr(ep, "thumbUrl"), "wide")
    row.detail = rh_getStr(ep, "overview")
    row.right = rh_minutesLabel(runtime)
    row.progress = rh_mediaFraction(rh_get(ep, "progress"))
    row.watched = rh_mediaIsWatched(ep)
    row.raw = ep
    return row
end function

' Seasons of a show detail, sorted by number, each { number, title, episodes: [row] }.
function rh_seasonList(detail as dynamic) as object
    seasons = []
    for each s in rh_getArr(detail, "seasons")
        number = rh_getNum(s, "number", 0)
        title = rh_getStr(s, "name")
        if title = "" then
            if number = 0 then
                title = "Specials"
            else
                title = "Season " + rh_intStr(number)
            end if
        end if
        rows = []
        for each ep in rh_getArr(s, "episodes")
            rows.Push(rh_episodeRow(ep))
        end for
        seasons.Push({ number: number, title: title, episodes: rows })
    end for
    ' Insertion sort: a handful of seasons.
    for i = 1 to seasons.Count() - 1
        j = i
        while j > 0 and seasons[j - 1].number > seasons[j].number
            tmp = seasons[j - 1]
            seasons[j - 1] = seasons[j]
            seasons[j] = tmp
            j = j - 1
        end while
    end for
    return seasons
end function

' Index into `seasons` of the season holding episode `episodeId`, else 0.
function rh_seasonIndexOf(seasons as object, episodeId as string) as integer
    for i = 0 to seasons.Count() - 1
        for each row in seasons[i].episodes
            if row.id = episodeId then return i
        end for
    end for
    return 0
end function

' The playback request's query (MOVIES.md, Playback). start < 0 resumes from the saved position.
'' segments=ts: when the server repackages a file it sends MPEG-TS, not fMP4 - Roku plays the
' video of the server's fMP4 sessions but finds no audio in them (AAC and Dolby alike).
function rh_playbackQuery(start as dynamic, videoCodecs as string, audioCodecs as string) as object
    q = { video: videoCodecs, audio: audioCodecs, segments: "ts" }
    if rh_isNumber(start) then
        if start >= 0 then q.start = Int(start)
    end if
    return q
end function

' How a Video node should be told about a playback answer's stream.
function rh_videoStreamFormat(playback as dynamic) as string
    if rh_getStr(playback, "mode") = "hls" then return "hls"
    url = LCase(rh_getStr(playback, "url"))
    q = Instr(1, url, "?")
    if q > 0 then url = Left(url, q - 1)
    if Right(url, 4) = ".mkv" then return "mkv"
    if Right(url, 5) = ".m3u8" then return "hls"
    return "mp4"
end function

' The film's own clock for a player position: an HLS session's time 0 is the film at
' startSeconds; a direct file is the whole film.
function rh_playbackOffset(playback as dynamic) as dynamic
    if rh_getStr(playback, "mode") = "hls" then return rh_getNum(playback, "startSeconds", 0)
    return 0
end function

' ---------------------------------------------------------------- Music

' Album and artist art at the size a tile draws it (the server downscales /api/ art on request).
function rh_sizedArt(path as string, size as integer) as string
    if path = "" or not rh_startsWith(path, "/api/") then return path
    return rh_withParam(path, "size", Str(size).Trim())
end function

function rh_albumTile(album as dynamic) as object
    subtitle = rh_getStr(album, "artist")
    year = rh_getNum(album, "year", 0)
    if year > 0 then subtitle = rh_join([subtitle, rh_intStr(year)], " · ")
    t = rh_tile("album", rh_getStr(album, "id"), rh_getStr(album, "title"), subtitle, rh_sizedArt(rh_getStr(album, "artUrl"), 400), "square")
    t.raw = album
    return t
end function

function rh_artistTile(artist as dynamic) as object
    count = rh_getNum(artist, "albumCount", 0)
    subtitle = ""
    if count = 1 then
        subtitle = "1 album"
    else if count > 1 then
        subtitle = rh_intStr(count) + " albums"
    end if
    t = rh_tile("artist", rh_getStr(artist, "id"), rh_getStr(artist, "name"), subtitle, rh_sizedArt(rh_getStr(artist, "artUrl"), 400), "square")
    t.raw = artist
    return t
end function

function rh_firstArt(obj as dynamic) as string
    for each a in rh_getArr(obj, "artUrls")
        if rh_isString(a) then
            if a <> "" then return a
        end if
    end for
    return rh_getStr(obj, "artUrl")
end function

function rh_playlistTile(playlist as dynamic) as object
    count = rh_getNum(playlist, "trackCount", 0)
    subtitle = rh_intStr(count) + " tracks"
    if count = 1 then subtitle = "1 track"
    if rh_getBool(playlist, "smart") then subtitle = "Smart playlist"
    owner = rh_getStr(playlist, "ownerName")
    if owner <> "" and not rh_getBool(playlist, "mine") then subtitle = rh_join([subtitle, owner], " · ")
    t = rh_tile("playlist", rh_getStr(playlist, "id"), rh_getStr(playlist, "name"), subtitle, rh_sizedArt(rh_firstArt(playlist), 400), "square")
    t.raw = playlist
    return t
end function

function rh_mixTile(mix as dynamic) as object
    t = rh_tile("mix", rh_getStr(mix, "id"), rh_getStr(mix, "name"), rh_getStr(mix, "description"), rh_sizedArt(rh_firstArt(mix), 400), "square")
    t.raw = mix
    return t
end function

' A track as a row of an album, playlist or artist page.
function rh_trackRow(track as dynamic, showAlbum as boolean) as object
    subtitle = rh_getStr(track, "artist")
    if showAlbum then subtitle = rh_join([subtitle, rh_getStr(track, "album")], " · ")
    title = rh_getStr(track, "title")
    number = rh_get(track, "trackNumber")
    row = rh_tile("track", rh_getStr(track, "id"), title, subtitle, rh_sizedArt(rh_getStr(track, "artUrl"), 160), "square")
    if not showAlbum and rh_isNumber(number) then row.index = rh_intStr(number)
    row.right = rh_formatClock(rh_getNum(track, "durationSeconds", 0))
    row.raw = track
    return row
end function

' The music stream's Roku stream format: what the server sends is the original when its codec is
' in our list, else AAC in an .m4a.
function rh_trackStreamFormat(codec as string, codecs as string) as string
    c = LCase(codec)
    if not rh_contains(rh_csv(codecs), c) then return "mp4"
    if c = "mp3" then return "mp3"
    if c = "flac" then return "flac"
    if c = "wav" or c = "pcm" then return "wav"
    return "mp4"
end function

' A track as an entry of the player's queue (all URLs absolute).
function rh_trackQueueItem(track as dynamic, server as string, codecs as string) as object
    id = rh_getStr(track, "id")
    stream = rh_getStr(track, "streamUrl", "/api/music/tracks/" + id + "/stream")
    return {
        type: "track"
        id: id
        title: rh_getStr(track, "title")
        subtitle: rh_join([rh_getStr(track, "artist"), rh_getStr(track, "album")], " · ")
        art: rh_absUrl(server, rh_sizedArt(rh_getStr(track, "artUrl"), 600))
        url: rh_withParam(rh_absUrl(server, stream), "codecs", codecs)
        format: rh_trackStreamFormat(rh_getStr(track, "codec"), codecs)
        duration: rh_getNum(track, "durationSeconds", 0)
        resume: 0
    }
end function

' ---------------------------------------------------------------- Podcasts

function rh_podcastTile(podcast as dynamic) as object
    unplayed = rh_getNum(podcast, "unplayedCount", 0)
    subtitle = rh_getStr(podcast, "author")
    if unplayed > 0 then subtitle = rh_intStr(unplayed) + " new"
    t = rh_tile("podcast", rh_getStr(podcast, "id"), rh_getStr(podcast, "title"), subtitle, rh_getStr(podcast, "artUrl"), "square")
    t.raw = podcast
    return t
end function

function rh_podFraction(progress as dynamic) as dynamic
    if not rh_isAA(progress) or rh_getBool(progress, "played") then return -1
    return rh_mediaFraction(progress)
end function

function rh_podEpisodeTile(ep as dynamic) as object
    t = rh_tile("podEpisode", rh_getStr(ep, "id"), rh_getStr(ep, "title"), rh_getStr(ep, "podcastTitle"), rh_getStr(ep, "artUrl"), "square")
    t.progress = rh_podFraction(rh_get(ep, "progress"))
    t.watched = rh_getBool(rh_get(ep, "progress"), "played")
    t.raw = ep
    return t
end function

' "Mar 4, 2026" from an ISO-8601 instant.
function rh_shortDate(iso as string) as string
    if Len(iso) < 10 then return ""
    months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    month = Val(Mid(iso, 6, 2))
    day = Val(Mid(iso, 9, 2))
    if month < 1 or month > 12 or day < 1 then return ""
    return months[month - 1] + " " + Str(day).Trim() + ", " + Left(iso, 4)
end function

function rh_podEpisodeRow(ep as dynamic) as object
    progress = rh_get(ep, "progress")
    status = ""
    if rh_getBool(progress, "played") then
        status = "Played"
    else if rh_getNum(progress, "positionSeconds", 0) > 0 then
        remaining = rh_getNum(ep, "durationSeconds", 0) - rh_getNum(progress, "positionSeconds", 0)
        if remaining > 0 then status = rh_minutesLabel(remaining / 60) + " left"
    end if
    subtitle = rh_join([rh_shortDate(rh_getStr(ep, "publishedAt")), status], " · ")
    row = rh_tile("podEpisode", rh_getStr(ep, "id"), rh_getStr(ep, "title"), subtitle, rh_getStr(ep, "artUrl"), "square")
    row.detail = rh_getStr(ep, "summary")
    row.right = rh_minutesLabel(rh_getNum(ep, "durationSeconds", 0) / 60)
    row.progress = rh_podFraction(progress)
    row.watched = rh_getBool(progress, "played")
    row.raw = ep
    return row
end function

function rh_episodeStreamFormat(mimeType as string) as string
    mime = LCase(mimeType)
    if Instr(1, mime, "mp4") > 0 or Instr(1, mime, "m4a") > 0 or Instr(1, mime, "aac") > 0 then return "mp4"
    if Instr(1, mime, "flac") > 0 then return "flac"
    if Instr(1, mime, "wav") > 0 then return "wav"
    return "mp3"
end function

' A podcast episode as a queue entry; `resume` is where to pick it up (0 from the top).
function rh_episodeQueueItem(ep as dynamic, server as string) as object
    id = rh_getStr(ep, "id")
    progress = rh_get(ep, "progress")
    resume = 0
    if not rh_getBool(progress, "played") then resume = rh_getNum(progress, "positionSeconds", 0)
    return {
        type: "episode"
        id: id
        title: rh_getStr(ep, "title")
        subtitle: rh_getStr(ep, "podcastTitle")
        art: rh_absUrl(server, rh_sizedArt(rh_getStr(ep, "artUrl"), 600))
        url: rh_absUrl(server, rh_getStr(ep, "audioUrl", "/api/podcasts/episodes/" + id + "/audio"))
        format: rh_episodeStreamFormat(rh_getStr(ep, "mimeType"))
        duration: rh_getNum(ep, "durationSeconds", 0)
        resume: resume
    }
end function

' ---------------------------------------------------------------- Home

function rh_actionTile(id as string, title as string, subtitle as string) as object
    return rh_tile("action", id, title, subtitle, "", "action")
end function

function rh_row(title as string, shape as string, tiles as object) as object
    return { title: title, shape: shape, tiles: tiles }
end function

function rh_mediaRow(title as string, shape as string, items as object) as object
    tiles = []
    for each item in items
        if rh_isAA(item) then tiles.Push(rh_mediaTile(item, shape))
    end for
    return rh_row(title, shape, tiles)
end function

' Home's rows, empty ones left out. `data` holds whatever each request returned (invalid for a
' request that failed or a section that is off):
'   mediaHome, movies, shows (MediaItemsPage), musicHome, playlists ([Playlist]),
'   podcastHome, podcasts ([Podcast]), plus the flags mediaEnabled, musicEnabled,
'   podcastsEnabled and audioActive.
function rh_homeRows(data as object) as object
    rows = []
    media = rh_getBool(data, "mediaEnabled")
    music = rh_getBool(data, "musicEnabled")
    pods = rh_getBool(data, "podcastsEnabled")
    mediaHome = rh_get(data, "mediaHome")
    musicHome = rh_get(data, "musicHome")
    podHome = rh_get(data, "podcastHome")

    if media then rows.Push(rh_mediaRow("Continue Watching", "wide", rh_getArr(mediaHome, "continueWatching")))
    if pods then
        tiles = []
        for each ep in rh_getArr(podHome, "continueListening")
            tiles.Push(rh_podEpisodeTile(ep))
        end for
        rows.Push(rh_row("Continue Listening", "square", tiles))
    end if
    if media then
        rows.Push(rh_mediaRow("My List", "poster", rh_getArr(mediaHome, "myList")))
        rows.Push(rh_mediaRow("Recently Added Movies", "poster", rh_getArr(mediaHome, "recentMovies")))
        rows.Push(rh_mediaRow("Recently Added TV", "poster", rh_getArr(mediaHome, "recentShows")))
        rows.Push(rh_mediaRow("New Episodes", "wide", rh_getArr(mediaHome, "recentEpisodes")))
        movies = rh_mediaRow("Movies", "poster", rh_getArr(rh_get(data, "movies"), "items"))
        if movies.tiles.Count() > 0 then movies.tiles.Push(rh_actionTile("allMovies", "All Movies", "Browse everything"))
        rows.Push(movies)
        shows = rh_mediaRow("TV Shows", "poster", rh_getArr(rh_get(data, "shows"), "items"))
        if shows.tiles.Count() > 0 then shows.tiles.Push(rh_actionTile("allShows", "All TV Shows", "Browse everything"))
        rows.Push(shows)
    end if
    if music then
        tiles = []
        for each album in rh_getArr(musicHome, "recentlyAdded")
            tiles.Push(rh_albumTile(album))
        end for
        if tiles.Count() > 0 then tiles.Push(rh_actionTile("albums", "All Albums", "Browse music"))
        rows.Push(rh_row("Recently Added Music", "square", tiles))
        tiles = []
        for each mix in rh_getArr(musicHome, "mixes")
            tiles.Push(rh_mixTile(mix))
        end for
        rows.Push(rh_row("Mixes for You", "square", tiles))
        tiles = []
        seen = {}
        for each list in [rh_getArr(musicHome, "pinned"), rh_getArr(data, "playlists")]
            for each p in list
                id = rh_getStr(p, "id")
                if id <> "" and not seen.DoesExist(id) then
                    seen[id] = true
                    tiles.Push(rh_playlistTile(p))
                end if
            end for
        end for
        rows.Push(rh_row("Playlists", "square", tiles))
    end if
    if pods then
        tiles = []
        for each p in rh_getArr(data, "podcasts")
            tiles.Push(rh_podcastTile(p))
        end for
        rows.Push(rh_row("Your Podcasts", "square", tiles))
        tiles = []
        for each ep in rh_getArr(podHome, "newEpisodes")
            tiles.Push(rh_podEpisodeTile(ep))
        end for
        rows.Push(rh_row("New Podcast Episodes", "square", tiles))
    end if

    browse = []
    if rh_getBool(data, "audioActive") then browse.Push(rh_actionTile("nowPlaying", "Now Playing", "Back to the player"))
    if media then
        browse.Push(rh_actionTile("allMovies", "Movies", "Every movie"))
        browse.Push(rh_actionTile("allShows", "TV Shows", "Every show"))
    end if
    if music then
        browse.Push(rh_actionTile("albums", "Albums", "Your music"))
        browse.Push(rh_actionTile("artists", "Artists", "Your music"))
        browse.Push(rh_actionTile("playlists", "Playlists", "Yours and shared"))
        browse.Push(rh_actionTile("shuffleAll", "Shuffle All", "Music, shuffled"))
    end if
    if pods then browse.Push(rh_actionTile("podcasts", "Podcasts", "Shows you follow"))
    browse.Push(rh_actionTile("settings", "Settings", "Server and account"))
    rows.Push(rh_row("Browse", "action", browse))

    out = []
    for each r in rows
        if r.tiles.Count() > 0 then out.Push(r)
    end for
    return out
end function

' Whether an /api/health answer is a ReelHouse server.
function rh_isReelHouseHealth(data as dynamic) as boolean
    return rh_getStr(data, "product") = "ReelHouse"
end function

' The server's version out of /api/health: build is { version, commit, isDirty, display }.
function rh_buildLabel(data as dynamic) as string
    build = rh_get(data, "build")
    if rh_isString(build) then return build
    return rh_getStr(build, "display", rh_getStr(build, "version"))
end function
