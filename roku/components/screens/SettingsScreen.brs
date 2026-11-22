' SettingsScreen - see SettingsScreen.xml.

sub init()
    m.info = m.top.findNode("info")
    m.buttons = m.top.findNode("buttons")
    rh_styleButtons(m.buttons)
    m.buttons.minWidth = 460
    m.buttons.observeField("buttonSelected", "onButton")
    m.actions = []
    m.serverBuild = ""
    m.top.observeField("params", "onParams")
    m.top.observeField("focusedChild", "onFocusChanged")
    m.top.observeField("closing", "onClosing")
end sub

sub onParams()
    actions = [{ label: "Change Server", id: "changeServer" }]
    if m.global.authEnabled then actions.Push({ label: "Sign Out", id: "signOut" })
    actions.Push({ label: "Done", id: "done" })
    m.actions = actions
    labels = []
    for each a in actions
        labels.Push(a.label)
    end for
    m.buttons.buttons = labels
    render()
    rh_api("GET", "/api/health", { timeout: 8000 }, onHealth)
end sub

sub onFocusChanged()
    if m.top.hasFocus() then m.buttons.setFocus(true)
end sub

sub onClosing()
    rh_cancelRequests()
end sub

sub onHealth(resp as object)
    if resp.ok then m.serverBuild = rh_buildLabel(resp.data)
    render()
end sub

sub render()
    nl = Chr(10)
    lines = []
    lines.Push("SERVER")
    lines.Push("   " + rh_displayServer(m.global.serverUrl))
    if m.serverBuild <> "" then lines.Push("   ReelHouse " + m.serverBuild)
    lines.Push("")
    lines.Push("ACCOUNT")
    if not m.global.authEnabled then
        lines.Push("   Sign-in is turned off on this server: everyone shares one view.")
    else
        role = m.global.role
        if role = "" then role = "Admin"
        lines.Push("   Signed in as " + m.global.username + " (" + role + ")")
        if role = "Viewer" then lines.Push("   Viewers can watch and listen; managing the library is for admins, on the web dashboard.")
    end if
    lines.Push("")
    lines.Push("SECTIONS ON THIS SERVER")
    sections = []
    if m.global.mediaEnabled then sections.Push("Movies & TV")
    if m.global.musicEnabled then sections.Push("Music")
    if m.global.podcastsEnabled then sections.Push("Podcasts")
    if sections.Count() = 0 then sections.Push("none yet")
    lines.Push("   " + rh_join(sections, ", "))
    lines.Push("")
    lines.Push("THIS ROKU")
    lines.Push("   " + m.global.deviceName + "  ·  channel " + m.global.appVersion)
    lines.Push("   Video: " + m.global.videoCodecs + "  ·  audio: " + m.global.videoAudioCodecs)
    lines.Push("   Music: " + m.global.musicCodecs)
    lines.Push("")
    lines.Push("Adding titles, downloads, libraries and server settings are on the server's web dashboard.")
    m.info.text = lines.Join(nl)
end sub

sub onButton()
    i = m.buttons.buttonSelected
    if i < 0 or i >= m.actions.Count() then return
    id = m.actions[i].id
    if id = "done" then
        m.top.action = { type: "pop" }
    else
        m.top.action = { type: id }
    end if
end sub
