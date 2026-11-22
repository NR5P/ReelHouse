' ReelHouse for Roku - starting server requests from a component (render thread).
'
'   rh_api("GET", "/api/media/home", { query: {...}, tag: "home" }, onHome)
'   sub onHome(resp as object) ... resp.ok, resp.data, resp.error, resp.tag
'
' Each request runs on its own ApiTask (components/tasks/ApiTask.xml). The handler is a function
' of the calling component, passed by reference; pass invalid to fire and forget. The task is
' kept referenced in m.rhTasks until it answers, then let go.

function rh_api(method as string, path as string, options = invalid as dynamic, handler = invalid as dynamic) as object
    req = { method: method, path: path }
    if rh_isAA(options) then req.Append(options)
    if m.rhTasks = invalid then m.rhTasks = {}
    if m.rhSeq = invalid then m.rhSeq = 0
    m.rhSeq = m.rhSeq + 1
    key = "req" + Str(m.rhSeq).Trim()
    req.key = key
    task = CreateObject("roSGNode", "ApiTask")
    m.rhTasks[key] = { task: task, handler: handler }
    task.observeField("response", "rh_onApiResponse")
    task.request = req
    task.control = "RUN"
    return task
end function

sub rh_onApiResponse(event as object)
    resp = event.getData()
    key = rh_getStr(resp, "key")
    if m.rhTasks = invalid then return
    entry = m.rhTasks[key]
    if entry = invalid then return
    m.rhTasks.Delete(key)
    entry.task.unobserveField("response")
    handler = entry.handler
    ' A local variable, not entry.handler(...): calling it through the object would make `m`
    ' that object inside the handler instead of this component.
    if type(handler) = "Function" or type(handler) = "roFunction" then handler(resp)
end sub

' Forgets every request still in flight; their answers are dropped (the screen is going away).
sub rh_cancelRequests()
    if m.rhTasks = invalid then return
    for each key in m.rhTasks
        entry = m.rhTasks[key]
        entry.task.unobserveField("response")
        entry.task.control = "STOP"
    end for
    m.rhTasks = {}
end sub
