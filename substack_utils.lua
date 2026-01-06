local lfs = require("libs/libkoreader-lfs")
local JSON = (package.loaded["json"] or (pcall(require, "json") and require("json")) or require("util").json)

local SubstackUtils = {}

function SubstackUtils.readJSON(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*all")
    f:close()
    local ok, decoded = pcall(JSON.decode, content)
    return ok and decoded or nil
end

function SubstackUtils.saveJSON(path, data)
    local f = io.open(path, "w")
    if f then
        f:write(JSON.encode(data))
        f:close()
        return true
    end
    return false
end

function SubstackUtils.rm_recursive(path)
    if not lfs.attributes(path) then return end
    if lfs.attributes(path).mode == "directory" then
        for file in lfs.dir(path) do
            if file ~= "." and file ~= ".." then
                SubstackUtils.rm_recursive(path .. "/" .. file)
            end
        end
        lfs.rmdir(path)
    else
        os.remove(path)
    end
end

function SubstackUtils.read_txt(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*all")
    f:close()
    return string.gsub(string.gsub(content, "^%s+", ""), "%s+$", "")
end

function SubstackUtils.truncate(str, len)
    if #str <= len then return str end
    return str:sub(1, math.max(0, len - 3)) .. "..."
end


function SubstackUtils.get_ordinal(n)
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

function SubstackUtils.format_date(iso_date)
    if not iso_date or iso_date == "" then return nil end
    local y, m, d = string.match(iso_date, "^(%d+)-(%d+)-(%d+)")
    if not y or not m or not d then return nil end
    y, m, d = tonumber(y), tonumber(m), tonumber(d)
    return string.format("%d%s %s %d", d, SubstackUtils.get_ordinal(d), months[m], y)
end

function SubstackUtils.get_pub_name(post, pub_map)
    local p = post.post or post
    local pid = p.publication_id or post.publication_id
    if pid and pub_map and pub_map[tostring(pid)] then
        return pub_map[tostring(pid)]
    end

    local url = p.canonical_url or p.url or post.canonical_url or post.url
    if not url or type(url) ~= "string" then return "Substack" end

    -- Fallback: Remove protocol (https://, http://) and www.
    local clean = string.gsub(string.gsub(url, "^https?://", ""), "^www%.", "")
    -- Keep only the domain part (everything before the first /)
    return string.match(clean, "^([^/]+)") or clean
end

return SubstackUtils
