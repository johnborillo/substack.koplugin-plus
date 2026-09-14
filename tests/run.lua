local plugin_dir = (... and ... ~= "" and ...) or "."
package.path = plugin_dir .. "/?.lua;" .. package.path

local passed, failed = 0, 0
local function check(name, condition)
    if condition then
        passed = passed + 1
        io.write("ok - ", name, "\n")
    else
        failed = failed + 1
        io.write("not ok - ", name, "\n")
    end
end

package.preload["logger"] = function()
    return { warn = function() end, info = function() end, err = function() end }
end

local SubstackURL = require("substack_url")
check("recognizes root Substack host", SubstackURL.isSubstackHost("substack.com"))
check("recognizes publication Substack host", SubstackURL.isSubstackHost("example.substack.com"))
check("rejects lookalike host", not SubstackURL.isSubstackHost("substack.com.example.org"))
check("rejects malformed Substack host", not SubstackURL.isSubstackHost("bad\n.substack.com"))
check("rejects HTTP external URL", not SubstackURL.isSafeExternal("http://cdn.example.org/image.jpg"))
check("rejects private external URL", not SubstackURL.isSafeExternal("https://192.168.1.2/image.jpg"))
check("resolves relative redirect", SubstackURL.resolve("https://substack.com/api/posts", "../login") == "https://substack.com/api/../login")
check("escapes a path segment", SubstackURL.escapePathSegment("a/b c") == "a%2Fb%20c")
check("validates publication subdomains", SubstackURL.validSubdomain("good-news")
    and not SubstackURL.validSubdomain("../settings") and not SubstackURL.validSubdomain("bad-"))

local captured = {}
package.preload["socket"] = function() return { sleep = function() end } end
package.preload["socketutil"] = function()
    return {
        set_timeout = function() end, reset_timeout = function() end,
        table_sink = function(target)
            return function(chunk)
                if chunk then table.insert(target, chunk) end
                return 1
            end
        end,
    }
end
package.preload["json"] = function()
    return { decode = function() return {} end, encode = function() return "{}" end }
end
package.preload["ssl.https"] = function()
    return {
        request = function(request)
            table.insert(captured, request)
            if request.url == "https://substack.com/start" then
                request.sink(""); request.sink(nil)
                return 1, 302, { location = "https://images.example.org/pixel" }, "redirect"
            end
            request.sink("{}"); request.sink(nil)
            return 1, 200, {}, "ok"
        end,
    }
end

local SubstackClient = require("substack_client")
local client = SubstackClient:new("secret-token")
client:raw_request("/reader/posts")
check("authenticated API request includes cookie", captured[1].headers.Cookie == "substack.sid=secret-token")
captured = {}
client:raw_request("https://substack.com/start")
check("redirect starts authenticated", captured[1].headers.Cookie == "substack.sid=secret-token")
check("cross-origin redirect drops cookie", captured[2].headers.Cookie == nil)
local code, error_message = client:raw_request("http://substack.com/api/v1/reader/posts")
check("HTTP API request is blocked", code == nil and error_message:match("HTTPS") ~= nil)
local external_code, external_error = client:raw_request("https://example.org/not-an-api")
check("authenticated external request is blocked", external_code == nil and external_error:match("outside Substack") ~= nil)
local alternate_port_code = client:raw_request("https://substack.com:8443/api/v1/reader/posts")
check("authenticated nonstandard port is blocked", alternate_port_code == nil)
local bad_client = SubstackClient:new("bad\r\nInjected: value")
local bad_code = bad_client:raw_request("/reader/posts")
check("header injection in cookie is blocked", bad_code == nil)

package.loaded["substack_api"] = nil
package.loaded["substack_client"] = {
    new = function() return { request = function() end, download_file = function() end, download_data = function() end } end,
}
local SubstackAPI = require("substack_api")
local api = SubstackAPI:new("")
local request_count = 0
api.request = function()
    request_count = request_count + 1
    local posts = {}
    for index = 1, 20 do table.insert(posts, { id = index }) end
    return { posts = posts, publications = {}, inboxItems = {} }
end
local page = api:getInbox(40)
check("pagination stops when a page has no new IDs", request_count == 2 and #page.posts == 20)

package.preload["libs/libkoreader-lfs"] = function() return {} end
package.preload["gettext"] = function() return function(value) return value end end
package.preload["ffi/util"] = function()
    return { template = function(value, replacement) return value:gsub("%%1", tostring(replacement)) end }
end
package.loaded["substack_utils"] = nil
local SubstackUtils = require("substack_utils")
check("UTF-8 truncation preserves characters", SubstackUtils.truncate("é中文abc", 3) == "é中…")
check("HTML escaping handles markup", SubstackUtils.escape_html("<x>&\"") == "&lt;x&gt;&amp;&quot;")
local cleaned = SubstackUtils.clean_html('<SCRIPT>alert(1)</SCRIPT><p onclick="bad()"><a href="javascript:bad()">Safe</a></p>')
check("sanitizer removes script blocks", not cleaned:lower():match("script"))
check("sanitizer removes event handlers", not cleaned:lower():match("onclick"))
check("sanitizer neutralizes javascript links", not cleaned:lower():match("javascript:"))

package.loaded["substack_post"] = nil
local SubstackPost = require("substack_post")
local fake_api = { downloadData = function() return "\255\216image-data" end }
local bundle, images = SubstackPost.build(fake_api, {
    id = 42,
    title = "A <better> reader",
    subtitle = "Fast & calm",
    publishedBylines = { { name = "Jane <Writer>" } },
    post_date = "2026-09-14T12:00:00Z",
    canonical_url = "https://publication.substack.com/p/example",
    body_html = '<p>Hello</p><img src="https://cdn.example.org/photo?format=auto" alt="Cover & art">',
}, { publication = "Example & Co", subdomain = "publication", include_images = true })
check("post pipeline returns a cache bundle", bundle and bundle.id == "42" and bundle.images_complete)
check("post pipeline localizes images", #images == 1 and bundle.html_content:match('src="images/'))
check("post pipeline escapes header metadata", bundle.html_content:match("A &lt;better&gt; reader") ~= nil
    and bundle.html_content:match("Example &amp; Co") ~= nil
    and bundle.html_content:match("By Jane &lt;Writer&gt;") ~= nil)
local text_only = SubstackPost.build(fake_api, {
    id = 43, title = "Text", canonical_url = "https://publication.substack.com/p/text",
    body_html = '<img src="https://cdn.example.org/photo.jpg">',
}, { include_images = false })
check("text-only cache records incomplete images", text_only and not text_only.images_complete)
local limited_bundle, limited_images = SubstackPost.build(fake_api, {
    id = 44, title = "Limited", canonical_url = "https://publication.substack.com/p/limited",
    body_html = '<img src="https://cdn.example.org/one.jpg"><img src="https://cdn.example.org/two.jpg">',
}, { include_images = true, max_images = 1 })
check("post pipeline enforces image-count limits", limited_bundle and not limited_bundle.images_complete
    and #limited_images == 1)
local duplicate_bundle, duplicate_images = SubstackPost.build(fake_api, {
    id = 45, title = "Duplicate", canonical_url = "https://publication.substack.com/p/duplicate",
    body_html = '<img src="https://cdn.example.org/same.jpg"><img src="https://cdn.example.org/same.jpg">',
}, { include_images = true })
check("post pipeline stores duplicate images once", duplicate_bundle and duplicate_bundle.images_complete
    and #duplicate_images == 1)

io.write(string.format("\n%d passed, %d failed\n", passed, failed))
if failed > 0 then os.exit(1) end
