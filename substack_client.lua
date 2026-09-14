local https = require("ssl.https")
local socket = require("socket")
local socketutil = require("socketutil")
local JSON = require("json")
local logger = require("logger")
local SubstackURL = require("substack_url")

local USER_AGENT = "KOReader-Substack/2.0"
local API_MAX_BYTES = 8 * 1024 * 1024
local IMAGE_MAX_BYTES = 20 * 1024 * 1024
local BLOCK_TIMEOUT = 10
local TOTAL_TIMEOUT = 45

local SubstackClient = {}
SubstackClient.__index = SubstackClient

local function is_auth_destination(parsed)
    return parsed and parsed.scheme == "https" and SubstackURL.isSubstackHost(parsed.host)
        and (parsed.port == nil or parsed.port == 443)
end

local function bounded_sink(chunks, max_bytes)
    local size = 0
    local sink = socketutil.table_sink(chunks)
    return function(chunk, err)
        if chunk then
            size = size + #chunk
            if size > max_bytes then return nil, "response_too_large" end
        end
        return sink(chunk, err)
    end
end

function SubstackClient:new(cookie)
    return setmetatable({ cookie = cookie, base_url = "https://substack.com/api/v1" }, self)
end

function SubstackClient:_get_cookie_header()
    local raw = self.cookie
    if type(raw) ~= "string" or raw == "" then return nil, "Authentication cookie missing" end
    if raw:find("[%c%s]") then return nil, "Authentication cookie contains invalid whitespace" end
    local sid = raw:match("^substack%.sid=([^;]+)")
        or raw:match("[;]substack%.sid=([^;]+)")
        or (not raw:find(";", 1, true) and raw)
    if not sid or sid == "" then return nil, "substack.sid cookie missing" end
    return "substack.sid=" .. sid
end

function SubstackClient:_prepare_url(path_or_url)
    if type(path_or_url) ~= "string" then return nil, "Invalid URL" end
    if path_or_url:match("^https?://") then return path_or_url end
    if path_or_url:sub(1, 1) ~= "/" then return nil, "API path must start with /" end
    return self.base_url .. path_or_url
end

function SubstackClient:_headers_for(url, authenticated)
    local parsed = SubstackURL.parse(url)
    if not parsed or parsed.scheme ~= "https" then return nil, "Only HTTPS requests are allowed" end
    if authenticated and not is_auth_destination(parsed) then
        return nil, "Refusing to send credentials outside Substack"
    end
    if not authenticated and SubstackURL.isPrivateHost(parsed.host) then
        return nil, "Refusing to download from a private network host"
    end
    local headers = { ["Accept-Encoding"] = "identity", ["User-Agent"] = USER_AGENT }
    if authenticated then
        local cookie, err = self:_get_cookie_header()
        if not cookie then return nil, err .. ". Please check substack_cookie.txt" end
        headers["Cookie"] = cookie
    end
    return headers
end

function SubstackClient:raw_request(path_or_url, options)
    options = options or {}
    local authenticated = options.authenticated ~= false
    local max_bytes = options.max_bytes or API_MAX_BYTES
    local current_url, url_err = self:_prepare_url(path_or_url)
    if not current_url then return nil, url_err end
    local initial = SubstackURL.parse(current_url)
    if not initial or initial.scheme ~= "https" then return nil, "Only HTTPS requests are allowed" end
    if authenticated and not is_auth_destination(initial) then
        return nil, "Refusing authenticated request outside Substack"
    end

    local retry_delays = { 0.5, 1.0, 2.0 }
    local last_error
    for attempt = 1, #retry_delays + 1 do
        local attempt_url = current_url
        for redirect_count = 0, 5 do
            local parsed = SubstackURL.parse(attempt_url)
            local send_auth = authenticated and is_auth_destination(parsed)
            local headers, header_err = self:_headers_for(attempt_url, send_auth)
            if not headers then return nil, header_err end

            local chunks = {}
            socketutil:set_timeout(BLOCK_TIMEOUT, TOTAL_TIMEOUT)
            local ok, res, code, response_headers, status = pcall(https.request, {
                url = attempt_url, method = "GET", headers = headers, redirect = false,
                sink = bounded_sink(chunks, max_bytes),
            })
            socketutil:reset_timeout()
            if not ok then last_error = tostring(res); break end
            if not res then last_error = tostring(code or status or "Network error"); break end

            code = tonumber(code)
            if code == 301 or code == 302 or code == 303 or code == 307 or code == 308 then
                if redirect_count == 5 then return nil, "Too many redirects" end
                local next_url = SubstackURL.resolve(attempt_url, response_headers and response_headers.location)
                local next_parsed = SubstackURL.parse(next_url)
                if not next_parsed or next_parsed.scheme ~= "https" then return nil, "Unsafe redirect blocked" end
                attempt_url = next_url
            elseif code == 429 or (code and code >= 500 and code <= 599) then
                last_error = "HTTP " .. tostring(code)
                break
            else
                return code, chunks, response_headers
            end
        end
        if attempt <= #retry_delays then
            local delay = retry_delays[attempt]
            logger.warn("[Substack] Request failed; retrying in", delay, "seconds:", last_error)
            if socket and socket.sleep then socket.sleep(delay) end
        end
    end
    return nil, "Request failed after retries (" .. tostring(last_error or "unknown error") .. ")"
end

function SubstackClient:request(path)
    local code, chunks_or_error = self:raw_request(path, { authenticated = true, max_bytes = API_MAX_BYTES })
    if type(chunks_or_error) ~= "table" then return nil, tostring(chunks_or_error or "Unknown error") end
    local body = table.concat(chunks_or_error)
    local ok, decoded = pcall(JSON.decode, body)
    if code and code >= 200 and code <= 299 then
        if ok then return decoded end
        return nil, "JSON decode failed"
    end
    if ok and type(decoded) == "table" and decoded.errors and decoded.errors[1] then
        return nil, string.format("HTTP %s: %s", tostring(code), tostring(decoded.errors[1].msg or "request failed"))
    end
    return nil, "HTTP " .. tostring(code or "unknown")
end

function SubstackClient:download_data(url)
    if not SubstackURL.isSafeExternal(url) then return nil, "Unsafe image URL" end
    local code, chunks_or_error = self:raw_request(url, { authenticated = false, max_bytes = IMAGE_MAX_BYTES })
    if code and code >= 200 and code <= 299 and type(chunks_or_error) == "table" then
        return table.concat(chunks_or_error)
    end
    return nil, tostring(chunks_or_error or "Download failed")
end

function SubstackClient:download_file(url, target_path)
    local data, err = self:download_data(url)
    if not data then return false, err end
    local temporary_path = target_path .. ".part"
    local file = io.open(temporary_path, "wb")
    if not file then return false, "Unable to open temporary file" end
    local ok = file:write(data)
    file:close()
    if not ok then os.remove(temporary_path); return false, "Unable to write file" end
    if not os.rename(temporary_path, target_path) then
        os.remove(temporary_path)
        return false, "Unable to finalize file"
    end
    return true
end

return SubstackClient
