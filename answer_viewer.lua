local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputText = require("ui/widget/inputtext")
local ScrollHtmlWidget = require("ui/widget/scrollhtmlwidget")
local Size = require("ui/size")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local _ = require("gettext")

local source = debug.getinfo(1, "S").source
local PLUGIN_DIR = source:match("^@(.*/)") or ""
local Renderer = dofile(PLUGIN_DIR .. "conversation_renderer.lua")
local Screen = Device.screen

local ConversationViewer = InputContainer:extend{
    is_always_active = true,
    title = nil,
    messages = nil,
    stream_text = nil,
    status = nil,
    busy = false,
    closed = false,
}

local VIEWER_CSS = [[
@page {
    margin: 0;
    font-family: 'Noto Sans CJK TC', 'Noto Sans Arabic', 'Noto Sans Devanagari UI', 'FreeSans', 'Noto Sans', sans-serif;
}
body {
    margin: 0;
    padding: 0;
    line-height: 1.3;
}
.user-message {
    display: block;
    margin: 0.55em 0;
    padding: 0.65em;
    background-color: #e3e3e3;
    border-left: 0.3em solid #888888;
}
.ai-message {
    display: block;
    margin: 0.55em 0;
    padding: 0.2em 0.35em;
}
.tool-message {
    display: block;
    margin: 0.55em 0;
    padding: 0.55em;
    background-color: #f2f2f2;
    border: 1px solid #aaaaaa;
}
.tool-call {
    margin: 0.1em 0;
}
.tool-detail {
    margin-top: 0.3em;
    color: #555555;
    font-size: 0.82em;
}
.role-label {
    margin-bottom: 0.35em;
    color: #555555;
    font-size: 0.72em;
    font-weight: bold;
}
.selection-label {
    margin: 0.3em 0 0.15em 0;
    color: #555555;
    font-size: 0.72em;
    font-weight: bold;
}
.selection-text {
    margin: 0 0 0.55em 0;
    padding-left: 0.55em;
    border-left: 0.15em solid #999999;
    font-size: 0.84em;
}
.message-separator {
    margin: 0.7em 0;
    border: 0;
    border-top: 1px solid #aaaaaa;
}
.stream-status, .empty-conversation {
    color: #666666;
    font-style: italic;
}
h1, h2, h3, h4, h5, h6 {
    margin: 0.7em 0 0.3em 0;
}
p {
    margin: 0.45em 0;
}
blockquote {
    margin: 0.5em 1em;
}
pre {
    margin: 0.5em 0;
    padding: 0.45em;
    background-color: #eeeeee;
    font-size: 0.82em;
}
code {
    font-family: monospace;
    font-size: 0.88em;
}
ol, ul {
    margin: 0.4em 0;
    padding-left: 1.5em;
}
li {
    margin: 0.15em 0;
}
table {
    border-collapse: collapse;
    font-size: 0.85em;
}
td, th {
    border: 1px solid black;
    padding: 0.2em;
}
]]

function ConversationViewer:_html()
    return Renderer.render(self.messages, self.stream_text, self.status)
end

function ConversationViewer:_buildScrollWidget(outer_height)
    local scroll_widget = ScrollHtmlWidget:new{
        html_body = self:_html(),
        css = VIEWER_CSS,
        default_font_size = Screen:scaleBySize(20),
        width = self.width - 2 * self.text_padding - 2 * self.text_margin,
        height = outer_height - 2 * self.text_padding - 2 * self.text_margin,
        dialog = self,
    }
    local original_on_tap = scroll_widget.onTapScrollText
    scroll_widget.onTapScrollText = function(widget, arg, ges)
        if self:_hideKeyboard() then return true end
        return original_on_tap(widget, arg, ges)
    end
    return scroll_widget
end

function ConversationViewer:_hideKeyboard()
    if not self.input_widget or not self.input_widget:isKeyboardVisible() then return false end
    self.input_widget:onCloseKeyboard()
    self.input_widget:unfocus()
    return true
end

function ConversationViewer:_submitInput()
    if self.closed or self.busy or not self.input_widget then return end
    local text = tostring(self.input_widget:getText() or "")
        :gsub("^%s+", "")
        :gsub("%s+$", "")
    if text == "" then return end
    self.input_widget:setText("")
    self.input_widget:onCloseKeyboard()
    if self.on_send then self.on_send(text) end
end

function ConversationViewer:init()
    self.align = "center"
    self.width = Screen:getWidth()
    self.height = Screen:getHeight()
    self.region = Geom:new{ w = self.width, h = self.height }
    self.text_padding = Size.padding.large
    self.text_margin = Size.margin.small
    self.key_events = self.key_events or {}
    if Device:isTouchDevice() then
        self.ges_events = {
            Tap = {
                GestureRange:new{
                    ges = "tap",
                    range = Geom:new{ w = self.width, h = self.height },
                },
            },
        }
    end
    if Device:hasKeys() then self.key_events.Close = {{ Device.input.group.Back }} end

    self.title_bar = TitleBar:new{
        width = self.width,
        align = "left",
        with_bottom_line = true,
        title = self.title or _("BookAgent conversation"),
        title_multilines = true,
        close_callback = function() self:onClose() end,
        show_parent = self,
    }

    self.input_widget = InputText:new{
        parent = self,
        text = "",
        hint = _("Message BookAgent…"),
        width = math.floor(self.width * 0.72),
        height = Screen:scaleBySize(72),
        scroll = true,
        enter_callback = function() self:_submitInput() end,
    }
    self.send_button = Button:new{
        text = _("Send"),
        id = "send",
        width = math.floor(self.width * 0.18),
        show_parent = self,
        enabled_func = function() return not self.busy end,
        callback = function() self:_submitInput() end,
    }
    self.composer = HorizontalGroup:new{
        align = "center",
        self.input_widget,
        self.send_button,
    }

    self.button_table = ButtonTable:new{
        width = self.width - 2 * Size.padding.default,
        zero_sep = true,
        show_parent = self,
        buttons = {{
            {
                text = _("Stop"),
                id = "stop",
                enabled_func = function() return self.busy == true end,
                callback = function() if self.on_stop then self.on_stop() end end,
            },
            {
                text = "⇱",
                callback = function() self.scroll_widget:scrollToRatio(0) end,
            },
            {
                text = "⇲",
                callback = function() self.scroll_widget:scrollToRatio(1) end,
            },
            {
                text = _("Close"),
                id = "close",
                callback = function() self:onClose() end,
            },
        }},
    }

    local outer_height = self.height
        - self.title_bar:getHeight()
        - self.composer:getSize().h
        - self.button_table:getSize().h
    self.scroll_widget = self:_buildScrollWidget(outer_height)
    self.text_frame = FrameContainer:new{
        padding = self.text_padding,
        margin = self.text_margin,
        bordersize = 0,
        self.scroll_widget,
    }
    self.frame = FrameContainer:new{
        radius = 0,
        bordersize = 0,
        padding = 0,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            self.title_bar,
            CenterContainer:new{
                dimen = Geom:new{ w = self.width, h = self.text_frame:getSize().h },
                self.text_frame,
            },
            CenterContainer:new{
                dimen = Geom:new{ w = self.width, h = self.composer:getSize().h },
                self.composer,
            },
            CenterContainer:new{
                dimen = Geom:new{ w = self.width, h = self.button_table:getSize().h },
                self.button_table,
            },
        },
    }
    self[1] = CenterContainer:new{ dimen = self.region, self.frame }
    self.scroll_widget:scrollToRatio(1)
end

function ConversationViewer:update(messages, stream_text, status, busy)
    if self.closed then return end
    self.messages = messages or self.messages
    self.stream_text = stream_text
    self.status = status
    self.busy = busy == true
    self.send_button:enableDisable(not self.busy)
    self.scroll_widget = self:_buildScrollWidget(self.text_frame:getSize().h)
    self.text_frame:clear()
    self.text_frame[1] = self.scroll_widget
    self.scroll_widget:scrollToRatio(1)
    UIManager:setDirty(self, "ui")
end

function ConversationViewer:onShow()
    UIManager:setDirty(self, "ui")
    return true
end

function ConversationViewer:onTap(_, ges)
    if not self.input_widget or not self.input_widget:isKeyboardVisible() then return end
    local keyboard = self.input_widget.keyboard
    if not keyboard or not keyboard.dimen or ges.pos:notIntersectWith(keyboard.dimen) then
        self:_hideKeyboard()
        return true
    end
end

function ConversationViewer:onClose()
    if self.closed then return true end
    self.closed = true
    UIManager:close(self)
    if self.close_callback then self.close_callback() end
    return true
end

function ConversationViewer:onCloseWidget()
    if self.input_widget then
        self.input_widget:onCloseWidget()
        self.input_widget = nil
    end
    UIManager:setDirty(self, function() return "ui", self.frame.dimen end)
end

return ConversationViewer
