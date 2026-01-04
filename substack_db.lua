local SQ3 = require("lua-ljsqlite3/init")
local JSON = (package.loaded["json"] or (pcall(require, "json") and require("json")) or require("util").json)
local logger = require("logger")

local SubstackDB = {}

function SubstackDB:new(db_path)
    local obj = {
        db_path = db_path
    }
    setmetatable(obj, self)
    self.__index = self
    obj:init()
    return obj
end

function SubstackDB:init()
    local conn = SQ3.open(self.db_path)
    
    -- Posts table
    conn:exec([[
        CREATE TABLE IF NOT EXISTS posts (
            id TEXT PRIMARY KEY,
            title TEXT,
            publication TEXT,
            subdomain TEXT,
            html_content TEXT,
            metadata TEXT,
            cached_at INTEGER
        );
    ]])
    
    -- Images table
    conn:exec([[
        CREATE TABLE IF NOT EXISTS images (
            url_hash TEXT PRIMARY KEY,
            post_id TEXT,
            data BLOB,
            extension TEXT,
            FOREIGN KEY(post_id) REFERENCES posts(id) ON DELETE CASCADE
        );
    ]])
    
    conn:close()
end

function SubstackDB:savePost(post_id, title, publication, subdomain, html_content, metadata)
    local conn = SQ3.open(self.db_path)
    local metadata_str = JSON.encode(metadata)
    local stmt = conn:prepare([[
        INSERT OR REPLACE INTO posts (id, title, publication, subdomain, html_content, metadata, cached_at)
        VALUES (?, ?, ?, ?, ?, ?, ?);
    ]])
    stmt:reset():bind(post_id, title, publication, subdomain, html_content, metadata_str, os.time()):step()
    stmt:close()
    conn:close()
end

function SubstackDB:getPost(post_id)
    local conn = SQ3.open(self.db_path)
    local stmt = conn:prepare("SELECT * FROM posts WHERE id = ?;")
    local result = stmt:reset():bind(post_id):step()
    stmt:close()
    conn:close()
    
    if result then
        return {
            id = result[1],
            title = result[2],
            publication = result[3],
            subdomain = result[4],
            html_content = result[5],
            metadata = JSON.decode(result[6]),
            cached_at = result[7]
        }
    end
    return nil
end

function SubstackDB:saveImage(url_hash, post_id, data, extension)
    local conn = SQ3.open(self.db_path)
    local stmt = conn:prepare([[
        INSERT OR REPLACE INTO images (url_hash, post_id, data, extension)
        VALUES (?, ?, ?, ?);
    ]])
    stmt:reset():bind(url_hash, post_id, data, extension):step()
    stmt:close()
    conn:close()
end

function SubstackDB:getImagesForPost(post_id)
    local conn = SQ3.open(self.db_path)
    local stmt = conn:prepare("SELECT url_hash, data, extension FROM images WHERE post_id = ?;")
    local images = {}
    for row in stmt:reset():bind(post_id):rows() do
        table.insert(images, {
            url_hash = row[1],
            data = row[2],
            extension = row[3]
        })
    end
    stmt:close()
    conn:close()
    return images
end

function SubstackDB:clearCache()
    local conn = SQ3.open(self.db_path)
    conn:exec("DELETE FROM images;")
    conn:exec("DELETE FROM posts;")
    conn:close()
end

function SubstackDB:isPostCached(post_id)
    local conn = SQ3.open(self.db_path)
    local stmt = conn:prepare("SELECT 1 FROM posts WHERE id = ?;")
    local result = stmt:reset():bind(post_id):step()
    stmt:close()
    conn:close()
    return result ~= nil
end

return SubstackDB
