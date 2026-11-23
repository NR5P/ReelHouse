' MainScene - connection, sign-in, navigation and the shared audio player.
'
' Start-up: no saved server -> ServerSetupScreen. Otherwise GET /api/auth/status:
'   unreachable                      -> ServerSetupScreen, with the error and a Try Again button
'   login off (enabled=false)        -> Home (everyone is effectively signed in)
'   signed in (authenticated=true)   -> Home
'   otherwise                        -> LoginScreen
' Any request that later answers 401 sets m.global.authLost and lands back on LoginScreen.

sub init()
    m.colors = rh_colors()
    m.top.backgroundColor = m.colors.bg
    m.top.backgroundUri = ""
    m.screens = m.top.findNode("screens")
    m.status = m.top.findNode("status")
    m.statusText = m.top.findNode("statusText")
    m.spinner = m.top.findNode("spinner")
    m.spinner.poster.uri = "pkg:/images/spinner.png"
    m.spinner.poster.width = 96
    m.spinner.poster.height = 96
    m.miniPlayer = m.top.findNode("miniPlayer")
    m.miniText = m.top.findNode("miniText")
    m.player = m.top.findNode("player")
    m.global.player = m.player
    m.stack = []

    m.global.observeField("cookie", "onCookieChanged")
    m.global.observeField("authLost", "onAuthLost")
    m.player.observeField("current", "updateMiniPlayer")
    m.player.observeField("state", "updateMiniPlayer")

    applyCookie()
    connect()
end sub

' ---------------------------------------------------------------- session

' Posters and every other node that fetches from the server share the Scene's HTTP agent, so the
' session cookie goes on it. (The Video and Audio nodes get their own agent and send the cookie
' through their content's HttpHeaders instead - see VideoPlayerScreen and AudioPlayer.)
sub applyCookie()
    agent = m.top.getHttpAgent()
    if agent = invalid then return
    headers = {}
    if m.global.cookie <> "" then headers["Cookie"] = m.global.cookie
    agent.SetHeaders(headers)
end sub

sub onCookieChanged()
    applyCookie()
end sub

sub connect()
    server = m.global.serverUrl
    if server = "" then
        resetTo("ServerSetupScreen", {})
        return
    end if
    showStatus("Connecting to " + rh_displayServer(server) + "...")
    rh_api("GET", "/api/auth/status", { timeout: 10000 }, onAuthStatus)
end sub

sub onAuthStatus(resp as object)
    hideStatus()
    if not resp.ok then
        resetTo("ServerSetupScreen", { error: "Couldn't connect to " + rh_displayServer(m.global.serverUrl) + ". " + resp.error, canRetry: true })
        return
    end if
    data = resp.data
    m.global.authEnabled = rh_getBool(data, "enabled")
    if rh_getBool(data, "authenticated") then
        m.global.username = rh_getStr(data, "username")
        m.global.role = rh_getStr(data, "role")
        resetTo("HomeScreen", {})
        return
    end if
    message = ""
    if not rh_getBool(data, "configured") then
        message = "This server has no accounts yet. Open its web dashboard in a browser on your home network to create the admin account, then sign in here."
    end if
    resetTo("LoginScreen", { message: message })
end sub

sub onAuthLost()
    if not m.global.authLost then return
    m.global.authLost = false
    if m.global.cookie <> "" then
        m.global.cookie = ""
        rh_saveCookie("")
    end if
    m.player.command = "stop"
    top = topScreen()
    if top <> invalid and top.subtype() = "LoginScreen" then return
    resetTo("LoginScreen", { message: "Your session has ended. Sign in again." })
end sub

sub signOut()
    showStatus("Signing out...")
    m.player.command = "stop"
    rh_api("POST", "/api/auth/logout", invalid, onSignedOut)
end sub

sub onSignedOut(resp as object)
    ' Forget the cookie whatever the server said: a failed sign-out still means "not me".
    m.global.cookie = ""
    rh_saveCookie("")
    m.global.username = ""
    m.global.role = ""
    connect()
end sub

sub chooseServer(url as string)
    if url <> m.global.serverUrl then
        m.player.command = "stop"
        m.global.cookie = ""
        rh_saveCookie("")
    end if
    m.global.serverUrl = url
    rh_saveServer(url)
    connect()
end sub

' ---------------------------------------------------------------- status overlay

sub showStatus(text as string)
    m.statusText.text = text
    m.status.visible = true
    m.spinner.control = "start"
end sub

sub hideStatus()
    m.status.visible = false
    m.spinner.control = "stop"
end sub

' ---------------------------------------------------------------- navigation stack

function topScreen() as dynamic
    if m.stack.Count() = 0 then return invalid
    return m.stack.Peek()
end function

function pushScreen(name as string, params as object) as dynamic
    screen = CreateObject("roSGNode", name)
    if screen = invalid then
        print "ReelHouse: no component named "; name
        return invalid
    end if
    previous = topScreen()
    if previous <> invalid then previous.visible = false
    screen.observeField("action", "onScreenAction")
    m.screens.appendChild(screen)
    m.stack.Push(screen)
    screen.params = params
    screen.setFocus(true)
    updateMiniPlayer()
    return screen
end function

sub popScreen(refresh = true as boolean)
    if m.stack.Count() <= 1 then return
    closing = m.stack.Pop()
    closing.unobserveField("action")
    closing.closing = true
    m.screens.removeChild(closing)
    previous = topScreen()
    previous.visible = true
    if refresh then previous.revisit = previous.revisit + 1
    previous.setFocus(true)
    updateMiniPlayer()
end sub

sub onFinalReport(resp as object)
    top = topScreen()
    if top <> invalid then top.revisit = top.revisit + 1
end sub

sub resetTo(name as string, params as object)
    hideStatus()
    for each screen in m.stack
        screen.unobserveField("action")
        screen.closing = true
    end for
    m.screens.removeChildrenIndex(m.screens.getChildCount(), 0)
    m.stack = []
    pushScreen(name, params)
end sub

function onKeyEvent(key as string, press as boolean) as boolean
    if not press then return false
    if key = "back" then
        if m.stack.Count() > 1 then
            popScreen()
            return true
        end if
        return false
    end if
    if key = "play" and m.player.active then
        top = topScreen()
        if top <> invalid then
            kind = top.subtype()
            if kind <> "NowPlayingScreen" and kind <> "VideoPlayerScreen" then
                pushScreen("NowPlayingScreen", {})
                return true
            end if
        end if
    end if
    return false
end function

' ---------------------------------------------------------------- what screens ask for

sub onScreenAction(event as object)
    a = event.getData()
    kind = rh_getStr(a, "type")
    if kind = "push" then
        pushScreen(rh_getStr(a, "screen"), rh_get(a, "params", {}))
    else if kind = "pop" then
        ' A closing player hands over its last progress report: sent from here, because the
        ' screen's own requests go with it.
        ' The screen underneath refreshes (revisit) once the report has landed, so Continue
        ' Watching and the progress bars include it.
        report = rh_get(a, "report")
        if rh_isAA(report) then
            rh_api("POST", rh_getStr(report, "path"), { body: rh_get(report, "body") }, onFinalReport)
            popScreen(false)
        else
            popScreen(true)
        end if
    else if kind = "open" then
        openTile(rh_get(a, "tile"))
    else if kind = "play" then
        quickPlay(rh_get(a, "tile"))
    else if kind = "playVideo" then
        playVideo(rh_getStr(a, "itemId"), rh_getNum(a, "start", -1), rh_getStr(a, "title"))
    else if kind = "playAudio" then
        playAudio(rh_getArr(a, "queue"), Int(rh_getNum(a, "index", 0)), rh_get(a, "context", {}))
    else if kind = "serverChosen" then
        chooseServer(rh_getStr(a, "url"))
    else if kind = "retry" then
        connect()
    else if kind = "signedIn" then
        connect()
    else if kind = "signOut" then
        signOut()
    else if kind = "changeServer" then
        resetTo("ServerSetupScreen", { current: m.global.serverUrl })
    end if
end sub

' Where selecting a tile goes.
sub openTile(tile as dynamic)
    if not rh_isAA(tile) then return
    kind = rh_getStr(tile, "kind")
    id = rh_getStr(tile, "id")
    raw = rh_get(tile, "raw", {})
    if kind = "movie" or kind = "show" then
        pushScreen("MediaDetailScreen", { id: id, kind: kind, title: rh_getStr(tile, "title") })
    else if kind = "episode" then
        ' An episode opens its show, on that episode's season (as on the Apple TV).
        pushScreen("MediaDetailScreen", { id: rh_getStr(raw, "showId", id), kind: "show", title: rh_getStr(raw, "showTitle"), focusEpisode: id })
    else if kind = "album" or kind = "artist" or kind = "playlist" or kind = "mix" or kind = "podcast" then
        pushScreen("CollectionScreen", { kind: kind, id: id, title: rh_getStr(tile, "title"), raw: raw })
    else if kind = "podEpisode" then
        playAudio([rh_episodeQueueItem(raw, m.global.serverUrl)], 0, { "type": "podcast", "id": rh_getStr(raw, "podcastId"), "name": rh_getStr(raw, "podcastTitle") })
    else if kind = "action" then
        openAction(id)
    end if
end sub

sub openAction(id as string)
    if id = "allMovies" then
        pushScreen("GridScreen", { kind: "movies", title: "Movies" })
    else if id = "allShows" then
        pushScreen("GridScreen", { kind: "shows", title: "TV Shows" })
    else if id = "albums" then
        pushScreen("GridScreen", { kind: "albums", title: "Albums" })
    else if id = "artists" then
        pushScreen("GridScreen", { kind: "artists", title: "Artists" })
    else if id = "playlists" then
        pushScreen("GridScreen", { kind: "playlists", title: "Playlists" })
    else if id = "podcasts" then
        pushScreen("GridScreen", { kind: "podcasts", title: "Podcasts" })
    else if id = "shuffleAll" then
        pushScreen("CollectionScreen", { kind: "shuffle", id: "", title: "Shuffle All", autoPlay: true })
    else if id = "nowPlaying" then
        pushScreen("NowPlayingScreen", {})
    else if id = "settings" then
        pushScreen("SettingsScreen", {})
    end if
end sub

' The remote's Play button on a tile: start it straight away instead of opening it.
sub quickPlay(tile as dynamic)
    if not rh_isAA(tile) then return
    kind = rh_getStr(tile, "kind")
    raw = rh_get(tile, "raw", {})
    if kind = "movie" or kind = "episode" then
        playVideo(rh_getStr(tile, "id"), -1, rh_getStr(tile, "title"))
    else if kind = "show" and rh_getStr(raw, "nextEpisodeId") <> "" then
        playVideo(rh_getStr(raw, "nextEpisodeId"), -1, rh_getStr(tile, "title"))
    else if kind = "album" or kind = "playlist" or kind = "mix" or kind = "artist" then
        pushScreen("CollectionScreen", { kind: kind, id: rh_getStr(tile, "id"), title: rh_getStr(tile, "title"), raw: raw, autoPlay: true })
    else
        openTile(tile)
    end if
end sub

sub playVideo(itemId as string, start as dynamic, title as string)
    if itemId = "" then return
    ' Stopped, not paused: Roku allows one open player, and a paused Audio node still holds it -
    ' the video then fails with "only one playing instance supported". Stopping saves the
    ' podcast's place (or the track's listen) first.
    if m.player.active then m.player.command = "stop"
    pushScreen("VideoPlayerScreen", { itemId: itemId, start: start, title: title })
end sub

sub playAudio(queue as object, index as integer, context as dynamic)
    if queue.Count() = 0 then return
    m.player.load = { queue: queue, index: index, context: context }
    top = topScreen()
    if top = invalid or top.subtype() <> "NowPlayingScreen" then pushScreen("NowPlayingScreen", {})
end sub

' ---------------------------------------------------------------- now playing pill

sub updateMiniPlayer()
    top = topScreen()
    current = m.player.current
    show = m.player.active and rh_isAA(current) and top <> invalid
    if show then
        kind = top.subtype()
        show = kind <> "NowPlayingScreen" and kind <> "VideoPlayerScreen" and kind <> "ServerSetupScreen" and kind <> "LoginScreen"
    end if
    m.miniPlayer.visible = show
    if not show then return
    label = "NOW PLAYING"
    if m.player.state = "paused" then label = "PAUSED"
    m.miniText.text = label + "  ·  " + rh_join([rh_getStr(current, "title"), rh_getStr(current, "subtitle")], " - ") + "   (Play to open)"
end sub
