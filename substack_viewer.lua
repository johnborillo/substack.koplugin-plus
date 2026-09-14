local InputContainer = require("ui/widget/container/inputcontainer")
local TitleBar = require("ui/widget/titlebar")
local ButtonTable = require("ui/widget/buttontable")
local ScrollHtmlWidget = require("ui/widget/scrollhtmlwidget")
local FrameContainer = require("ui/widget/container/framecontainer")
local MovableContainer = require("ui/widget/container/movablecontainer")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local UIManager = require("ui/uimanager")
local Size = require("ui/size")
local Device = require("device")
local Screen = Device.screen
local Geom = require("ui/geometry")
local Blitbuffer = require("ffi/blitbuffer")
local _ = require("gettext")

local READER_CSS = require("substack_post").READER_CSS

local SubstackPostViewer = InputContainer:extend {
    title = nil,
    html_body = nil,
    html_body_inner = nil,
    html_resource_directory = nil,
    line_spacing = 1.2,
    font_size = 22,
    font_family = "sans-serif",
    show_images = true,
    has_prev = false,
    has_next = false,
    on_prev = nil,
    on_next = nil,
    post_index = nil,
    post_count = nil,
    fullscreen = true,
    initial_ratio = 0,
}

local FONT_FAMILIES = {
    { id = "sans-serif", name = "Sans" },
    { id = "serif", name = "Serif" },
    { id = "monospace", name = "Mono" },
}

local function get_font_family_label(id)
    for _, f in ipairs(FONT_FAMILIES) do
        if f.id == id then return f.name end
    end
    return "Sans"
end

local function get_next_font_family(current_id)
    for i, f in ipairs(FONT_FAMILIES) do
        if f.id == current_id then
            return FONT_FAMILIES[i % #FONT_FAMILIES + 1].id
        end
    end
    return FONT_FAMILIES[1].id
end

function SubstackPostViewer:init()
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()

    self.dimen = Geom:new { w = screen_w, h = screen_h }
    self.html_body = self.html_body or ""
    
    -- Robustly extract body content (handling newlines which . matches fail on)
    local body_start = self.html_body:find("<body>", 1, true)
    local body_end = self.html_body:find("</body>", 1, true)
    if body_start and body_end then
        self.html_body_inner = self.html_body:sub(body_start + 6, body_end - 1)
    else
        self.html_body_inner = self.html_body
    end

    self.width = self.width or screen_w
    self.height = self.height or screen_h
    self.font_size = self.font_size or 22
    self.font_family = self.font_family or "sans-serif"
    if self.show_images == nil then self.show_images = true end

    local title_text = self.title
    if self.post_index and self.post_count and self.post_count > 1 then
        title_text = string.format("(%d/%d) %s", self.post_index, self.post_count, self.title or "")
    end

    self.titlebar = TitleBar:new {
        width = self.width,
        align = "center",
        with_bottom_line = true,
        title = title_text,
        close_callback = function() self:onClose() end,
        show_parent = self,
    }

    local spacings = { 1.0, 1.2, 1.4, 1.6, 1.8, 2.0 }
    local function get_next_spacing(current)
        for i, s in ipairs(spacings) do
            if math.abs(s - current) < 0.01 then
                return spacings[i % #spacings + 1]
            end
        end
        return spacings[1]
    end

    local font_sizes = { 16, 18, 20, 22, 24, 26, 28, 30 }
    local function get_next_font_size(current)
        for i, s in ipairs(font_sizes) do
            if math.abs(s - current) < 0.1 then
                return font_sizes[i % #font_sizes + 1]
            end
        end
        return font_sizes[1]
    end

    local prev_text = self.has_prev and _("< Prev") or _("[< Prev]")
    local next_text = self.has_next and _("Next >") or _("[Next >]")

    self.button_table = ButtonTable:new {
        width = self.width,
        buttons = {
            {
                {
                    text = prev_text,
                    id = "prev_post",
                    enabled = self.has_prev,
                    callback = function()
                        if self.has_prev and self.on_prev then
                            self:onClose()
                            self.on_prev()
                        end
                    end,
                },
                {
                    text = string.format(_("Font: %s"), get_font_family_label(self.font_family)),
                    id = "font_family",
                    callback = function()
                        self.font_family = get_next_font_family(self.font_family)
                        local btn = self.button_table:getButtonById("font_family")
                        btn:setText(string.format(_("Font: %s"), get_font_family_label(self.font_family)), btn.width)
                        self:updateContent()
                        btn:refresh()
                    end,
                },
                {
                    text = next_text,
                    id = "next_post",
                    enabled = self.has_next,
                    callback = function()
                        if self.has_next and self.on_next then
                            self:onClose()
                            self.on_next()
                        end
                    end,
                },
            },
            {
                {
                    text = string.format(_("Size: %d"), self.font_size),
                    id = "font_size",
                    callback = function()
                        self.font_size = get_next_font_size(self.font_size)
                        local btn = self.button_table:getButtonById("font_size")
                        btn:setText(string.format(_("Size: %d"), self.font_size), btn.width)
                        self:updateContent()
                        btn:refresh()
                    end,
                },
                {
                    text = self.show_images and _("Img: On") or _("Img: Off"),
                    id = "show_images",
                    callback = function()
                        self.show_images = not self.show_images
                        local btn = self.button_table:getButtonById("show_images")
                        btn:setText(self.show_images and _("Img: On") or _("Img: Off"), btn.width)
                        self:updateContent()
                        btn:refresh()
                    end,
                },
                {
                    text = string.format(_("Spacing: %.1f"), self.line_spacing),
                    id = "spacing",
                    callback = function()
                        self.line_spacing = get_next_spacing(self.line_spacing)
                        local btn = self.button_table:getButtonById("spacing")
                        btn:setText(string.format(_("Spacing: %.1f"), self.line_spacing), btn.width)
                        self:updateContent()
                        btn:refresh()
                    end,
                },
            }
        },
        show_parent = self,
    }

    local content_h = self.height - self.titlebar:getHeight() - self.button_table:getSize().h
    local css = self:generateCss()

    self.scroll_html_w = ScrollHtmlWidget:new {
        width = self.width,
        height = content_h,
        html_body = self.html_body_inner,
        css = css,
        default_font_size = Screen:scaleBySize(self.font_size),
        margin_w = 0,
        margin_h = 0,
        padding = 0,
        text_align = "left",
        html_resource_directory = self.html_resource_directory,
        dialog = self,
    }
    if self.initial_ratio and self.initial_ratio > 0 then
        self.scroll_html_w:scrollToRatio(self.initial_ratio)
    end

    self.frame = FrameContainer:new {
        dimen = Geom:new { w = self.width, h = self.height },
        radius = Size.radius.window,
        padding = 0,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new {
            align = "left",
            padding = 0,
            self.titlebar,
            self.scroll_html_w,
            self.button_table,
        }
    }

    self.movable = MovableContainer:new {
        dimen = Geom:new { w = self.width, h = self.height },
        self.frame,
    }

    self[1] = WidgetContainer:new {
        align = "center",
        dimen = self.dimen,
        self.movable,
    }
end

function SubstackPostViewer:generateCss()
    local font_css = string.format("body, html { font-family: %s !important; }", self.font_family or "sans-serif")
    local css = READER_CSS .. "\n" .. font_css .. string.format("\n* { line-height: %.1f !important; }", self.line_spacing)
    if not self.show_images then
        css = css .. "\nimg { display: none !important; }"
        css = css .. "\nfigure { display: none !important; }"
    end
    return css
end

function SubstackPostViewer:updateContent()
    local ratio = self.scroll_html_w:getCurrentRatio()
    local css = self:generateCss()

    local htmlbox = self.scroll_html_w.htmlbox_widget
    htmlbox.margin_w = 0
    htmlbox.margin_h = 0
    htmlbox.padding = 0
    htmlbox:setContent(self.html_body_inner, css, Screen:scaleBySize(self.font_size), false, nil, self.html_resource_directory)

    -- Clamp page number to avoid MuPDF error "cannot open page #xx: invalid page number"
    if htmlbox.page_number > htmlbox.page_count then
        htmlbox:setPageNumber(htmlbox.page_count)
    end

    self.scroll_html_w:scrollToRatio(ratio)

    self.scroll_html_w:_updateScrollBar()
    self.scroll_html_w.v_scroll_bar.enable = htmlbox.page_count > 1
    htmlbox:freeBb()
    htmlbox:_render()
    UIManager:setDirty(self, "ui")
end

function SubstackPostViewer:_notifyClose()
    if self._close_notified then return end
    self._close_notified = true
    local ratio = 0
    if self.scroll_html_w and self.scroll_html_w.htmlbox_widget then
        local htmlbox = self.scroll_html_w.htmlbox_widget
        if htmlbox.page_count and htmlbox.page_count > 0 then
            ratio = htmlbox.page_number >= htmlbox.page_count and 1
                or math.max(0, (htmlbox.page_number - 1) / htmlbox.page_count)
        end
    end
    if self.close_callback then
        self.close_callback(self.line_spacing, self.font_size, self.show_images, self.font_family, ratio)
    end
end

function SubstackPostViewer:onShow()
    UIManager:setDirty(self, "ui")
    return true
end

function SubstackPostViewer:onCloseWidget()
    self:_notifyClose()
    if self.scroll_html_w and self.scroll_html_w.htmlbox_widget then
        self.scroll_html_w.htmlbox_widget:free()
    end
end

function SubstackPostViewer:onClose()
    self:_notifyClose()
    UIManager:close(self)
end

return SubstackPostViewer
