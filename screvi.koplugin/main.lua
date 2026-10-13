local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local DocSettings = require("docsettings")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local ConfirmBox = require("ui/widget/confirmbox")
local LuaSettings = require("luasettings")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local md5 = require("ffi/sha2").md5
local rapidjson = require("rapidjson")
local T = require("ffi/util").template
local _ = require("gettext")

local Screvi = WidgetContainer:extend{
    name = "screvi",
    is_doc_only = false,
}

local API_URL = "https://api.screvi.com/api/extension/import"
local PAIRING_URL = "https://api.screvi.com/api/device-pairing"
local USER_AGENT = "screvi-koreader/1.1"
local SETTINGS_FILE = "screvi_settings.lua"
local IMPORT_TYPE = "koreader"
-- The server skips sources without an author, so never send an empty one.
local UNKNOWN_AUTHOR = "Unknown Author"
-- Keep each request well under the server's body limit and timeout.
local MAX_HIGHLIGHTS_PER_REQUEST = 500

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function Screvi:init()
    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/" .. SETTINGS_FILE)
    self.api_key = self.settings:readSetting("api_key", "")
    self.auto_sync = self.settings:readSetting("auto_sync", false)
    self.synced_hashes = self.settings:readSetting("synced_hashes", {})
    -- Drop hashes from 0.1 (8-char djb2); they never match the md5 ones.
    for hash in pairs(self.synced_hashes) do
        if #hash ~= 32 then self.synced_hashes[hash] = nil end
    end
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function Screvi:onDispatcherRegisterActions()
    Dispatcher:registerAction("screvi_sync", {
        category = "none",
        event = "ScreviSync",
        title = _("Screvi: sync current book"),
        reader = true,
    })
    Dispatcher:registerAction("screvi_sync_all", {
        category = "none",
        event = "ScreviSyncAll",
        title = _("Screvi: sync all books"),
        general = true,
    })
end

function Screvi:onScreviSync()
    self:syncCurrentBook()
    return true
end

function Screvi:onScreviSyncAll()
    self:syncAllBooks()
    return true
end

function Screvi:onCloseDocument()
    if not self.auto_sync or not self:hasApiKey() then return end
    -- Never prompt for Wi-Fi when leaving a book: if we're offline, the
    -- highlights stay unsynced and go out with the next sync.
    if not NetworkMgr:isConnected() then return end
    local ok, book = pcall(self.getCurrentBook, self)
    if not ok then
        logger.warn("Screvi: could not read highlights on close:", book)
        return
    end
    if not book then return end
    local sources = self:pendingSources({ book })
    if #sources == 0 then return end
    -- The document is being torn down; send once the close has finished.
    UIManager:nextTick(function()
        local sent_ok, err = pcall(self.upload, self, sources, true)
        if not sent_ok then logger.warn("Screvi: auto-sync failed:", err) end
    end)
end

-- ---------------------------------------------------------------------------
-- Menu
-- ---------------------------------------------------------------------------

function Screvi:addToMainMenu(menu_items)
    menu_items.screvi = {
        text = _("Screvi"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Sync current book"),
                enabled_func = function() return self.ui.document ~= nil end,
                keep_menu_open = true,
                callback = function() self:syncCurrentBook() end,
            },
            {
                text = _("Sync all books"),
                keep_menu_open = true,
                callback = function() self:syncAllBooks() end,
            },
            {
                text = _("Auto-sync when closing a book"),
                help_text = _("Sends new highlights when you close a book, if Wi-Fi is already on."),
                checked_func = function() return self.auto_sync end,
                callback = function()
                    self.auto_sync = not self.auto_sync
                    self.settings:saveSetting("auto_sync", self.auto_sync)
                    self.settings:flush()
                end,
                separator = true,
            },
            {
                text_func = function()
                    return self:hasApiKey() and _("Connected to Screvi (reconnect)") or _("Connect to Screvi")
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    self:connect(touchmenu_instance)
                end,
            },
            {
                text_func = function()
                    return self:hasApiKey() and _("API key (set)") or _("API key (not set)")
                end,
                help_text = _("Paste a key by hand instead of connecting with a code."),
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    self:showApiKeyDialog(touchmenu_instance)
                end,
            },
            {
                text = _("Re-send all highlights"),
                help_text = _("Forget which highlights were already sent. Screvi skips ones it already has, so this only fills gaps."),
                keep_menu_open = true,
                callback = function()
                    UIManager:show(ConfirmBox:new{
                        text = _("Forget sync history? The next sync will send every highlight again. Screvi skips the ones it already has."),
                        ok_text = _("Forget"),
                        ok_callback = function()
                            self.synced_hashes = {}
                            self.settings:saveSetting("synced_hashes", self.synced_hashes)
                            self.settings:flush()
                        end,
                    })
                end,
            },
            {
                text_func = function()
                    local last = self.settings:readSetting("last_sync")
                    return last and T(_("Last sync: %1"), last) or _("Never synced")
                end,
                enabled_func = function() return false end,
            },
            {
                text = _("About"),
                keep_menu_open = true,
                callback = function()
                    UIManager:show(InfoMessage:new{
                        text = _("Screvi syncs your KOReader highlights and notes to screvi.com.\n\nUse \"Connect to Screvi\" to link this device with a short code, no typing needed."),
                    })
                end,
            },
        },
    }
end

-- ---------------------------------------------------------------------------
-- API key dialog
-- ---------------------------------------------------------------------------

function Screvi:hasApiKey()
    return self.api_key ~= nil and self.api_key ~= ""
end

function Screvi:showApiKeyDialog(touchmenu_instance)
    local dialog
    dialog = InputDialog:new{
        title = _("Screvi API key"),
        input = self.api_key,
        input_hint = "sk_live_…",
        description = _("Create one with write access at app.screvi.com → Settings → API."),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local key = (dialog:getInputText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
                        UIManager:close(dialog)
                        if key == self.api_key then return end
                        self.api_key = key
                        self.settings:saveSetting("api_key", key)
                        self.settings:flush()
                        if touchmenu_instance then touchmenu_instance:updateItems() end
                        UIManager:show(InfoMessage:new{
                            text = key ~= "" and _("API key saved.") or _("API key removed."),
                            timeout = 2,
                        })
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- ---------------------------------------------------------------------------
-- Pairing: connect with a short code instead of typing a key
-- ---------------------------------------------------------------------------

--- POST a JSON body. Returns the HTTP status (nil when unreachable) and the decoded body.
function Screvi:postJson(url, body)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local socket = require("socket")
    local socketutil = require("socketutil")

    local payload = rapidjson.encode(body)
    local sink = {}
    socketutil:set_timeout(10, 15)
    local code = socket.skip(1, http.request{
        url = url,
        method = "POST",
        headers = {
            ["Content-Type"] = "application/json",
            ["Content-Length"] = tostring(#payload),
            ["User-Agent"] = USER_AGENT,
        },
        source = ltn12.source.string(payload),
        sink = ltn12.sink.table(sink),
    })
    socketutil:reset_timeout()

    local text = table.concat(sink)
    local ok, decoded = pcall(rapidjson.decode, text)
    return type(code) == "number" and code or nil, ok and type(decoded) == "table" and decoded or {}
end

--- What the approval page shows as this device, e.g. "Kindle Paperwhite".
function Screvi.deviceName()
    local ok, Device = pcall(require, "device")
    if ok and type(Device) == "table" and type(Device.model) == "string" and Device.model ~= "" then
        return Device.model
    end
    return nil
end

--- Ask the server for a code. Returns the pairing, or nil and an error message.
function Screvi:startPairing()
    local code, body = self:postJson(PAIRING_URL .. "/start", {
        client = "koreader",
        device_name = Screvi.deviceName(),
    })
    if code == 201 and type(body.code) == "string" and type(body.poll_token) == "string" then
        return body
    end
    logger.warn("Screvi: pairing start failed", code, body.error)
    if not code then
        return nil, _("Couldn't reach Screvi. Check your connection and try again.")
    elseif code == 429 then
        return nil, _("Too many attempts. Wait a few minutes and try again.")
    end
    return nil, T(_("Couldn't start connecting (HTTP %1)."), code)
end

--- One poll. Returns "pending", "connected", "expired", "denied" or "error" (keep trying).
function Screvi:pollPairing(pairing)
    local code, body = self:postJson(PAIRING_URL .. "/poll", { poll_token = pairing.poll_token })
    if code ~= 200 then return "error" end
    if body.status == "approved" and type(body.api_key) == "string" and body.api_key ~= "" then
        self.api_key = body.api_key
        self.settings:saveSetting("api_key", body.api_key)
        self.settings:flush()
        return "connected"
    end
    if body.status == "expired" or body.status == "denied" or body.status == "pending" then
        return body.status
    end
    return "error"
end

--- The dialog: code, where to enter it, a QR code that goes straight there, and Cancel.
function Screvi:buildPairingDialog(pairing, on_cancel)
    local Blitbuffer = require("ffi/blitbuffer")
    local Button = require("ui/widget/button")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local Device = require("device")
    local Font = require("ui/font")
    local FrameContainer = require("ui/widget/container/framecontainer")
    local InputContainer = require("ui/widget/container/inputcontainer")
    local QRWidget = require("ui/widget/qrwidget")
    local Size = require("ui/size")
    local TextBoxWidget = require("ui/widget/textboxwidget")
    local TextWidget = require("ui/widget/textwidget")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    local Screen = Device.screen

    local width = math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.85)
    local inner = width - 2 * Size.padding.large
    local qr_size = math.floor(inner * 0.6)
    local gap = VerticalSpan:new{ width = Size.span.vertical_large * 2 }

    local dialog = InputContainer:new{ modal = true }
    local content = VerticalGroup:new{
        align = "center",
        TextWidget:new{ text = _("Connect to Screvi"), face = Font:getFace("tfont") },
        gap,
        TextBoxWidget:new{
            text = _("On your phone or computer, open"),
            face = Font:getFace("cfont", 18), width = inner, alignment = "center",
        },
        TextWidget:new{ text = "app.screvi.com/pair", face = Font:getFace("cfont", 20), bold = true },
        TextBoxWidget:new{
            text = _("and enter this code:"),
            face = Font:getFace("cfont", 18), width = inner, alignment = "center",
        },
        gap,
        TextWidget:new{ text = pairing.code, face = Font:getFace("scfont", 36), bold = true },
        gap,
        QRWidget:new{
            text = pairing.verification_url_complete or ("https://app.screvi.com/pair?code=" .. pairing.code),
            width = qr_size, height = qr_size,
        },
        TextBoxWidget:new{
            text = _("Or scan this with your phone."),
            face = Font:getFace("cfont", 16), width = inner, alignment = "center",
        },
        gap,
        TextBoxWidget:new{
            text = _("Waiting for you to approve… The code works for 10 minutes."),
            face = Font:getFace("cfont", 16), width = inner, alignment = "center",
        },
        gap,
        Button:new{
            text = _("Cancel"),
            width = math.floor(inner * 0.5),
            callback = function()
                UIManager:close(dialog)
                on_cancel()
            end,
        },
    }
    dialog[1] = CenterContainer:new{
        dimen = Screen:getSize(),
        FrameContainer:new{
            background = Blitbuffer.COLOR_WHITE,
            radius = Size.radius.window,
            bordersize = Size.border.window,
            padding = Size.padding.large,
            width = width,
            content,
        },
    }
    function dialog:onShow()
        UIManager:setDirty(self, "full")
        return true
    end
    return dialog
end

--- Show a code, poll until it's approved, then keep the key. The person never types it.
function Screvi:connect(touchmenu_instance)
    NetworkMgr:runWhenOnline(function()
        local pairing, err = self:startPairing()
        if not pairing then
            UIManager:show(InfoMessage:new{ text = err })
            return
        end

        local interval = tonumber(pairing.interval) or 5
        local deadline = os.time() + (tonumber(pairing.expires_in) or 600)
        local active = true
        local dialog

        local function finish(msg, timeout)
            active = false
            if dialog then UIManager:close(dialog) end
            if touchmenu_instance then touchmenu_instance:updateItems() end
            UIManager:show(InfoMessage:new{ text = msg, timeout = timeout })
        end

        local poll
        poll = function()
            if not active then return end
            if os.time() >= deadline then
                return finish(_("The code expired. Choose \"Connect to Screvi\" to get a new one."))
            end
            local status = self:pollPairing(pairing)
            if status == "connected" then
                return finish(_("Connected to Screvi. Your highlights can now sync."), 4)
            elseif status == "denied" then
                return finish(_("The connection was declined on Screvi."))
            elseif status == "expired" then
                return finish(_("The code expired. Choose \"Connect to Screvi\" to get a new one."))
            end
            -- "pending", or a network hiccup: try again on the next tick.
            UIManager:scheduleIn(interval, poll)
        end

        dialog = self:buildPairingDialog(pairing, function()
            active = false
            UIManager:unschedule(poll)
        end)
        UIManager:show(dialog)
        UIManager:scheduleIn(interval, poll)
    end)
end

-- ---------------------------------------------------------------------------
-- Highlight extraction
-- ---------------------------------------------------------------------------

local function isEmpty(s)
    return s == nil or s == ""
end

local function trim(s)
    if type(s) ~= "string" then return nil end
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" then return nil end
    return s
end

--- KOReader stores local "YYYY-MM-DD HH:MM:SS"; Screvi wants UTC ISO 8601.
function Screvi.toIsoDate(datetime)
    if type(datetime) ~= "string" then return nil end
    local y, mo, d, h, mi, s = datetime:match("^(%d+)%-(%d+)%-(%d+)[ T](%d+):(%d+):(%d+)")
    if not y then return nil end
    local ts = os.time{
        year = tonumber(y), month = tonumber(mo), day = tonumber(d),
        hour = tonumber(h), min = tonumber(mi), sec = tonumber(s),
        isdst = -1,
    }
    if not ts then return nil end
    return os.date("!%Y-%m-%dT%H:%M:%SZ", ts)
end

--- Only an explicitly labelled ISBN: a wrong one would merge the wrong book.
function Screvi.parseIsbn(identifiers)
    if type(identifiers) ~= "string" then return nil end
    for line in identifiers:gmatch("[^\n]+") do
        local lower = line:lower()
        if lower:find("isbn", 1, true) then
            local digits = lower:gsub("[^%dx]", "")
            if #digits == 13 or #digits == 10 then
                return digits:upper()
            end
        end
    end
    return nil
end

function Screvi.bookFromProps(props, file)
    props = props or {}
    local title = trim(props.display_title) or trim(props.title)
    if not title and file then
        title = file:match("([^/]+)$"):gsub("%.[^.]+$", "")
    end
    local author = props.authors or props.author
    if type(author) == "string" then
        -- Multiple authors are newline-separated.
        author = trim(author:gsub("%s*\n%s*", ", "))
    else
        author = nil
    end
    return {
        name = title or _("Unknown"),
        author = author or UNKNOWN_AUTHOR,
        type = "book",
        isbn = Screvi.parseIsbn(props.identifiers),
        highlights = {},
    }
end

local function makeHighlight(text, note, datetime, pageno, chapter)
    local location = tonumber(pageno)
    chapter = trim(chapter)
    return {
        content = text,
        note = trim(note),
        date = Screvi.toIsoDate(datetime),
        location = location and tostring(location) or nil,
        -- An empty table would encode as [], so leave it out entirely.
        metadata = (location or chapter) and { page = location, chapter = chapter } or nil,
    }
end

--- Modern format (KOReader 2024.05+). Page bookmarks have no drawer and an
--- auto-generated text ("in <chapter>"), so they are not highlights.
function Screvi.parseAnnotations(annotations)
    local highlights = {}
    for _, item in ipairs(annotations or {}) do
        local text = trim(item.text)
        if item.drawer and text then
            local pageno = item.pageno or (type(item.page) == "number" and item.page) or nil
            table.insert(highlights, makeHighlight(text, item.note, item.datetime, pageno, item.chapter))
        end
    end
    return highlights
end

--- Legacy format: highlights keyed by page; notes live on the bookmark with
--- the same datetime, unless it is just the auto-text "Page N <quote> @ <date>".
function Screvi.parseLegacy(highlight_table, bookmarks)
    local notes = {}
    for _, bm in ipairs(bookmarks or {}) do
        if bm.datetime and bm.highlighted and not isEmpty(bm.text) then
            local is_auto = bm.text:match("^Page %S+ .* @ %d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d$")
            if not is_auto and bm.text ~= bm.notes then
                notes[bm.datetime] = bm.text
            end
        end
    end
    local highlights = {}
    local pages = {}
    for page in pairs(highlight_table or {}) do table.insert(pages, page) end
    table.sort(pages, function(a, b) return (tonumber(a) or 0) < (tonumber(b) or 0) end)
    for _, page in ipairs(pages) do
        for _, item in ipairs(highlight_table[page]) do
            local text = trim(item.text)
            if text then
                table.insert(highlights, makeHighlight(text, notes[item.datetime], item.datetime, page, item.chapter))
            end
        end
    end
    return highlights
end

--- The open book, read from memory so unsaved highlights are included.
function Screvi:getCurrentBook()
    if not self.ui or not self.ui.document then return nil end
    local file = self.ui.document.file
    local book = Screvi.bookFromProps(self.ui.doc_props, file)
    if self.ui.annotation and self.ui.annotation.annotations then
        book.highlights = Screvi.parseAnnotations(self.ui.annotation.annotations)
    end
    return book
end

--- A book on disk, read from its sidecar.
function Screvi.getBookFromSidecar(file)
    local doc_settings = DocSettings:open(file)
    local book = Screvi.bookFromProps(doc_settings:readSetting("doc_props"), file)
    local annotations = doc_settings:readSetting("annotations")
    if annotations then
        book.highlights = Screvi.parseAnnotations(annotations)
    else
        book.highlights = Screvi.parseLegacy(
            doc_settings:readSetting("highlight"),
            doc_settings:readSetting("bookmarks"))
    end
    return book
end

--- Every book in reading history that has a sidecar.
function Screvi:getAllBooks()
    local current_file = self.ui.document and self.ui.document.file
    local books = {}
    for _, item in ipairs(require("readhistory").hist) do
        local file = item.file
        if file == current_file then
            local book = self:getCurrentBook()
            if book then table.insert(books, book) end
        elseif not item.dim and DocSettings:hasSidecarFile(file) then
            local ok, book = pcall(Screvi.getBookFromSidecar, file)
            if ok then
                table.insert(books, book)
            else
                logger.warn("Screvi: skipping", file, book)
            end
        end
    end
    return books
end

-- ---------------------------------------------------------------------------
-- Sync bookkeeping
-- ---------------------------------------------------------------------------

function Screvi.highlightHash(book, highlight)
    return md5(book.name .. "\0" .. highlight.content .. "\0" .. (highlight.note or ""))
end

--- Copies of the books holding only highlights not yet sent.
function Screvi:pendingSources(books)
    local sources = {}
    for _, book in ipairs(books) do
        local pending = {}
        for _, h in ipairs(book.highlights) do
            if not self.synced_hashes[Screvi.highlightHash(book, h)] then
                table.insert(pending, h)
            end
        end
        if #pending > 0 then
            local source = {}
            for k, v in pairs(book) do source[k] = v end
            source.highlights = pending
            table.insert(sources, source)
        end
    end
    return sources
end

function Screvi:markSynced(sources)
    for _, source in ipairs(sources) do
        for _, h in ipairs(source.highlights) do
            self.synced_hashes[Screvi.highlightHash(source, h)] = true
        end
    end
    self.settings:saveSetting("synced_hashes", self.synced_hashes)
    self.settings:saveSetting("last_sync", os.date("%Y-%m-%d %H:%M"))
    self.settings:flush()
end

--- Split sources into requests of at most MAX_HIGHLIGHTS_PER_REQUEST highlights.
--- A huge single book is split across requests too.
function Screvi.batchSources(sources, limit)
    limit = limit or MAX_HIGHLIGHTS_PER_REQUEST
    local batches, current, count = {}, {}, 0
    local function flush()
        if #current > 0 then table.insert(batches, current) end
        current, count = {}, 0
    end
    for _, source in ipairs(sources) do
        local i = 1
        while i <= #source.highlights do
            if count >= limit then flush() end
            local take = math.min(limit - count, #source.highlights - i + 1)
            local part = {}
            for k, v in pairs(source) do part[k] = v end
            part.highlights = { unpack(source.highlights, i, i + take - 1) }
            table.insert(current, part)
            count = count + take
            i = i + take
        end
    end
    flush()
    return batches
end

-- ---------------------------------------------------------------------------
-- Sync entry points
-- ---------------------------------------------------------------------------

function Screvi:requireApiKey()
    if self:hasApiKey() then return true end
    UIManager:show(ConfirmBox:new{
        text = _("This device isn't connected to Screvi yet. Connect it now? You'll get a short code to enter on your phone or computer."),
        ok_text = _("Connect"),
        ok_callback = function() self:connect() end,
    })
    return false
end

function Screvi:syncCurrentBook()
    if not self:requireApiKey() then return end
    local book = self:getCurrentBook()
    if not book then
        UIManager:show(InfoMessage:new{ text = _("No book is open."), timeout = 2 })
        return
    end
    if #book.highlights == 0 then
        UIManager:show(InfoMessage:new{ text = _("This book has no highlights."), timeout = 2 })
        return
    end
    local sources = self:pendingSources({ book })
    if #sources == 0 then
        UIManager:show(InfoMessage:new{ text = _("All highlights are already synced."), timeout = 2 })
        return
    end
    NetworkMgr:runWhenOnline(function() self:upload(sources, false) end)
end

function Screvi:syncAllBooks()
    if not self:requireApiKey() then return end
    local scanning = InfoMessage:new{ text = _("Looking for highlights…") }
    UIManager:show(scanning)
    UIManager:forceRePaint()
    local books = self:getAllBooks()
    UIManager:close(scanning)

    local sources = self:pendingSources(books)
    if #sources == 0 then
        local any = false
        for _, b in ipairs(books) do
            if #b.highlights > 0 then any = true break end
        end
        UIManager:show(InfoMessage:new{
            text = any and _("All highlights are already synced.") or _("No highlights found."),
            timeout = 2,
        })
        return
    end
    NetworkMgr:runWhenOnline(function() self:upload(sources, false) end)
end

-- ---------------------------------------------------------------------------
-- HTTP
-- ---------------------------------------------------------------------------

--- POST one batch. Returns the decoded body on success, or nil and an error message.
function Screvi:post(sources)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local socket = require("socket")
    local socketutil = require("socketutil")

    local payload = rapidjson.encode({ type = IMPORT_TYPE, data = sources })
    local sink = {}
    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local code, _headers, status = socket.skip(1, http.request{
        url = API_URL,
        method = "POST",
        headers = {
            ["Content-Type"] = "application/json",
            ["Content-Length"] = tostring(#payload),
            ["X-API-Key"] = self.api_key,
            ["User-Agent"] = USER_AGENT,
        },
        source = ltn12.source.string(payload),
        sink = ltn12.sink.table(sink),
    })
    socketutil:reset_timeout()

    local body = table.concat(sink)
    local decoded = body ~= "" and rapidjson.decode(body) or nil
    if code == 200 then
        return decoded or {}
    end

    logger.warn("Screvi: import failed", code, status, body)
    local server_msg = type(decoded) == "table" and decoded.error or nil
    if type(code) ~= "number" then
        return nil, _("Couldn't reach Screvi. Check your connection and try again.")
    elseif code == 401 then
        return nil, _("Screvi rejected the API key. Check it in Screvi → API key.")
    elseif code == 403 then
        return nil, server_msg or _("This API key isn't allowed to import highlights.")
    elseif code == 413 then
        return nil, _("Too many highlights in one go. Try syncing a single book.")
    elseif code == 429 then
        return nil, _("Too many requests. Wait a minute and try again.")
    end
    return nil, T(_("Sync failed (HTTP %1)."), code) .. (server_msg and ("\n" .. server_msg) or "")
end

function Screvi:upload(sources, silent)
    local batches = Screvi.batchSources(sources)
    local sent, added, failed = 0, 0, nil
    for _, batch in ipairs(batches) do
        local result, err = self:post(batch)
        if not result then
            failed = err
            break
        end
        self:markSynced(batch)
        for _, s in ipairs(batch) do sent = sent + #s.highlights end
        local stats = type(result.results) == "table" and result.results or {}
        added = added + (tonumber(stats.newHighlights) or 0)
    end

    logger.info("Screvi: sent", sent, "highlights,", added, "new")
    if silent then return end

    local msg
    if sent == 0 then
        msg = failed
    else
        local book_count = #sources
        if added == 0 then
            msg = _("Screvi already had these highlights.")
        elseif book_count == 1 then
            msg = T(_("Added %1 highlights from “%2” to Screvi."), added, sources[1].name)
        else
            msg = T(_("Added %1 highlights from %2 books to Screvi."), added, book_count)
        end
        if failed then
            msg = msg .. "\n\n" .. _("Some highlights weren't sent:") .. "\n" .. failed
        end
    end
    UIManager:show(InfoMessage:new{ text = msg, timeout = failed and nil or 3 })
end

return Screvi
