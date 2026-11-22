' ReelHouse for Roku - entry point.
'
' Creates the SceneGraph screen, fills in the global node every component reads (server address,
' session cookie, what this Roku can decode) and runs the event loop until the channel exits.
' Everything else happens in MainScene and the components under components/.

sub Main(args as dynamic)
    screen = CreateObject("roSGScreen")
    port = CreateObject("roMessagePort")
    screen.setMessagePort(port)

    ' Fields must exist before CreateScene: every component's init() may read them.
    globalNode = screen.getGlobalNode()
    store = CreateObject("roRegistrySection", "ReelHouse")
    serverUrl = ""
    cookie = ""
    if store.Exists("serverUrl") then serverUrl = store.Read("serverUrl")
    if store.Exists("cookie") then cookie = store.Read("cookie")

    device = CreateObject("roDeviceInfo")
    appInfo = CreateObject("roAppInfo")
    globalNode.addFields({
        serverUrl: serverUrl
        cookie: cookie
        authEnabled: true
        username: ""
        role: ""
        authLost: false
        deviceId: device.GetChannelClientId()
        deviceName: DeviceDisplayName(device)
        appVersion: appInfo.GetVersion()
        videoCodecs: VideoCodecs(device)
        videoAudioCodecs: VideoAudioCodecs(device)
        musicCodecs: MusicCodecs(device)
        mediaEnabled: false
        musicEnabled: false
        podcastsEnabled: false
        launchArgs: args
    })
    globalNode.addField("player", "node", false)

    scene = screen.CreateScene("MainScene")
    screen.show()

    while true
        msg = wait(0, port)
        if type(msg) = "roSGScreenEvent" and msg.isScreenClosed() then return
    end while
end sub

' "Living Room Roku" when the owner named it, else the model's name.
function DeviceDisplayName(device as object) as string
    name = ""
    if FindMemberFunction(device, "GetFriendlyName") <> invalid then name = device.GetFriendlyName()
    if name = invalid or name = "" then name = device.GetModelDisplayName()
    if name = invalid or name = "" then name = "Roku"
    return name
end function

' The playback endpoint's `video` list (MOVIES.md, Playback). Every Roku decodes H.264; HEVC
' only the 4K models, which say so through CanDecodeVideo.
function VideoCodecs(device as object) as string
    codecs = "h264"
    if CanDecode(device.CanDecodeVideo({ Codec: "hevc" })) then codecs = codecs + ",hevc"
    return codecs
end function

' The playback endpoint's `audio` list. AAC always; Dolby Digital (Plus) when the Roku decodes it
' or can pass it through to the receiver; MP3 plays inside a directly-played MP4 (the server
' converts it to AAC inside HLS anyway).
function VideoAudioCodecs(device as object) as string
    codecs = "aac,mp3"
    if CanDecode(device.CanDecodeAudio({ Codec: "ac3" })) then codecs = codecs + ",ac3"
    if CanDecode(device.CanDecodeAudio({ Codec: "eac3" })) then codecs = codecs + ",eac3"
    return codecs
end function

' The music stream's `codecs` list (MUSIC_AND_PODCASTS.md, Streaming). Anything not listed the
' server converts to AAC in an .m4a, which every Roku plays.
function MusicCodecs(device as object) as string
    codecs = "mp3,aac"
    if CanDecode(device.CanDecodeAudio({ Codec: "flac" })) then codecs = codecs + ",flac"
    if CanDecode(device.CanDecodeAudio({ Codec: "alac" })) then codecs = codecs + ",alac"
    if CanDecode(device.CanDecodeAudio({ Codec: "lpcm" })) then codecs = codecs + ",wav"
    return codecs
end function

function CanDecode(answer as dynamic) as boolean
    return type(answer) = "roAssociativeArray" and answer.result = true
end function
