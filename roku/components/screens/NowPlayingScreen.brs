' NowPlayingScreen - see NowPlayingScreen.xml.

sub init()
    m.player = m.global.player
    m.backdrop = m.top.findNode("backdrop")
    m.art = m.top.findNode("art")
    m.kicker = m.top.findNode("kicker")
    m.title = m.top.findNode("title")
    m.subtitle = m.top.findNode("subtitle")
    m.positionLabel = m.top.findNode("position")
    m.barFill = m.top.findNode("barFill")
    m.elapsed = m.top.findNode("elapsed")
    m.remaining = m.top.findNode("remaining")
    m.error = m.top.findNode("error")
    m.buttons = m.top.findNode("buttons")
    rh_styleButtons(m.buttons)
    m.buttons.minWidth = 220
    m.buttons.maxWidth = 260
    m.buttons.observeField("buttonSelected", "onButton")
    m.layoutKind = ""
    m.commands = []
    m.player.observeField("current", "onCurrent")
    m.player.observeField("position", "onPosition")
    m.player.observeField("duration", "onPosition")
    m.player.observeField("state", "onPlayerState")
    m.player.observeField("errorText", "onError")
    m.top.observeField("focusedChild", "onFocusChanged")
    m.top.observeField("closing", "onClosing")
    onCurrent()
end sub

sub onFocusChanged()
    if m.top.hasFocus() then m.buttons.setFocus(true)
end sub

sub onClosing()
    m.player.unobserveField("current")
    m.player.unobserveField("position")
    m.player.unobserveField("duration")
    m.player.unobserveField("state")
    m.player.unobserveField("errorText")
end sub

sub onCurrent()
    item = m.player.current
    if not rh_isAA(item) or not m.player.active then
        m.kicker.text = "NOTHING PLAYING"
        m.title.text = "Pick an album, playlist or episode to play."
        m.subtitle.text = ""
        m.positionLabel.text = ""
        m.art.uri = ""
        m.backdrop.uri = ""
        setButtons("none")
        return
    end if
    podcast = item.type = "episode"
    if podcast then
        m.kicker.text = "PODCAST"
        setButtons("podcast")
    else
        m.kicker.text = "NOW PLAYING"
        setButtons("music")
    end if
    m.title.text = item.title
    m.subtitle.text = item.subtitle
    m.art.uri = item.art
    m.backdrop.uri = item.art
    if m.player.count > 1 then
        noun = "Track "
        if podcast then noun = "Episode "
        m.positionLabel.text = noun + Str(m.player.index + 1).Trim() + " of " + Str(m.player.count).Trim()
    else
        m.positionLabel.text = ""
    end if
    m.error.text = m.player.errorText
    onPosition()
end sub

sub setButtons(kind as string)
    if kind = m.layoutKind then return
    m.layoutKind = kind
    if kind = "podcast" then
        m.commands = ["back15", "toggle", "fwd30", "next"]
        m.buttons.buttons = ["Back 15s", "Play / Pause", "Ahead 30s", "Next"]
        m.buttons.focusButton = 1
    else if kind = "music" then
        m.commands = ["prev", "toggle", "next", "stop"]
        m.buttons.buttons = ["Previous", "Play / Pause", "Next", "Stop"]
        m.buttons.focusButton = 1
    else
        m.commands = []
        m.buttons.buttons = []
    end if
end sub

sub onPosition()
    position = m.player.position
    duration = m.player.duration
    m.elapsed.text = rh_formatClock(position)
    if duration > 0 then
        remainingSecs = duration - position
        if remainingSecs < 0 then remainingSecs = 0
        m.remaining.text = "-" + rh_formatClock(remainingSecs)
        fraction = position / duration
        if fraction > 1 then fraction = 1
        m.barFill.width = 960 * fraction
    else
        m.remaining.text = ""
        m.barFill.width = 0
    end if
end sub

sub onPlayerState()
    state = m.player.state
    if state = "buffering" then
        m.kicker.text = "LOADING..."
    else if state = "paused" then
        m.kicker.text = "PAUSED"
    else if state = "playing" then
        if m.layoutKind = "podcast" then
            m.kicker.text = "PODCAST"
        else
            m.kicker.text = "NOW PLAYING"
        end if
    else if state = "stopped" and not m.player.active then
        onCurrent()
    end if
end sub

sub onError()
    m.error.text = m.player.errorText
end sub

sub onButton()
    i = m.buttons.buttonSelected
    if i < 0 or i >= m.commands.Count() then return
    m.player.command = m.commands[i]
end sub

function onKeyEvent(key as string, press as boolean) as boolean
    if not press then return false
    podcast = m.layoutKind = "podcast"
    if key = "play" then
        m.player.command = "toggle"
        return true
    else if key = "fastforward" then
        if podcast then
            m.player.command = "fwd30"
        else
            m.player.command = "next"
        end if
        return true
    else if key = "rewind" then
        if podcast then
            m.player.command = "back15"
        else
            m.player.command = "prev"
        end if
        return true
    else if key = "replay" then
        m.player.command = "back15"
        return true
    end if
    return false
end function
