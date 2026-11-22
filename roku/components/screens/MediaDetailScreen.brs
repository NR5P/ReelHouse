' MediaDetailScreen - see MediaDetailScreen.xml.

sub init()
    m.backdrop = m.top.findNode("backdrop")
    m.poster = m.top.findNode("poster")
    m.title = m.top.findNode("title")
    m.meta = m.top.findNode("meta")
    m.tagline = m.top.findNode("tagline")
    m.overview = m.top.findNode("overview")
    m.cast = m.top.findNode("cast")
    m.fileInfo = m.top.findNode("fileInfo")
    m.error = m.top.findNode("error")
    m.loading = m.top.findNode("loading")
    m.buttons = m.top.findNode("buttons")
    rh_styleButtons(m.buttons)
    m.buttons.minWidth = 300
    m.buttons.maxWidth = 300
    m.buttons.observeField("buttonSelected", "onButton")
    m.showPanel = m.top.findNode("showPanel")
    m.seasonList = m.top.findNode("seasons")
    m.seasonList.observeField("itemFocused", "onSeasonFocused")
    m.seasonList.observeField("itemSelected", "onSeasonSelected")
    m.episodes = m.top.findNode("episodes")
    m.episodes.observeField("itemSelected", "onEpisodeSelected")
    m.detail = invalid
    m.seasons = []
    m.seasonIndex = 0
    m.actions = []
    m.focusEpisode = ""
    m.focusEpisodesNext = false
    m.kind = ""
    m.top.observeField("params", "onParams")
    m.top.observeField("revisit", "onRevisit")
    m.top.observeField("focusedChild", "onFocusChanged")
    m.top.observeField("closing", "onClosing")
end sub

sub onParams()
    p = m.top.params
    m.itemId = rh_getStr(p, "id")
    m.focusEpisode = rh_getStr(p, "focusEpisode")
    m.title.text = rh_getStr(p, "title")
    load()
end sub

sub onRevisit()
    load()
end sub

sub onFocusChanged()
    if m.top.hasFocus() then
        if m.focusEpisodesNext and m.episodes.content <> invalid and m.episodes.content.getChildCount() > 0 then
            m.focusEpisodesNext = false
            m.episodes.setFocus(true)
        else
            m.buttons.setFocus(true)
        end if
    end if
end sub

sub onClosing()
    rh_cancelRequests()
end sub

sub load()
    rh_api("GET", "/api/media/items/" + m.itemId, { timeout: 30000 }, onDetail)
end sub

sub onDetail(resp as object)
    m.loading.visible = false
    if not resp.ok then
        m.error.text = resp.error
        if m.detail = invalid then setButtons([{ label: "Back", id: "back" }])
        return
    end if
    m.error.text = ""
    d = resp.data
    m.detail = d
    m.kind = rh_getStr(d, "kind", "movie")
    server = m.global.serverUrl
    m.title.text = rh_getStr(d, "title")
    m.meta.text = rh_mediaMetaLine(d)
    m.tagline.text = rh_getStr(d, "tagline")
    m.overview.text = rh_getStr(d, "overview")
    m.backdrop.uri = rh_absUrl(server, rh_getStr(d, "backdropUrl"))
    m.poster.uri = rh_absUrl(server, rh_getStr(d, "posterUrl"))

    names = []
    for each member in rh_getArr(d, "cast")
        if names.Count() < 8 then names.Push(rh_getStr(member, "name"))
    end for
    m.cast.text = ""
    if names.Count() > 0 then m.cast.text = "Starring " + rh_join(names, ", ")
    m.fileInfo.text = fileSummary(rh_get(d, "file"))

    isShow = m.kind = "show"
    m.showPanel.visible = isShow
    m.cast.visible = not isShow
    m.fileInfo.visible = not isShow
    if isShow then
        m.overview.maxLines = 4
        showSeasons(d)
    else
        m.overview.maxLines = 6
    end if
    buildButtons(d)
end sub

' "1080p · HEVC · EAC3 5.1" (MediaModels.swift MediaFileInfo.summaryLine).
function fileSummary(file as dynamic) as string
    if not rh_isAA(file) then return ""
    parts = []
    height = rh_getNum(file, "height", 0)
    width = rh_getNum(file, "width", 0)
    if height > 0 then
        if height >= 2000 or width >= 3200 then
            parts.Push("4K")
        else if height >= 1000 or width >= 1800 then
            parts.Push("1080p")
        else if height >= 700 or width >= 1200 then
            parts.Push("720p")
        else
            parts.Push(rh_intStr(height) + "p")
        end if
    end if
    codec = LCase(rh_getStr(file, "videoCodec"))
    if codec = "h264" or codec = "avc" then
        parts.Push("H.264")
    else if codec = "hevc" or codec = "h265" then
        parts.Push("HEVC")
    else if codec <> "" then
        parts.Push(UCase(codec))
    end if
    audio = UCase(rh_getStr(file, "audioCodec"))
    channels = rh_getNum(file, "audioChannels", 0)
    if audio <> "" then
        if channels = 2 then audio = audio + " 2.0"
        if channels = 6 then audio = audio + " 5.1"
        if channels = 8 then audio = audio + " 7.1"
        parts.Push(audio)
    end if
    return rh_join(parts, " · ")
end function

sub buildButtons(d as object)
    actions = []
    if m.kind = "show" then
        nextEp = nextEpisode(d)
        if nextEp <> invalid then
            code = rh_episodeCode(nextEp)
            if code = "" then code = "Next Episode"
            if rh_mediaResumeSeconds(nextEp) > 0 then
                actions.Push({ label: "Resume " + code, id: "playNext" })
            else
                actions.Push({ label: "Play " + code, id: "playNext" })
            end if
        end if
    else
        resume = rh_mediaResumeSeconds(d)
        if resume > 0 then
            actions.Push({ label: "Resume " + rh_formatClock(resume), id: "resume" })
            actions.Push({ label: "From Beginning", id: "startOver" })
        else
            actions.Push({ label: "Play", id: "resume" })
        end if
    end if
    if rh_mediaIsWatched(d) then
        actions.Push({ label: "Mark Unwatched", id: "unwatched" })
    else
        actions.Push({ label: "Mark Watched", id: "watched" })
    end if
    if rh_getBool(d, "inList") then
        actions.Push({ label: "Remove from List", id: "unlist" })
    else
        actions.Push({ label: "Add to My List", id: "list" })
    end if
    setButtons(actions)
end sub

sub setButtons(actions as object)
    focused = m.buttons.buttonFocused
    m.actions = actions
    labels = []
    for each a in actions
        labels.Push(a.label)
    end for
    m.buttons.buttons = labels
    if focused >= 0 and focused < labels.Count() then m.buttons.focusButton = focused
end sub

' The episode Play starts: the server's pick (in progress, else first unwatched), else the first.
function nextEpisode(d as object) as dynamic
    wanted = rh_getStr(d, "nextEpisodeId")
    first = invalid
    for each season in m.seasons
        for each row in season.episodes
            if first = invalid then first = row.raw
            if row.id = wanted then return row.raw
        end for
    end for
    return first
end function

sub showSeasons(d as object)
    m.seasons = rh_seasonList(d)
    content = CreateObject("roSGNode", "ContentNode")
    for each s in m.seasons
        item = content.createChild("ContentNode")
        item.title = s.title
    end for
    m.seasonList.content = content
    if m.seasons.Count() = 0 then
        m.episodes.content = rh_listContent([], "")
        return
    end if
    ' Open on the season of the episode we came for, else the one Play would start.
    target = m.focusEpisode
    if target = "" then target = rh_getStr(d, "nextEpisodeId")
    index = m.seasonIndex
    if target <> "" then index = rh_seasonIndexOf(m.seasons, target)
    if index >= m.seasons.Count() then index = 0
    m.seasonIndex = index
    m.seasonList.jumpToItem = index
    showEpisodes(index)
    if m.focusEpisode <> "" then
        rows = m.seasons[index].episodes
        for i = 0 to rows.Count() - 1
            if rows[i].id = m.focusEpisode then m.episodes.jumpToItem = i
        end for
        m.focusEpisode = ""
        m.focusEpisodesNext = true
        if m.top.isInFocusChain() then m.episodes.setFocus(true)
    end if
end sub

sub showEpisodes(index as integer)
    if index < 0 or index >= m.seasons.Count() then return
    m.seasonIndex = index
    m.episodes.content = rh_listContent(m.seasons[index].episodes, m.global.serverUrl)
    m.top.findNode("episodesTitle").text = UCase(m.seasons[index].title) + " · " + rh_intStr(m.seasons[index].episodes.Count()) + " EPISODES"
end sub

sub onSeasonFocused()
    i = m.seasonList.itemFocused
    if i <> m.seasonIndex then showEpisodes(i)
end sub

sub onSeasonSelected()
    showEpisodes(m.seasonList.itemSelected)
    m.episodes.setFocus(true)
end sub

function focusedEpisode() as dynamic
    if m.seasonIndex >= m.seasons.Count() then return invalid
    rows = m.seasons[m.seasonIndex].episodes
    i = m.episodes.itemFocused
    if i < 0 or i >= rows.Count() then return invalid
    return rows[i]
end function

sub onEpisodeSelected()
    rows = m.seasons[m.seasonIndex].episodes
    i = m.episodes.itemSelected
    if i < 0 or i >= rows.Count() then return
    m.top.action = { type: "playVideo", itemId: rows[i].id, start: -1, title: rows[i].title }
end sub

sub onButton()
    i = m.buttons.buttonSelected
    if i < 0 or i >= m.actions.Count() then return
    id = m.actions[i].id
    if id = "back" then
        m.top.action = { type: "pop" }
    else if id = "resume" then
        m.top.action = { type: "playVideo", itemId: m.itemId, start: -1, title: m.title.text }
    else if id = "startOver" then
        m.top.action = { type: "playVideo", itemId: m.itemId, start: 0, title: m.title.text }
    else if id = "playNext" then
        ep = nextEpisode(m.detail)
        if ep <> invalid then m.top.action = { type: "playVideo", itemId: rh_getStr(ep, "id"), start: -1, title: rh_getStr(ep, "title") }
    else if id = "watched" or id = "unwatched" then
        rh_api("POST", "/api/media/items/" + m.itemId + "/watched", { body: { "watched": id = "watched" } }, onChanged)
    else if id = "list" or id = "unlist" then
        rh_api("POST", "/api/media/items/" + m.itemId + "/list", { body: { "inList": id = "list" } }, onChanged)
    end if
end sub

sub onChanged(resp as object)
    if not resp.ok then m.error.text = resp.error
    load()
end sub

function onKeyEvent(key as string, press as boolean) as boolean
    if not press then return false
    isShow = m.kind = "show"
    if key = "right" then
        if m.buttons.isInFocusChain() and isShow and m.seasons.Count() > 0 then
            m.seasonList.setFocus(true)
            return true
        else if m.seasonList.isInFocusChain() then
            m.episodes.setFocus(true)
            return true
        end if
    else if key = "left" then
        if m.episodes.isInFocusChain() then
            m.seasonList.setFocus(true)
            return true
        else if m.seasonList.isInFocusChain() then
            m.buttons.setFocus(true)
            return true
        end if
    else if key = "options" and m.episodes.isInFocusChain() then
        ep = focusedEpisode()
        if ep <> invalid then
            rh_api("POST", "/api/media/items/" + ep.id + "/watched", { body: { "watched": not ep.watched } }, onChanged)
            return true
        end if
    else if key = "play" then
        if m.episodes.isInFocusChain() then
            ep = focusedEpisode()
            if ep <> invalid then m.top.action = { type: "playVideo", itemId: ep.id, start: -1, title: ep.title }
            return true
        end if
        onPlayKey()
        return true
    end if
    return false
end function

sub onPlayKey()
    if m.detail = invalid then return
    if m.kind = "show" then
        ep = nextEpisode(m.detail)
        if ep <> invalid then m.top.action = { type: "playVideo", itemId: rh_getStr(ep, "id"), start: -1, title: rh_getStr(ep, "title") }
    else
        m.top.action = { type: "playVideo", itemId: m.itemId, start: -1, title: m.title.text }
    end if
end sub
