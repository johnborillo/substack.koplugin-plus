local SubstackUtils = require("substack_utils")
local SubstackURL = require("substack_url")
local _ = require("gettext")
local T = require("ffi/util").template

local SubstackPost = {}
local DEFAULT_MAX_IMAGES = 40
local DEFAULT_MAX_IMAGE_BYTES = 60 * 1024 * 1024

local READER_CSS = [[
    @page { margin: 0; }
    body, html { margin: 0; padding: 0 0.7em; }
    p { margin: 0 0 1em; }
    img { max-width: 100%; height: auto; display: block; margin: 1em auto; }
    blockquote { margin: 1em 0.8em; padding-left: 0.8em; border-left: 0.18em solid #777; }
    .header-title { text-align: center; font-size: 1.5em; font-weight: bold; margin: 0.6em 0 0.35em; }
    .header-subtitle { text-align: center; font-size: 1.08em; font-style: italic; }
    .header-byline { text-align: center; font-size: 0.95em; }
    .header-date { text-align: center; font-size: 0.9em; }
    .publication { text-align: center; font-weight: bold; margin-bottom: 1.2em; }
    .image-placeholder { text-align: center; font-style: italic; color: #666; }
]]

local function image_extension(data)
    if type(data) ~= "string" then return "jpg" end
    if data:sub(1, 8) == "\137PNG\r\n\26\n" then return "png" end
    if data:sub(1, 3) == "GIF" then return "gif" end
    if data:sub(1, 2) == "\255\216" then return "jpg" end
    if data:sub(1, 4) == "RIFF" and data:sub(9, 12) == "WEBP" then return "webp" end
    return "jpg"
end

local function absolute_image_url(url, base_url)
    if type(url) ~= "string" or url == "" then return nil end
    if url:sub(1, 2) == "//" then return "https:" .. url end
    if url:match("^https://") then return url end
    if url:sub(1, 1) == "/" and base_url then return SubstackURL.resolve(base_url, url) end
    return nil
end

local function author_name(post)
    if type(post.author_name) == "string" then return post.author_name end
    if type(post.byline) == "string" then return post.byline end
    if type(post.publishedBylines) == "table" and type(post.publishedBylines[1]) == "table" then
        return post.publishedBylines[1].name
    end
    if type(post.user) == "table" then return post.user.name end
end

function SubstackPost.build(api, full, options)
    options = options or {}
    local post = type(full) == "table" and (full.post or full) or nil
    if type(post) ~= "table" then return nil, nil, "Invalid post response" end
    local id = tostring(post.id or options.fallback_id or post.slug or "")
    if id == "" then return nil, nil, "Post has no identifier" end

    local content = SubstackUtils.clean_html(post.body_html or "")
    local images, attempted, failed, total_image_bytes = {}, 0, 0, 0
    local max_images = math.max(0, tonumber(options.max_images) or DEFAULT_MAX_IMAGES)
    local max_image_bytes = math.max(0, tonumber(options.max_image_bytes) or DEFAULT_MAX_IMAGE_BYTES)
    local localized_images = {}
    content = content:gsub("<img([^>]*)>", function(attributes)
        local quote, source = attributes:match("[Ss][Rr][Cc]%s*=%s*(['\"])(.-)%1")
        local alt_quote, alt = attributes:match("[Aa][Ll][Tt]%s*=%s*(['\"])(.-)%1")
        local url = absolute_image_url(source, post.canonical_url or post.url)
        if not url then return "" end
        attempted = attempted + 1
        if not options.include_images then
            return '<p class="image-placeholder">[' .. SubstackUtils.escape_html(_("Image omitted")) .. "]</p>"
        end
        if localized_images[url] then
            return string.format('<img src="images/%s.%s" alt="%s">', localized_images[url].hash,
                localized_images[url].extension, SubstackUtils.escape_html(alt or ""))
        end
        if #images >= max_images then
            failed = failed + 1
            return '<p class="image-placeholder">[' .. SubstackUtils.escape_html(_("Image omitted")) .. "]</p>"
        end
        local download_url = url:gsub("f_auto", "f_jpg"):gsub("f_webp", "f_jpg")
        local data = api:downloadData(download_url)
        if not data then failed = failed + 1; return '<p class="image-placeholder">[' .. SubstackUtils.escape_html(_("Image unavailable")) .. "]</p>" end
        if total_image_bytes + #data > max_image_bytes then
            failed = failed + 1
            return '<p class="image-placeholder">[' .. SubstackUtils.escape_html(_("Image omitted")) .. "]</p>"
        end
        local extension = image_extension(data)
        local hash = SubstackUtils.stable_hash(id .. "|" .. url)
        table.insert(images, { url_hash = hash, data = data, extension = extension })
        total_image_bytes = total_image_bytes + #data
        localized_images[url] = { hash = hash, extension = extension }
        return string.format('<img src="images/%s.%s" alt="%s">', hash, extension, SubstackUtils.escape_html(alt or ""))
    end)

    if content == "" then
        content = post.audience == "only_paid"
            and "<p><i>" .. SubstackUtils.escape_html(_("Post is paywalled. Check your Substack login.")) .. "</i></p>"
            or "<p><i>" .. SubstackUtils.escape_html(_("No readable content was found.")) .. "</i></p>"
    end

    local subtitle = ""
    if post.subtitle and post.subtitle ~= "" then
        subtitle = '<p class="header-subtitle">' .. SubstackUtils.escape_html(post.subtitle) .. "</p>"
    end
    local author = SubstackUtils.trim(author_name(post))
    if author ~= "" then
        subtitle = subtitle .. '<p class="header-byline">' .. SubstackUtils.escape_html(T(_("By %1"), author)) .. "</p>"
    end
    local date = SubstackUtils.format_date(post.post_date)
    if date then subtitle = subtitle .. '<p class="header-date">' .. SubstackUtils.escape_html(date) .. "</p>" end
    if options.publication and options.publication ~= "" then
        subtitle = subtitle .. '<div class="publication">' .. SubstackUtils.escape_html(options.publication) .. "</div>"
    end
    local title = SubstackUtils.trim(post.title ~= nil and post.title or _("Untitled"))
    local html = string.format(
        "<!DOCTYPE html><html><head><meta charset='UTF-8'><style>%s</style></head><body><h1 class='header-title'>%s</h1>%s<hr>%s</body></html>",
        READER_CSS, SubstackUtils.escape_html(title), subtitle, content)

    return {
        id = id, title = title, publication = options.publication or "", subdomain = options.subdomain,
        html_content = html, metadata = post,
        images_complete = options.include_images and failed == 0 or attempted == 0,
    }, images
end

SubstackPost.READER_CSS = READER_CSS
return SubstackPost
