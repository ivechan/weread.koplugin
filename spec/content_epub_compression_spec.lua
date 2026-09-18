-- EPUB compression selection: text entries are deflated, already-compressed
-- image assets are stored, and mimetype stays uncompressed. Uses a fake
-- Archiver.Writer so no real archive is built.

package.path = "./?.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

package.preload["weread.lib.crypto"] = function() return {} end
package.preload["weread.lib.reader_state"] = function() return {} end
package.preload["weread.lib.protocol"] = function()
    return {
        reader_url = function(book_id, chapter_uid)
            return "https://example/" .. tostring(book_id) .. "/"
                .. tostring(chapter_uid)
        end,
    }
end
package.preload["weread.lib.logger"] = function()
    local function noop() end
    return {
        info = noop, warn = noop, err = noop, dbg = noop,
        scoped = function()
            return { info = noop, warn = noop, err = noop, dbg = noop }
        end,
    }
end

local added = {}
local Writer = {}
Writer.__index = Writer
function Writer.new()
    return setmetatable({ err = nil }, Writer)
end
function Writer:open(path)
    self._path = path
    self._file = io.open(path, "wb")
    return true
end
function Writer:setZipCompression(method)
    self._method = method
    return true
end
function Writer:addFileFromMemory(name, _data, _mtime)
    added[#added + 1] = { name = name, method = self._method }
    return true
end
function Writer:addPath(name, _path, _recursive, _mtime)
    added[#added + 1] = { name = name, method = self._method }
    return true
end
function Writer:close()
    if self._file then
        self._file:write("epub")
        self._file:close()
    end
    return true
end
package.preload["ffi/archiver"] = function()
    return { Writer = { new = function() return Writer.new() end } }
end

local Content = require("weread.lib.content")

local dir = "/tmp/weread-epub-compression-spec"
os.execute("rm -rf " .. dir)
local settings = { cache_dir = dir }
local book = { book_id = "book", title = "Book", author = "Author", cache_dir = dir }
local chapter = { chapterUid = 1, title = "One" }
local assets = {
    { href = "images/a.jpg", data = "JPEGDATA", store = true },
    { href = "images/b.png", data = "PNGDATA", store = true },
}

local path = Content.save_chapter_epub(
    settings, book, chapter, "<p>hi</p>", assets, nil)
expect(type(path) == "string" and path:find("%.epub$") ~= nil,
    "chapter EPUB was not written")

local method_by_name = {}
for _i, entry in ipairs(added) do
    method_by_name[entry.name] = entry.method
end
expect(method_by_name["mimetype"] == "store",
    "mimetype must stay stored uncompressed")
expect(method_by_name["OEBPS/text/chapter.xhtml"] == "deflate",
    "chapter text should still be deflated")
expect(method_by_name["OEBPS/content.opf"] == "deflate",
    "package metadata should still be deflated")
expect(method_by_name["OEBPS/style.css"] == "deflate",
    "stylesheet should still be deflated")
expect(method_by_name["OEBPS/images/a.jpg"] == "store"
    and method_by_name["OEBPS/images/b.png"] == "store",
    "image assets must be stored, not deflated")

os.execute("rm -rf " .. dir)
print(("content_epub_compression_spec: %d checks"):format(checks))
