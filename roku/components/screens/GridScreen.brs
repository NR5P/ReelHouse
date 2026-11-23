' GridScreen - see GridScreen.xml.

sub init()
    m.title = m.top.findNode("title")
    m.count = m.top.findNode("count")
    m.grid = m.top.findNode("grid")
    m.message = m.top.findNode("message")
    m.grid.observeField("itemSelected", "onSelected")
    m.grid.observeField("itemFocused", "onFocused")
    m.config = invalid
    m.sortIndex = 0
    m.loaded = 0
    m.total = -1
    m.loading = false
    m.seq = 0
    m.top.observeField("params", "onParams")
    m.top.observeField("revisit", "onRevisit")
    m.top.observeField("focusedChild", "onFocusChanged")
    m.top.observeField("closing", "onClosing")
end sub

' What each kind lists, how, and in which orders.
function gridConfig(kind as string) as object
    if kind = "movies" or kind = "shows" then
        mediaKind = "movie"
        if kind = "shows" then mediaKind = "show"
        return { path: "/api/media/items", query: { kind: mediaKind }, paged: true, shape: "poster", columns: 7,
            sorts: ["title", "added", "year", "rating", "plays"], sortNames: ["Title", "Recently Added", "Year", "Rating", "Most Played"] }
    else if kind = "albums" then
        return { path: "/api/music/albums", query: {}, paged: true, shape: "square", columns: 6,
            sorts: ["title", "artist", "year", "added", "plays"], sortNames: ["Title", "Artist", "Year", "Recently Added", "Most Played"] }
    else if kind = "artists" then
        return { path: "/api/music/artists", query: { "albumArtistsOnly": "true" }, paged: true, shape: "square", columns: 6,
            sorts: ["name", "plays", "added"], sortNames: ["Name", "Most Played", "Recently Added"] }
    else if kind = "playlists" then
        return { path: "/api/music/playlists", query: {}, paged: false, shape: "square", columns: 6, sorts: [], sortNames: [] }
    end if
    return { path: "/api/podcasts", query: {}, paged: false, shape: "square", columns: 6, sorts: [], sortNames: [] }
end function

sub onParams()
    p = m.top.params
    m.kind = rh_getStr(p, "kind", "movies")
    m.config = gridConfig(m.kind)
    m.title.text = rh_getStr(p, "title")
    size = rh_shapeSize(m.config.shape)
    m.grid.itemSize = size
    m.grid.numColumns = m.config.columns
    ' Only the rows that fit on the screen: with more, focus moves onto a row below its bottom
    ' edge and the gold frame is drawn where nobody can see it.
    m.grid.numRows = rh_rowsThatFit(210, size[1], 24)
    if m.config.sorts.Count() > 0 then m.top.findNode("header").hint = "* Sort   PLAY starts"
    reload()
end sub

sub onRevisit()
    ' Progress and watched badges may have changed in the player; refresh what's on screen.
    if m.kind = "movies" or m.kind = "shows" or m.kind = "podcasts" then reload()
end sub

sub onFocusChanged()
    if m.top.hasFocus() then m.grid.setFocus(true)
end sub

sub onClosing()
    rh_cancelRequests()
end sub

sub reload()
    m.seq = m.seq + 1
    m.loaded = 0
    m.total = -1
    m.loading = false
    m.keepFocus = m.grid.itemFocused
    m.grid.content = CreateObject("roSGNode", "ContentNode")
    m.message.text = "Loading..."
    updateCount()
    loadMore()
end sub

sub loadMore()
    if m.loading then return
    if m.total >= 0 and m.loaded >= m.total then return
    query = {}
    query.Append(m.config.query)
    if m.config.sorts.Count() > 0 then query.sort = m.config.sorts[m.sortIndex]
    if m.config.paged then
        query.offset = m.loaded
        query.limit = 60
    end if
    m.loading = true
    rh_api("GET", m.config.path, { query: query, tag: m.seq, timeout: 30000 }, onPage)
end sub

sub onPage(resp as object)
    if resp.tag <> m.seq then return
    m.loading = false
    if not resp.ok then
        if m.loaded = 0 then m.message.text = resp.error
        m.total = m.loaded
        return
    end if
    items = []
    if rh_isArray(resp.data) then
        items = resp.data
        m.total = m.loaded + items.Count()
    else
        items = rh_getArr(resp.data, "items")
        m.total = rh_getNum(resp.data, "total", m.loaded + items.Count())
        if items.Count() = 0 then m.total = m.loaded
    end if
    if not m.config.paged then m.total = m.loaded + items.Count()

    root = m.grid.content
    server = m.global.serverUrl
    for each item in items
        root.appendChild(rh_tileNode(tileFor(item), server))
    end for
    m.loaded = m.loaded + items.Count()
    if m.loaded = 0 then
        m.message.text = "Nothing here yet."
    else
        m.message.text = ""
    end if
    updateCount()
    if m.keepFocus > 0 and m.keepFocus < m.loaded then
        m.grid.jumpToItem = m.keepFocus
        m.keepFocus = -1
    end if
end sub

function tileFor(item as object) as object
    if m.kind = "movies" or m.kind = "shows" then return rh_mediaTile(item, "poster")
    if m.kind = "albums" then return rh_albumTile(item)
    if m.kind = "artists" then return rh_artistTile(item)
    if m.kind = "playlists" then return rh_playlistTile(item)
    return rh_podcastTile(item)
end function

sub updateCount()
    text = ""
    if m.total > 0 then text = rh_intStr(m.total) + " items"
    if m.config <> invalid and m.config.sorts.Count() > 0 then text = rh_join([text, "Sorted by " + m.config.sortNames[m.sortIndex]], " · ")
    m.count.text = text
end sub

sub onFocused()
    ' Two rows from the end: fetch the next page.
    if m.config.paged and m.grid.itemFocused >= m.loaded - m.config.columns * 2 then loadMore()
end sub

function tileAt(i as integer) as dynamic
    root = m.grid.content
    if root = invalid or i < 0 then return invalid
    return rh_nodeTile(root.getChild(i))
end function

sub onSelected()
    tile = tileAt(m.grid.itemSelected)
    if tile <> invalid then m.top.action = { type: "open", tile: tile }
end sub

function onKeyEvent(key as string, press as boolean) as boolean
    if not press then return false
    if key = "options" and m.config.sorts.Count() > 0 then
        m.sortIndex = (m.sortIndex + 1) mod m.config.sorts.Count()
        m.keepFocus = -1
        reload()
        m.keepFocus = -1
        return true
    end if
    if key = "play" then
        tile = tileAt(m.grid.itemFocused)
        if tile <> invalid then
            m.top.action = { type: "play", tile: tile }
            return true
        end if
    end if
    return false
end function
