' ApiTask - see ApiTask.xml for the request/response contract.
'
' The session cookie travels by hand: roUrlTransfer's own cookie jar lives and dies with each
' transfer object, so the cookie the server issues (at sign-in, and again whenever its sliding
' expiration renews it) is read out of Set-Cookie here, kept in m.global.cookie for every other
' request and for the Video/Audio nodes, and written to the registry for the next launch.

sub init()
    m.top.functionName = "execute"
end sub

sub execute()
    req = m.top.request
    if not rh_isAA(req) then req = {}
    server = rh_getStr(req, "server", m.global.serverUrl)
    path = rh_getStr(req, "path")
    url = rh_buildUrl(server, path, rh_get(req, "query"))
    method = UCase(rh_getStr(req, "method", "GET"))
    timeout = rh_getNum(req, "timeout", 20000)

    if url = "" then
        respond(req, 0, invalid, "No server address is set.")
        return
    end if

    port = CreateObject("roMessagePort")
    xfer = CreateObject("roUrlTransfer")
    xfer.SetMessagePort(port)
    xfer.SetUrl(url)
    xfer.RetainBodyOnError(true)
    xfer.EnableEncodings(true)
    if rh_startsWith(LCase(url), "https:") then
        xfer.SetCertificatesFile("common:/certs/ca-bundle.crt")
        xfer.InitClientCertificates()
    end if
    xfer.AddHeader("Accept", "application/json")
    cookie = m.global.cookie
    if not rh_getBool(req, "noCookie") and cookie <> "" then xfer.AddHeader("Cookie", cookie)

    started = false
    if method = "GET" then
        started = xfer.AsyncGetToString()
    else
        xfer.SetRequest(method)
        payload = ""
        body = rh_get(req, "body")
        if body <> invalid then
            payload = FormatJson(body)
            xfer.AddHeader("Content-Type", "application/json")
        end if
        started = xfer.AsyncPostFromString(payload)
    end if
    if not started then
        respond(req, -1, invalid, "Couldn't start the request.")
        return
    end if

    msg = wait(timeout, port)
    if type(msg) <> "roUrlEvent" then
        xfer.AsyncCancel()
        respond(req, -28, invalid, rh_errorMessage(-28, invalid, ""))
        return
    end if

    status = msg.GetResponseCode()
    text = msg.GetString()
    data = invalid
    if text <> invalid and text <> "" then data = ParseJson(text)

    ' Only from our own server: a probe of somebody else's address must not overwrite it.
    if not rh_getBool(req, "noCookie") then
        issued = rh_sessionCookieFromHeaders(msg.GetResponseHeadersArray(), "reelhouse_session")
        if issued <> invalid and issued <> m.global.cookie then
            m.global.cookie = issued
            rh_saveCookie(issued)
        end if
    end if

    ' A 401 anywhere but the sign-in routes means the session has gone: MainScene sends the
    ' viewer back to the sign-in screen.
    if status = 401 and not rh_startsWith(path, "/api/auth/") and not rh_getBool(req, "noCookie") then
        m.global.authLost = true
    end if

    errorText = ""
    if status < 200 or status >= 300 then errorText = rh_errorMessage(status, data, msg.GetFailureReason())
    respond(req, status, data, errorText)
end sub

sub respond(req as object, status as integer, data as dynamic, errorText as string)
    m.top.response = {
        key: rh_getStr(req, "key")
        tag: rh_get(req, "tag", "")
        ok: status >= 200 and status < 300
        status: status
        data: data
        error: errorText
    }
end sub
