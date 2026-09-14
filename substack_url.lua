local SubstackURL = {}

local function lower(value)
    return type(value) == "string" and value:lower() or nil
end

function SubstackURL.parse(value)
    if type(value) ~= "string" then return nil end
    local scheme, authority, path = value:match("^([%a][%w+.-]*)://([^/?#]+)(.*)$")
    if not scheme or not authority or authority == "" or authority:find("@", 1, true) then return nil end

    local host, port
    if authority:sub(1, 1) == "[" then
        host, port = authority:match("^%[([^%]]+)%]:?(%d*)$")
    else
        host, port = authority:match("^([^:]+):?(%d*)$")
    end
    if not host or host == "" then return nil end
    return {
        scheme = lower(scheme), authority = authority, host = lower(host),
        port = port ~= "" and tonumber(port) or nil,
        path = path ~= "" and path or "/",
    }
end

function SubstackURL.isSubstackHost(host)
    host = lower(host)
    if not host or #host > 253 or host:find("[^a-z0-9.-]") or host:find("..", 1, true) then return false end
    for label in host:gmatch("[^.]+") do
        if #label > 63 or label:sub(1, 1) == "-" or label:sub(-1) == "-" then return false end
    end
    return host == "substack.com" or host:match("%.substack%.com$") ~= nil
end

function SubstackURL.isPrivateHost(host)
    host = lower(host)
    if not host then return true end
    if host == "localhost" or host:match("%.localhost$") or host:match("%.local$") then return true end
    if host == "::1" or host:match("^fe[89ab]") or host:match("^f[cd]") then return true end
    local a, b = host:match("^(%d+)%.(%d+)%.")
    a, b = tonumber(a), tonumber(b)
    if not a then return false end
    if a == 0 or a == 10 or a == 127 or a >= 224 then return true end
    if a == 100 and b and b >= 64 and b <= 127 then return true end
    if a == 169 and b == 254 then return true end
    if a == 172 and b and b >= 16 and b <= 31 then return true end
    if a == 192 and b == 168 then return true end
    return false
end

function SubstackURL.isSafeExternal(url)
    local parsed = SubstackURL.parse(url)
    return parsed ~= nil and parsed.scheme == "https" and not SubstackURL.isPrivateHost(parsed.host)
end

function SubstackURL.resolve(base_url, location)
    if type(location) ~= "string" or location == "" then return nil end
    if location:match("^[%a][%w+.-]*://") then return location end
    local base = SubstackURL.parse(base_url)
    if not base then return nil end
    if location:sub(1, 2) == "//" then return base.scheme .. ":" .. location end
    if location:sub(1, 1) == "/" then return base.scheme .. "://" .. base.authority .. location end
    local directory = base.path:gsub("[?#].*$", ""):match("^(.*)/") or ""
    return base.scheme .. "://" .. base.authority .. directory .. "/" .. location
end

function SubstackURL.escapePathSegment(value)
    return (tostring(value or ""):gsub("([^%w%-._~])", function(char)
        return string.format("%%%02X", string.byte(char))
    end))
end

function SubstackURL.validSubdomain(value)
    if type(value) ~= "string" or #value == 0 or #value > 63 then return false end
    return value:match("^[a-zA-Z0-9]$") ~= nil
        or value:match("^[a-zA-Z0-9][a-zA-Z0-9-]*[a-zA-Z0-9]$") ~= nil
end

return SubstackURL
