' LoginScreen - see LoginScreen.xml.

sub init()
    m.heading = m.top.findNode("heading")
    m.message = m.top.findNode("message")
    m.error = m.top.findNode("error")
    m.buttons = m.top.findNode("buttons")
    rh_styleButtons(m.buttons)
    m.buttons.minWidth = 760
    m.buttons.observeField("buttonSelected", "onButton")
    m.username = ""
    m.password = ""
    m.busy = false
    m.top.findNode("header").hint = "Back exits"
    m.top.observeField("params", "onParams")
    m.top.observeField("focusedChild", "onFocusChanged")
    m.top.observeField("closing", "onClosing")
end sub

sub onParams()
    m.heading.text = "Sign in to " + rh_displayServer(m.global.serverUrl)
    m.message.text = rh_getStr(m.top.params, "message")
    if m.message.text = "" then m.message.text = "This server asks everyone to sign in."
    m.username = m.global.username
    refreshButtons(0)
end sub

sub onFocusChanged()
    if m.top.hasFocus() then m.buttons.setFocus(true)
end sub

sub onClosing()
    m.password = ""
    rh_cancelRequests()
end sub

sub refreshButtons(focus as integer)
    user = m.username
    if user = "" then user = "(not set)"
    secret = "(not set)"
    if m.password <> "" then secret = String(Len(m.password), "*")
    m.buttons.buttons = ["Username:  " + user, "Password:  " + secret, "Sign In", "Change Server"]
    m.buttons.focusButton = focus
end sub

sub onButton()
    if m.busy then return
    i = m.buttons.buttonSelected
    if i = 0 then
        rh_openKeyboard("Username", "", m.username, false, "onUsernameEntered")
    else if i = 1 then
        rh_openKeyboard("Password", "", "", true, "onPasswordEntered")
    else if i = 2 then
        signIn()
    else if i = 3 then
        m.top.action = { type: "changeServer" }
    end if
end sub

sub onUsernameEntered()
    if m.keyboard = invalid then return
    pressed = m.keyboard.buttonSelected
    text = m.keyboard.text
    rh_closeKeyboard()
    if pressed = 0 then m.username = text.Trim()
    ' Straight on to the password when it's still empty.
    if pressed = 0 and m.password = "" then
        refreshButtons(1)
        m.buttons.setFocus(true)
        rh_openKeyboard("Password", "", "", true, "onPasswordEntered")
        return
    end if
    refreshButtons(0)
    m.buttons.setFocus(true)
end sub

sub onPasswordEntered()
    if m.keyboard = invalid then return
    pressed = m.keyboard.buttonSelected
    text = m.keyboard.text
    rh_closeKeyboard()
    if pressed = 0 then m.password = text
    if pressed = 0 and m.username <> "" and m.password <> "" then
        refreshButtons(2)
        m.buttons.setFocus(true)
        signIn()
        return
    end if
    refreshButtons(1)
    m.buttons.setFocus(true)
end sub

sub signIn()
    if m.username = "" or m.password = "" then
        m.error.text = "Enter your username and password first."
        return
    end if
    m.error.text = ""
    m.message.text = "Signing in..."
    m.busy = true
    body = { "username": m.username, "password": m.password }
    rh_api("POST", "/api/auth/login", { body: body, timeout: 15000 }, onSignIn)
end sub

sub onSignIn(resp as object)
    m.busy = false
    m.password = ""
    refreshButtons(1)
    if resp.ok then
        m.top.action = { type: "signedIn" }
        return
    end if
    m.message.text = ""
    if resp.status = 401 then
        m.error.text = "Invalid username or password."
    else
        m.error.text = resp.error
    end if
end sub
