local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ConfirmBox = require("ui/widget/confirmbox")
local NetworkMgr = require("ui/network/manager")
local SubstackAPI = require("substack_api")
local DataStorage = require("datastorage")
local _ = require("gettext")
local lfs = require("libs/libkoreader-lfs")

local JSON = (package.loaded["json"] or (pcall(require, "json") and require("json")) or require("util").json)

local READER_CSS = [[<style>
    .header-title { text-align: center; font-size: 1.5em; font-weight: bold; margin: 0 0 0.5em 0; padding: 0; }
    .header-subtitle { text-align: center; font-size: 1.1em; font-weight: normal; font-style: italic; color: #666; margin: 0 0 0.5em 0; }
    .header-date { text-align: center; font-size: 0.9em; color: #888; margin: 0 0 1em 0; }
    .publication { display: block; text-align: center; font-weight: bold; color: #555; margin: 0 0 2em 0; text-transform: uppercase; font-size: 0.9em; }
    img { max-width: 100%; height: auto; display: block; margin: 1.5em auto; border-radius: 4px; }
    blockquote { border-left: 4px solid #eee; padding-left: 1.5em; margin-left: 0; color: #444; font-style: italic; }
    pre { background: #f9f9f9; padding: 1em; overflow-x: auto; border-radius: 4px; font-family: monospace; }
    hr { border: 0; border-top: 1px solid #eee; margin: 3em 0; }
</style>]]

local SubstackReader = WidgetContainer:extend {
    name = "substack",
}

local APP_TITLE = _("Substack Reader")

function SubstackReader:init()
    self.settings_file = DataStorage:getSettingsDir() .. "/substack_settings.json"
    self.cookie_file = DataStorage:getSettingsDir() .. "/substack_cookie.json"
    self.image_dir = DataStorage:getSettingsDir() .. "/substack_images"
    self.post_dir = DataStorage:getSettingsDir() .. "/substack_posts"
    self.inbox_cache = DataStorage:getSettingsDir() .. "/substack_inbox_cache.json"
    self.saved_cache = DataStorage:getSettingsDir() .. "/substack_saved_cache.json"
    self.subscriptions_cache = DataStorage:getSettingsDir() .. "/substack_subscriptions_cache.json"
    self.pub_posts_dir = DataStorage:getSettingsDir() .. "/substack_pub_posts_cache"

    self:loadSettings()
    self.api = SubstackAPI:new(self.settings.cookie)
    self.ui.menu:registerToMainMenu(self)

    if not lfs.attributes(self.image_dir) then lfs.mkdir(self.image_dir) end
    if not lfs.attributes(self.post_dir) then lfs.mkdir(self.post_dir) end
    if not lfs.attributes(self.pub_posts_dir) then lfs.mkdir(self.pub_posts_dir) end
end

function SubstackReader:addToMainMenu(menu_items)
    menu_items.substack = {
        text = APP_TITLE,
        sorting_hint = "tools",
        callback = function() self:onSubstackMain() end,
    }
end

function SubstackReader:readJSON(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*all")
    f:close()
    local ok, decoded = pcall(JSON.decode, content)
    return ok and decoded or nil
end

function SubstackReader:saveJSON(path, data)
    local f = io.open(path, "w")
    if f then
        f:write(JSON.encode(data))
        f:close()
        return true
    end
    return false
end

function SubstackReader:loadSettings()
    self.settings = self:readJSON(self.settings_file) or
        { cookie = "", debug_offline = false, post_limit = 20 }
    if self.settings.debug_offline == nil then self.settings.debug_offline = false end
    if self.settings.post_limit == nil then self.settings.post_limit = 20 end


    -- Extract cookie from substack_cookie.json (object or browser-array format)
    local cookie_data = self:readJSON(self.cookie_file)

    -- Fallback: check in the plugin directory if not found in settings
    if not cookie_data then
        local plugin_dir = "plugins/substack.koplugin"
        cookie_data = self:readJSON(plugin_dir .. "/substack_cookie.json")
    end

    if type(cookie_data) == "table" then
        if cookie_data.cookie then
            self.settings.cookie = cookie_data.cookie
        else
            for _, c in ipairs(cookie_data) do
                if c.name == "substack.sid" then
                    self.settings.cookie = c.value
                    break
                end
            end
        end
    end

    -- Update API with loaded cookie
    if self.api then
        self.api.cookie = self.settings.cookie
    end
end

function SubstackReader:saveSettings()
    self:saveJSON(self.settings_file, self.settings)
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
                local InputDialog = require("ui/widget/inputdialog")
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

        { text = _("Cookie Help"), callback = function() UIManager:show(InfoMessage:new { text = _("Place substack_cookie.json in:\n" .. self.cookie_file) }) end },
    }
    UIManager:show(Menu:new { title = APP_TITLE, item_table = menu_items })
end

function SubstackReader:clearCache()
    local img_count = 0
    local post_count = 0

    local function rm_recursive(path)
        if not lfs.attributes(path) then return end
        if lfs.attributes(path).mode == "directory" then
            for file in lfs.dir(path) do
                if file ~= "." and file ~= ".." then
                    rm_recursive(path .. "/" .. file)
                end
            end
            lfs.rmdir(path)
        else
            os.remove(path)
        end
    end

    if lfs.attributes(self.image_dir) then
        for file in lfs.dir(self.image_dir) do
            if file ~= "." and file ~= ".." then
                os.remove(self.image_dir .. "/" .. file)
                img_count = img_count + 1
            end
        end
    end

    if lfs.attributes(self.post_dir) then
        for file in lfs.dir(self.post_dir) do
            if file ~= "." and file ~= ".." then
                local full_path = self.post_dir .. "/" .. file
                rm_recursive(full_path)
                post_count = post_count + 1
            end
        end
    end

    os.remove(self.inbox_cache)
    os.remove(self.saved_cache)
    os.remove(self.subscriptions_cache)
    rm_recursive(self.pub_posts_dir)
    lfs.mkdir(self.pub_posts_dir)

    UIManager:show(InfoMessage:new { text = _("Cache cleared.") .. string.format("\n(%d posts, %d images)", post_count, img_count) })
end

local function truncate(str, len)
    if #str <= len then return str end
    return str:sub(1, math.max(0, len - 3)) .. "..."
end

local function get_pub_name(post, pub_map)
    local p = post.post or post
    local pid = p.publication_id or post.publication_id
    if pid and pub_map and pub_map[tostring(pid)] then
        return pub_map[tostring(pid)]
    end

    local url = p.canonical_url or p.url or post.canonical_url or post.url
    if not url or type(url) ~= "string" then return "Substack" end

    -- Fallback: Remove protocol (https://, http://) and www.
    local clean = url:gsub("^https?://", ""):gsub("^www%.", "")
    -- Keep only the domain part (everything before the first /)
    return clean:match("^([^/]+)") or clean
end

local function get_ordinal(n)
    local last_digit = n % 10
    if n >= 11 and n <= 13 then return "th" end
    if last_digit == 1 then return "st" end
    if last_digit == 2 then return "nd" end
    if last_digit == 3 then return "rd" end
    return "th"
end

local months = {
    "January", "February", "March", "April", "May", "June",
    "July", "August", "September", "October", "November", "December"
}

local function format_date(iso_date)
    if not iso_date or iso_date == "" then return nil end
    local y, m, d = iso_date:match("^(%d+)-(%d+)-(%d+)")
    if not y or not m or not d then return nil end
    y, m, d = tonumber(y), tonumber(m), tonumber(d)
    return string.format("%d%s %s %d", d, get_ordinal(d), months[m], y)
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
        data = self:readJSON(cache_file)
        if not data then
            UIManager:close(info)
            UIManager:show(InfoMessage:new { text = _("No cached data found.") })
            return
        end
    else
        data, err = api_call()
        if data then
            self:saveJSON(cache_file, data)
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

function SubstackReader:getPostLocalPath(post)
    local p = post.post or post
    local post_id = tostring(p.id or p.slug or "")
    if post_id == "" then return nil end
    return self.post_dir .. "/" .. post_id .. ".html"
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
                    local pid = item.post_id or (item.content_key and item.content_key:match("post:(%d+)"))
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
                local pub_name = get_pub_name(post, pub_map)
                local subdomain = pub_domain_map[pub_id]

                local local_path = self:getPostLocalPath(post)
                local is_locally_cached = local_path and lfs.attributes(local_path) ~= nil

                local display_title = truncate(title, MAX_WIDTH - PUB_MIN - 6)
                local display_pub = truncate(pub_name, MAX_WIDTH - #display_title - 6)
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

function SubstackReader:showSubscriptions(is_cached)
    self:checkOffline(function(use_cache)
        local api_call = function() return self.api:getSubscriptions() end
        self:loadData(self.subscriptions_cache, api_call, use_cache or is_cached, function(data)
            local items = {}
            local subs = data.publications or data.subscriptions or data.follows or (type(data) == "table" and data)

            if not subs or type(subs) ~= "table" then
                UIManager:show(InfoMessage:new { text = _("No subscriptions found.") })
                return
            end

            for _, item in pairs(subs) do
                local pub = item.publication or item
                if type(pub) == "table" and pub.name then
                    table.insert(items, {
                        text = tostring(pub.name),
                        callback = function() self:showPublicationPosts(pub) end
                    })
                end
            end

            if #items == 0 then
                UIManager:show(InfoMessage:new { text = _("No subscriptions found in response.") })
                return
            end

            table.sort(items, function(a, b) return a.text:lower() < b.text:lower() end)
            local list_title = APP_TITLE .. " | " .. _("Subscriptions")
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
                local title = truncate(p_info.title or "Untitled", MAX_WIDTH - 6)
                local local_path = self:getPostLocalPath(post)
                local is_locally_cached = local_path and lfs.attributes(local_path) ~= nil
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
    local path = self:getPostLocalPath(post)

    -- If we have the file already, we can potentially skip fetching
    local cached_exists = path and lfs.attributes(path) ~= nil

    if not self:isOnline() then
        if cached_exists then
            require("apps/reader/readerui"):showReader(path)
            return
        else
            UIManager:show(InfoMessage:new { text = _("This post is not cached and you are offline.") })
            return
        end
    end

    local info = InfoMessage:new { text = _("Fetching full post...") }
    UIManager:show(info)
    local full, err = self.api:getPostByUrl(p.canonical_url or p.url, p.id, subdomain, p.slug)
    UIManager:close(info)

    if not full then
        local target = p.canonical_url or p.url or p.id or "unknown"
        local msg = _("Could not fetch post content:") .. "\n" .. tostring(target)
        if err then
            msg = msg .. "\n(" .. tostring(err) .. ")"
        end
        UIManager:show(InfoMessage:new { text = msg })
        return
    end

    local p = full.post or full
    local content = p.body_html or ""
    local post_id = tostring(p.id or p.slug or "")
    if post_id == "" then post_id = tostring(os.time()) end
    local post_img_dir_name = post_id .. "_images"
    local post_img_dir = self.post_dir .. "/" .. post_img_dir_name

    if not lfs.attributes(post_img_dir) then lfs.mkdir(post_img_dir) end

    -- Download images and rewrite to relative local paths
    local image_count = 0
    content = content:gsub('<img[^>]+src=["\']([^"\']+)["\'][^>]*>', function(url)
        image_count = image_count + 1
        local download_url = url:gsub("f_auto", "f_jpg"):gsub("f_webp", "f_jpg")
        local ext = url:match("%.(%w+)$") or "jpg"
        if #ext > 4 then ext = "jpg" end

        local local_name = string.format("img_%03d.%s", image_count, ext)
        local local_path = post_img_dir .. "/" .. local_name
        local local_rel_path = post_img_dir_name .. "/" .. local_name

        if self.api:downloadFile(download_url, local_path) then
            return string.format('<img src="%s">', local_rel_path)
        end
        return string.format('<img src="%s">', url)
    end)

    -- Strip wrapping <a> tags from images to trigger KOReader's internal viewer popup.
    -- This avoids opening the image as a separate document.
    content = content:gsub('(<a[^>]-href=["\'])([^"\']-)(["\'][^>]->)([%s%S]-)(</a>)',
        function(a_start, a_href, a_end_tag, a_inner, a_close)
            if a_inner:find('<img') then
                return a_inner -- Return only the content, stripping the <a> and </a>
            end
            return a_start .. a_href .. a_end_tag .. a_inner .. a_close
        end)

    if content == "" then
        content = p.audience == "only_paid" and _("<p><i>(Post is paywalled. Check cookie.)</i></p>") or
            _("<p><i>(No content found.)</i></p>")
    end

    local subtitle_html = ""
    if p.subtitle and p.subtitle ~= "" then
        subtitle_html = "<p class='header-subtitle'>" .. p.subtitle .. "</p>"
    end

    local date_text = format_date(p.post_date)
    if date_text then
        subtitle_html = subtitle_html .. "<p class='header-date'>" .. date_text .. "</p>"
    end

    if pub_name then
        subtitle_html = subtitle_html .. "<div class='publication'>" .. pub_name .. "</div>"
    end

    local clean_title = (p.title or "Untitled"):gsub("^%s+", ""):gsub("%s+$", "")
    local clean_content = content:gsub("^%s+", ""):gsub("%s+$", "")
    local html = string.format(
        "<!DOCTYPE html><html><head><meta charset='UTF-8'>%s</head><body><p class='header-title'>%s</p>%s<hr>%s</body></html>",
        READER_CSS, clean_title, subtitle_html, clean_content)

    local path = self.post_dir .. "/" .. post_id .. ".html"
    local f = io.open(path, "w")
    if f then
        f:write(html)
        f:close()
        require("apps/reader/readerui"):showReader(path)
    end
end

return SubstackReader
