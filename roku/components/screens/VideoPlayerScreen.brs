' VideoPlayerScreen - see VideoPlayerScreen.xml.
'
' The one rule that matters (MOVIES.md, Playback): an HLS session's clock starts at
' startSeconds. The Video node's position 0 is the film at startSeconds, so every position sent
' to the server is startSeconds + video.position. A direct file is the whole film; the Video
' node is started at startSeconds instead (content.PlayStart).

sub init()
    m.video = m.top.findNode("video")
    m.overlay = m.top.findNode("overlay")
    m.overlayArt = m.top.findNode("overlayArt")
    m.overlayTitle = m.top.findNode("overlayTitle")
    m.overlayText = m.top.findNode("overlayText")
    m.spinner = m.top.findNode("spinner")
    m.spinner.poster.uri = "pkg:/images/spinner.png"
    m.spinner.poster.width = 96
    m.spinner.poster.height = 96
    m.timer = m.top.findNode("progressTimer")
    m.timer.observeField("fire", "onTick")

    ' Its own HTTP agent so the Scene's (which carries the cookie for artwork) isn't inherited;
    ' the cookie reaches the playlist and every segment through content.HttpHeaders instead.
    agent = CreateObject("roHttpAgent")
    agent.SetCertificatesFile("common:/certs/ca-bundle.crt")
    agent.InitClientCertificates()
    m.video.setHttpAgent(agent)
    m.video.notificationInterval = 1
    m.video.observeField("state", "onState")

    m.playback = invalid
    m.itemId = ""
    m.offset = 0
    m.started = false
    m.failed = false
    m.lastReported = -1
    m.stopped = false
    m.seq = 0
    m.top.observeField("params", "onParams")
    m.top.observeField("focusedChild", "onFocusChanged")
    m.top.observeField("closing", "onClosing")
end sub

sub onParams()
    p = m.top.params
    load(rh_getStr(p, "itemId"), rh_getNum(p, "start", -1), rh_getStr(p, "title"))
end sub

sub onFocusChanged()
    if m.top.hasFocus() then m.video.setFocus(true)
end sub

sub onClosing()
    m.stopped = true
    m.timer.control = "stop"
    m.video.control = "stop"
    m.video.content = invalid
    m.spinner.control = "stop"
    rh_cancelRequests()
end sub

sub showOverlay(title as string, text as string, busy as boolean)
    m.overlayTitle.text = title
    m.overlayText.text = text
    m.overlay.visible = true
    if busy then
        m.spinner.visible = true
        m.spinner.control = "start"
    else
        m.spinner.visible = false
        m.spinner.control = "stop"
    end if
end sub

sub hideOverlay()
    m.overlay.visible = false
    m.spinner.control = "stop"
end sub

sub load(itemId as string, start as dynamic, title as string)
    m.itemId = itemId
    m.playback = invalid
    m.started = false
    m.failed = false
    m.lastReported = -1
    m.offset = 0
    m.seq = m.seq + 1
    if title = "" then title = "Starting"
    showOverlay(title, "Getting it ready. A file the server has to convert can take up to a minute to start.", true)
    query = rh_playbackQuery(start, m.global.videoCodecs, m.global.videoAudioCodecs)
    ' The server only answers once ffmpeg has the first segments ready - give it time.
    rh_api("GET", "/api/media/items/" + itemId + "/playback", { query: query, timeout: 100000, tag: m.seq }, onPlayback)
end sub

sub onPlayback(resp as object)
    if m.stopped or resp.tag <> m.seq then return
    if not resp.ok then
        showError(resp.error)
        return
    end if
    pb = resp.data
    m.playback = pb
    m.offset = rh_playbackOffset(pb)
    server = m.global.serverUrl
    title = rh_getStr(pb, "title")
    subtitle = rh_getStr(pb, "subtitle")
    m.overlayTitle.text = title
    m.overlayText.text = rh_join([subtitle, "Starting..."], Chr(10))
    m.overlayArt.uri = rh_absUrl(server, rh_sizedArt(rh_getStr(pb, "backdropUrl"), 1200))

    content = CreateObject("roSGNode", "ContentNode")
    content.url = rh_absUrl(server, rh_getStr(pb, "url"))
    content.streamFormat = rh_videoStreamFormat(pb)
    content.title = rh_join([title, subtitle], " · ")
    content.HDPosterUrl = rh_absUrl(server, rh_sizedArt(rh_getStr(pb, "posterUrl"), 400))
    if m.global.cookie <> "" then content.HttpHeaders = ["Cookie: " + m.global.cookie]
    duration = rh_getNum(pb, "durationSeconds", 0)
    start = rh_getNum(pb, "startSeconds", 0)
    if rh_getStr(pb, "mode") = "hls" then
        if duration > m.offset then content.Length = Int(duration - m.offset)
    else
        if duration > 0 then content.Length = Int(duration)
        if start > 1 then content.PlayStart = start
        ' Direct play: the file's text subtitles as WebVTT side tracks (HLS carries them in the
        ' master playlist).
        tracks = []
        for each s in rh_getArr(pb, "subtitles")
            url = rh_absUrl(server, rh_getStr(s, "url"))
            if url <> "" then tracks.Push({ "TrackName": url, "Language": rh_getStr(s, "language", "und"), "Description": rh_getStr(s, "label") })
        end for
        if tracks.Count() > 0 then content.SubtitleTracks = tracks
    end if
    m.video.content = content
    m.video.control = "play"
    m.video.setFocus(true)
end sub

sub onState()
    state = m.video.state
    if m.stopped then return
    if state = "playing" then
        if not m.started then
            m.started = true
            hideOverlay()
            ' A growing (EVENT) HLS playlist can look live, and a live stream starts near its end;
            ' the film starts at the top of the playlist.
            if rh_getStr(m.playback, "mode") = "hls" and m.video.position > 3 then m.video.seek = 0
            m.timer.control = "start"
        end if
    else if state = "paused" then
        reportProgress(true)
    else if state = "finished" then
        onFinished()
    else if state = "error" then
        detail = m.video.errorMsg
        if m.video.errorStr <> invalid and m.video.errorStr <> "" then detail = detail + " (" + m.video.errorStr + ")"
        showError("This video couldn't be played. " + detail)
    end if
end sub

sub onTick()
    if m.video.state = "playing" then reportProgress(false)
end sub

' The film's own clock.
function currentPosition() as float
    return m.offset + m.video.position
end function

function currentDuration() as float
    duration = rh_getNum(m.playback, "durationSeconds", 0)
    if duration > 0 then return duration
    if m.video.duration > 0 then return m.offset + m.video.duration
    return 0
end function

function progressBody(position as float) as object
    body = { "positionSeconds": position }
    duration = currentDuration()
    if duration > 0 then body["durationSeconds"] = duration
    return body
end function

sub reportProgress(force as boolean)
    if not m.started or m.playback = invalid then return
    position = currentPosition()
    if not force and m.lastReported >= 0 and Abs(position - m.lastReported) < 1 then return
    m.lastReported = position
    rh_api("POST", "/api/media/items/" + m.itemId + "/progress", { body: progressBody(position) })
end sub

' The end is the end, whatever the last tick said: the server marks it watched at 92%.
sub onFinished()
    m.timer.control = "stop"
    report = invalid
    if m.started then
        duration = currentDuration()
        position = currentPosition()
        if duration > 0 then position = duration
        report = { path: "/api/media/items/" + m.itemId + "/progress", body: progressBody(position) }
    end if
    m.started = false
    nextId = rh_getStr(m.playback, "nextEpisodeId")
    if nextId <> "" then
        if report <> invalid then rh_api("POST", report.path, { body: report.body })
        load(nextId, -1, "Up next: " + rh_getStr(m.playback, "nextEpisodeTitle"))
    else
        leave(report)
    end if
end sub

' Closes the player. The last progress report goes with the request to close, so MainScene sends
' it: this screen's own requests are dropped as it goes away.
sub leave(report as dynamic)
    m.timer.control = "stop"
    m.video.control = "stop"
    m.top.action = { type: "pop", report: report }
end sub

sub showError(text as string)
    m.failed = true
    m.timer.control = "stop"
    title = rh_getStr(m.playback, "title", m.overlayTitle.text)
    showOverlay(title, text + Chr(10) + Chr(10) + "Press Back to return.", false)
end sub

function onKeyEvent(key as string, press as boolean) as boolean
    if not press then return false
    if key = "back" or (key = "OK" and m.failed) then
        report = invalid
        if m.started and m.playback <> invalid then
            report = { path: "/api/media/items/" + m.itemId + "/progress", body: progressBody(currentPosition()) }
        end if
        leave(report)
        return true
    end if
    return false
end function
