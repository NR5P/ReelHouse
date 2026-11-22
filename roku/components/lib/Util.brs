' ReelHouse for Roku - pure helpers: type checks, strings, URLs, cookies, formatting.
'
' Nothing in here touches SceneGraph, the network or the registry, so the whole file runs under
' the brs command-line interpreter too - tests/run_tests.brs exercises it. Keep it that way.

' ---------------------------------------------------------------- types

function rh_isString(v as dynamic) as boolean
    t = type(v)
    return t = "String" or t = "roString"
end function

function rh_isNumber(v as dynamic) as boolean
    t = type(v)
    return t = "Integer" or t = "roInt" or t = "Float" or t = "roFloat" or t = "Double" or t = "roDouble" or t = "LongInteger" or t = "roLongInteger"
end function

function rh_isBool(v as dynamic) as boolean
    t = type(v)
    return t = "Boolean" or t = "roBoolean"
end function

function rh_isArray(v as dynamic) as boolean
    return type(v) = "roArray"
end function

function rh_isAA(v as dynamic) as boolean
    return type(v) = "roAssociativeArray"
end function

' aa[key], or `fallback` when aa is not an object or the key is missing/null.
function rh_get(aa as dynamic, key as string, fallback = invalid as dynamic) as dynamic
    if rh_isAA(aa) then
        v = aa.Lookup(key)
        if v <> invalid then return v
    end if
    return fallback
end function

function rh_getStr(aa as dynamic, key as string, fallback = "" as string) as string
    v = rh_get(aa, key)
    if rh_isString(v) then return v
    if rh_isNumber(v) then return rh_numStr(v)
    return fallback
end function

function rh_getNum(aa as dynamic, key as string, fallback = 0 as dynamic) as dynamic
    v = rh_get(aa, key)
    if rh_isNumber(v) then return v
    return fallback
end function

function rh_getBool(aa as dynamic, key as string) as boolean
    v = rh_get(aa, key)
    if rh_isBool(v) then return v
    return false
end function

function rh_getArr(aa as dynamic, key as string) as object
    v = rh_get(aa, key)
    if rh_isArray(v) then return v
    return []
end function

' ---------------------------------------------------------------- numbers and strings

' 12 -> "12", 6.25 -> "6.25"; never the leading space Str() adds.
function rh_numStr(v as dynamic) as string
    if not rh_isNumber(v) then return ""
    if v = Int(v) and Abs(v) < 2000000000 then return Str(Int(v)).Trim()
    return Str(v).Trim()
end function

function rh_intStr(v as dynamic) as string
    if not rh_isNumber(v) then return "0"
    return Str(Int(v)).Trim()
end function

' One decimal place: 6.199999 -> "6.2", 7 -> "7.0".
function rh_oneDecimal(v as dynamic) as string
    if not rh_isNumber(v) then return ""
    tenths = Int(v * 10 + 0.5)
    whole = Int(tenths / 10)
    return Str(whole).Trim() + "." + Str(tenths - whole * 10).Trim()
end function

function rh_pad2(n as integer) as string
    if n < 10 then return "0" + Str(n).Trim()
    return Str(n).Trim()
end function

' "1:02:03" or "4:05".
function rh_formatClock(seconds as dynamic) as string
    if not rh_isNumber(seconds) then seconds = 0
    if seconds < 0 then seconds = 0
    total = Int(seconds)
    h = Int(total / 3600)
    mins = Int((total - h * 3600) / 60)
    s = total - h * 3600 - mins * 60
    if h > 0 then return Str(h).Trim() + ":" + rh_pad2(mins) + ":" + rh_pad2(s)
    return Str(mins).Trim() + ":" + rh_pad2(s)
end function

' "1h 42m" / "48m" from minutes.
function rh_minutesLabel(minutes as dynamic) as string
    if not rh_isNumber(minutes) then return ""
    if minutes <= 0 then return ""
    whole = Int(minutes + 0.5)
    if whole >= 60 then return Str(Int(whole / 60)).Trim() + "h " + Str(whole mod 60).Trim() + "m"
    return Str(whole).Trim() + "m"
end function

' Joins the non-empty strings of `parts` with `sep`.
function rh_join(parts as object, sep as string) as string
    out = ""
    for each p in parts
        text = ""
        if rh_isString(p) then text = p
        if text <> "" then
            if out <> "" then out = out + sep
            out = out + text
        end if
    end for
    return out
end function

function rh_isDigits(s as string) as boolean
    if s = "" then return false
    for i = 1 to Len(s)
        c = Asc(Mid(s, i, 1))
        if c < 48 or c > 57 then return false
    end for
    return true
end function

function rh_startsWith(s as string, prefix as string) as boolean
    return Len(s) >= Len(prefix) and Left(s, Len(prefix)) = prefix
end function

function rh_contains(list as object, value as string) as boolean
    for each v in list
        if v = value then return true
    end for
    return false
end function

' "mp3,aac,flac" -> ["mp3", "aac", "flac"], lower-cased and trimmed.
function rh_csv(s as string) as object
    out = []
    for each part in s.Split(",")
        p = LCase(part.Trim())
        if p <> "" then out.Push(p)
    end for
    return out
end function

' ---------------------------------------------------------------- server addresses

' What someone typed into the address keyboard, as the base URL every request is built on.
'   "192.168.1.20"            -> "http://192.168.1.20:3350"
'   "192.168.1.20:8080"       -> "http://192.168.1.20:8080"
'   "http://nas.local"        -> "http://nas.local:3350"
'   "https://192.168.1.20"    -> "http://192.168.1.20:3350"  (see below)
'   "https://media.example.com:443/" -> "https://media.example.com:443"
' Returns "" for anything that isn't an address.
'
' The server's own HTTPS port (3453) uses a certificate authority it made itself, which a Roku
' has no way to trust, so an https address on that port (or with no port) becomes the server's
' plain-HTTP port instead. An https address on any other port is kept: that's a reverse proxy,
' which may well have a real certificate.
function rh_normalizeServer(raw as dynamic) as string
    if not rh_isString(raw) then return ""
    s = raw.Trim()
    if s = "" then return ""
    scheme = "http"
    lower = LCase(s)
    if rh_startsWith(lower, "http://") then
        s = Mid(s, 8)
    else if rh_startsWith(lower, "https://") then
        scheme = "https"
        s = Mid(s, 9)
    else if Instr(1, lower, "://") > 0 then
        return ""
    end if
    slash = Instr(1, s, "/")
    if slash > 0 then s = Left(s, slash - 1)
    question = Instr(1, s, "?")
    if question > 0 then s = Left(s, question - 1)
    host = s
    port = ""
    colon = Instr(1, s, ":")
    if colon > 0 then
        host = Left(s, colon - 1)
        port = Mid(s, colon + 1)
        if not rh_isDigits(port) then return ""
        if Val(port) < 1 or Val(port) > 65535 then return ""
    end if
    if not rh_isHostName(host) then return ""
    if scheme = "https" and (port = "" or port = "3453") then
        scheme = "http"
        port = "3350"
    end if
    if port = "" then port = "3350"
    return scheme + "://" + LCase(host) + ":" + port
end function

' Letters, digits, dots and dashes; no empty labels.
function rh_isHostName(host as string) as boolean
    if host = "" or Len(host) > 253 then return false
    if Left(host, 1) = "." or Right(host, 1) = "." then return false
    if Instr(1, host, "..") > 0 then return false
    for i = 1 to Len(host)
        c = Asc(Mid(host, i, 1))
        ok = (c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c = 45 or c = 46
        if not ok then return false
    end for
    return true
end function

' "http://192.168.1.20:3350" -> "192.168.1.20:3350", for showing on screen.
function rh_displayServer(url as string) as string
    s = url
    if rh_startsWith(LCase(s), "http://") then s = Mid(s, 8)
    if rh_startsWith(LCase(s), "https://") then s = Mid(s, 9)
    return s
end function

' The 253 neighbours of `ip` on its /24 ("192.168.1.50" -> http://192.168.1.1:3350 ...), itself
' left out. [] for anything that isn't a private-looking dotted IPv4 address.
function rh_subnetCandidates(ip as string, port as integer) as object
    out = []
    parts = ip.Split(".")
    if parts.Count() <> 4 then return out
    for each p in parts
        if not rh_isDigits(p) or Val(p) > 255 then return out
    end for
    if parts[0] = "127" or (parts[0] = "169" and parts[1] = "254") then return out
    prefix = parts[0] + "." + parts[1] + "." + parts[2] + "."
    own = Val(parts[3])
    portText = Str(port).Trim()
    for host = 1 to 254
        if host <> own then out.Push("http://" + prefix + Str(host).Trim() + ":" + portText)
    end for
    return out
end function

' "192.168.1.50" -> "192.168.1." (what the address keyboard starts with), else "".
function rh_subnetPrefix(ip as string) as string
    parts = ip.Split(".")
    if parts.Count() <> 4 then return ""
    return parts[0] + "." + parts[1] + "." + parts[2] + "."
end function

' ---------------------------------------------------------------- URLs

' Percent-encodes a query value or path segment (RFC 3986 unreserved characters kept), writing
' non-ASCII characters as their UTF-8 bytes.
function rh_urlEncode(s as dynamic) as string
    if rh_isNumber(s) then return rh_numStr(s)
    if rh_isBool(s) then
        if s then return "true"
        return "false"
    end if
    if not rh_isString(s) then return ""
    out = ""
    for i = 1 to Len(s)
        ch = Mid(s, i, 1)
        c = Asc(ch)
        if (c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c = 45 or c = 46 or c = 95 or c = 126 then
            out = out + ch
        else
            for each b in rh_utf8Bytes(c)
                out = out + "%" + rh_hex2(b)
            end for
        end if
    end for
    return out
end function

function rh_utf8Bytes(cp as integer) as object
    if cp < 0 then cp = 63
    if cp < &h80 then return [cp]
    if cp < &h800 then return [&hC0 or (cp >> 6), &h80 or (cp and &h3F)]
    if cp < &h10000 then return [&hE0 or (cp >> 12), &h80 or ((cp >> 6) and &h3F), &h80 or (cp and &h3F)]
    return [&hF0 or (cp >> 18), &h80 or ((cp >> 12) and &h3F), &h80 or ((cp >> 6) and &h3F), &h80 or (cp and &h3F)]
end function

function rh_hex2(b as integer) as string
    digits = "0123456789ABCDEF"
    return Mid(digits, Int(b / 16) + 1, 1) + Mid(digits, (b mod 16) + 1, 1)
end function

' {sort: "title", limit: 60} -> "limit=60&sort=title" (keys in order, empty values left out).
function rh_queryString(query as dynamic) as string
    if not rh_isAA(query) then return ""
    out = ""
    keys = query.Keys()
    keys.Sort()
    for each key in keys
        v = query[key]
        text = ""
        if rh_isString(v) or rh_isNumber(v) or rh_isBool(v) then text = rh_urlEncode(v)
        if text <> "" then
            if out <> "" then out = out + "&"
            out = out + rh_urlEncode(key) + "=" + text
        end if
    end for
    return out
end function

' A request URL: the server plus a path from the API ("/api/media/home"), plus a query. An
' absolute path (http...) is used as it is. A path that already has a query keeps it.
function rh_buildUrl(server as string, path as string, query = invalid as dynamic) as string
    url = rh_absUrl(server, path)
    if url = "" then return ""
    qs = rh_queryString(query)
    if qs = "" then return url
    if Instr(1, url, "?") > 0 then return url + "&" + qs
    return url + "?" + qs
end function

' Artwork and stream paths come relative to the server ("/api/media/items/x/poster").
function rh_absUrl(server as string, path as dynamic) as string
    if not rh_isString(path) then return ""
    if path = "" then return ""
    lower = LCase(path)
    if rh_startsWith(lower, "http://") or rh_startsWith(lower, "https://") then return path
    if server = "" then return ""
    base = server
    if Right(base, 1) = "/" then base = Left(base, Len(base) - 1)
    if Left(path, 1) <> "/" then return base + "/" + path
    return base + path
end function

' Adds name=value to a URL unless it already has that parameter.
function rh_withParam(url as string, name as string, value as string) as string
    if url = "" then return ""
    if Instr(1, url, "?" + name + "=") > 0 or Instr(1, url, "&" + name + "=") > 0 then return url
    if Instr(1, url, "?") > 0 then return url + "&" + name + "=" + rh_urlEncode(value)
    return url + "?" + name + "=" + rh_urlEncode(value)
end function

' ---------------------------------------------------------------- session cookie

' Reads the session cookie out of a response's headers (roUrlEvent.GetResponseHeadersArray():
' an array of one-entry objects, so repeated Set-Cookie headers all survive).
' Returns invalid when the response didn't touch the cookie, "" when it deleted it (sign-out),
' else "reelhouse_session=<value>", ready for a Cookie header.
function rh_sessionCookieFromHeaders(headers as dynamic, cookieName as string) as dynamic
    if not rh_isArray(headers) then return invalid
    result = invalid
    for each header in headers
        if rh_isAA(header) then
            for each key in header
                if LCase(key) = "set-cookie" then
                    parsed = rh_parseSetCookie(header[key], cookieName)
                    if parsed <> invalid then result = parsed
                end if
            end for
        end if
    end for
    return result
end function

' One Set-Cookie value. invalid when it's a different cookie; "" when it deletes ours.
function rh_parseSetCookie(value as dynamic, cookieName as string) as dynamic
    if not rh_isString(value) then return invalid
    parts = value.Split(";")
    if parts.Count() = 0 then return invalid
    first = parts[0].Trim()
    eq = Instr(1, first, "=")
    if eq <= 1 then return invalid
    name = Left(first, eq - 1).Trim()
    if name <> cookieName then return invalid
    cookieValue = Mid(first, eq + 1).Trim()
    if cookieValue = "" then return ""
    for i = 1 to parts.Count() - 1
        attr = LCase(parts[i].Trim())
        if rh_startsWith(attr, "max-age=") and Val(Mid(attr, 9)) <= 0 then return ""
        if rh_startsWith(attr, "expires=") and Instr(1, attr, "1970") > 0 then return ""
    end for
    return name + "=" + cookieValue
end function

' ---------------------------------------------------------------- errors

' The words to show for a failed request: the server's own `{ error }` / `{ errors: [] }` when
' it sent one, else something that names the actual problem.
function rh_errorMessage(status as integer, data as dynamic, failure as dynamic) as string
    message = rh_getStr(data, "error")
    if message = "" then
        errors = rh_getArr(data, "errors")
        lines = []
        for each e in errors
            if rh_isString(e) then lines.Push(e)
        end for
        message = rh_join(lines, Chr(10))
    end if
    if message <> "" then return message
    if status = 401 then return "This server requires you to sign in."
    if status = 403 then return "Your account isn't allowed to do that."
    if status = 404 then return "Not found on the server (it may be switched off in Settings)."
    if status = 429 then return "Too many sign-in attempts. Wait a few minutes and try again."
    if status = -28 or status = 0 then return "The server took too long to answer."
    if status < 0 then
        reason = ""
        if rh_isString(failure) then reason = failure
        if reason <> "" then return "Can't reach the server: " + reason
        return "Can't reach the server. Check it is running and on the same network as this Roku."
    end if
    return "Server request failed (HTTP " + Str(status).Trim() + ")."
end function
