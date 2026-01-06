local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local UIManager = require("ui/uimanager")
local Dispatcher = require("dispatcher")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local InputContainer = require("ui/widget/container/inputcontainer")
local ConfirmBox = require("ui/widget/confirmbox")
local NetworkMgr = require("ui/network/manager")
local SubstackAPI = require("substack_api")
local SubstackDB = require("substack_db")
local DataStorage = require("datastorage")
local _ = require("gettext")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local SubstackUtils = require("substack_utils")
local SubstackPostViewer = require("substack_viewer")

local JSON = (package.loaded["json"] or (pcall(require, "json") and require("json")) or require("util").json)
local TitleBar = require("ui/widget/titlebar")
local ScrollHtmlWidget = require("ui/widget/scrollhtmlwidget")
local ButtonTable = require("ui/widget/buttontable")
local VerticalGroup = require("ui/widget/verticalgroup")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local MovableContainer = require("ui/widget/container/movablecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputDialog = require("ui/widget/inputdialog")
local CheckButton = require("ui/widget/checkbutton")
local Notification = require("ui/widget/notification")
local Size = require("ui/size")
local Font = require("ui/font")
local Device = require("device")
local Screen = Device.screen
local Geom = require("ui/geometry")
local Blitbuffer = require("ffi/blitbuffer")









local SubstackReader = WidgetContainer:extend {
    name = "substack",
}

local APP_TITLE = _("Substack Reader")

function SubstackReader:onDispatcherRegisterActions()
    Dispatcher:registerAction("substack_open", {
        category = "none",
        event = "SubstackOpen",
        title = APP_TITLE,
        general = true,
    })
end

function SubstackReader:init()
    self.settings_file = DataStorage:getSettingsDir() .. "/substack_settings.json"
    self.cookie_file = DataStorage:getSettingsDir() .. "/substack_cookie.txt"
    self.inbox_cache = DataStorage:getSettingsDir() .. "/substack_inbox_cache.json"
    self.saved_cache = DataStorage:getSettingsDir() .. "/substack_saved_cache.json"
    self.subscriptions_cache = DataStorage:getSettingsDir() .. "/substack_subscriptions_cache.json"
    self.pub_posts_dir = DataStorage:getSettingsDir() .. "/substack_pub_posts_cache"
    self.db_file = DataStorage:getSettingsDir() .. "/substack_cache.sqlite3"
    self.transient_dir = DataStorage:getSettingsDir() .. "/substack_current_post"

    self:loadSettings()
    self.api = SubstackAPI:new(self.settings.cookie)
    self.db = SubstackDB:new(self.db_file)
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)

    if not lfs.attributes(self.pub_posts_dir) then lfs.mkdir(self.pub_posts_dir) end
    if not lfs.attributes(self.transient_dir) then lfs.mkdir(self.transient_dir) end
end

function SubstackReader:addToMainMenu(menu_items)
    menu_items.substack = {
        text = APP_TITLE,
        sorting_hint = "tools",
        callback = function() self:onSubstackMain() end,
    }
end

function SubstackReader:onSubstackOpen()
    self:onSubstackMain()
end




function SubstackReader:loadSettings()
    self.settings = SubstackUtils.readJSON(self.settings_file) or
        { cookie = "", debug_offline = false, post_limit = 20, favourites = {}, line_spacing = 1.2, font_size = Screen:scaleBySize(22), show_images = true }
    if self.settings.debug_offline == nil then self.settings.debug_offline = false end
    if self.settings.post_limit == nil then self.settings.post_limit = 20 end
    if self.settings.favourites == nil then self.settings.favourites = {} end
    if self.settings.line_spacing == nil then self.settings.line_spacing = 1.2 end
    if self.settings.font_size == nil or self.settings.font_size > 50 then self.settings.font_size = 22 end
    if self.settings.show_images == nil then self.settings.show_images = true end


    -- Load cookie from substack_cookie.txt
    -- This file is the source of truth. If it exists, we use it. 
    -- If it's missing or empty, we must clear any cached cookie to ensure we don't use stale credentials.
    local cookie = SubstackUtils.read_txt(self.cookie_file)
    self.settings.cookie = cookie

    -- Update API with loaded cookie
    if self.api then
        self.api.cookie = self.settings.cookie
    end
end

function SubstackReader:saveSettings()
    SubstackUtils.saveJSON(self.settings_file, self.settings)
end

function SubstackReader:isOnline()
    return not self.settings.debug_offline and NetworkMgr:isOnline()
end

function SubstackReader:onSubstackMain()
    local debug_text = self.settings.debug_offline and _("Debug: Force Offline [On]") or _("Debug: Force Offline [Off]")
    local menu_items = {
        { text = _("Recent Posts"),  callback = function() self:showPostList("inbox") end },
        { text = _("Saved Posts"),   callback = function() self:showPostList("saved") end },
        { text = _("Subscriptions"), callback = function() self:showSubscriptions() end },
        { text = _("Clear Cache"),   callback = function() self:clearCache() end },
        {
            text = debug_text,
            callback = function()
                self.settings.debug_offline = not self.settings.debug_offline
                self:saveSettings()
                self:onSubstackMain() -- Refresh menu
            end
        },
        {
            text = _("Post Limit: ") .. self.settings.post_limit,
            callback = function()

                local limit_input
                limit_input = InputDialog:new {
                    title = _("Set Post Limit"),
                    input = tostring(self.settings.post_limit),
                    text_type = "number",
                    buttons = {
                        {
                            {
                                text = _("Cancel"),
                                id = "cancel",
                                callback = function()
                                    UIManager:close(limit_input)
                                end,
                            },
                            {
                                text = _("OK"),
                                id = "ok",
                                is_enter_default = true,
                                callback = function()
                                    local val = tonumber(limit_input:getInputValue())
                                    if val and val >= 1 and val <= 100 then
                                        self.settings.post_limit = val
                                        self:saveSettings()
                                        UIManager:close(limit_input)
                                        self:onSubstackMain()
                                    else
                                        UIManager:show(InfoMessage:new { text = _("Please enter a number between 1 and 100.") })
                                    end
                                end,
                            },
                        }
                    },
                }
                UIManager:show(limit_input)
            end
        },

    }
    UIManager:show(Menu:new { title = APP_TITLE, item_table = menu_items })
end

function SubstackReader:clearCache()
    self.db:clearCache()
    SubstackUtils.rm_recursive(self.transient_dir)
    lfs.mkdir(self.transient_dir)

    os.remove(self.inbox_cache)
    os.remove(self.saved_cache)
    os.remove(self.subscriptions_cache)
    SubstackUtils.rm_recursive(self.pub_posts_dir)
    lfs.mkdir(self.pub_posts_dir)

    UIManager:show(InfoMessage:new { text = _("Cache cleared.") })
end





function SubstackReader:checkOffline(callback)
    if self:isOnline() then
        callback(false)
        return
    end

    local menu
    local menu_items = {
        {
            text = _("Use Cache (Offline)"),
            callback = function()
                UIManager:close(menu)
                callback(true)
            end,
        },
        {
            text = _("Cancel"),
            callback = function()
                UIManager:close(menu)
            end,
        },
    }
    menu = Menu:new {
        title = _("You are offline. Reconnect or use cache?"),
        item_table = menu_items,
    }
    UIManager:show(menu)
end

function SubstackReader:loadData(cache_file, api_call, is_cached, callback)
    local info_text = is_cached and _("Loading from cache...") or _("Loading...")
    local info = InfoMessage:new { text = info_text }
    UIManager:show(info)

    local data, err
    if is_cached then
        data = SubstackUtils.readJSON(cache_file)
        if not data then
            UIManager:close(info)
            UIManager:show(InfoMessage:new { text = _("No cached data found.") })
            return
        end
    else
        data, err = api_call()
        if data then
            SubstackUtils.saveJSON(cache_file, data)
        end
    end

    UIManager:close(info)

    if not data then
        local msg = _("Error fetching data.")
        if err then msg = msg .. "\n(" .. tostring(err) .. ")" end
        UIManager:show(InfoMessage:new { text = msg .. "\n" .. _("Check your connection.") })
        return
    end

    callback(data)
end

function SubstackReader:isPostCached(post)
    local p = post.post or post
    local post_id = tostring(p.id or p.slug or "")
    return post_id ~= "" and self.db:isPostCached(post_id)
end

function SubstackReader:getPostLocalPath(post)
    return self.transient_dir .. "/index.html"
end

function SubstackReader:showPostList(mode, is_cached)
    local cache_file = (mode == "inbox") and self.inbox_cache or self.saved_cache

    self:checkOffline(function(use_cache)
        local api_call = function()
            if mode == "inbox" then
                return self.api:getInbox(self.settings.post_limit)
            else
                return self.api:getSaved(self.settings.post_limit)
            end
        end

        self:loadData(cache_file, api_call, use_cache or is_cached, function(data)
            if not data.posts or #data.posts == 0 then
                UIManager:show(InfoMessage:new { text = _("No posts found.") })
                return
            end

            -- Build mapping for saved/inbox date
            local date_map = {}
            if data.inboxItems then
                for _, item in ipairs(data.inboxItems) do
                    local pid = item.post_id or (item.content_key and string.match(item.content_key, "post:(%d+)"))
                    if pid then
                        date_map[tostring(pid)] = item.saved_at or item.inbox_date or item.content_date
                    end
                end
            end

            -- Sort posts by date descending
            table.sort(data.posts, function(a, b)
                local id_a = tostring(a.id or (a.post and a.post.id) or "")
                local id_b = tostring(b.id or (b.post and b.post.id) or "")
                local date_a = date_map[id_a] or a.post_date or (a.post and a.post.post_date) or ""
                local date_b = date_map[id_b] or b.post_date or (b.post and b.post.post_date) or ""
                return date_a > date_b
            end)

            -- Build mapping for publication names
            local pub_map = {}
            local pub_domain_map = {}
            if data.publications then
                for _, pub in ipairs(data.publications) do
                    if pub.id then
                        if pub.name then pub_map[tostring(pub.id)] = pub.name end
                        if pub.subdomain then pub_domain_map[tostring(pub.id)] = pub.subdomain end
                    end
                end
            end

            local items = {}
            local MAX_WIDTH = 60
            local PUB_MIN = 20

            for i, post in ipairs(data.posts) do
                local p_info = post.post or post
                local title = p_info.title or "Untitled"
                local pub_id = tostring(p_info.publication_id or post.publication_id or "")
                local pub_name = SubstackUtils.get_pub_name(post, pub_map)
                local subdomain = pub_domain_map[pub_id]

                local is_locally_cached = self:isPostCached(post)

                local display_title = SubstackUtils.truncate(title, MAX_WIDTH - PUB_MIN - 6)
                local display_pub = SubstackUtils.truncate(pub_name, MAX_WIDTH - #display_title - 6)
                local prefix = is_locally_cached and "[C] " or ""
                local full_text = string.format("%s%s | %s", prefix, display_title, display_pub)

                table.insert(items, {
                    text = full_text,
                    callback = function() self:renderPost(post, pub_name, subdomain) end
                })
                if i >= self.settings.post_limit then break end
            end

            local list_title = string.format("%s | %s (%d)", APP_TITLE,
                (mode == "inbox" and _("Recent posts") or _("Saved posts")),
                self.settings.post_limit)
            if use_cache or is_cached then
                list_title = list_title .. " (" .. _("Cached") .. ")"
            end

            UIManager:show(Menu:new { title = list_title, item_table = items })
        end)
    end)
end

function SubstackReader:toggleFavourite(pub)
    local pid = tostring(pub.id or pub.subdomain or "")
    if pid == "" then return end
    if self.settings.favourites[pid] then
        self.settings.favourites[pid] = nil
    else
        self.settings.favourites[pid] = true
    end
    self:saveSettings()
end

function SubstackReader:showSubscriptions(is_cached, manage_mode)
    self:checkOffline(function(use_cache)
        local api_call = function() return self.api:getSubscriptions() end
        self:loadData(self.subscriptions_cache, api_call, use_cache or is_cached, function(data)
            local items = {}
            local subs = data.publications or data.subscriptions or data.follows or (type(data) == "table" and data)

            if not subs or type(subs) ~= "table" then
                UIManager:show(InfoMessage:new { text = _("No subscriptions found.") })
                return
            end

            -- Header for Manage Mode
            if manage_mode then
                table.insert(items, {
                    text = _("[ Exit Manage Mode ]"),
                    callback = function() self:showSubscriptions(true, false) end
                })
            else
                table.insert(items, {
                    text = _("[ Manage Favourites ]"),
                    callback = function() self:showSubscriptions(true, true) end
                })
            end

            for _, item in pairs(subs) do
                local pub = item.publication or item
                if type(pub) == "table" and pub.name then
                    local pid = tostring(pub.id or pub.subdomain or "")
                    local is_fav = self.settings.favourites[pid]
                    local display_name = (is_fav and "* " or "") .. tostring(pub.name)

                    table.insert(items, {
                        text = display_name,
                        is_fav = is_fav, -- Keep for sorting
                        callback = function()
                            if manage_mode then
                                self:toggleFavourite(pub)
                                self:showSubscriptions(true, true)
                            else
                                self:showPublicationPosts(pub)
                            end
                        end,
                    })
                end
            end

            if #items == (manage_mode and 1 or 1) and #subs == 0 then
                UIManager:show(InfoMessage:new { text = _("No subscriptions found in response.") })
                return
            end

            -- Sort everything below the header
            local header = table.remove(items, 1)
            table.sort(items, function(a, b)
                local fav_a = a.is_fav and 1 or 0
                local fav_b = b.is_fav and 1 or 0
                if fav_a ~= fav_b then
                    return fav_a > fav_b
                end
                return a.text:lower() < b.text:lower()
            end)
            table.insert(items, 1, header)

            local list_title = APP_TITLE .. " | " .. _("Subscriptions")
            if manage_mode then list_title = list_title .. " [" .. _("Managing") .. "]" end
            if use_cache or is_cached then list_title = list_title .. " (" .. _("Cached") .. ")" end
            UIManager:show(Menu:new { title = list_title, item_table = items })
        end)
    end)
end

function SubstackReader:showPublicationPosts(pub, is_cached)
    local subdomain = pub.subdomain
    if not subdomain then
        UIManager:show(InfoMessage:new { text = _("Could not find subdomain for ") .. (pub.name or "this newsletter") })
        return
    end

    local cache_file = self.pub_posts_dir .. "/" .. subdomain .. ".json"

    self:checkOffline(function(use_cache)
        local api_call = function() return self.api:getPublicationPosts(subdomain, self.settings.post_limit) end
        self:loadData(cache_file, api_call, use_cache or is_cached, function(data)
            local posts = data.posts or data
            if type(posts) ~= "table" or #posts == 0 then
                UIManager:show(InfoMessage:new { text = _("No posts found for this newsletter.") })
                return
            end

            local items = {}
            local MAX_WIDTH = 60
            for i, post in ipairs(posts) do
                local p_info = post.post or post
                local title = SubstackUtils.truncate(p_info.title or "Untitled", MAX_WIDTH - 6)
                local is_locally_cached = self:isPostCached(post)
                local prefix = is_locally_cached and "[C] " or ""

                table.insert(items, {
                    text = prefix .. title,
                    callback = function() self:renderPost(post, pub.name, subdomain) end
                })
                if i >= self.settings.post_limit then break end
            end

            local list_title = string.format("%s (%d)", pub.name, self.settings.post_limit)
            if use_cache or is_cached then list_title = list_title .. " (" .. _("Cached") .. ")" end
            UIManager:show(Menu:new { title = list_title, item_table = items })
        end)
    end)
end

function SubstackReader:renderPost(post, pub_name, subdomain)
    local p = post.post or post
    local post_id = tostring(p.id or p.slug or "")
    if post_id == "" then return end

    local function extract_from_db(pid)
        local db_post = self.db:getPost(pid)
        if not db_post then return false end

        -- Clear and recreate transient dir
        SubstackUtils.rm_recursive(self.transient_dir)
        lfs.mkdir(self.transient_dir)
        local img_dir = self.transient_dir .. "/images"
        lfs.mkdir(img_dir)

        -- Extract images
        local images = self.db:getImagesForPost(pid)
        for _, img in ipairs(images) do
            local img_path = img_dir .. "/" .. img.url_hash .. "." .. img.extension
            local f = io.open(img_path, "wb")
            if f then
                f:write(img.data)
                f:close()
            end
        end

        -- Write HTML
        local html_path = self.transient_dir .. "/index.html"
        local f = io.open(html_path, "w")
        if f then
            f:write(db_post.html_content)
            f:close()
            local viewer = SubstackPostViewer:new {
                title = db_post.title or _("Post"),
                html_body = db_post.html_content,
                html_resource_directory = self.transient_dir,
                line_spacing = self.settings.line_spacing,
                font_size = self.settings.font_size,
                show_images = self.settings.show_images,
                close_callback = function(spacing, font_size, show_images)
                    self.settings.line_spacing = spacing
                    self.settings.font_size = font_size
                    self.settings.show_images = show_images
                    self:saveSettings()
                end,
            }
            UIManager:show(viewer)
            return true
        end
        return false
    end

    -- 1. Try Cache First
    if self:isPostCached(post) then
        if extract_from_db(post_id) then return end
    end

    -- 2. Fetch if Online
    if not self:isOnline() then
        UIManager:show(InfoMessage:new { text = _("Post not cached and you are offline.") })
        return
    end

    local info = InfoMessage:new { text = _("Fetching full post...") }
    UIManager:show(info)
    local full, err = self.api:getPostByUrl(p.canonical_url or p.url, p.id, subdomain, p.slug)
    UIManager:close(info)

    if not full then
        local target = p.canonical_url or p.url or p.id or "unknown"
        local msg = _("Could not fetch post content:") .. "\n" .. tostring(target)
        if err then msg = msg .. "\n(" .. tostring(err) .. ")" end
        UIManager:show(InfoMessage:new { text = msg })
        return
    end

    local fp = full.post or full
    local content = fp.body_html or ""
    local fetched_post_id = tostring(fp.id or fp.slug or post_id)

    -- Download images to memory and save to DB
    local image_count = 0
    content = string.gsub(content, '<img[^>]+src=["\']([^"\']+)["\'][^>]*>', function(url)
        image_count = image_count + 1
        local download_url = string.gsub(string.gsub(url, "f_auto", "f_jpg"), "f_webp", "f_jpg")
        local ext = string.match(url, "%.(%w+)$") or "jpg"
        if #ext > 4 then ext = "jpg" end

        -- Use a hash of the URL as the filename to avoid conflicts and allow simple DB storage
        local url_hash = string.gsub(url, "[^%w]", ""):sub(-16) .. "_" .. image_count
        local img_data = self.api:downloadData(download_url)

        if img_data then
            self.db:saveImage(url_hash, fetched_post_id, img_data, ext)
            return string.format('<img src="images/%s.%s">', url_hash, ext)
        end
        return string.format('<img src="%s">', url)
    end)

    -- Formatting logic (Title, Date, Publication etc.)
    content = string.gsub(content, '(<a[^>]-href=["\'])([^"\']-)(["\'][^>]->)([%s%S]-)(</a>)',
        function(a_start, a_href, a_end_tag, a_inner, a_close)
            if string.find(a_inner, '<img') then return a_inner end
            return a_start .. a_href .. a_end_tag .. a_inner .. a_close
        end)

    if content == "" then
        content = fp.audience == "only_paid" and _("<p><i>(Post is paywalled. Check cookie.)</i></p>") or
            _("<p><i>(No content found.)</i></p>")
    end

    local subtitle_html = ""
    if fp.subtitle and fp.subtitle ~= "" then subtitle_html = "<p class='header-subtitle'>" .. fp.subtitle .. "</p>" end
    local date_text = SubstackUtils.format_date(fp.post_date)
    if date_text then subtitle_html = subtitle_html .. "<p class='header-date'>" .. date_text .. "</p>" end
    if pub_name then subtitle_html = subtitle_html .. "<div class='publication'>" .. pub_name .. "</div>" end

    local clean_title = string.gsub(string.gsub(fp.title or "Untitled", "^%s+", ""), "%s+$", "")
    local html = string.format(
        "<!DOCTYPE html><html><head><meta charset='UTF-8'><style>%s</style></head><body><p class='header-title'>%s</p>%s<hr>%s</body></html>",
        READER_CSS,
        clean_title,
        subtitle_html,
        content
    )
    -- Save to DB
    self.db:savePost(fetched_post_id, clean_title, pub_name, subdomain, html, fp)

    -- Extract and Show
    extract_from_db(fetched_post_id)
end

return SubstackReader
