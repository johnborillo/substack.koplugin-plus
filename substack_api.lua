local SubstackClient = require("substack_client")
local logger = require("logger")

local SubstackAPI = {}

function SubstackAPI:new(cookie)
    local obj = {
        client = SubstackClient:new(cookie)
    }
    setmetatable(obj, SubstackAPI)
    return obj
end

-- Compatibility property for main.lua
function SubstackAPI.__index(self, key)
    if key == "cookie" then
        return rawget(self, "client").cookie
    end
    return SubstackAPI[key]
end

function SubstackAPI.__newindex(self, key, value)
    if key == "cookie" then
        rawget(self, "client").cookie = value
    else
        rawset(self, key, value)
    end
end

function SubstackAPI:request(path)
    return self.client:request(path)
end

function SubstackAPI:downloadFile(url, target_path)
    return self.client:download_file(url, target_path)
end

function SubstackAPI:parseUrl(url)
    if not url or type(url) ~= "string" then return nil end
    local scheme, netloc, path = string.match(url, "^(https?://)([^/]+)(/?.*)$")
    if not scheme then return nil end

    local base = scheme .. netloc
    local slug = string.match(path, "/p/([^/?#]+)") or string.match(path, "/home/post/p%-([^/?#]+)") or
    string.match(path, "([^/]+)$")
    if slug == "" or slug == "/" then slug = nil end
    return base, slug
end

function SubstackAPI:getInbox(limit)
    return self:request("/reader/posts?limit=" .. (limit or 20) .. "&sort=new")
end

function SubstackAPI:getSaved(limit)
    return self:request("/reader/posts?inboxType=saved&limit=" .. (limit or 20))
end

function SubstackAPI:getSubscriptions()
    local endpoints = {
        "/subscriptions",
        "/reader/followed_publications",
        "/reader/follows",
        "/api/v1/profile",
        "/profile"
    }

    local user_id
    local inbox = self:getInbox()
    if inbox and inbox.inboxItems and inbox.inboxItems[1] then
        user_id = inbox.inboxItems[1].user_id
    end

    if user_id then
        table.insert(endpoints, "/user/" .. tostring(user_id) .. "/public_profile")
        table.insert(endpoints, "/user/" .. tostring(user_id))
    end

    local last_err
    for _, path in ipairs(endpoints) do
        logger.info("[Substack] Trying subscriptions endpoint: " .. path)
        local data, err = self:request(path)
        if data and type(data) == "table" then
            if data.subscriptions or data.follows or data.publications or (#data > 0) then
                logger.info("[Substack] Success on endpoint: " .. path)
                return data
            end
            logger.info("[Substack] Endpoint " .. path .. " returned data but no subscriptions found in it.")
        else
            logger.info("[Substack] Endpoint " .. path .. " failed: " .. tostring(err))
            last_err = err
        end
    end

    return nil, last_err or "Could not find subscriptions after trying all endpoints"
end

function SubstackAPI:getPublicationPosts(subdomain, limit)
    if not subdomain then return nil, "No subdomain provided" end
    return self:request(string.format("https://%s.substack.com/api/v1/posts?limit=%d&sort=new", subdomain, limit or 20))
end

function SubstackAPI:getPostByUrl(url, id, subdomain, slug)
    if not url and not id and not slug then return nil, "No identifiers provided" end

    local entries = {}
    local function add(c)
        if not c or c == "" or c == "/" then return end
        c = tostring(c)
        for _, v in ipairs(entries) do if v == c then return end end
        table.insert(entries, c)
    end
    local _, u_slug = self:parseUrl(url)
    add(slug); add(u_slug); add(id)

    local errors = {}
    local tried = {}
    local function try_p(path)
        if tried[path] then return end
        tried[path] = true
        local res, err = self:request(path)
        if res then return res end
        table.insert(errors, string.format("%s: %s", path, tostring(err or "error")))
    end

    -- 1. Try subdomain-specific API
    if subdomain then
        for _, c in ipairs(entries) do
            local res = try_p("https://" .. subdomain .. ".substack.com/api/v1/posts/" .. c)
            if res then return res end
        end
    end

    -- 2. Try generic posts API
    for _, c in ipairs(entries) do
        local res = try_p("/posts/" .. c)
        if res then return res end
    end

    -- 3. Try reader API as fallback
    if id then
        local res = try_p("/reader/posts/" .. tostring(id))
        if res then return res end
    end

    return nil, "Post fetch failed:\n" .. table.concat(errors, "\n")
end

return SubstackAPI
