' HomeScreen - see HomeScreen.xml.
'
' Loads in two waves: which sections the server has on (/api/media/enabled, /api/audio/enabled),
' then each enabled section's lists, all at once. The rows are built when the last answer is in
' (Mappers.brs rh_homeRows), and rebuilt each time Home comes back to the top so progress bars
' and Continue Watching are current after the player closes.

sub init()
    m.rows = m.top.findNode("rows")
    m.message = m.top.findNode("message")
    m.rows.observeField("rowItemSelected", "onSelected")
    m.loadSeq = 0
    m.pending = 0
    m.data = {}
    m.failure = ""
    m.top.observeField("params", "onParams")
    m.top.observeField("revisit", "onRevisit")
    m.top.observeField("focusedChild", "onFocusChanged")
    m.top.observeField("closing", "onClosing")
end sub

sub onParams()
    load()
end sub

sub onRevisit()
    load()
end sub

sub onFocusChanged()
    if m.top.hasFocus() then m.rows.setFocus(true)
end sub

sub onClosing()
    rh_cancelRequests()
end sub

sub load()
    m.loadSeq = m.loadSeq + 1
    if m.rows.content = invalid then m.message.text = "Loading your library..."
    player = m.global.player
    m.data = { audioActive: player <> invalid and player.active }
    m.failure = ""
    m.pending = 2
    rh_api("GET", "/api/media/enabled", { tag: m.loadSeq }, onMediaEnabled)
    rh_api("GET", "/api/audio/enabled", { tag: m.loadSeq }, onAudioEnabled)
end sub

function isCurrent(resp as object) as boolean
    tag = resp.tag
    if rh_isAA(tag) then tag = tag.seq
    return tag = m.loadSeq
end function

sub request(name as string, path as string, query as object)
    m.pending = m.pending + 1
    rh_api("GET", path, { query: query, tag: { seq: m.loadSeq, name: name }, timeout: 30000 }, onPart)
end sub

sub onMediaEnabled(resp as object)
    if not isCurrent(resp) then return
    ' A 404 is an older server or the section switched off: no Movies & TV, not an error.
    enabled = resp.ok and rh_getBool(resp.data, "enabled")
    if resp.status < 0 then m.failure = resp.error
    m.data.mediaEnabled = enabled
    m.global.mediaEnabled = enabled
    if enabled then
        request("mediaHome", "/api/media/home", {})
        request("movies", "/api/media/items", { kind: "movie", sort: "added", limit: 30 })
        request("shows", "/api/media/items", { kind: "show", sort: "added", limit: 30 })
    end if
    partDone()
end sub

sub onAudioEnabled(resp as object)
    if not isCurrent(resp) then return
    music = resp.ok and rh_getBool(resp.data, "music")
    pods = resp.ok and rh_getBool(resp.data, "podcasts")
    if resp.status < 0 then m.failure = resp.error
    m.data.musicEnabled = music
    m.data.podcastsEnabled = pods
    m.global.musicEnabled = music
    m.global.podcastsEnabled = pods
    if music then
        request("musicHome", "/api/music/home", {})
        request("playlists", "/api/music/playlists", {})
    end if
    if pods then
        request("podcastHome", "/api/podcasts/home", {})
        request("podcasts", "/api/podcasts", {})
    end if
    partDone()
end sub

sub onPart(resp as object)
    if not isCurrent(resp) then return
    if resp.ok then m.data[resp.tag.name] = resp.data
    partDone()
end sub

sub partDone()
    m.pending = m.pending - 1
    if m.pending <= 0 then render()
end sub

sub render()
    rows = rh_homeRows(m.data)
    anything = rh_getBool(m.data, "mediaEnabled") or rh_getBool(m.data, "musicEnabled") or rh_getBool(m.data, "podcastsEnabled")
    if m.failure <> "" and not anything then
        m.message.text = m.failure + Chr(10) + "Press OK on Settings to change the server, or Back to exit."
    else if rows.Count() <= 1 then
        m.message.text = "Nothing here yet. Add a Movies, TV, Music or Podcasts library in the server's web dashboard (Settings), then come back."
    else
        m.message.text = ""
    end if

    focus = m.rows.rowItemFocused
    sizes = []
    heights = []
    for each r in rows
        size = rh_shapeSize(r.shape)
        sizes.Push(size)
        heights.Push(size[1] + 72)
    end for
    m.rows.rowItemSize = sizes
    m.rows.rowHeights = heights
    m.rows.content = rh_rowListContent(rows, m.global.serverUrl)
    ' Put focus back where it was before the refresh.
    if rh_isArray(focus) and focus.Count() = 2 and rows.Count() > 0 then
        row = focus[0]
        if row >= 0 and row < rows.Count() then
            col = focus[1]
            if col >= rows[row].tiles.Count() then col = rows[row].tiles.Count() - 1
            if col < 0 then col = 0
            m.rows.jumpToRowItem = [row, col]
        end if
    end if
end sub

function focusedTile() as dynamic
    content = m.rows.content
    focus = m.rows.rowItemFocused
    if content = invalid or not rh_isArray(focus) or focus.Count() <> 2 then return invalid
    row = content.getChild(focus[0])
    if row = invalid then return invalid
    return rh_nodeTile(row.getChild(focus[1]))
end function

sub onSelected()
    sel = m.rows.rowItemSelected
    content = m.rows.content
    if content = invalid or not rh_isArray(sel) then return
    row = content.getChild(sel[0])
    if row = invalid then return
    tile = rh_nodeTile(row.getChild(sel[1]))
    if tile <> invalid then m.top.action = { type: "open", tile: tile }
end sub

function onKeyEvent(key as string, press as boolean) as boolean
    if not press then return false
    if key = "options" then
        m.top.action = { type: "push", screen: "SettingsScreen", params: {} }
        return true
    end if
    if key = "play" then
        tile = focusedTile()
        if tile <> invalid and tile.kind <> "action" then
            m.top.action = { type: "play", tile: tile }
            return true
        end if
    end if
    return false
end function
