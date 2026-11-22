' ListRowItem - see ListRowItem.xml.

sub init()
    m.bg = m.top.findNode("bg")
    m.focusBg = m.top.findNode("focusBg")
    m.art = m.top.findNode("art")
    m.index = m.top.findNode("index")
    m.title = m.top.findNode("title")
    m.subtitle = m.top.findNode("subtitle")
    m.detail = m.top.findNode("detail")
    m.right = m.top.findNode("right")
    m.barTrack = m.top.findNode("barTrack")
    m.barFill = m.top.findNode("barFill")
    m.focused = false
end sub

sub onContent()
    content = m.top.itemContent
    if content = invalid then return
    m.title.text = content.title
    m.subtitle.text = content.subtitle
    m.detail.text = content.detail
    m.right.text = content.right
    m.index.text = content.index
    m.art.uri = content.HDPosterUrl
    layout()
end sub

sub layout()
    w = m.top.width
    h = m.top.height
    content = m.top.itemContent
    if w <= 0 or h <= 0 or content = invalid then return
    m.bg.width = w
    m.bg.height = h
    m.focusBg.width = w
    m.focusBg.height = h

    pad = 12
    x = pad
    artH = h - pad * 2
    hasArt = content.HDPosterUrl <> "" and content.index = ""
    m.art.visible = hasArt
    if hasArt then
        artW = artH
        if content.shape = "wide" then artW = Int(artH * 16 / 9)
        m.art.translation = [x, pad]
        m.art.width = artW
        m.art.height = artH
        m.art.loadWidth = artW
        m.art.loadHeight = artH
        x = x + artW + 20
    end if
    m.index.visible = content.index <> ""
    if content.index <> "" then
        m.index.translation = [x, 0]
        m.index.width = 60
        m.index.height = h
        x = x + 72
    end if

    rightW = 160
    textW = w - x - rightW - pad * 2
    hasDetail = content.detail <> "" and h >= 120
    m.detail.visible = hasDetail
    top = Int((h - 70) / 2)
    if hasDetail then top = pad + 4
    m.title.translation = [x, top]
    m.title.width = textW
    m.subtitle.translation = [x, top + 36]
    m.subtitle.width = textW
    if hasDetail then
        m.detail.translation = [x, top + 66]
        m.detail.width = textW
        m.detail.height = h - top - 66 - pad
        m.detail.wrap = true
        m.detail.maxLines = 2
    end if
    m.right.translation = [w - rightW - pad, 0]
    m.right.width = rightW
    m.right.height = h

    progress = content.progress
    m.barTrack.visible = progress > 0
    m.barFill.visible = progress > 0
    if progress > 0 then
        m.barTrack.translation = [x, h - pad - 6]
        m.barTrack.width = textW
        m.barTrack.height = 6
        m.barFill.translation = [x, h - pad - 6]
        m.barFill.width = textW * progress
        m.barFill.height = 6
    end if
    onFocus()
end sub

sub onFocus()
    level = m.top.focusPercent
    if not m.top.listHasFocus then level = 0
    m.focusBg.opacity = level
    focused = level > 0.5
    if focused = m.focused and m.top.itemContent <> invalid then return
    m.focused = focused
    if focused then
        dark = "0x0E0A12FF"
        m.title.color = dark
        m.subtitle.color = "0x3A2410FF"
        m.detail.color = "0x3A2410FF"
        m.right.color = dark
        m.index.color = dark
        m.barFill.color = "0xE23D3DFF"
    else
        m.title.color = "0xF4E9DAFF"
        m.subtitle.color = "0xA99A8EFF"
        m.detail.color = "0xA99A8EFF"
        m.right.color = "0xA99A8EFF"
        m.index.color = "0xA99A8EFF"
        m.barFill.color = "0xFFC24BFF"
    end if
end sub
