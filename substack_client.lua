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
    local cookie_header = self.cookie
    if not cookie_header or cookie_header == "" then return nil end
    if not string.match(cookie_header, "=") then
        cookie_header = "substack.sid=" .. cookie_header
    end
    return cookie_header
end

function SubstackClient:raw_request(path_or_url, sink)
    local current_url = path_or_url
    if type(current_url) ~= "string" then return nil, "Invalid URL" end

    -- STRICT COOKIE CHECK
    local cookie_header = self:_get_cookie_header()
    if not cookie_header then
        return nil, "Authentication cookie missing. Please check substack_cookie.txt"
    end

    if not string.match(current_url, "^https?://") then
        current_url = self.base_url .. path_or_url
    end

    local headers = {
        ["User-Agent"] = USER_AGENT,
        ["Cookie"] = cookie_header,
    }

    local max_redirects = 5
    local retries_delays = { 0.25, 0.5, 1.0 } -- Delays after 1st, 2nd, 3rd failure
    local max_retries = #retries_delays + 1 -- Total attempts = 1 initial + 3 retries
    local attempt = 0

    while attempt < max_retries do
        attempt = attempt + 1
        
        -- Reset redirect count for this attempt
        local redirect_count = 0
        local attempt_url = current_url
        local last_code, last_body

        while redirect_count < max_redirects do
            local response_body = {}
            local request_sink = sink or ltn12.sink.table(response_body)

            local res, code, response_headers, status = https.request({
                url = attempt_url,
                method = "GET",
                headers = headers,
                sink = request_sink,
            })

            if not res then
                last_code = code or status or "Network error"
                break -- Network error, retry outer loop by breaking inner loop
            end

            -- Redirect handling
            if code == 301 or code == 302 or code == 307 or code == 308 then
                attempt_url = response_headers["location"]
                if not attempt_url then break end
                redirect_count = redirect_count + 1
            elseif code == 400 or code >= 500 then
                -- Transient error candidate
                last_code = code
                last_body = response_body
                logger.warn("[Substack] HTTP " .. tostring(code) .. " on " .. attempt_url .. " - Attempt " .. attempt .. " failed")
                break -- Break inner loop to trigger retry check
            else
                -- Success or permanent client error (e.g. 404, 401, 403)
                return code, response_body
            end
        end

        if attempt < max_retries then
            local delay = retries_delays[attempt]
            if delay then
                logger.warn("[Substack] Retrying in " .. delay .. "s...")
                require("ffi/unistd").sleep(delay)
            end
        end
    end

    return nil, "Request failed after " .. attempt .. " attempts"
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

function SubstackClient:download_data(url)
    local code, body_or_err = self:raw_request(url)

    if code == 200 and type(body_or_err) == "table" then
        return table.concat(body_or_err)
    end
    return nil, tostring(body_or_err or "Download failed")
end

return SubstackClient
