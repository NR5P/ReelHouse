' PosterItem - see PosterItem.xml.

sub init()
    m.frame = m.top.findNode("frame")
    m.card = m.top.findNode("card")
    m.cardLabel = m.top.findNode("cardLabel")
    m.cardSub = m.top.findNode("cardSub")
    m.art = m.top.findNode("art")
    m.badge = m.top.findNode("watchedBadge")
    m.barTrack = m.top.findNode("barTrack")
    m.barFill = m.top.findNode("barFill")
    m.title = m.top.findNode("title")
    m.subtitle = m.top.findNode("subtitle")
    m.isAction = false
    m.art.observeField("loadStatus", "onArtStatus")
end sub

sub onContent()
    content = m.top.itemContent
    if content = invalid then return
    m.isAction = content.kind = "action"
    m.title.text = content.title
    m.subtitle.text = content.subtitle
    m.cardLabel.text = content.title
    m.cardSub.text = ""
    if m.isAction then m.cardSub.text = content.subtitle
    m.art.uri = ""
    if not m.isAction then m.art.uri = content.HDPosterUrl
    m.badge.visible = (content.watched = true) and not m.isAction
    ' RowList and MarkupGrid set width/height from their item sizes; if a parent doesn't, fall
    ' back to the size this tile's shape is drawn at (Ui.brs rh_shapeSize).
    if m.top.width <= 0 or m.top.height <= 0 then
        sizes = { poster: [230, 420], wide: [420, 310], square: [270, 360], action: [300, 170] }
        size = sizes[content.shape]
        if size = invalid then size = sizes.square
        m.top.width = size[0]
        m.top.height = size[1]
    end if
    layout()
    onArtStatus()
end sub

' Artwork area: everything above the two text lines (the whole tile for an action card).
function artHeight() as float
    if m.isAction then return m.top.height
    return m.top.height - 70
end function

sub layout()
    w = m.top.width
    h = artHeight()
    if w <= 0 or h <= 0 then return
    edge = 6
    top = m.top.findNode("frameTop")
    top.width = w
    top.height = edge
    bottom = m.top.findNode("frameBottom")
    bottom.translation = [0, h - edge]
    bottom.width = w
    bottom.height = edge
    left = m.top.findNode("frameLeft")
    left.width = edge
    left.height = h
    right = m.top.findNode("frameRight")
    right.translation = [w - edge, 0]
    right.width = edge
    right.height = h
    m.card.width = w
    m.card.height = h
    m.cardLabel.translation = [12, 0]
    m.cardLabel.width = w - 24
    m.cardLabel.height = h
    m.cardSub.translation = [12, h - 44]
    m.cardSub.width = w - 24
    m.art.width = w
    m.art.height = h
    ' Decode no bigger than drawn: a page of full-size posters is a lot of texture memory.
    m.art.loadWidth = w
    m.art.loadHeight = h
    m.badge.translation = [w - 148, 8]
    m.barTrack.translation = [0, h - 8]
    m.barTrack.width = w
    m.barTrack.height = 8
    m.barFill.translation = [0, h - 8]
    m.barFill.height = 8
    m.title.translation = [0, h + 12]
    m.title.width = w
    m.subtitle.translation = [0, h + 44]
    m.subtitle.width = w
    m.title.visible = not m.isAction
    m.subtitle.visible = not m.isAction
    if m.isAction then
        m.card.color = "0x2A1C30FF"
        m.cardLabel.color = "0xFFC24BFF"
    else
        m.card.color = "0x1F1629FF"
        m.cardLabel.color = "0xF4E9DAFF"
    end if
    updateProgress()
end sub

sub updateProgress()
    content = m.top.itemContent
    progress = -1
    if content <> invalid and not m.isAction then progress = content.progress
    show = progress > 0
    m.barTrack.visible = show
    m.barFill.visible = show
    if show then m.barFill.width = m.top.width * progress
end sub

' The text card stays visible underneath until the artwork has actually arrived.
sub onArtStatus()
    ready = m.art.loadStatus = "ready" and m.art.uri <> ""
    m.cardLabel.visible = not ready
    m.cardSub.visible = not ready
end sub

sub onFocus()
    level = m.top.focusPercent * m.top.rowFocusPercent
    ' Each container sets only its own flag - and a RowList sets gridHasFocus to false for its
    ' tiles - so read the one that belongs to the container this tile is in.
    if inRowList() then
        hasFocus = m.top.rowListHasFocus
    else
        hasFocus = m.top.gridHasFocus
    end if
    if not hasFocus then level = 0
    m.frame.opacity = level
    if level > 0.5 then
        m.title.color = "0xFFC24BFF"
    else
        m.title.color = "0xF4E9DAFF"
    end if
end sub

' Looked up once the tile is attached (a field can change before it has a parent).
function inRowList() as boolean
    if m.inRowList <> invalid then return m.inRowList
    node = m.top.getParent()
    if node = invalid then return false
    found = false
    while node <> invalid
        if node.subtype() = "RowList" then
            found = true
            exit while
        end if
        node = node.getParent()
    end while
    m.inRowList = found
    return found
end function
