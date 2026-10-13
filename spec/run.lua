-- Runs the plugin's real main.lua against stubbed KOReader modules.
-- Usage (from koreader-plugin/): luajit spec/run.lua
package.path = "./?.lua;" .. package.path

local failures, passed = 0, 0
local function check(cond, msg)
    if cond then passed = passed + 1 else failures = failures + 1; print("FAIL: " .. msg) end
end
local function eq(a, b, msg) check(a == b, msg .. " (got " .. tostring(a) .. ", want " .. tostring(b) .. ")") end

-- Minimal JSON encoder (stands in for rapidjson; output is validated by python below).
local function encode(v)
    local t = type(v)
    if t == "nil" then return "null"
    elseif t == "boolean" or t == "number" then return tostring(v)
    elseif t == "string" then
        return '"' .. v:gsub('[%c"\\]', function(c)
            return ({ ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n' })[c] or string.format("\\u%04x", c:byte())
        end) .. '"'
    end
    if #v > 0 or next(v) == nil then
        local out = {}
        for _, x in ipairs(v) do out[#out + 1] = encode(x) end
        return "[" .. table.concat(out, ",") .. "]"
    end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys)
    local out = {}
    for _, k in ipairs(keys) do out[#out + 1] = encode(k) .. ":" .. encode(v[k]) end
    return "{" .. table.concat(out, ",") .. "}"
end

-- ---------------------------------------------------------------- stubs
local shown = {}
local settings_store = {}
local sidecars = {}
local history = {}
local online = true
local http_log = {}
local http_responses = {}

local function stub(name, value) package.preload[name] = function() return value end end
stub("datastorage", { getSettingsDir = function() return "/tmp" end })
stub("dispatcher", { registerAction = function() end })
stub("docsettings", {
    hasSidecarFile = function(_, f) return sidecars[f] ~= nil end,
    open = function(_, f)
        return { readSetting = function(_, k) return sidecars[f][k] end }
    end,
})
local function widget(kind)
    return { new = function(_, o) o = o or {}; o.kind = kind; return o end }
end
stub("ui/widget/infomessage", widget("info"))
stub("ui/widget/inputdialog", widget("input"))
stub("ui/widget/confirmbox", widget("confirm"))
stub("luasettings", {
    open = function()
        return {
            readSetting = function(_, k, d) if settings_store[k] == nil then return d end return settings_store[k] end,
            saveSetting = function(_, k, v) settings_store[k] = v end,
            flush = function() end,
        }
    end,
})
stub("ui/network/manager", {
    isConnected = function() return online end,
    runWhenOnline = function(_, cb) if online then cb() end end,
})
local ticks = {}
local scheduled = {}
stub("ui/uimanager", {
    show = function(_, w) table.insert(shown, w) end,
    close = function() end,
    forceRePaint = function() end,
    nextTick = function(_, f) table.insert(ticks, f) end,
    scheduleIn = function(_, secs, f) table.insert(scheduled, { secs = secs, f = f }) end,
    unschedule = function(_, f)
        for i = #scheduled, 1, -1 do if scheduled[i].f == f then table.remove(scheduled, i) end end
    end,
})
stub("ui/widget/container/widgetcontainer", { extend = function(_, o) return o end })
stub("logger", { info = function() end, warn = function() end, dbg = function() end })
stub("ffi/sha2", { md5 = function(s)
    local h1, h2 = 5381, 7
    for i = 1, #s do h1 = (h1 * 33 + s:byte(i)) % 4294967296; h2 = (h2 * 31 + s:byte(i)) % 4294967296 end
    return string.format("%016x%016x", h1, h2)
end })
stub("rapidjson", {
    encode = encode,
    decode = function(s)
        local n = s:match('"newHighlights":(%d+)')
        local out = { results = n and { newHighlights = tonumber(n) } or nil }
        -- Flat string and number fields, enough for the pairing responses.
        for k, v in s:gmatch('"([%w_]+)":"([^"]*)"') do out[k] = v end
        for k, v in s:gmatch('"([%w_]+)":(%d+)') do if out[k] == nil then out[k] = tonumber(v) end end
        return out
    end,
})
stub("ffi/util", { template = function(s, ...)
    local args = { ... }
    return (s:gsub("%%(%d)", function(i) return tostring(args[tonumber(i)]) end))
end })
stub("gettext", function(s) return s end)
stub("readhistory", { hist = history })
stub("socket", { skip = function(n, ...) return select(n + 1, ...) end })
stub("ltn12", {
    source = { string = function(s) return s end },
    sink = { table = function(t) return t end },
})
stub("socketutil", { set_timeout = function() end, reset_timeout = function() end, LARGE_BLOCK_TIMEOUT = 1, LARGE_TOTAL_TIMEOUT = 1 })
stub("socket.http", { request = function(req)
    table.insert(http_log, req)
    local r = table.remove(http_responses, 1) or { 200, '{"results":{"newHighlights":0}}' }
    if r[1] == nil then return nil, "host not found" end
    table.insert(req.sink, r[2])
    return 1, r[1], {}, "HTTP " .. r[1]
end })

-- KOReader's Provider registry and the Exporter plugin's base class.
local providers = {}
stub("provider", { register = function(_, feature, name, impl) providers[feature .. "/" .. name] = impl; return true end })
local export_requests = {}
stub("base", {
    settings_key = "exporter",
    new = function(self, o)
        o = o or {}
        o.settings = {}
        setmetatable(o, { __index = self })
        return o
    end,
    isEnabled = function(self) return self.settings.enabled and self:isReadyToExport() end,
    toggleEnabled = function(self) if self:isReadyToExport() then self.settings.enabled = not self.settings.enabled end end,
    makeJsonRequest = function(_, url, method, body, headers)
        table.insert(export_requests, { url = url, method = method, body = body, headers = headers })
        return {}
    end,
})

local Screvi = dofile("main.lua")

local function newPlugin(ui)
    local p = setmetatable({ ui = ui }, { __index = Screvi })
    ui.menu = { registerToMainMenu = function() end }
    p:init()
    return p
end

-- ---------------------------------------------------------------- fixtures
local modern = {
    doc_props = { title = "Meditations", authors = "Marcus Aurelius\nGregory Hays", identifiers = "uuid:abc\nISBN: 978-0-8129-6825-6" },
    annotations = {
        { text = "in Book Two", page = "/body/DocFragment[3]", pageno = 12, datetime = "2024-03-01 09:00:00" }, -- page bookmark
        { text = "You could leave life right now.", drawer = "lighten", page = "/body/DocFragment[4]/p[2]", pageno = 20, chapter = "Book Two", datetime = "2024-03-01 09:05:00", note = "  memento mori " },
        { text = "  ", drawer = "lighten", pageno = 21 },
        { text = "The impediment to action advances action.", drawer = "underscore", pageno = 55, datetime = "2024-03-02 10:00:00", note = "" },
    },
}
local legacy = {
    doc_props = { title = "", authors = "" },
    highlight = {
        [7] = { { text = "Old highlight with note", datetime = "2020-01-01 08:00:00", chapter = "One" } },
        [3] = { { text = "Earlier highlight", datetime = "2020-01-01 07:00:00" } },
    },
    bookmarks = {
        { highlighted = true, datetime = "2020-01-01 08:00:00", notes = "Old highlight with note", text = "my thought" },
        { highlighted = true, datetime = "2020-01-01 07:00:00", notes = "Earlier highlight", text = "Page 3 Earlier highlight @ 2020-01-01 07:00:00" },
    },
}
sidecars["/books/Meditations.epub"] = modern
sidecars["/books/Some Legacy Book.pdf"] = legacy
sidecars["/books/Empty.epub"] = { doc_props = { title = "Empty" }, annotations = {} }
history[1] = { file = "/books/Meditations.epub" }
history[2] = { file = "/books/Some Legacy Book.pdf" }
history[3] = { file = "/books/Empty.epub" }
history[4] = { file = "/books/Gone.epub", dim = true }
history[5] = { file = "/books/NeverOpened.epub" }

-- ---------------------------------------------------------------- tests
-- pure helpers
eq(Screvi.parseIsbn("uuid:1\nISBN: 978-0-8129-6825-6"), "9780812968256", "isbn parsed")
eq(Screvi.parseIsbn("calibre:9780812968256"), nil, "unlabelled number not treated as isbn")
eq(Screvi.parseIsbn("urn:isbn:080442957X"), "080442957X", "isbn-10 with X")
local iso = Screvi.toIsoDate("2024-03-01 09:05:00")
check(iso and iso:match("^2024%-0[23]%-%d%dT%d%d:05:00Z$"), "iso date " .. tostring(iso))
eq(Screvi.toIsoDate("garbage"), nil, "bad date -> nil")

-- modern parsing
local book = Screvi.getBookFromSidecar("/books/Meditations.epub")
eq(book.name, "Meditations", "title")
eq(book.author, "Marcus Aurelius, Gregory Hays", "authors joined")
eq(book.isbn, "9780812968256", "isbn on source")
eq(#book.highlights, 2, "bookmark and blank highlight skipped")
eq(book.highlights[1].note, "memento mori", "note trimmed")
eq(book.highlights[1].location, "20", "location from pageno, not xpointer")
eq(book.highlights[1].metadata.chapter, "Book Two", "chapter kept")
eq(book.highlights[2].note, nil, "empty note dropped")

-- legacy parsing
local lb = Screvi.getBookFromSidecar("/books/Some Legacy Book.pdf")
eq(lb.name, "Some Legacy Book", "title from filename")
eq(lb.author, "Unknown Author", "author fallback so server doesn't drop the source")
eq(#lb.highlights, 2, "legacy highlights")
eq(lb.highlights[1].content, "Earlier highlight", "legacy sorted by page")
eq(lb.highlights[1].note, nil, "auto-text bookmark is not a note")
eq(lb.highlights[2].note, "my thought", "legacy note from bookmark")

-- batching
local big = { name = "Big", author = "A", type = "book", highlights = {} }
for i = 1, 1203 do big.highlights[i] = { content = "h" .. i } end
local batches = Screvi.batchSources({ big, { name = "Small", author = "B", highlights = { { content = "x" } } } }, 500)
eq(#batches, 3, "three batches")
eq(#batches[1][1].highlights, 500, "first batch full")
eq(#batches[3], 2, "last batch carries the rest of Big plus Small")
eq(#batches[3][1].highlights + #batches[3][2].highlights, 204, "no highlight lost")

-- sync all (file manager context: no document)
local fm = newPlugin({})
fm.api_key = ""
fm:syncAllBooks()
eq(shown[#shown].text:match("isn.t connected") ~= nil, true, "offers to connect when no key")
fm.api_key = "sk_live_test"
http_responses = { { 200, '{"results":{"newHighlights":4}}' } }
fm:syncAllBooks()
eq(#http_log, 1, "one request")
local req = http_log[1]
eq(req.headers["X-API-Key"], "sk_live_test", "api key header")
eq(req.url, "https://api.screvi.com/api/extension/import", "url")
local f = io.open("/tmp/screvi_payload.json", "w"); f:write(req.source); f:close()
check(shown[#shown].text:find("Added 4 highlights from 2 books"), "success message: " .. shown[#shown].text)
check(settings_store.last_sync ~= nil, "last sync recorded")

-- second run: nothing pending, no request
fm:syncAllBooks()
eq(#http_log, 1, "no request when everything synced")
check(shown[#shown].text:find("already synced"), "already synced message")

-- new highlight in the open book goes out on its own; auto-sync on close
modern.annotations[#modern.annotations + 1] = { text = "New one", drawer = "lighten", pageno = 80 }
local reader = newPlugin({ document = { file = "/books/Meditations.epub" }, doc_props = modern.doc_props, annotation = { annotations = modern.annotations } })
reader.api_key = "sk_live_test"
reader.auto_sync = true
online = false
reader:onCloseDocument()
eq(#ticks, 0, "offline close does nothing (no wifi prompt)")
online = true
reader:onCloseDocument()
eq(#ticks, 1, "online close schedules upload")
ticks[1]()
eq(#http_log, 2, "close uploaded")
check(http_log[2].source:find('"New one"') and not http_log[2].source:find("impediment"), "only the new highlight sent")

-- failures don't mark synced
modern.annotations[#modern.annotations + 1] = { text = "Another", drawer = "lighten", pageno = 81 }
http_responses = { { 401, '{"error":"Invalid API key"}' } }
reader:syncCurrentBook()
check(shown[#shown].text:find("rejected the API key"), "401 message")
http_responses = { { nil } }
reader:syncCurrentBook()
check(shown[#shown].text:find("Couldn't reach Screvi"), "network message: " .. shown[#shown].text)
http_responses = { { 200, '{"results":{"newHighlights":1}}' } }
reader:syncCurrentBook()
check(shown[#shown].text:find("Added 1 highlights from “Meditations”"), "retry succeeds: " .. shown[#shown].text)

-- legacy 0.1 hashes are dropped on init
settings_store.synced_hashes = { ["deadbeef"] = true }
local p2 = newPlugin({})
eq(next(p2.synced_hashes), nil, "old hashes cleared")

-- ---------------------------------------------------------------- pairing
local pp = newPlugin({})
pp.api_key = ""
settings_store.api_key = nil
http_log = {}
local built
pp.buildPairingDialog = function(_, pairing, on_cancel) built = { pairing = pairing, cancel = on_cancel }; return { kind = "pairing" } end

-- syncing without a key offers to connect
pp:syncAllBooks()
eq(shown[#shown].kind, "confirm", "no key offers to connect")

http_responses = { { 201, '{"code":"BCDF-2345","poll_token":"tok","verification_url_complete":"https://app.screvi.com/pair?code=BCDF-2345","interval":5,"expires_in":600}' } }
scheduled = {}
pp:connect()
eq(built.pairing.code, "BCDF-2345", "dialog shows the code")
eq(shown[#shown].kind, "pairing", "pairing dialog shown")
check(http_log[1].url:find("/device%-pairing/start$"), "start url: " .. http_log[1].url)
check(http_log[1].source:find('"client":"koreader"'), "start sends client")
eq(#scheduled, 1, "first poll scheduled")
eq(scheduled[1].secs, 5, "polls at the server's interval")

-- pending keeps polling, a network error too
http_responses = { { 200, '{"status":"pending"}' } }
local next_poll = table.remove(scheduled, 1).f
next_poll()
eq(#scheduled, 1, "pending reschedules")
http_responses = { { nil } }
table.remove(scheduled, 1).f()
eq(#scheduled, 1, "network error reschedules")
check(http_log[#http_log].source:find('"poll_token":"tok"'), "poll sends the token")

-- approval stores the key and stops
http_responses = { { 200, '{"status":"approved","api_key":"sk_live_paired"}' } }
table.remove(scheduled, 1).f()
eq(#scheduled, 0, "stops polling once connected")
eq(pp.api_key, "sk_live_paired", "key kept in memory")
eq(settings_store.api_key, "sk_live_paired", "key saved")
check(shown[#shown].text:find("Connected to Screvi"), "connected message: " .. tostring(shown[#shown].text))

-- denied and expired end the flow without a key
for _, case in ipairs({ { '{"status":"denied"}', "declined" }, { '{"status":"expired"}', "expired" } }) do
    pp.api_key = ""
    settings_store.api_key = nil
    scheduled = {}
    http_responses = { { 201, '{"code":"BCDF-2345","poll_token":"tok","interval":5,"expires_in":600}' }, { 200, case[1] } }
    pp:connect()
    table.remove(scheduled, 1).f()
    eq(#scheduled, 0, case[2] .. " stops polling")
    check(shown[#shown].text:find(case[2]), case[2] .. " message: " .. tostring(shown[#shown].text))
    eq(pp.api_key, "", case[2] .. " leaves no key")
end

-- cancel stops polling
scheduled = {}
http_responses = { { 201, '{"code":"BCDF-2345","poll_token":"tok","interval":5,"expires_in":600}' } }
pp:connect()
built.cancel()
eq(#scheduled, 0, "cancel unschedules the poll")

-- start failures are reported
http_responses = { { 429, '{"error":"Too many pairing attempts."}' } }
pp:connect()
check(shown[#shown].text:find("Too many attempts"), "429 message")
http_responses = { { nil } }
pp:connect()
check(shown[#shown].text:find("Couldn't reach Screvi"), "offline start message")

-- ---------------------------------------------------------------- export highlights target
local target = providers["exporter/screvi"]
check(target ~= nil, "registered with the exporter at load")
eq(target.is_remote, true, "remote target")
settings_store.api_key = nil
eq(target:isReadyToExport(), false, "not ready without a key")
settings_store.api_key = "sk_live_paired"
eq(target:isReadyToExport(), true, "ready with the paired key")
target:getMenuTable().callback()
eq(target:isEnabled(), true, "menu toggles it on")

local booknotes = {
    title = "Meditations", author = "Marcus Aurelius\nGregory Hays",
    { { text = "  You could leave life right now. ", note = " memento ", page = 20, chapter = "Book Two", time = 1709283900 } },
    { { text = "", page = 21, image = { png = "x" } } },
}
export_requests = {}
eq(target:export({ booknotes, { title = "Images only", { { text = "", image = {} } } } }), true, "export succeeds")
eq(#export_requests, 1, "one request")
local req = export_requests[1]
eq(req.headers["X-API-Key"], "sk_live_paired", "uses the paired key")
check(req.url:find("/api/extension/import$"), "import url")
eq(req.body.type, "koreader", "import type")
eq(#req.body.data, 1, "image-only book skipped")
local src = req.body.data[1]
eq(src.author, "Marcus Aurelius, Gregory Hays", "authors joined")
eq(#src.highlights, 1, "image clipping skipped")
eq(src.highlights[1].content, "You could leave life right now.", "text trimmed")
eq(src.highlights[1].note, "memento", "note trimmed")
eq(src.highlights[1].location, "20", "page as location")
eq(src.highlights[1].metadata.chapter, "Book Two", "chapter kept")
eq(src.highlights[1].date, os.date("!%Y-%m-%dT%H:%M:%SZ", 1709283900), "date in UTC")

-- big exports are split into batches of at most 500 highlights
local big = {}
for b = 1, 3 do
    local chapter = {}
    for i = 1, 300 do chapter[i] = { text = "h" .. b .. "-" .. i, page = i } end
    big[b] = { title = "Book " .. b, author = "A", chapter }
end
export_requests = {}
target:export(big)
eq(#export_requests, 3, "300+300 would exceed 500, so one book per request")

settings_store.api_key = nil
eq(target:export({ booknotes }), false, "no key, no export")

print(string.format("%d passed, %d failed", passed, failures))
os.exit(failures == 0 and 0 or 1)
