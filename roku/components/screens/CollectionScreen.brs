' CollectionScreen - see CollectionScreen.xml.

sub init()
    m.art = m.top.findNode("art")
    m.kicker = m.top.findNode("kicker")
    m.title = m.top.findNode("title")
    m.subtitle = m.top.findNode("subtitle")
    m.message = m.top.findNode("message")
    m.list = m.top.findNode("list")
    m.list.observeField("itemSelected", "onRowSelected")
    m.buttons = m.top.findNode("buttons")
    rh_styleButtons(m.buttons)
    m.buttons.minWidth = 420
    m.buttons.maxWidth = 420
    m.buttons.observeField("buttonSelected", "onButton")
    m.rows = []
    m.tracks = []
    m.episodes = []
    m.actions = []
    m.top.observeField("params", "onParams")
    m.top.observeField("revisit", "onRevisit")
    m.top.observeField("focusedChild", "onFocusChanged")
    m.top.observeField("closing", "onClosing")
end sub

sub onParams()
    p = m.top.params
    m.kind = rh_getStr(p, "kind")
    m.id = rh_getStr(p, "id")
    m.autoPlay = rh_getBool(p, "autoPlay")
    m.title.text = rh_getStr(p, "title")
    kickers = { album: "ALBUM", playlist: "PLAYLIST", artist: "ARTIST", mix: "MIX", shuffle: "SHUFFLE ALL", podcast: "PODCAST" }
    m.kicker.text = rh_getStr(kickers, m.kind)
    ' Draw what the tile already knew while the full list loads.
    raw = rh_get(p, "raw")
    if rh_isAA(raw) then
        art = rh_getStr(raw, "artUrl")
        if art = "" then art = rh_firstArt(raw)
        m.art.uri = rh_absUrl(m.global.serverUrl, rh_sizedArt(art, 420))
    end if
    if m.kind = "podcast" then
        m.list.itemSize = [1244, 132]
        m.list.numRows = 6
        m.top.findNode("header").hint = "OK plays an episode"
    end if
    load()
end sub

sub onRevisit()
    ' Episode progress moves as you listen.
    if m.kind = "podcast" then load()
end sub

sub onFocusChanged()
    if m.top.hasFocus() then
        if m.rows.Count() > 0 and not m.buttons.isInFocusChain() then
            m.list.setFocus(true)
        else
            m.buttons.setFocus(true)
        end if
    end if
end sub

sub onClosing()
    rh_cancelRequests()
end sub

sub load()
    if m.kind = "album" then
        rh_api("GET", "/api/music/albums/" + m.id, invalid, onLoaded)
    else if m.kind = "playlist" then
        rh_api("GET", "/api/music/playlists/" + m.id, invalid, onLoaded)
    else if m.kind = "artist" then
        rh_api("GET", "/api/music/artists/" + m.id, invalid, onLoaded)
    else if m.kind = "mix" then
        rh_api("GET", "/api/music/mix", { query: { mix: m.id }, timeout: 30000 }, onLoaded)
    else if m.kind = "shuffle" then
        rh_api("GET", "/api/music/shuffle", { query: { limit: 200 }, timeout: 30000 }, onLoaded)
    else if m.kind = "podcast" then
        rh_api("GET", "/api/podcasts/" + m.id, invalid, onPodcast)
        rh_api("GET", "/api/podcasts/" + m.id + "/episodes", { query: { sort: "newest", limit: 100 } }, onEpisodes)
    end if
end sub

' ---------------------------------------------------------------- music

sub onLoaded(resp as object)
    if not resp.ok then
        m.message.text = resp.error
        setButtons([])
        return
    end if
    d = resp.data
    server = m.global.serverUrl
    trackList = []
    if rh_isArray(d) then
        trackList = d
    else if m.kind = "artist" then
        trackList = rh_getArr(d, "topTracks")
    else
        trackList = rh_getArr(d, "tracks")
    end if

    showAlbum = m.kind <> "album"
    m.tracks = trackList
    m.rows = []
    for each t in trackList
        m.rows.Push(rh_trackRow(t, showAlbum))
    end for
    if m.kind = "artist" then
        for each album in rh_getArr(d, "albums")
            row = rh_albumTile(album)
            row.right = "Album"
            row.art = rh_sizedArt(rh_getStr(album, "artUrl"), 160)
            m.rows.Push(row)
        end for
        for each album in rh_getArr(d, "appearsOn")
            row = rh_albumTile(album)
            row.right = "Appears on"
            row.art = rh_sizedArt(rh_getStr(album, "artUrl"), 160)
            m.rows.Push(row)
        end for
    end if

    ' Header: cover, name and a summary line.
    if m.kind = "album" then
        m.title.text = rh_getStr(d, "title")
        m.subtitle.text = rh_join([rh_getStr(d, "artist"), yearText(d), countText(trackList.Count(), "track"), rh_minutesLabel(rh_getNum(d, "durationSeconds", 0) / 60)], " · ")
        m.art.uri = rh_absUrl(server, rh_sizedArt(rh_getStr(d, "artUrl"), 420))
    else if m.kind = "playlist" then
        m.title.text = rh_getStr(d, "name")
        m.subtitle.text = rh_join([rh_getStr(d, "description"), countText(trackList.Count(), "track"), rh_getStr(d, "ownerName")], " · ")
        m.art.uri = rh_absUrl(server, rh_sizedArt(rh_firstArt(d), 420))
    else if m.kind = "artist" then
        m.title.text = rh_getStr(d, "name")
        m.subtitle.text = rh_join([countText(rh_getNum(d, "albumCount", 0), "album"), countText(rh_getNum(d, "trackCount", 0), "track")], " · ")
        m.art.uri = rh_absUrl(server, rh_sizedArt(rh_getStr(d, "artUrl"), 420))
    else
        name = rh_getStr(d, "name")
        if name <> "" then m.title.text = name
        m.subtitle.text = countText(trackList.Count(), "track")
        if trackList.Count() > 0 and m.art.uri = "" then m.art.uri = rh_absUrl(server, rh_sizedArt(rh_getStr(trackList[0], "artUrl"), 420))
    end if

    m.list.content = rh_listContent(m.rows, server)
    if m.rows.Count() = 0 then
        m.message.text = "Nothing to play here."
    else
        m.message.text = ""
    end if

    actions = []
    if m.tracks.Count() > 0 then
        if m.kind = "artist" then
            actions.Push({ label: "Play Top Tracks", id: "play" })
        else
            actions.Push({ label: "Play", id: "play" })
        end if
        actions.Push({ label: "Shuffle", id: "shuffle" })
    end if
    if m.kind = "artist" then actions.Push({ label: "Artist Radio", id: "radio" })
    setButtons(actions)

    if m.autoPlay and m.tracks.Count() > 0 then
        m.autoPlay = false
        playTracks(m.tracks, 0, false)
    end if
end sub

function yearText(d as object) as string
    year = rh_getNum(d, "year", 0)
    if year > 0 then return rh_intStr(year)
    return ""
end function

function countText(n as dynamic, noun as string) as string
    if not rh_isNumber(n) then return ""
    if n <= 0 then return ""
    if n = 1 then return "1 " + noun
    return rh_intStr(n) + " " + noun + "s"
end function

sub setButtons(actions as object)
    m.actions = actions
    labels = []
    for each a in actions
        labels.Push(a.label)
    end for
    m.buttons.buttons = labels
    m.buttons.visible = labels.Count() > 0
end sub

function context() as object
    return { "type": m.kind, "id": m.id, "name": m.title.text }
end function

sub playTracks(tracks as object, index as integer, shuffled as boolean)
    server = m.global.serverUrl
    codecs = m.global.musicCodecs
    queue = []
    for each t in tracks
        queue.Push(rh_trackQueueItem(t, server, codecs))
    end for
    if shuffled then
        ' Fisher-Yates.
        for i = queue.Count() - 1 to 1 step -1
            j = Rnd(i + 1) - 1
            tmp = queue[i]
            queue[i] = queue[j]
            queue[j] = tmp
        end for
        index = 0
    end if
    m.top.action = { type: "playAudio", queue: queue, index: index, context: context() }
end sub

sub onButton()
    i = m.buttons.buttonSelected
    if i < 0 or i >= m.actions.Count() then return
    id = m.actions[i].id
    if id = "play" then
        if m.kind = "podcast" then
            playLatestEpisode()
        else
            playTracks(m.tracks, 0, false)
        end if
    else if id = "shuffle" then
        playTracks(m.tracks, 0, true)
    else if id = "radio" then
        m.message.text = "Starting radio..."
        rh_api("GET", "/api/music/mix", { query: { "seedType": "artist", "seedId": m.id, "limit": 50 }, timeout: 30000 }, onRadio)
    end if
end sub

sub onRadio(resp as object)
    m.message.text = ""
    if not resp.ok then
        m.message.text = resp.error
        return
    end if
    tracks = rh_getArr(resp.data, "tracks")
    if tracks.Count() > 0 then playTracks(tracks, 0, false)
end sub

sub onRowSelected()
    i = m.list.itemSelected
    if i < 0 or i >= m.rows.Count() then return
    row = m.rows[i]
    if row.kind = "track" then
        ' Tracks come first in the rows, in the same order as m.tracks.
        playTracks(m.tracks, i, false)
    else if row.kind = "album" then
        m.top.action = { type: "open", tile: row }
    else if row.kind = "podEpisode" then
        playEpisode(row.raw)
    end if
end sub

' ---------------------------------------------------------------- podcasts

sub onPodcast(resp as object)
    if not resp.ok then
        m.message.text = resp.error
        return
    end if
    d = resp.data
    m.title.text = rh_getStr(d, "title")
    unplayed = rh_getNum(d, "unplayedCount", 0)
    unplayedText = ""
    if unplayed > 0 then unplayedText = rh_intStr(unplayed) + " unplayed"
    m.subtitle.text = rh_join([rh_getStr(d, "author"), unplayedText], " · ")
    m.art.uri = rh_absUrl(m.global.serverUrl, rh_sizedArt(rh_getStr(d, "artUrl"), 420))
end sub

sub onEpisodes(resp as object)
    if not resp.ok then
        m.message.text = resp.error
        return
    end if
    m.episodes = rh_getArr(resp.data, "items")
    focused = m.list.itemFocused
    m.rows = []
    for each ep in m.episodes
        m.rows.Push(rh_podEpisodeRow(ep))
    end for
    m.list.content = rh_listContent(m.rows, m.global.serverUrl)
    if focused > 0 and focused < m.rows.Count() then m.list.jumpToItem = focused
    if m.rows.Count() = 0 then
        m.message.text = "No episodes yet."
        setButtons([])
    else
        m.message.text = ""
        setButtons([{ label: "Play Latest", id: "play" }])
    end if
end sub

' The newest episode not yet played (else the newest).
sub playLatestEpisode()
    if m.episodes.Count() = 0 then return
    for each ep in m.episodes
        if not rh_getBool(rh_get(ep, "progress"), "played") then
            playEpisode(ep)
            return
        end if
    end for
    playEpisode(m.episodes[0])
end sub

sub playEpisode(ep as object)
    m.top.action = { type: "playAudio", queue: [rh_episodeQueueItem(ep, m.global.serverUrl)], index: 0, context: context() }
end sub

function onKeyEvent(key as string, press as boolean) as boolean
    if not press then return false
    if key = "right" and m.buttons.isInFocusChain() and m.rows.Count() > 0 then
        m.list.setFocus(true)
        return true
    end if
    if key = "left" and m.list.isInFocusChain() and m.actions.Count() > 0 then
        m.buttons.setFocus(true)
        return true
    end if
    if key = "play" then
        if m.list.isInFocusChain() then
            i = m.list.itemFocused
            if i >= 0 and i < m.rows.Count() then
                row = m.rows[i]
                if row.kind = "track" then playTracks(m.tracks, i, false)
                if row.kind = "podEpisode" then playEpisode(row.raw)
                if row.kind = "album" then m.top.action = { type: "play", tile: row }
            end if
        else if m.kind = "podcast" then
            playLatestEpisode()
        else if m.tracks.Count() > 0 then
            playTracks(m.tracks, 0, false)
        end if
        return true
    end if
    return false
end function
