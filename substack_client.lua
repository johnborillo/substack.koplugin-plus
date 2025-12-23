local https = require("ssl.https")
local ltn12 = require("ltn12")
local JSON = (package.loaded["json"] or (pcall(require, "json") and require("json")) or require("util").json)
local logger = require("logger")

local USER_AGENT =
"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.77 Safari/537.36"

local SubstackClient = {}

function SubstackClient:new(cookie)
    local obj = {
        cookie = cookie,
        base_url = "https://substack.com/api/v1"
    }
    setmetatable(obj, self)
    self.__index = self
    return obj
end

function SubstackClient:_get_cookie_header()
    local cookie_header = self.cookie or ""
    if cookie_header ~= "" and not cookie_header:match("=") then
        cookie_header = "substack.sid=" .. cookie_header
    end
    return cookie_header
end

function SubstackClient:raw_request(path_or_url, sink)
    local current_url = path_or_url
    if type(current_url) ~= "string" then return nil, "Invalid URL" end

    if not current_url:match("^https?://") then
        current_url = self.base_url .. path_or_url
    end

    local cookie_header = self:_get_cookie_header()
    local max_redirects = 5
    local redirect_count = 0

    while redirect_count < max_redirects do
        local response_body = {}
        local request_sink = sink or ltn12.sink.table(response_body)

        local res, code, headers, status = https.request({
            url = current_url,
            method = "GET",
            headers = {
                ["Cookie"] = cookie_header,
                ["User-Agent"] = USER_AGENT,
            },
            sink = request_sink,
        })

        if not res then
            return nil, tostring(code or status or "Network error")
        end

        -- Redirect handling
        if code == 301 or code == 302 or code == 307 or code == 308 then
            current_url = headers["location"]
            if not current_url then break end
            redirect_count = redirect_count + 1
        else
            return code, response_body
        end
    end
    return nil, "Too many redirects"
end

function SubstackClient:request(path)
    local code, body_or_err = self:raw_request(path)

    if type(body_or_err) == "table" then
        local body_str = table.concat(body_or_err)
        local ok, decoded = pcall(JSON.decode, body_str)

        if code == 200 then
            if ok then return decoded end
            return nil, "JSON decode failed"
        else
            -- Check for Substack error messages in JSON
            if ok and decoded and decoded.errors and decoded.errors[1] and decoded.errors[1].msg then
                return nil, string.format("HTTP %s on %s: %s", tostring(code), path, decoded.errors[1].msg)
            end
            return nil, string.format("HTTP %s on %s", tostring(code), path)
        end
    end

    return nil, tostring(body_or_err or "Unknown error")
end

function SubstackClient:download_file(url, target_path)
    local file = io.open(target_path, "wb")
    if not file then return false end

    local code, body_or_err = self:raw_request(url, ltn12.sink.file(file))

    if io.type(file) == "file" then file:close() end

    if code == 200 then
        return true
    end
    os.remove(target_path)
    return false
end

return SubstackClient
