' ReelHouse for Roku - what survives a restart, in the registry (section "ReelHouse"):
'   serverUrl  the chosen server, e.g. http://192.168.1.20:3350
'   cookie     the session cookie, "reelhouse_session=<value>", exactly as sent back to the server
' The username and password are never stored: only the cookie the server issued for them.
' Works on the render thread and in Task threads.

function rh_registry() as object
    return CreateObject("roRegistrySection", "ReelHouse")
end function

sub rh_saveServer(url as string)
    reg = rh_registry()
    reg.Write("serverUrl", url)
    reg.Flush()
end sub

sub rh_saveCookie(cookie as string)
    reg = rh_registry()
    if cookie = "" then
        reg.Delete("cookie")
    else
        reg.Write("cookie", cookie)
    end if
    reg.Flush()
end sub
