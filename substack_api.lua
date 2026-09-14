local SubstackClient = require("substack_client")
local SubstackURL = require("substack_url")
local logger = require("logger")

local SubstackAPI = {}

function SubstackAPI:new(cookie)
    return setmetatable({ client = SubstackClient:new(cookie) }, self)
end

function SubstackAPI.__index(self, key)
    if key == "cookie" then return rawget(self, "client").cookie end
    return SubstackAPI[key]
end

function SubstackAPI.__newindex(self, key, value)
    if key == "cookie" then rawget(self, "client").cookie = value else rawset(self, key, value) end
end

function SubstackAPI:request(path) return self.client:request(path) end
function SubstackAPI:downloadFile(url, target_path) return self.client:download_file(url, target_path) end
function SubstackAPI:downloadData(url) return self.client:download_data(url) end

function SubstackAPI:parseUrl(url)
    if type(url) ~= "string" then return nil end
    local parsed = SubstackURL.parse(url)
    if not parsed then return nil end
    local slug = parsed.path:match("/p/([^/?#]+)")
        or parsed.path:match("/home/post/p%-([^/?#]+)")
        or parsed.path:match("/([^/?#]+)/?$")
    return parsed.scheme .. "://" .. parsed.authority, slug
end

local function append_unique(target, values, seen, id_getter, limit)
    if type(values) ~= "table" then return 0 end
    local added = 0
    for _, value in ipairs(values) do
        if type(value) == "table" then
            local id = tostring(id_getter(value) or "")
            if id == "" or not seen[id] then
                if id ~= "" then seen[id] = true end
                table.insert(target, value)
                added = added + 1
                if limit and #target >= limit then break end
            end
        end
    end
    return added
end

function SubstackAPI:_getReaderPosts(limit, inbox_type)
    limit = math.max(1, math.min(100, tonumber(limit) or 20))
    local posts, publications, inbox_items = {}, {}, {}
    local seen_posts, seen_publications = {}, {}
    local offset, page = 0, 0
    local max_pages = math.ceil(limit / 20) + 2
    local warning

    while #posts < limit and page < max_pages do
        page = page + 1
        local request_limit = math.min(20, limit - #posts)
        local type_query = inbox_type and ("&inboxType=" .. inbox_type) or "&sort=new"
        local path = string.format("/reader/posts?limit=%d&offset=%d%s", request_limit, offset, type_query)
        local data, err = self:request(path)
        if type(data) ~= "table" then
            if #posts == 0 then return nil, err end
            warning = err
            break
        end

        local page_posts = type(data.posts) == "table" and data.posts or {}
        if #page_posts == 0 then break end
        local added = append_unique(posts, page_posts, seen_posts, function(value)
            return (value.post and value.post.id) or value.id or (value.post and value.post.slug) or value.slug
        end, limit)
        append_unique(publications, data.publications, seen_publications, function(value)
            return value.id or value.subdomain or value.name
        end)
        if type(data.inboxItems) == "table" then
            for _, item in ipairs(data.inboxItems) do table.insert(inbox_items, item) end
        end

        offset = offset + #page_posts
        if #page_posts < request_limit or added == 0 then
            if added == 0 and #page_posts >= request_limit then warning = "Pagination stopped: endpoint returned no new posts" end
            break
        end
    end

    return {
        posts = posts, publications = publications, inboxItems = inbox_items,
        partial_warning = warning,
    }
end

function SubstackAPI:getInbox(limit) return self:_getReaderPosts(limit, nil) end
function SubstackAPI:getSaved(limit) return self:_getReaderPosts(limit, "saved") end

function SubstackAPI:getSubscriptions()
    local endpoints = {
        "/reader/follows", "/subscriptions", "/reader/followed_publications", "/profile",
    }
    local last_error
    for _, path in ipairs(endpoints) do
        local data, err = self:request(path)
        if type(data) == "table" then
            local has_items = (type(data.publications) == "table" and #data.publications > 0)
                or (type(data.subscriptions) == "table" and #data.subscriptions > 0)
                or (type(data.follows) == "table" and #data.follows > 0)
                or #data > 0
            if has_items then return data end
        end
        last_error = err or last_error
        if type(err) == "string" and (err:match("HTTP 401") or err:match("HTTP 403")) then return nil, err end
    end

    logger.info("[Substack] Subscription endpoints unavailable; using publications from the recent feed")
    local inbox, err = self:_getReaderPosts(100, nil)
    if inbox and #inbox.publications > 0 then
        return { publications = inbox.publications, is_partial = true }
    end
    return nil, last_error or err or "Could not retrieve subscriptions"
end

function SubstackAPI:getPublicationPosts(subdomain, limit)
    if not SubstackURL.validSubdomain(subdomain) then return nil, "Invalid publication subdomain" end
    limit = math.max(1, math.min(100, tonumber(limit) or 20))
    local posts, seen = {}, {}
    local offset, page = 0, 0
    local max_pages = math.ceil(limit / 20) + 2
    while #posts < limit and page < max_pages do
        page = page + 1
        local request_limit = math.min(20, limit - #posts)
        local url = string.format("https://%s.substack.com/api/v1/posts?limit=%d&offset=%d&sort=new", subdomain, request_limit, offset)
        local data, err = self:request(url)
        if type(data) ~= "table" then
            if #posts == 0 then return nil, err end
            return { posts = posts, partial_warning = err }
        end
        local page_posts = type(data.posts) == "table" and data.posts or data
        if type(page_posts) ~= "table" or #page_posts == 0 then break end
        local added = append_unique(posts, page_posts, seen, function(value)
            return (value.post and value.post.id) or value.id or (value.post and value.post.slug) or value.slug
        end, limit)
        offset = offset + #page_posts
        if #page_posts < request_limit or added == 0 then break end
    end
    return { posts = posts }
end

function SubstackAPI:getPostByUrl(url, id, subdomain, slug)
    if not url and not id and not slug then return nil, "No identifiers provided" end
    local entries, seen_entries = {}, {}
    local function add(value)
        value = tostring(value or "")
        if value ~= "" and value ~= "/" and not seen_entries[value] then
            seen_entries[value] = true
            table.insert(entries, SubstackURL.escapePathSegment(value))
        end
    end
    local _, url_slug = self:parseUrl(url)
    add(slug); add(url_slug); add(id)

    local errors, tried = {}, {}
    local function try_path(path)
        if tried[path] then return nil end
        tried[path] = true
        local result, err = self:request(path)
        if result then return result end
        table.insert(errors, tostring(err or "request failed"))
    end

    if SubstackURL.validSubdomain(subdomain) then
        for _, entry in ipairs(entries) do
            local result = try_path("https://" .. subdomain .. ".substack.com/api/v1/posts/" .. entry)
            if result then return result end
        end
    end
    for _, entry in ipairs(entries) do
        local result = try_path("/posts/" .. entry)
        if result then return result end
    end
    if id then
        local result = try_path("/reader/posts/" .. SubstackURL.escapePathSegment(id))
        if result then return result end
    end
    return nil, "Post fetch failed: " .. table.concat(errors, "; ")
end

return SubstackAPI
