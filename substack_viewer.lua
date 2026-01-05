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

local READER_CSS = [[
    @page { margin: 0; }
    * { margin: 0 !important; padding: 0 !important; }
    body, html { margin: 0 !important; padding: 0 0.4em !important; }
    p { margin-bottom: 1em !important; }
    img { max-width: 100%; height: auto; display: block; }
    .header-title { text-align: center; font-size: 1.5em; font-weight: bold; margin: 0.5em 0; }
    .header-subtitle { text-align: center; font-size: 1.1em; font-style: italic; }
    .header-date { text-align: center; font-size: 0.9em; margin-bottom: 1em; }
    .publication { text-align: center; font-weight: bold; margin-bottom: 1.5em; }
]]

local SubstackPostViewer = InputContainer:extend {
    title = nil,
    html_body = nil,
    html_body_inner = nil,
    html_resource_directory = nil,
    line_spacing = 1.2,
    fullscreen = true,
}

function SubstackPostViewer:init()
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()

    self.dimen = Geom:new { w = screen_w, h = screen_h }
    
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
    if self.show_images == nil then self.show_images = true end

    self.titlebar = TitleBar:new {
        width = self.width,
        align = "center",
        with_bottom_line = true,
        title = self.title,
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

    self.button_table = ButtonTable:new {
        width = self.width,
        buttons = {
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
    -- Using default if global G_reader_settings not available, just purely mostly for safety
    local header_font = (G_reader_settings and G_reader_settings:readSetting("header_font")) or "Noto Sans"
    
    self.scroll_html_w = ScrollHtmlWidget:new {
        width = self.width,
        height = content_h,
        html_body = self.html_body_inner,
        css = READER_CSS .. string.format("\n* { line-height: %.1f; }", self.line_spacing),
        default_font_size = Screen:scaleBySize(self.font_size),
        margin_w = 0,
        margin_h = 0,
        padding = 0,
        text_align = "left",
        html_resource_directory = self.html_resource_directory,
        dialog = self,
    }

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

function SubstackPostViewer:updateContent()
    local css = READER_CSS .. string.format("\n* { line-height: %.1f !important; }", self.line_spacing)
    if not self.show_images then
        css = css .. "\nimg { display: none !important; }"
        css = css .. "\nfigure { display: none !important; }"
    end

    local htmlbox = self.scroll_html_w.htmlbox_widget
    htmlbox.margin_w = 0
    htmlbox.margin_h = 0
    htmlbox.padding = 0
    htmlbox:setContent(self.html_body_inner, css, Screen:scaleBySize(self.font_size), false, nil, self.html_resource_directory)

    -- Clamp page number to avoid MuPDF error "cannot open page #xx: invalid page number"
    if htmlbox.page_number > htmlbox.page_count then
        htmlbox:setPageNumber(htmlbox.page_count)
    end

    self.scroll_html_w:_updateScrollBar()
    self.scroll_html_w.v_scroll_bar.enable = htmlbox.page_count > 1
    htmlbox:freeBb()
    UIManager:setDirty(self, "ui")
end

function SubstackPostViewer:onShow()
    UIManager:setDirty(self, "ui")
    return true
end

function SubstackPostViewer:onCloseWidget()
    if self.scroll_html_w and self.scroll_html_w.htmlbox_widget then
        self.scroll_html_w.htmlbox_widget:free()
    end
end

function SubstackPostViewer:onClose()
    UIManager:close(self)
    if self.close_callback then
        self.close_callback(self.line_spacing, self.font_size, self.show_images)
    end
end

return SubstackPostViewer
