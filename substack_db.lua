local SQ3 = require("lua-ljsqlite3/init")
local JSON = require("json")
local Device = require("device")
local logger = require("logger")

local SubstackDB = {}
SubstackDB.__index = SubstackDB

local function open_connection(path)
    local conn = SQ3.open(path)
    conn:exec("PRAGMA foreign_keys=ON; PRAGMA busy_timeout=3000;")
    return conn
end

local function decode_json(value)
    if type(value) ~= "string" or value == "" then return {} end
    local ok, decoded = pcall(JSON.decode, value)
    return ok and type(decoded) == "table" and decoded or {}
end

local function post_from_row(row)
    if not row then return nil end
    return {
        id = row[1], title = row[2], publication = row[3], subdomain = row[4],
        html_content = row[5], metadata = decode_json(row[6]), cached_at = tonumber(row[7]),
        images_complete = tonumber(row[8] or 0) == 1,
    }
end

function SubstackDB:new(db_path)
    local object = setmetatable({ db_path = db_path }, self)
    object:init()
    return object
end

function SubstackDB:init()
    local conn = open_connection(self.db_path)
    if Device.canUseWAL and Device:canUseWAL() then
        conn:exec("PRAGMA journal_mode=WAL;")
    else
        conn:exec("PRAGMA journal_mode=TRUNCATE;")
    end
    conn:exec([[
        CREATE TABLE IF NOT EXISTS posts (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL DEFAULT '',
            publication TEXT NOT NULL DEFAULT '',
            subdomain TEXT,
            html_content TEXT NOT NULL,
            metadata TEXT NOT NULL DEFAULT '{}',
            cached_at INTEGER NOT NULL,
            images_complete INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS images (
            url_hash TEXT PRIMARY KEY,
            post_id TEXT NOT NULL,
            data BLOB NOT NULL,
            extension TEXT NOT NULL,
            FOREIGN KEY(post_id) REFERENCES posts(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS images_post_id_idx ON images(post_id);
        CREATE TABLE IF NOT EXISTS read_posts (
            post_id TEXT PRIMARY KEY,
            read_at INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS reading_progress (
            post_id TEXT PRIMARY KEY,
            ratio REAL NOT NULL DEFAULT 0,
            updated_at INTEGER NOT NULL,
            FOREIGN KEY(post_id) REFERENCES posts(id) ON DELETE CASCADE
        );
    ]])

    local version = tonumber(conn:rowexec("PRAGMA user_version;")) or 0
    if version < 2 then
        pcall(conn.exec, conn, "ALTER TABLE posts ADD COLUMN images_complete INTEGER NOT NULL DEFAULT 0;")
        conn:exec("CREATE INDEX IF NOT EXISTS images_post_id_idx ON images(post_id); PRAGMA user_version=2;")
    end
    conn:close()
end

function SubstackDB:savePostBundle(post, images)
    assert(type(post) == "table" and post.id and post.id ~= "", "post id required")
    local metadata_ok, metadata = pcall(JSON.encode, post.metadata or {})
    if not metadata_ok then metadata = "{}" end
    local conn = open_connection(self.db_path)
    local ok, err = pcall(function()
        conn:exec("BEGIN IMMEDIATE;")
        local stmt = conn:prepare([[
            INSERT INTO posts (id, title, publication, subdomain, html_content, metadata, cached_at, images_complete)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                title=excluded.title, publication=excluded.publication, subdomain=excluded.subdomain,
                html_content=excluded.html_content, metadata=excluded.metadata,
                cached_at=excluded.cached_at, images_complete=excluded.images_complete;
        ]])
        stmt:bind(tostring(post.id), post.title or "", post.publication or "", post.subdomain,
            post.html_content or "", metadata, os.time(), post.images_complete and 1 or 0):step()
        stmt:close()
        stmt = conn:prepare("DELETE FROM images WHERE post_id = ?;")
        stmt:bind(tostring(post.id)):step()
        stmt:close()
        if type(images) == "table" and #images > 0 then
            stmt = conn:prepare("INSERT OR REPLACE INTO images (url_hash, post_id, data, extension) VALUES (?, ?, ?, ?);")
            for _, image in ipairs(images) do
                stmt:reset():bind(image.url_hash, tostring(post.id), image.data, image.extension):step()
            end
            stmt:close()
        end
        conn:exec("COMMIT;")
    end)
    if not ok then
        pcall(conn.exec, conn, "ROLLBACK;")
        logger.err("[Substack] Unable to save post bundle:", err)
    end
    conn:close()
    return ok, ok and nil or tostring(err)
end

function SubstackDB:getPost(post_id)
    if not post_id or post_id == "" then return nil end
    local conn = open_connection(self.db_path)
    local stmt = conn:prepare("SELECT id,title,publication,subdomain,html_content,metadata,cached_at,images_complete FROM posts WHERE id=?;")
    local result = stmt:bind(tostring(post_id)):step()
    local post = post_from_row(result)
    stmt:close(); conn:close()
    return post
end

function SubstackDB:getImagesForPost(post_id)
    local conn = open_connection(self.db_path)
    local stmt = conn:prepare("SELECT url_hash,data,extension FROM images WHERE post_id=?;")
    local images = {}
    for row in stmt:bind(tostring(post_id)):rows() do
        table.insert(images, { url_hash = row[1], data = row[2], extension = row[3] })
    end
    stmt:close(); conn:close()
    return images
end

function SubstackDB:isPostCached(post_id, require_images)
    if not post_id or post_id == "" then return false end
    local conn = open_connection(self.db_path)
    local sql = require_images
        and "SELECT 1 FROM posts WHERE id=? AND images_complete=1;"
        or "SELECT 1 FROM posts WHERE id=?;"
    local stmt = conn:prepare(sql)
    local result = stmt:bind(tostring(post_id)):step()
    stmt:close(); conn:close()
    return result ~= nil
end

function SubstackDB:deletePost(post_id)
    local conn = open_connection(self.db_path)
    local stmt = conn:prepare("DELETE FROM posts WHERE id=?;")
    stmt:bind(tostring(post_id)):step()
    stmt:close(); conn:close()
end

function SubstackDB:searchPosts(query, limit)
    query = tostring(query or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if query == "" then return {} end
    local pattern = "%" .. query .. "%"
    local conn = open_connection(self.db_path)
    local stmt = conn:prepare([[
        SELECT id,title,publication,subdomain,html_content,metadata,cached_at,images_complete
        FROM posts WHERE title LIKE ? OR publication LIKE ? OR html_content LIKE ?
        ORDER BY cached_at DESC LIMIT ?;
    ]])
    local posts = {}
    for row in stmt:bind(pattern, pattern, pattern, math.max(1, math.min(100, tonumber(limit) or 50))):rows() do
        table.insert(posts, post_from_row(row))
    end
    stmt:close(); conn:close()
    return posts
end

function SubstackDB:getContinueReading(limit)
    local conn = open_connection(self.db_path)
    local stmt = conn:prepare([[
        SELECT p.id,p.title,p.publication,p.subdomain,p.html_content,p.metadata,p.cached_at,p.images_complete
        FROM posts p JOIN reading_progress r ON p.id=r.post_id
        WHERE r.ratio > 0.01 AND r.ratio < 0.98 ORDER BY r.updated_at DESC LIMIT ?;
    ]])
    local posts = {}
    for row in stmt:bind(math.max(1, math.min(20, tonumber(limit) or 5))):rows() do table.insert(posts, post_from_row(row)) end
    stmt:close(); conn:close()
    return posts
end

function SubstackDB:saveReadingProgress(post_id, ratio)
    ratio = math.max(0, math.min(1, tonumber(ratio) or 0))
    local conn = open_connection(self.db_path)
    local stmt = conn:prepare("INSERT OR REPLACE INTO reading_progress (post_id,ratio,updated_at) VALUES (?,?,?);")
    stmt:bind(tostring(post_id), ratio, os.time()):step()
    stmt:close(); conn:close()
end

function SubstackDB:getReadingProgress(post_id)
    local conn = open_connection(self.db_path)
    local stmt = conn:prepare("SELECT ratio FROM reading_progress WHERE post_id=?;")
    local result = stmt:bind(tostring(post_id)):step()
    stmt:close(); conn:close()
    return result and tonumber(result[1]) or 0
end

function SubstackDB:markPostAsRead(post_id)
    if not post_id or post_id == "" then return end
    local conn = open_connection(self.db_path)
    local stmt = conn:prepare("INSERT OR REPLACE INTO read_posts (post_id,read_at) VALUES (?,?);")
    stmt:bind(tostring(post_id), os.time()):step()
    stmt:close(); conn:close()
end

function SubstackDB:markPostAsUnread(post_id)
    local conn = open_connection(self.db_path)
    local stmt = conn:prepare("DELETE FROM read_posts WHERE post_id=?;")
    stmt:bind(tostring(post_id)):step()
    stmt:close(); conn:close()
end

function SubstackDB:isPostRead(post_id)
    if not post_id or post_id == "" then return false end
    local conn = open_connection(self.db_path)
    local stmt = conn:prepare("SELECT 1 FROM read_posts WHERE post_id=?;")
    local result = stmt:bind(tostring(post_id)):step()
    stmt:close(); conn:close()
    return result ~= nil
end

function SubstackDB:getReadPostIds()
    local conn = open_connection(self.db_path)
    local result = {}
    local stmt = conn:prepare("SELECT post_id FROM read_posts;")
    for row in stmt:rows() do if row[1] then result[tostring(row[1])] = true end end
    stmt:close(); conn:close()
    return result
end

function SubstackDB:getCacheStats()
    local conn = open_connection(self.db_path)
    local posts = tonumber(conn:rowexec("SELECT COUNT(*) FROM posts;")) or 0
    local images = tonumber(conn:rowexec("SELECT COUNT(*) FROM images;")) or 0
    local bytes = tonumber(conn:rowexec("SELECT COALESCE(SUM(LENGTH(data)),0) FROM images;")) or 0
    conn:close()
    return { posts = posts, images = images, bytes = bytes }
end

function SubstackDB:clearCache()
    local conn = open_connection(self.db_path)
    conn:exec("BEGIN; DELETE FROM images; DELETE FROM reading_progress; DELETE FROM posts; COMMIT;")
    conn:close()
end

return SubstackDB
