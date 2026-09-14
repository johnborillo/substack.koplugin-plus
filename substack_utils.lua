local lfs = require("libs/libkoreader-lfs")
local JSON = require("json")
local _ = require("gettext")

local SubstackUtils = {}

function SubstackUtils.readJSON(path)
    local file = io.open(path, "r")
    if not file then return nil end
    local content = file:read("*all")
    file:close()
    local ok, decoded = pcall(JSON.decode, content)
    return ok and type(decoded) == "table" and decoded or nil
end

function SubstackUtils.saveJSON(path, data)
    local ok, encoded = pcall(JSON.encode, data)
    if not ok then return false, tostring(encoded) end
    local temporary_path = path .. ".part"
    local file = io.open(temporary_path, "w")
    if not file then return false, "Unable to open settings file" end
    local written = file:write(encoded)
    file:close()
    if not written then os.remove(temporary_path); return false, "Unable to write settings" end
    if not os.rename(temporary_path, path) then
        os.remove(temporary_path)
        return false, "Unable to finalize settings"
    end
    return true
end

function SubstackUtils.rm_recursive(path)
    local attributes = lfs.attributes(path)
    if not attributes then return end
    if attributes.mode == "directory" then
        for file in lfs.dir(path) do
            if file ~= "." and file ~= ".." then SubstackUtils.rm_recursive(path .. "/" .. file) end
        end
        lfs.rmdir(path)
    else
        os.remove(path)
    end
end

function SubstackUtils.read_txt(path)
    local file = io.open(path, "r")
    if not file then return nil end
    local content = file:read("*all")
    file:close()
    return content:gsub("^%s+", ""):gsub("%s+$", "")
end

function SubstackUtils.trim(value)
    return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

function SubstackUtils.truncate(value, length)
    local text, chars = tostring(value or ""), {}
    for char in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do table.insert(chars, char) end
    if #chars <= length then return text end
    local result = {}
    for index = 1, math.max(0, length - 1) do table.insert(result, chars[index]) end
    return table.concat(result) .. "…"
end

function SubstackUtils.escape_html(value)
    return tostring(value or ""):gsub("&", "&amp;"):gsub("<", "&lt;")
        :gsub(">", "&gt;"):gsub('"', "&quot;"):gsub("'", "&#39;")
end

function SubstackUtils.stable_hash(value)
    value = tostring(value or "")
    local first, second = 5381, 52711
    for index = 1, #value do
        local byte = value:byte(index)
        first = (first * 33 + byte) % 4294967296
        second = (second * 65599 + value:byte(#value - index + 1)) % 4294967296
    end
    return string.format("%08x%08x", first, second)
end

local months = {
    _("January"), _("February"), _("March"), _("April"), _("May"), _("June"),
    _("July"), _("August"), _("September"), _("October"), _("November"), _("December"),
}

function SubstackUtils.format_date(iso_date)
    if type(iso_date) ~= "string" then return nil end
    local year, month, day = iso_date:match("^(%d%d%d%d)%-(%d%d?)%-(%d%d?)")
    year, month, day = tonumber(year), tonumber(month), tonumber(day)
    if not year or not month or not day or month < 1 or month > 12 or day < 1 or day > 31 then return nil end
    return string.format("%d %s %d", day, months[month], year)
end

function SubstackUtils.get_pub_name(post, publication_map)
    if type(post) ~= "table" then return _("Substack") end
    local inner = type(post.post) == "table" and post.post or post
    local id = inner.publication_id or post.publication_id
    if id and publication_map and publication_map[tostring(id)] then return publication_map[tostring(id)] end
    local url = inner.canonical_url or inner.url or post.canonical_url or post.url
    if type(url) ~= "string" then return _("Substack") end
    local clean = url:gsub("^https?://", ""):gsub("^www%.", "")
    return clean:match("^([^/]+)") or clean
end

function SubstackUtils.clean_html(html)
    if type(html) ~= "string" or html == "" then return "" end
    local cleaned = html:gsub("%z", "")
    cleaned = cleaned:gsub("<!%-%-[%s%S]-%-%->", "")
    cleaned = cleaned:gsub("<(%s*/?%s*)([%a][%w:-]*)", function(prefix, name)
        return "<" .. prefix .. name:lower()
    end)
    for _, tag in ipairs({ "script", "style", "svg", "iframe", "object", "embed", "form", "button" }) do
        cleaned = cleaned:gsub("<" .. tag .. "%f[%s>][^>]*>[%s%S]-</" .. tag .. "%s*>", "")
    end
    for _, tag in ipairs({ "base", "meta", "link", "input" }) do
        cleaned = cleaned:gsub("<%s*" .. tag .. "%f[%s/>][^>]*>", "")
    end
    cleaned = cleaned:gsub("%s+[Oo][Nn][%w_:-]+%s*=%s*(['\"])[%s%S]-%1", "")
    cleaned = cleaned:gsub("%s+[Oo][Nn][%w_:-]+%s*=%s*[^%s>]+", "")
    cleaned = cleaned:gsub("(%s+[Hh][Rr][Ee][Ff]%s*=%s*['\"])%s*[Jj][Aa][Vv][Aa][Ss][Cc][Rr][Ii][Pp][Tt]:[^'\"]*(['\"])", "%1#%2")
    cleaned = cleaned:gsub("<p>%s*</p>", ""):gsub("<p>%s*&nbsp;%s*</p>", "")
    return cleaned
end

return SubstackUtils
