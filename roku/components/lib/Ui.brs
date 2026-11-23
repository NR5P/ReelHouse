' ReelHouse for Roku - look and feel shared by every screen: the "movie palace" palette, tile
' sizes, ContentNode builders for RowList/MarkupGrid/MarkupList, button styling and the
' on-screen keyboard. Render thread only (needs Util.brs).

function rh_colors() as object
    return {
        gold: "0xFFC24BFF"
        curtain: "0xE23D3DFF"
        amber: "0xFF9A3CFF"
        bg: "0x0E0A12FF"
        panel: "0x171020FF"
        card: "0x1F1629FF"
        text: "0xF4E9DAFF"
        dim: "0xA99A8EFF"
        dark: "0x0E0A12FF"
        shade: "0x0E0A12D9"
        track: "0x3A2B3AFF"
    }
end function

' [width, height] of one tile of each shape, artwork plus the two lines of text under it.
'' How many rows of `height`-tall tiles, `spacing` apart, fit between `top` and the bottom of a
' 1080-line screen (at least one).
function rh_rowsThatFit(top as integer, height as integer, spacing as integer) as integer
    rows = Int((1076 - top + spacing) / (height + spacing))
    if rows < 1 then rows = 1
    return rows
end function

function rh_shapeSize(shape as string) as object
    if shape = "poster" then return [230, 420]
    if shape = "wide" then return [420, 310]
    if shape = "square" then return [270, 360]
    return [300, 170]
end function

' A tile (Mappers.brs) as a ContentNode for PosterItem / ListRowItem.
function rh_tileNode(tile as object, server as string) as object
    node = CreateObject("roSGNode", "ContentNode")
    node.addField("kind", "string", false)
    node.addField("itemId", "string", false)
    node.addField("subtitle", "string", false)
    node.addField("detail", "string", false)
    node.addField("right", "string", false)
    node.addField("index", "string", false)
    node.addField("shape", "string", false)
    node.addField("progress", "float", false)
    node.addField("watched", "boolean", false)
    node.addField("raw", "assocarray", false)
    raw = tile.raw
    if not rh_isAA(raw) then raw = {}
    node.setFields({
        title: tile.title
        kind: tile.kind
        itemId: tile.id
        subtitle: tile.subtitle
        detail: rh_getStr(tile, "detail")
        right: rh_getStr(tile, "right")
        index: rh_getStr(tile, "index")
        shape: tile.shape
        progress: 0.0 + tile.progress
        watched: tile.watched
        HDPosterUrl: rh_absUrl(server, tile.art)
        raw: raw
    })
    return node
end function

' Tiles in a flat ContentNode (MarkupGrid / MarkupList content).
function rh_listContent(tiles as object, server as string) as object
    root = CreateObject("roSGNode", "ContentNode")
    for each t in tiles
        root.appendChild(rh_tileNode(t, server))
    end for
    return root
end function

' Home's rows (Mappers.brs rh_homeRows) as RowList content.
function rh_rowListContent(rows as object, server as string) as object
    root = CreateObject("roSGNode", "ContentNode")
    for each r in rows
        row = root.createChild("ContentNode")
        row.title = r.title
        for each t in r.tiles
            row.appendChild(rh_tileNode(t, server))
        end for
    end for
    return root
end function

' The tile a ContentNode was made from, back as a plain object.
function rh_nodeTile(node as dynamic) as dynamic
    if node = invalid then return invalid
    return {
        kind: node.kind
        id: node.itemId
        title: node.title
        subtitle: node.subtitle
        shape: node.shape
        raw: node.raw
    }
end function

sub rh_styleButtons(group as object)
    c = rh_colors()
    group.textColor = c.text
    group.focusedTextColor = c.dark
    group.focusBitmapUri = "pkg:/images/button_focus.9.png"
    group.focusFootprintBitmapUri = "pkg:/images/button_footprint.9.png"
    group.iconUri = ""
    group.focusedIconUri = ""
    group.minWidth = 380
    group.buttonHeight = 72
end sub

' The on-screen keyboard. `callback` (a sub of the calling component) runs when a button is
' pressed: read m.keyboard.text, then rh_closeKeyboard(). Button 0 is OK, 1 is Cancel.
' StandardKeyboardDialog needs Roku OS 10; older firmware gets the classic KeyboardDialog.
function rh_openKeyboard(title as string, message as string, text as string, secure as boolean, callback as string) as object
    dlg = CreateObject("roSGNode", "StandardKeyboardDialog")
    if dlg <> invalid then
        dlg.title = title
        if message <> "" then dlg.message = [message]
        if secure then
            editBox = dlg.textEditBox
            if editBox <> invalid then editBox.secureMode = true
        end if
    else
        dlg = CreateObject("roSGNode", "KeyboardDialog")
        dlg.title = title
        if message <> "" then dlg.message = message
        if secure then
            keyboard = dlg.keyboard
            if keyboard <> invalid and keyboard.textEditBox <> invalid then keyboard.textEditBox.secureMode = true
        end if
    end if
    dlg.text = text
    dlg.buttons = ["OK", "Cancel"]
    dlg.observeField("buttonSelected", callback)
    m.keyboard = dlg
    m.top.getScene().dialog = dlg
    return dlg
end function

sub rh_closeKeyboard()
    if m.keyboard <> invalid then
        m.keyboard.unobserveField("buttonSelected")
        m.keyboard.close = true
    end if
    m.keyboard = invalid
end sub

' Shows/hides a whole set of nodes.
sub rh_show(nodes as object, visible as boolean)
    for each n in nodes
        if n <> invalid then n.visible = visible
    end for
end sub
