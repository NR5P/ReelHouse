' ServerSetupScreen - see ServerSetupScreen.xml.

sub init()
    m.buttons = m.top.findNode("buttons")
    rh_styleButtons(m.buttons)
    m.buttons.observeField("buttonSelected", "onButton")
    m.error = m.top.findNode("error")
    m.scanStatus = m.top.findNode("scanStatus")
    m.scanFill = m.top.findNode("scanFill")
    m.found = m.top.findNode("found")
    m.found.observeField("itemSelected", "onFoundSelected")
    m.foundServers = []
    m.scanner = invalid
    m.labels = []
    m.top.findNode("header").hint = "Back exits"
    m.top.observeField("params", "onParams")
    m.top.observeField("focusedChild", "onFocusChanged")
    m.top.observeField("closing", "onClosing")
end sub

sub onParams()
    p = m.top.params
    m.error.text = rh_getStr(p, "error")
    m.canRetry = rh_getBool(p, "canRetry")
    m.labels = []
    if m.canRetry then m.labels.Push("Try Again")
    m.labels.Push("Scan My Network")
    m.labels.Push("Enter Address")
    m.buttons.buttons = m.labels
    m.scanStatus.text = "Not scanned yet."
    ' Nothing saved yet: start looking straight away.
    if rh_getStr(p, "current") = "" and not m.canRetry then startScan()
end sub

sub onFocusChanged()
    if m.top.hasFocus() then m.buttons.setFocus(true)
end sub

sub onClosing()
    stopScan()
    rh_cancelRequests()
end sub

sub onButton()
    label = m.labels[m.buttons.buttonSelected]
    if label = "Try Again" then
        m.top.action = { type: "retry" }
    else if label = "Scan My Network" then
        startScan()
    else if label = "Enter Address" then
        enterAddress()
    end if
end sub

' ---------------------------------------------------------------- scanning

sub startScan()
    stopScan()
    m.foundServers = []
    m.found.content = rh_listContent([], "")
    m.scanFill.width = 0
    m.scanStatus.text = "Looking for ReelHouse servers..."
    m.scanner = CreateObject("roSGNode", "ScanTask")
    m.scanner.observeField("found", "onScanFound")
    m.scanner.observeField("progress", "onScanProgress")
    m.scanner.observeField("done", "onScanDone")
    m.scanner.control = "RUN"
end sub

sub stopScan()
    if m.scanner = invalid then return
    m.scanner.unobserveField("found")
    m.scanner.unobserveField("progress")
    m.scanner.unobserveField("done")
    m.scanner.control = "STOP"
    m.scanner = invalid
end sub

sub onScanFound()
    if m.scanner = invalid then return
    m.foundServers = m.scanner.found
    tiles = []
    for each s in m.foundServers
        t = rh_tile("server", s.url, s.address, "ReelHouse " + s.build, "", "square")
        t.right = "Select"
        tiles.Push(t)
    end for
    m.found.content = rh_listContent(tiles, "")
end sub

sub onScanProgress()
    if m.scanner = invalid then return
    progress = m.scanner.progress
    m.scanFill.width = 1180 * progress / 100
    subnets = rh_join(m.scanner.subnets, ", ")
    if subnets = "" then subnets = "this network"
    m.scanStatus.text = "Scanning " + subnets + "...  " + Str(progress).Trim() + "%"
end sub

sub onScanDone()
    if m.scanner = invalid or not m.scanner.done then return
    count = m.foundServers.Count()
    if m.scanner.subnets.Count() = 0 then
        m.scanStatus.text = "This Roku has no IPv4 network address to scan from. Enter the server's address instead."
    else if count = 0 then
        m.scanStatus.text = "No ReelHouse server answered on port 3350. Check it is running, or enter its address."
    else if count = 1 then
        m.scanStatus.text = "Found 1 server. Select it to connect."
        m.found.setFocus(true)
    else
        m.scanStatus.text = "Found " + Str(count).Trim() + " servers. Select one to connect."
        m.found.setFocus(true)
    end if
    stopScan()
end sub

sub onFoundSelected()
    i = m.found.itemSelected
    if i < 0 or i >= m.foundServers.Count() then return
    stopScan()
    m.top.action = { type: "serverChosen", url: m.foundServers[i].url }
end sub

' ---------------------------------------------------------------- typing an address

sub enterAddress()
    start = rh_displayServer(rh_getStr(m.top.params, "current"))
    if start = "" then start = ownSubnetPrefix()
    rh_openKeyboard("Server address", "For example 192.168.1.20 or 192.168.1.20:3350", start, false, "onAddressEntered")
end sub

function ownSubnetPrefix() as string
    addresses = CreateObject("roDeviceInfo").GetIPAddrs()
    if rh_isAA(addresses) then
        for each iface in addresses
            prefix = rh_subnetPrefix(addresses[iface])
            if prefix <> "" then return prefix
        end for
    end if
    return ""
end function

sub onAddressEntered()
    if m.keyboard = invalid then return
    pressed = m.keyboard.buttonSelected
    typed = m.keyboard.text
    rh_closeKeyboard()
    m.buttons.setFocus(true)
    if pressed <> 0 then return
    url = rh_normalizeServer(typed)
    if url = "" then
        m.error.text = "That doesn't look like a server address. Type its IP address, like 192.168.1.20."
        return
    end if
    m.error.text = ""
    m.scanStatus.text = "Checking " + rh_displayServer(url) + "..."
    m.probing = url
    rh_api("GET", "/api/health", { server: url, noCookie: true, timeout: 6000 }, onProbe)
end sub

sub onProbe(resp as object)
    url = m.probing
    if resp.ok and rh_isReelHouseHealth(resp.data) then
        m.top.action = { type: "serverChosen", url: url }
        return
    end if
    m.scanStatus.text = ""
    if resp.ok then
        m.error.text = "Something answered at " + rh_displayServer(url) + ", but it isn't a ReelHouse server."
    else
        m.error.text = "Couldn't reach " + rh_displayServer(url) + ". " + resp.error
    end if
end sub

function onKeyEvent(key as string, press as boolean) as boolean
    if not press then return false
    if key = "right" and m.buttons.isInFocusChain() and m.foundServers.Count() > 0 then
        m.found.setFocus(true)
        return true
    end if
    if key = "left" and m.found.isInFocusChain() then
        m.buttons.setFocus(true)
        return true
    end if
    return false
end function
