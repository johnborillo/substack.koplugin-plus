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

return SubstackUtils
