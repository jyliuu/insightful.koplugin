local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local HtmlBoxWidget = require("ui/widget/htmlboxwidget")
local ScrollHtmlWidget = require("ui/widget/scrollhtmlwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalScrollBar = require("ui/widget/verticalscrollbar")
local VerticalSpan = require("ui/widget/verticalspan")

-- MuPDF lays HTML out in discrete pages. Use half-height pages and show two
-- consecutive pages at once, so each navigation step keeps a half-page overlap.
local HalfPageScrollHtmlWidget = ScrollHtmlWidget:extend{
    half_height = 0,
    max_start_page = 1,
    htmlbox_widget_bottom = nil,
}

function HalfPageScrollHtmlWidget:init()
    self.half_height = math.max(1, math.floor(self.height / 2))
    self.height = self.half_height
    ScrollHtmlWidget.init(self)

    self.height = self.half_height * 2
    local page_count = self.htmlbox_widget.page_count
    self.max_start_page = math.max(1, page_count - 1)

    local pages = VerticalGroup:new{
        self.htmlbox_widget,
    }
    if page_count > 1 then
        self.htmlbox_widget_bottom = HtmlBoxWidget:new{
            dimen = Geom:new{
                w = self.width - self.scroll_bar_width - self.text_scroll_span,
                h = self.half_height,
            },
            dialog = self.dialog,
            highlight_text_selection = self.highlight_text_selection,
            html_link_tapped_callback = self.html_link_tapped_callback,
        }
        self.htmlbox_widget_bottom:setContent(
            self.html_body,
            self.css,
            self.default_font_size,
            self.is_xhtml,
            nil,
            self.html_resource_directory
        )
        self.htmlbox_widget_bottom:setPageNumber(2)
        table.insert(pages, self.htmlbox_widget_bottom)
    else
        table.insert(pages, VerticalSpan:new{ width = self.half_height })
    end

    self.v_scroll_bar = VerticalScrollBar:new{
        enable = self.max_start_page > 1,
        width = self.scroll_bar_width,
        height = self.height,
        scroll_callback = function(ratio) self:scrollToRatio(ratio) end,
    }
    self:_updateScrollBar()

    self[1] = HorizontalGroup:new{
        pages,
        HorizontalSpan:new{ width = self.text_scroll_span },
        self.v_scroll_bar,
    }
    self.dimen = Geom:new(self[1]:getSize())
end

function HalfPageScrollHtmlWidget:_updateScrollBar()
    if not self.v_scroll_bar or not self.htmlbox_widget then return end
    local page_count = math.max(1, self.htmlbox_widget.page_count)
    local start_page = self.htmlbox_widget.page_number
    local visible_pages = self.htmlbox_widget_bottom and 2 or 1
    self.v_scroll_bar:set(
        (start_page - 1) / page_count,
        math.min(start_page + visible_pages - 1, page_count) / page_count
    )
end

function HalfPageScrollHtmlWidget:_repaintPages()
    self.htmlbox_widget:freeBb()
    self.htmlbox_widget:_render()
    if self.htmlbox_widget_bottom then
        self.htmlbox_widget_bottom:freeBb()
        self.htmlbox_widget_bottom:_render()
    end

    if self.dialog.movable and self.dialog.movable.alpha then
        self.dialog.movable.alpha = nil
        UIManager:setDirty(self.dialog, function()
            return "partial", self.dialog.movable.dimen
        end)
    else
        UIManager:setDirty(self.dialog, function()
            return "partial", self.dimen
        end)
    end
end

function HalfPageScrollHtmlWidget:_setStartPage(page_number, repaint)
    page_number = math.max(1, math.min(self.max_start_page, page_number))
    if page_number == self.htmlbox_widget.page_number then return false end

    self.htmlbox_widget:setPageNumber(page_number)
    if self.htmlbox_widget_bottom then
        self.htmlbox_widget_bottom:setPageNumber(page_number + 1)
    end
    self:_updateScrollBar()
    if repaint then self:_repaintPages() end
    return true
end

function HalfPageScrollHtmlWidget:resetScroll()
    self:_setStartPage(1, false)
    self.v_scroll_bar.enable = self.max_start_page > 1
end

function HalfPageScrollHtmlWidget:scrollToRatio(ratio)
    ratio = math.max(0, math.min(1, ratio))
    local page_number = 1 + math.floor(self.max_start_page * ratio)
    self:_setStartPage(page_number, true)
end

function HalfPageScrollHtmlWidget:scrollText(direction)
    if direction == 0 then return end
    local step = direction > 0 and 1 or -1
    self:_setStartPage(self.htmlbox_widget.page_number + step, true)
end

function HalfPageScrollHtmlWidget:onScrollUp()
    if self.htmlbox_widget.page_number > 1 then
        self:scrollText(-1)
        return true
    end
end

function HalfPageScrollHtmlWidget:onScrollDown()
    if self.htmlbox_widget.page_number < self.max_start_page then
        self:scrollText(1)
        return true
    end
end

return HalfPageScrollHtmlWidget
