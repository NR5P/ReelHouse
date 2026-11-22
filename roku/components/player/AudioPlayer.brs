' AudioPlayer - see AudioPlayer.xml.

sub init()
    m.audio = m.top.findNode("audio")
    m.audio.notificationInterval = 1
    ' Its own HTTP agent, so the Scene's (which carries the cookie for posters) isn't inherited:
    ' the cookie goes through the content's HttpHeaders instead, and only once.
    agent = CreateObject("roHttpAgent")
    agent.SetCertificatesFile("common:/certs/ca-bundle.crt")
    agent.InitClientCertificates()
    m.audio.setHttpAgent(agent)
    m.audio.observeField("state", "onState")
    m.audio.observeField("position", "onPosition")
    m.progressTimer = m.top.findNode("progressTimer")
    m.progressTimer.observeField("fire", "onProgressTick")
    m.nowPlayingTimer = m.top.findNode("nowPlayingTimer")
    m.nowPlayingTimer.observeField("fire", "putNowPlaying")
    m.queue = []
    m.idx = -1
    m.context = {}
    m.listened = 0
    m.reported = true
    m.started = false
end sub

sub onLoad()
    req = m.top.load
    leaveCurrent(false)
    m.queue = rh_getArr(req, "queue")
    m.context = rh_get(req, "context", {})
    startAt(Int(rh_getNum(req, "index", 0)))
end sub

sub startAt(i as integer)
    if i < 0 or i >= m.queue.Count() then
        stopAll()
        return
    end if
    m.idx = i
    item = m.queue[i]
    m.listened = 0
    m.reported = false
    m.started = false
    m.top.errorText = ""

    content = CreateObject("roSGNode", "ContentNode")
    content.url = item.url
    content.streamFormat = item.format
    content.title = item.title
    content.HDPosterUrl = item.art
    if m.global.cookie <> "" then content.HttpHeaders = ["Cookie: " + m.global.cookie]
    m.audio.content = content
    m.audio.control = "play"

    m.top.current = item
    m.top.index = i
    m.top.count = m.queue.Count()
    m.top.position = 0
    m.top.duration = rh_getNum(item, "duration", 0)
    if item.type = "episode" then
        m.top.kind = "podcast"
    else
        m.top.kind = "music"
    end if
    m.top.active = true
    if item.type = "track" then rh_api("POST", "/api/music/now-playing-track", { body: { "trackId": item.id } })
    m.progressTimer.control = "start"
    m.nowPlayingTimer.control = "start"
    putNowPlaying()
end sub

sub onState()
    state = m.audio.state
    m.top.state = state
    if state = "playing" then
        if not m.started then
            m.started = true
            ' Podcasts pick up where they were left (MUSIC_AND_PODCASTS.md: progress follows a
            ' person between devices).
            resume = rh_getNum(currentItem(), "resume", 0)
            if resume > 10 then m.audio.seek = resume
        end if
        putNowPlaying()
    else if state = "paused" then
        reportPodcast(m.audio.position)
        putNowPlaying()
    else if state = "finished" then
        leaveCurrent(true)
        if m.idx + 1 < m.queue.Count() then
            startAt(m.idx + 1)
        else
            stopAll()
        end if
    else if state = "error" then
        m.top.errorText = "Couldn't play this: " + m.audio.errorMsg
        leaveCurrent(false)
    end if
end sub

sub onPosition()
    p = m.audio.position
    m.top.position = p
    if p > m.listened then m.listened = p
    if m.audio.duration > 0 then m.top.duration = m.audio.duration
end sub

sub onCommand()
    cmd = m.top.command
    state = m.audio.state
    if cmd = "toggle" then
        if state = "playing" or state = "buffering" then
            m.audio.control = "pause"
        else if state = "paused" then
            m.audio.control = "resume"
        else if m.idx >= 0 then
            startAt(m.idx)
        end if
    else if cmd = "pause" then
        if state = "playing" or state = "buffering" then m.audio.control = "pause"
    else if cmd = "resume" or cmd = "play" then
        if state = "paused" then m.audio.control = "resume"
    else if cmd = "next" then
        if m.idx + 1 < m.queue.Count() then
            leaveCurrent(false)
            startAt(m.idx + 1)
        end if
    else if cmd = "prev" then
        if m.audio.position > 5 or m.idx = 0 then
            m.audio.seek = 0
        else
            leaveCurrent(false)
            startAt(m.idx - 1)
        end if
    else if cmd = "back15" then
        target = m.audio.position - 15
        if target < 0 then target = 0
        m.audio.seek = target
    else if cmd = "fwd30" then
        target = m.audio.position + 30
        duration = m.top.duration
        if duration > 0 and target > duration - 1 then target = duration - 1
        m.audio.seek = target
    else if cmd = "stop" then
        leaveCurrent(false)
        stopAll()
    end if
end sub

function currentItem() as dynamic
    if m.idx < 0 or m.idx >= m.queue.Count() then return invalid
    return m.queue[m.idx]
end function

' The entry being left - finished, skipped or replaced - is reported once.
sub leaveCurrent(completed as boolean)
    item = currentItem()
    if item = invalid or m.reported then return
    m.reported = true
    if item.type = "track" then
        seconds = m.listened
        duration = m.top.duration
        if completed and duration > seconds then seconds = duration
        if seconds < 1 then return
        rh_api("POST", "/api/music/tracks/" + item.id + "/played", { body: {
            "secondsListened": Int(seconds + 0.5)
            "completed": completed
            "skipped": not completed
            "deviceName": m.global.deviceName
        } })
    else
        position = m.audio.position
        if completed and m.top.duration > 0 then position = m.top.duration
        reportPodcastFor(item, position)
    end if
end sub

sub onProgressTick()
    if m.audio.state = "playing" then reportPodcast(m.audio.position)
end sub

sub reportPodcast(position as float)
    item = currentItem()
    if item = invalid or item.type <> "episode" or m.reported then return
    reportPodcastFor(item, position)
end sub

' Under 10 s the server saves nothing, so nothing is sent.
sub reportPodcastFor(item as object, position as float)
    if item.type <> "episode" or position < 10 then return
    body = { "positionSeconds": position, "speed": 1.0, "deviceName": m.global.deviceName }
    if m.top.duration > 0 then body["durationSeconds"] = m.top.duration
    rh_api("POST", "/api/podcasts/episodes/" + item.id + "/progress", { body: body })
end sub

' "Playing on Living Room Roku" for the person's other devices (MUSIC_AND_PODCASTS.md §7).
sub putNowPlaying()
    if m.queue.Count() = 0 or m.idx < 0 then return
    refs = []
    first = m.idx - 250
    if first < 0 then first = 0
    last = first + 499
    if last > m.queue.Count() - 1 then last = m.queue.Count() - 1
    for i = first to last
        refs.Push({ "type": m.queue[i].type, "id": m.queue[i].id })
    end for
    body = {
        "deviceId": "roku-" + m.global.deviceId
        "deviceName": m.global.deviceName
        "kind": m.top.kind
        "queue": refs
        "index": m.idx - first
        "positionSeconds": m.audio.position
        "playing": m.audio.state = "playing"
        "shuffle": false
        "repeat": "off"
        "speed": 1.0
    }
    if rh_isAA(m.context) and m.context.Count() > 0 then body["context"] = m.context
    rh_api("PUT", "/api/audio/now-playing", { body: body })
end sub

sub stopAll()
    if m.idx >= 0 then
        m.audio.control = "stop"
        m.progressTimer.control = "stop"
        m.nowPlayingTimer.control = "stop"
        putNowPlayingStopped()
    end if
    m.queue = []
    m.idx = -1
    m.top.active = false
    m.top.current = {}
    m.top.index = -1
    m.top.count = 0
    m.top.state = "stopped"
end sub

sub putNowPlayingStopped()
    item = currentItem()
    if item = invalid then return
    rh_api("PUT", "/api/audio/now-playing", { body: {
        "deviceId": "roku-" + m.global.deviceId
        "deviceName": m.global.deviceName
        "kind": m.top.kind
        "queue": [{ "type": item.type, "id": item.id }]
        "index": 0
        "positionSeconds": m.audio.position
        "playing": false
        "shuffle": false
        "repeat": "off"
        "speed": 1.0
    } })
end sub
