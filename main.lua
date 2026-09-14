local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template

local SubstackAPI = require("substack_api")
local SubstackDB = require("substack_db")
local SubstackMenu = require("substack_menu")
local SubstackPost = require("substack_post")
local SubstackPostViewer = require("substack_viewer")
local SubstackURL = require("substack_url")
local SubstackUtils = require("substack_utils")

local APP_TITLE = _("Substack Reader")
local DEFAULT_SETTINGS = {
    debug_offline = false,
    post_limit = 20,
    favourites = {},
    line_spacing = 1.2,
    font_size = 22,
    show_images = true,
    sync_images = true,
    font_family = "serif",
    feed_density = "comfortable",
}

local SubstackReader = WidgetContainer:extend{
    name = "substack",
    is_doc_only = false,
}

local function copy_defaults(settings)
    local result = {}
    for key, value in pairs(DEFAULT_SETTINGS) do result[key] = value end
    if type(settings) == "table" then for key, value in pairs(settings) do result[key] = value end end
    result.cookie = nil -- migrate away from the legacy credential copy
    result.debug_offline = result.debug_offline == true
    result.post_limit = math.max(1, math.min(100, tonumber(result.post_limit) or 20))
    result.favourites = type(result.favourites) == "table" and result.favourites or {}
    result.line_spacing = math.max(1, math.min(2, tonumber(result.line_spacing) or 1.2))
    result.font_size = math.max(16, math.min(30, tonumber(result.font_size) or 22))
    result.show_images = result.show_images ~= false
    result.sync_images = result.sync_images ~= false
    result.font_family = ({ ["sans-serif"] = true, serif = true, monospace = true })[result.font_family]
        and result.font_family or "serif"
    result.feed_density = result.feed_density == "compact" and "compact" or "comfortable"
    return result
end

local function post_info(value)
    if type(value) ~= "table" then return {} end
    return type(value.post) == "table" and value.post or value
end

local function post_id(value)
    local post = post_info(value)
    return tostring(post.id or post.slug or "")
end

local function entry_id(entry)
    if type(entry) == "table" and type(entry.cached) == "table" and entry.cached.id ~= nil then
        return tostring(entry.cached.id)
    end
    return post_id(type(entry) == "table" and entry.post or entry)
end

local function extract_publications(data)
    local publications, seen = {}, {}
    local candidates = type(data) == "table" and {
        data.publications, data.subscriptions, data.follows, data.items,
        data.subscriptions_and_follows,
        type(data.user) == "table" and data.user.subscriptions or nil,
        type(data.profile) == "table" and data.profile.subscriptions or nil,
        data,
    } or {}
    for _, candidate in ipairs(candidates) do
        if type(candidate) == "table" then
            for _, value in pairs(candidate) do
                if type(value) == "table" then
                    local publication = type(value.publication) == "table" and value.publication or value
                    local name = publication.name or publication.title
                    local id = tostring(publication.id or publication.subdomain or name or "")
                    if type(name) == "string" and name ~= "" and not seen[id] then
                        seen[id] = true
                        table.insert(publications, publication)
                    end
                end
            end
        end
    end
    return publications
end

function SubstackReader:onDispatcherRegisterActions()
    Dispatcher:registerAction("substack_open", {
        category = "none", event = "SubstackOpen", title = APP_TITLE, general = true,
    })
end

function SubstackReader:init()
    local settings_dir = DataStorage:getSettingsDir()
    self.settings_file = settings_dir .. "/substack_settings.json"
    self.cookie_file = settings_dir .. "/substack_cookie.txt"
    self.inbox_cache = settings_dir .. "/substack_inbox_cache.json"
    self.saved_cache = settings_dir .. "/substack_saved_cache.json"
    self.subscriptions_cache = settings_dir .. "/substack_subscriptions_cache.json"
    self.pub_posts_dir = settings_dir .. "/substack_pub_posts_cache"
    self.db_file = settings_dir .. "/substack_cache.sqlite3"
    self.transient_dir = settings_dir .. "/substack_current_post"
    if not lfs.attributes(self.pub_posts_dir) then lfs.mkdir(self.pub_posts_dir) end
    if not lfs.attributes(self.transient_dir) then lfs.mkdir(self.transient_dir) end

    self.settings = copy_defaults(SubstackUtils.readJSON(self.settings_file))
    self.cookie = SubstackUtils.read_txt(self.cookie_file)
    self.api = SubstackAPI:new(self.cookie)
    self.db = SubstackDB:new(self.db_file)
    self:saveSettings()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function SubstackReader:saveSettings()
    local ok, err = SubstackUtils.saveJSON(self.settings_file, self.settings)
    if not ok then logger.err("[Substack] Could not save settings:", err) end
end

function SubstackReader:reloadCookie()
    self.cookie = SubstackUtils.read_txt(self.cookie_file)
    self.api.cookie = self.cookie
    return type(self.cookie) == "string" and self.cookie ~= ""
end

function SubstackReader:isOnline()
    return not self.settings.debug_offline and NetworkMgr:isOnline()
end

function SubstackReader:addToMainMenu(menu_items)
    menu_items.substack = {
        text = APP_TITLE, sorting_hint = "tools",
        callback = function() self:onSubstackMain() end,
    }
end

function SubstackReader:onSubstackOpen() self:onSubstackMain() end

function SubstackReader:onSubstackMain()
    local continue_count = #self.db:getContinueReading(5)
    local stats = self.db:getCacheStats()
    local items = {
        {
            text = _("Continue reading"), mandatory = continue_count > 0 and tostring(continue_count) or _("None"),
            select_enabled = continue_count > 0,
            callback = function() self:showContinueReading() end,
        },
        { text = _("Latest"), mandatory = _("Inbox"), callback = function() self:showPostList("inbox") end },
        { text = _("Saved"), mandatory = _("Posts"), callback = function() self:showPostList("saved") end },
        { text = _("Publications"), mandatory = _("Following"), callback = function() self:showSubscriptions() end },
        { text = _("Search downloads"), mandatory = tostring(stats.posts), callback = function() self:showSearchDialog() end },
        { text = _("Sync for offline"), mandatory = self:isOnline() and _("Online") or _("Offline"), callback = function() self:syncForOffline() end },
        { text = _("Settings"), mandatory = self:reloadCookie() and _("Signed in") or _("Sign-in needed"), callback = function() self:showSettings() end },
    }
    UIManager:show(SubstackMenu:new{ title = APP_TITLE, item_table = items, single_line = true })
end

function SubstackReader:_loadData(cache_file, api_call, force_cache, callback)
    local info = InfoMessage:new{ text = force_cache and _("Loading downloads…") or _("Refreshing…") }
    UIManager:show(info)
    UIManager:forceRePaint()
    local data, err, used_cache
    if force_cache or not self:isOnline() then
        data, used_cache = SubstackUtils.readJSON(cache_file), true
    else
        self:reloadCookie()
        data, err = api_call()
        if data then
            SubstackUtils.saveJSON(cache_file, data)
        else
            data = SubstackUtils.readJSON(cache_file)
            used_cache = data ~= nil
        end
    end
    UIManager:close(info)
    if not data then
        local message = err or _("No downloaded data is available.")
        UIManager:show(InfoMessage:new{ text = T(_("Unable to load Substack: %1"), tostring(message)) })
        return
    end
    if err and used_cache then
        UIManager:show(InfoMessage:new{ text = T(_("Refresh failed; showing downloaded data.\n%1"), tostring(err)), timeout = 4 })
    end
    callback(data, used_cache)
end

function SubstackReader:_publicationMaps(data)
    local names, subdomains = {}, {}
    if type(data.publications) == "table" then
        for _, publication in ipairs(data.publications) do
            if type(publication) == "table" and publication.id then
                if publication.name then names[tostring(publication.id)] = publication.name end
                if publication.subdomain then subdomains[tostring(publication.id)] = publication.subdomain end
            end
        end
    end
    return names, subdomains
end

function SubstackReader:_postEntries(posts, data, fixed_publication, fixed_subdomain)
    local names, subdomains = self:_publicationMaps(data or {})
    local entries = {}
    for _, raw_post in ipairs(posts or {}) do
        if type(raw_post) == "table" then
            local post = post_info(raw_post)
            local publication_id = tostring(post.publication_id or raw_post.publication_id or "")
            table.insert(entries, {
                post = raw_post,
                pub_name = fixed_publication or SubstackUtils.get_pub_name(raw_post, names),
                subdomain = fixed_subdomain or subdomains[publication_id],
            })
            if #entries >= self.settings.post_limit then break end
        end
    end
    return entries
end

function SubstackReader:_showPostEntries(title, entries, cached)
    if #entries == 0 then UIManager:show(InfoMessage:new{ text = _("No posts found.") }); return end
    local read = self.db:getReadPostIds()
    local items = {}
    local menu
    for index, entry in ipairs(entries) do
        local item_entry, item_index = entry, index
        local post = post_info(item_entry.post)
        local id = entry_id(item_entry)
        local is_read = read[id] == true
        local downloaded = self.db:isPostCached(id)
        local text = tostring(post.title or _("Untitled"))
        if self.settings.feed_density == "comfortable" and post.subtitle and post.subtitle ~= "" then
            text = text .. " — " .. SubstackUtils.truncate(post.subtitle, 90)
        end
        local row_label = tostring(item_entry.pub_name or _("Substack"))
        local date = self.settings.feed_density == "comfortable" and SubstackUtils.format_date(post.post_date) or nil
        if date then row_label = row_label .. " · " .. date end
        local source_item = {
            text = (is_read and "" or "• ") .. text,
            mandatory = row_label .. (downloaded and " ↓" or ""),
            bold = not is_read, dim = is_read,
        }
        source_item.callback = function()
            self:renderPost(item_entry, entries, item_index, false)
            if self.db:isPostRead(id) then
                source_item.text = source_item.text:gsub("^• ", "")
                source_item.bold, source_item.dim = false, true
                if menu then menu:updateItems(menu.itemnumber or 1, true) end
            end
        end
        source_item.hold_callback = function(source_menu, held_item)
            self:showPostActions(item_entry, entries, item_index, source_menu, held_item)
        end
        table.insert(items, source_item)
    end
    local suffix = cached and _(" · Offline") or ""
    menu = SubstackMenu:new{
        title = title .. suffix, item_table = items,
        items_max_lines = self.settings.feed_density == "comfortable" and 2 or 1,
    }
    UIManager:show(menu)
end

function SubstackReader:showPostList(mode, force_cache)
    local cache_file = mode == "inbox" and self.inbox_cache or self.saved_cache
    local api_call = mode == "inbox"
        and function() return self.api:getInbox(self.settings.post_limit) end
        or function() return self.api:getSaved(self.settings.post_limit) end
    self:_loadData(cache_file, api_call, force_cache, function(data, cached)
        if data.partial_warning then UIManager:show(InfoMessage:new{ text = tostring(data.partial_warning), timeout = 3 }) end
        local title = mode == "inbox" and _("Latest") or _("Saved")
        self:_showPostEntries(title, self:_postEntries(data.posts, data), cached)
    end)
end

function SubstackReader:showContinueReading()
    local cached_posts = self.db:getContinueReading(20)
    local entries = {}
    for _, cached in ipairs(cached_posts) do
        table.insert(entries, { post = cached.metadata, cached = cached, pub_name = cached.publication, subdomain = cached.subdomain })
    end
    self:_showPostEntries(_("Continue reading"), entries, true)
end

function SubstackReader:showSearchDialog()
    local dialog
    dialog = InputDialog:new{
        title = _("Search downloaded posts"), input = "",
        buttons = {{
            { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
            { text = _("Search"), is_enter_default = true, callback = function()
                local query = dialog:getInputValue()
                UIManager:close(dialog)
                local results = self.db:searchPosts(query, 50)
                local entries = {}
                for _, cached in ipairs(results) do
                    table.insert(entries, { post = cached.metadata, cached = cached, pub_name = cached.publication, subdomain = cached.subdomain })
                end
                self:_showPostEntries(T(_("Search: %1"), query), entries, true)
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function SubstackReader:showSubscriptions(force_cache)
    self:_loadData(self.subscriptions_cache, function() return self.api:getSubscriptions() end, force_cache,
        function(data, cached)
            local publications = extract_publications(data)
            local items = {}
            table.sort(publications, function(a, b)
                local a_id = tostring(a.id or a.subdomain or a.name or "")
                local b_id = tostring(b.id or b.subdomain or b.name or "")
                local a_fav, b_fav = self.settings.favourites[a_id] == true, self.settings.favourites[b_id] == true
                if a_fav ~= b_fav then return a_fav end
                return util.stringLower(tostring(a.name or a.title or "")) < util.stringLower(tostring(b.name or b.title or ""))
            end)
            for _, publication in ipairs(publications) do
                local item_publication = publication
                local id = tostring(item_publication.id or item_publication.subdomain or item_publication.name or "")
                local favourite = self.settings.favourites[id] == true
                table.insert(items, {
                    text = (favourite and "★ " or "☆ ") .. tostring(item_publication.name or item_publication.title or _("Untitled")),
                    mandatory = item_publication.subdomain or "",
                    callback = function() self:showPublicationPosts(item_publication) end,
                    hold_callback = function(menu)
                        self.settings.favourites[id] = favourite and nil or true
                        self:saveSettings()
                        UIManager:close(menu)
                        self:showSubscriptions(true)
                    end,
                })
            end
            if #items == 0 then UIManager:show(InfoMessage:new{ text = _("No publications found.") }); return end
            local title = data.is_partial and _("Publications · Partial") or _("Publications")
            if cached then title = title .. _(" · Offline") end
            UIManager:show(SubstackMenu:new{ title = title, item_table = items, single_line = true })
        end)
end

function SubstackReader:showPublicationPosts(publication, force_cache)
    local subdomain = publication.subdomain
    if not SubstackURL.validSubdomain(subdomain) then
        UIManager:show(InfoMessage:new{ text = _("This publication has no usable Substack subdomain.") })
        return
    end
    local cache_file = self.pub_posts_dir .. "/" .. subdomain .. ".json"
    self:_loadData(cache_file, function() return self.api:getPublicationPosts(subdomain, self.settings.post_limit) end,
        force_cache, function(data, cached)
            local posts = type(data.posts) == "table" and data.posts or data
            local entries = self:_postEntries(posts, {}, publication.name or publication.title, subdomain)
            self:_showPostEntries(publication.name or _("Publication"), entries, cached)
        end)
end

function SubstackReader:_navigation(entries, index)
    if not entries or not index then return {} end
    return {
        has_prev = index > 1, has_next = index < #entries,
        post_index = index, post_count = #entries,
        on_prev = function() if index > 1 then self:renderPost(entries[index - 1], entries, index - 1, false) end end,
        on_next = function() if index < #entries then self:renderPost(entries[index + 1], entries, index + 1, false) end end,
    }
end

function SubstackReader:_showCachedPost(cached, navigation)
    SubstackUtils.rm_recursive(self.transient_dir)
    lfs.mkdir(self.transient_dir)
    local image_dir = self.transient_dir .. "/images"
    lfs.mkdir(image_dir)
    for _, image in ipairs(self.db:getImagesForPost(cached.id)) do
        if tostring(image.url_hash):match("^[%w_-]+$") and tostring(image.extension):match("^[%w]+$") then
            local file = io.open(image_dir .. "/" .. image.url_hash .. "." .. image.extension, "wb")
            if file then file:write(image.data); file:close() end
        end
    end
    local viewer = SubstackPostViewer:new{
        title = cached.title or _("Post"), html_body = cached.html_content,
        html_resource_directory = self.transient_dir,
        line_spacing = self.settings.line_spacing, font_size = self.settings.font_size,
        show_images = self.settings.show_images, font_family = self.settings.font_family,
        initial_ratio = self.db:getReadingProgress(cached.id),
        has_prev = navigation.has_prev, has_next = navigation.has_next,
        post_index = navigation.post_index, post_count = navigation.post_count,
        on_prev = navigation.on_prev, on_next = navigation.on_next,
        close_callback = function(spacing, font_size, show_images, font_family, ratio)
            self.settings.line_spacing, self.settings.font_size = spacing, font_size
            self.settings.show_images, self.settings.font_family = show_images, font_family
            self:saveSettings()
            self.db:saveReadingProgress(cached.id, ratio)
        end,
    }
    UIManager:show(viewer)
    self.db:markPostAsRead(cached.id)
end

function SubstackReader:renderPost(entry, entries, index, force_refresh)
    local raw_post = entry.post
    local id = entry_id(entry)
    if id == "" then return end
    local navigation = self:_navigation(entries, index)
    local require_images = self.settings.show_images
    local cached = entry.cached or self.db:getPost(id)
    if cached and not force_refresh and (not require_images or cached.images_complete or not self:isOnline()) then
        self:_showCachedPost(cached, navigation)
        return
    end
    if not self:isOnline() then
        UIManager:show(InfoMessage:new{ text = _("This post is not available offline.") })
        return
    end
    self:reloadCookie()
    local info = InfoMessage:new{ text = force_refresh and _("Refreshing post…") or _("Downloading post…") }
    UIManager:show(info); UIManager:forceRePaint()
    local post = post_info(raw_post)
    local full, err = self.api:getPostByUrl(post.canonical_url or post.url, post.id, entry.subdomain, post.slug)
    if not full then
        UIManager:close(info)
        UIManager:show(InfoMessage:new{ text = T(_("Could not download post: %1"), tostring(err or _("Unknown error"))) })
        return
    end
    local bundle, images, build_err = SubstackPost.build(self.api, full, {
        fallback_id = id, publication = entry.pub_name, subdomain = entry.subdomain,
        include_images = self.settings.show_images,
    })
    if not bundle then
        UIManager:close(info)
        UIManager:show(InfoMessage:new{ text = tostring(build_err) })
        return
    end
    local ok, save_err = self.db:savePostBundle(bundle, images)
    UIManager:close(info)
    if not ok then UIManager:show(InfoMessage:new{ text = tostring(save_err) }); return end
    self:_showCachedPost(self.db:getPost(bundle.id), navigation)
end

function SubstackReader:showPostActions(entry, entries, index, source_menu, source_item)
    local id = entry_id(entry)
    local read = self.db:isPostRead(id)
    local downloaded = self.db:isPostCached(id)
    local action_menu
    local function refresh_source()
        UIManager:close(action_menu)
        source_menu:updateItems(source_menu.itemnumber or 1, true)
    end
    local items = {
        { text = read and _("Mark unread") or _("Mark read"), callback = function()
            local now_read = not read
            if now_read then self.db:markPostAsRead(id) else self.db:markPostAsUnread(id) end
            if source_item then
                local title = source_item.text:gsub("^• ", "")
                source_item.text = (now_read and "" or "• ") .. title
                source_item.bold, source_item.dim = not now_read, now_read
            end
            refresh_source()
        end },
        { text = _("Refresh download"), select_enabled = self:isOnline(), callback = function()
            UIManager:close(action_menu); self:renderPost(entry, entries, index, true)
        end },
        { text = _("Remove offline copy"), select_enabled = downloaded, callback = function()
            UIManager:close(action_menu)
            UIManager:show(ConfirmBox:new{
                text = _("Remove this post and its images from offline storage?"),
                ok_text = _("Remove"), ok_callback = function() self.db:deletePost(id); source_menu:updateItems(source_menu.itemnumber or 1, true) end,
            })
        end },
    }
    action_menu = SubstackMenu:new{ title = post_info(entry.post).title or _("Post actions"), item_table = items, single_line = true }
    UIManager:show(action_menu)
end

function SubstackReader:_replaceSettingsMenu(menu)
    if menu then UIManager:close(menu) end
    self:showSettings()
end

function SubstackReader:showSettings()
    local stats = self.db:getCacheStats()
    local menu
    local items = {
        { text = _("Account"), mandatory = self:reloadCookie() and _("Signed in") or _("Sign-in needed"), callback = function() self:testAccount() end },
        { text = _("Feed density"), mandatory = self.settings.feed_density == "compact" and _("Compact") or _("Comfortable"), callback = function()
            self.settings.feed_density = self.settings.feed_density == "compact" and "comfortable" or "compact"
            self:saveSettings(); self:_replaceSettingsMenu(menu)
        end },
        { text = _("Show images while reading"), mandatory = self.settings.show_images and _("On") or _("Off"), callback = function()
            self.settings.show_images = not self.settings.show_images; self:saveSettings(); self:_replaceSettingsMenu(menu)
        end },
        { text = _("Download images during sync"), mandatory = self.settings.sync_images and _("On") or _("Off"), callback = function()
            self.settings.sync_images = not self.settings.sync_images; self:saveSettings(); self:_replaceSettingsMenu(menu)
        end },
        { text = _("Post limit"), mandatory = tostring(self.settings.post_limit), callback = function() self:setPostLimit(menu) end },
        { text = _("Force offline"), mandatory = self.settings.debug_offline and _("On") or _("Off"), callback = function()
            self.settings.debug_offline = not self.settings.debug_offline; self:saveSettings(); self:_replaceSettingsMenu(menu)
        end },
        { text = _("Offline storage"), mandatory = T(_("%1 posts · %2 images"), stats.posts, stats.images), callback = function() self:showStorage() end },
    }
    menu = SubstackMenu:new{ title = _("Substack Settings"), item_table = items, single_line = true }
    UIManager:show(menu)
end

function SubstackReader:setPostLimit(settings_menu)
    local dialog
    dialog = InputDialog:new{
        title = _("Number of posts (1–100)"), input = tostring(self.settings.post_limit), text_type = "number",
        buttons = {{
            { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local value = tonumber(dialog:getInputValue())
                if not value or value < 1 or value > 100 then
                    UIManager:show(InfoMessage:new{ text = _("Enter a number from 1 to 100.") }); return
                end
                self.settings.post_limit = math.floor(value); self:saveSettings()
                UIManager:close(dialog); self:_replaceSettingsMenu(settings_menu)
            end },
        }},
    }
    UIManager:show(dialog); dialog:onShowKeyboard()
end

function SubstackReader:testAccount()
    if not self:reloadCookie() then
        UIManager:show(InfoMessage:new{ text = T(_("Create %1 and place only your substack.sid value inside it."), self.cookie_file) })
        return
    end
    if not self:isOnline() then UIManager:show(InfoMessage:new{ text = _("Connect to the internet to test your sign-in.") }); return end
    local info = InfoMessage:new{ text = _("Testing Substack sign-in…") }
    UIManager:show(info); UIManager:forceRePaint()
    local data, err = self.api:getInbox(1)
    UIManager:close(info)
    UIManager:show(InfoMessage:new{ text = data and _("Substack sign-in is working.") or T(_("Sign-in failed: %1"), tostring(err)) })
end

function SubstackReader:showStorage()
    local stats = self.db:getCacheStats()
    local megabytes = stats.bytes / 1024 / 1024
    local menu
    menu = SubstackMenu:new{
        title = _("Offline Storage"), single_line = true,
        item_table = {
            { text = _("Downloaded posts"), mandatory = tostring(stats.posts), select_enabled = false },
            { text = _("Downloaded images"), mandatory = tostring(stats.images), select_enabled = false },
            { text = _("Image storage"), mandatory = string.format("%.1f MB", megabytes), select_enabled = false },
            { text = _("Clear offline storage"), callback = function()
                UIManager:show(ConfirmBox:new{
                    text = _("Remove all downloaded posts and images? Read/unread history will be kept."),
                    ok_text = _("Clear"), ok_callback = function()
                        self.db:clearCache()
                        os.remove(self.inbox_cache); os.remove(self.saved_cache); os.remove(self.subscriptions_cache)
                        SubstackUtils.rm_recursive(self.pub_posts_dir); lfs.mkdir(self.pub_posts_dir)
                        UIManager:close(menu)
                        UIManager:show(InfoMessage:new{ text = _("Offline storage cleared.") })
                    end,
                })
            end },
        },
    }
    UIManager:show(menu)
end

function SubstackReader:syncForOffline()
    if not self:isOnline() then UIManager:show(InfoMessage:new{ text = _("Connect to the internet before syncing.") }); return end
    self:reloadCookie()
    UIManager:show(ConfirmBox:new{
        text = T(_("Download the latest %1 posts for offline reading?"), self.settings.post_limit),
        ok_text = _("Sync"), ok_callback = function() self:_beginSync() end,
    })
end

function SubstackReader:_beginSync()
    local info = InfoMessage:new{ text = _("Getting the latest posts…") }
    UIManager:show(info); UIManager:forceRePaint()
    local data, err = self.api:getInbox(self.settings.post_limit)
    if not data or type(data.posts) ~= "table" then
        UIManager:close(info); UIManager:show(InfoMessage:new{ text = tostring(err or _("Sync failed.")) }); return
    end
    SubstackUtils.saveJSON(self.inbox_cache, data)
    local entries = self:_postEntries(data.posts, data)
    local state = { index = 1, downloaded = 0, skipped = 0, failed = 0 }
    local function finish()
        UIManager:close(info)
        UIManager:show(InfoMessage:new{ text = T(
            _("Sync complete.\n\nDownloaded: %1\nAlready available: %2\nFailed: %3"),
            state.downloaded, state.skipped, state.failed) })
    end
    local function step()
        local entry = entries[state.index]
        if not entry then finish(); return end
        local id = entry_id(entry)
        if self.db:isPostCached(id, self.settings.sync_images) then
            state.skipped = state.skipped + 1
        else
            local post = post_info(entry.post)
            local full = self.api:getPostByUrl(post.canonical_url or post.url, post.id, entry.subdomain, post.slug)
            if full then
                local bundle, images = SubstackPost.build(self.api, full, {
                    fallback_id = id, publication = entry.pub_name, subdomain = entry.subdomain,
                    include_images = self.settings.sync_images,
                })
                local ok = bundle and self.db:savePostBundle(bundle, images)
                if ok then state.downloaded = state.downloaded + 1 else state.failed = state.failed + 1 end
            else
                state.failed = state.failed + 1
            end
        end
        state.index = state.index + 1
        if state.index <= #entries then
            UIManager:close(info)
            info = InfoMessage:new{ text = T(_("Syncing post %1 of %2…"), state.index, #entries) }
            UIManager:show(info); UIManager:forceRePaint()
        end
        UIManager:scheduleIn(0.05, step)
    end
    if #entries == 0 then finish(); return end
    UIManager:close(info)
    info = InfoMessage:new{ text = T(_("Syncing post %1 of %2…"), math.min(1, #entries), #entries) }
    UIManager:show(info); UIManager:forceRePaint()
    UIManager:scheduleIn(0.05, step)
end

return SubstackReader
