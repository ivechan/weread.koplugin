-- Focused tests for next-chapter selection and one-second prefetch notices.

package.path = "./?.lua;" .. package.path

local existing = {}
local logs = {}
package.preload["weread.lib.content"] = function()
    return {
        catalog_cache_path = function() return "/cache/catalog.json" end,
        save_catalog_cache = function() return true end,
    }
end
package.preload["weread.lib.logger"] = function()
    return {
        scoped = function()
            return {
                info = function(...) logs[#logs + 1] = { "info", ... } end,
                warn = function(...) logs[#logs + 1] = { "warn", ... } end,
            }
        end,
    }
end
package.preload["weread.lib.protocol"] = function()
    return { is_mp_book = function(book_id) return book_id == "mp-book" end }
end
local scheduled = {}
package.preload["ui/uimanager"] = function()
    return {
        scheduleIn = function(_self, delay, callback)
            scheduled[#scheduled + 1] = { delay = delay, callback = callback }
        end,
    }
end
package.preload["weread.lib.plugin_util"] = function()
    return {
        tr = function(text) return text end,
        T = function(text, ...)
            local values = { ... }
            return (text:gsub("%%(%d+)", function(index)
                return tostring(values[tonumber(index)] or "")
            end))
        end,
        display_error = function(value) return tostring(value) end,
        log_error = function(value) return tostring(value) end,
        file_exists = function(path) return existing[path] == true end,
    }
end

local Lifecycle = require("weread.lib.reader_lifecycle")

local checks, failures = 0, 0
local function expect(value, label)
    checks = checks + 1
    if not value then
        failures = failures + 1
        print("FAIL " .. label)
    end
end

local chapters = {
    { chapterUid = 1, title = "One" },
    { chapterUid = 2, title = "Two" },
    { chapterUid = 3, title = "Three" },
}
local book = {
    book_id = "book",
    chapters = chapters,
    cached_chapters = { ["1"] = "/cache/one.epub" },
}
existing["/cache/one.epub"] = true

local cache = {
    auto_prefetch_next_chapter = true,
    show_prefetch_notifications = true,
    download_underlines_and_thoughts = true,
}
local starts = {}
local notices = {}
local downloader = {
    cancelPrefetch = function() end,
    isPrefetching = function() return false end,
    isPromotedPrefetch = function() return false end,
    start = function(_self, target_book, target_chapters, suffix, options)
        starts[#starts + 1] = {
            book = target_book,
            chapters = target_chapters,
            suffix = suffix,
            options = options,
        }
        return true
    end,
}
local host = {
    settings = {
        get = function(_self, key)
            if key == "cache" then return cache end
            if key == "books" then return { book = book } end
        end,
    },
    downloader = downloader,
    ui = { document = { file = "/cache/one.epub" } },
    ensureChaptersLoaded = function() return chapters end,
    showTransientInfo = function(_self, text, timeout)
        notices[#notices + 1] = { text, timeout }
    end,
    detectWeReadBook = function() return nil end,
    requireLogin = function() return true end,
    progress_sync = { sync_now = function() end },
}
for key, value in pairs(Lifecycle) do host[key] = value end
host.detectWeReadBook = function() return nil end

expect(host:maybePrefetchNextChapter("book"), "prefetch request accepted")
expect(#starts == 1 and starts[1].chapters[1] == chapters[2],
    "only the immediate next chapter is selected")
expect(starts[1].options.include_annotations == false,
    "prefetch creates clean text regardless of the legacy annotation preference")
expect(starts[1].options.start_delay == 0.1,
    "prefetch starts promptly without waiting on a notice")

starts[1].options.on_start()
starts[1].options.on_complete(true, "/cache/two.epub")
expect(#notices == 0, "prefetch start and success are silent")
expect(#logs == 2 and logs[1][1] == "info" and logs[2][1] == "info",
    "prefetch start and success are logged")

starts = {}
notices = {}
book.cached_chapters["2"] = "/cache/two.epub"
existing["/cache/two.epub"] = true
expect(host:maybePrefetchNextChapter("book"), "cached next chapter is satisfied")
expect(#starts == 0, "cached next chapter does not scan forward to chapter three")

book.cached_chapters["2"] = nil
existing["/cache/two.epub"] = nil
host:maybePrefetchNextChapter("book")
starts[1].options.on_complete(false, "offline")
expect(#notices == 1
    and notices[1][1]:find("Network is not connected", 1, true) ~= nil
    and notices[1][2] == 3,
    "offline prefetch reports a long-lived failure notice")
expect(logs[#logs][1] == "warn", "prefetch failure is logged")

cache.show_prefetch_notifications = false
starts, notices = {}, {}
host:maybePrefetchNextChapter("book")
starts[1].options.on_start()
starts[1].options.on_complete(false, "network error")
expect(#notices == 0, "the notification setting silences prefetch failures")

-- Low memory skips the background prefetch; end-of-chapter auto-continue will
-- download the chapter on demand instead, avoiding fork/COW pressure.
cache.show_prefetch_notifications = true
starts = {}
local free_kb = 40 * 1024
host.prefetch_worker = {
    min_available_kb = 32 * 1024,
    availableMemoryKB = function() return free_kb end,
}
expect(host:maybePrefetchNextChapter("book") == false,
    "low memory skips the background prefetch")
expect(#starts == 0, "no prefetch is started when memory is tight")
free_kb = 96 * 1024
expect(host:maybePrefetchNextChapter("book") == true,
    "ample memory resumes prefetching")
expect(#starts == 1, "prefetch starts once memory headroom is restored")
host.prefetch_worker = nil

local legacy_single = {
    cached_file = "/cache/one.epub",
    cached_chapters = { ["1"] = "/cache/one.epub" },
}
expect(host:getFullBookCachePath(legacy_single) == nil,
    "legacy single chapter is not mistaken for a full book")
legacy_single.cached_chapters["2"] = "/cache/one.epub"
expect(host:getFullBookCachePath(legacy_single) == "/cache/one.epub",
    "legacy combined EPUB remains a full-book cache")

notices = {}
expect(not host:onWeReadSyncProgress(),
    "standalone sync gesture rejects a local document")
expect(notices[1] and notices[1][2] == 1,
    "standalone sync gesture explains missing WeRead context")

-- End-of-chapter auto-continue: on by default, no dialog when a next chapter
-- exists; falls back to the dialog when disabled, at the last chapter, or when
-- navigation cannot start.
G_reader_settings = { readSetting = function() return nil end }

local continued, dialogs = {}, 0
host.openChapterForReading = function(_self, target_book, chapter)
    continued[#continued + 1] = { book = target_book, chapter = chapter }
    return true
end
host.showEndOfBookDialog = function() dialogs = dialogs + 1; return true end
host.showInfo = function() end
host.detectWeReadBook = function() return "book" end
host._orig_onEndOfBook = function() return false end
host.ui.document.file = "/cache/one.epub"

cache.auto_next_chapter = true
expect(host:handleEndOfBook(nil) == true, "end of chapter is handled")
expect(#continued == 1 and continued[1].chapter == chapters[2],
    "auto-continue opens the immediate next chapter")
expect(dialogs == 0, "auto-continue does not show the end-of-book dialog")

cache.auto_next_chapter = false
continued, dialogs = {}, 0
host:handleEndOfBook(nil)
expect(#continued == 0 and dialogs == 1,
    "disabling auto-continue restores the end-of-book dialog")

cache.auto_next_chapter = true
continued, dialogs = {}, 0
book.cached_chapters["3"] = "/cache/three.epub"
existing["/cache/three.epub"] = true
host.ui.document.file = "/cache/three.epub"
host:handleEndOfBook(nil)
expect(#continued == 0 and dialogs == 1,
    "the last chapter still shows the end-of-book dialog")

continued, dialogs = {}, 0
host.ui.document.file = "/cache/one.epub"
host.openChapterForReading = function() return false end
host:handleEndOfBook(nil)
expect(dialogs == 1, "a navigation that cannot start falls back to the dialog")

-- Previous chapter: a backward page turn at the very start of a single-chapter
-- file opens the previous chapter and lands at its end.
cache.auto_previous_chapter = true
local prev_book = {
    book_id = "prev-book",
    chapters = chapters,
    cached_chapters = { ["2"] = "/cache/two.epub" },
}
existing["/cache/two.epub"] = true
host.detectWeReadBook = function() return "prev-book" end
host.settings.get = function(_self, key)
    if key == "cache" then return cache end
    if key == "books" then return { ["prev-book"] = prev_book } end
end
host.ensureChaptersLoaded = function() return chapters end
host.ui.document = { file = "/cache/two.epub" }

local opened_prev
host.openChapterForReading = function(_self, _book, chapter)
    opened_prev = chapter
    return true
end

local original_calls = 0
host.ui.rolling = {
    view = { view_mode = "page" },
    current_page = 1,
    onGotoViewRel = function()
        original_calls = original_calls + 1
        return "original"
    end,
}
expect(host:_installPreviousChapterHook(),
    "previous-chapter hook was not installed")
host.ui.rolling.onGotoViewRel(host.ui.rolling, -1)
expect(opened_prev == chapters[1],
    "a backward turn at the start opens the previous chapter")
expect(host._pending_previous_end
    and host._pending_previous_end.chapter_uid == "1",
    "the previous chapter is marked to open at its end")
expect(original_calls == 0,
    "the original page turn must not run when moving to the previous chapter")

opened_prev = nil
host.ui.rolling.current_page = 3
host.ui.rolling.onGotoViewRel(host.ui.rolling, -1)
expect(opened_prev == nil and original_calls == 1,
    "a backward turn mid-document keeps normal paging")

opened_prev = nil
host.ui.rolling.current_page = 1
host.ui.document.file = "/cache/one.epub"
prev_book.cached_chapters["1"] = "/cache/one.epub"
existing["/cache/one.epub"] = true
host.ui.rolling.onGotoViewRel(host.ui.rolling, -1)
expect(opened_prev == nil and original_calls == 2,
    "the first chapter keeps normal paging")

cache.auto_previous_chapter = false
opened_prev = nil
host.ui.document.file = "/cache/two.epub"
host.ui.rolling.onGotoViewRel(host.ui.rolling, -1)
expect(opened_prev == nil and original_calls == 3,
    "disabling auto-previous keeps normal paging")
cache.auto_previous_chapter = true

host:_removePreviousChapterHook()
expect(host.ui.rolling.onGotoViewRel ~= nil,
    "removing the hook restores the original page turn")

-- Landing at the end is scheduled and guarded by book and chapter.
local goto_fraction
host.progress_sync = {
    goto_fraction = function(fraction) goto_fraction = fraction end,
}
scheduled = {}
host._pending_previous_end = { book_id = "prev-book", chapter_uid = "1" }
host.ui.document.file = "/cache/one.epub"
host:_applyPendingPreviousEnd("prev-book")
expect(#scheduled == 1 and scheduled[1].delay == 0.3,
    "landing at the previous chapter end was not scheduled")
scheduled[1].callback()
expect(goto_fraction == 1, "the previous chapter did not open at its end")

host._pending_previous_end = { book_id = "prev-book", chapter_uid = "9" }
scheduled = {}
host:_applyPendingPreviousEnd("prev-book")
expect(#scheduled == 0,
    "a stale previous-chapter marker must not move the document")

-- Start detection covers both scroll and paged readers, and a full-book EPUB
-- never navigates to a previous chapter.
host.ui.rolling = { view = { view_mode = "scroll" }, current_pos = 0 }
expect(host:_isAtDocumentStart(), "scroll offset 0 is the document start")
host.ui.rolling.current_pos = 12
expect(not host:_isAtDocumentStart(), "scroll offset 12 is not the start")
host.ui.rolling = nil
host.ui.paging = { current_page = 1, visible_area = { y = 0 } }
expect(host:_isAtDocumentStart(), "page 1 of a paged document is the start")
host.ui.paging.visible_area.y = 8
expect(not host:_isAtDocumentStart(), "scrolling within page 1 is not the start")
host.ui.paging.visible_area.y = 0
host.ui.paging.current_page = 2
expect(not host:_isAtDocumentStart(), "page 2 is not the start")
host.ui.paging = nil

host.detectWeReadBook = function() return "prev-book" end
host.settings.get = function(_self, key)
    if key == "cache" then return cache end
    if key == "books" then return { ["prev-book"] = prev_book } end
end
host.ui.document = { file = "/cache/full.epub" }
prev_book.cached_full_book = "/cache/full.epub"
existing["/cache/full.epub"] = true
local full_opened
host.openChapterForReading = function(_self, _book, chapter)
    full_opened = chapter
    return true
end
expect(host:openPreviousChapter() == false and full_opened == nil,
    "a full-book EPUB never opens a previous chapter")
prev_book.cached_full_book = nil

-- The explicit next_file end-document action opens the next chapter directly
-- when auto-continue is off.
cache.auto_next_chapter = false
G_reader_settings = {
    readSetting = function(_self, key)
        if key == "end_document_action" then return "next_file" end
    end,
}
host.ui.document = { file = "/cache/two.epub" }
local next_opened
host.openChapterForReading = function(_self, _book, chapter)
    next_opened = chapter
    return true
end
host:handleEndOfBook(nil)
expect(next_opened == chapters[3], "next_file action opens the next chapter")
cache.auto_next_chapter = true
G_reader_settings = { readSetting = function() return nil end }

-- A failed promoted prefetch retries through the foreground reader path.
downloader.isPromotedPrefetch = function() return true end
host.detectWeReadBook = function() return "book" end
host.settings.get = function(_self, key)
    if key == "cache" then return cache end
    if key == "books" then return { book = book } end
end
host.ui.document = { file = "/cache/one.epub" }
local retried
host.openChapterForReading = function(_self, _book, chapter)
    retried = chapter
    return true
end
cache.auto_prefetch_next_chapter = true
book.cached_chapters["2"] = nil
existing["/cache/two.epub"] = nil
scheduled, starts = {}, {}
host:maybePrefetchNextChapter("book")
expect(#starts == 1, "the retry prefetch was not requested")
starts[1].options.on_complete(false, "network error")
expect(#scheduled == 1 and scheduled[1].delay == 0.5,
    "a failed promoted prefetch schedules a foreground retry")
scheduled[1].callback()
expect(retried == chapters[2],
    "the retry opens the next chapter through openChapterForReading")
downloader.isPromotedPrefetch = function() return false end

print(string.format(
    "prefetch_lifecycle_spec: %d checks, %d failure(s)", checks, failures))
os.exit(failures == 0 and 0 or 1)
