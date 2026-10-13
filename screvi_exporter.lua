--[[--
Screvi as a target in KOReader's built-in "Export highlights" menu.

Registered through KOReader's Provider API, so it appears next to the
built-in targets. It uses the key this plugin already has (Tools → Screvi →
Connect to Screvi), so there is nothing to set up twice.

@module screvi_exporter
]]

local _ = require("gettext")

local MAX_HIGHLIGHTS_PER_REQUEST = 500

local function trim(s)
    if type(s) ~= "string" then return nil end
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    return s ~= "" and s or nil
end

--- One exporter booknotes table in the shape Screvi's import API expects,
--- or nil when it has no text highlights (image-only clippings are skipped).
local function createSource(booknotes)
    local author = trim(booknotes.author)
    local source = {
        name = trim(booknotes.title) or _("Unknown"),
        -- Multiple authors are newline-separated; Screvi needs an author to import a book.
        author = author and author:gsub("%s*\n%s*", ", ") or "Unknown Author",
        type = "book",
        highlights = {},
    }
    for _, chapter in ipairs(booknotes) do
        for _, clipping in ipairs(chapter) do
            local text = trim(clipping.text)
            if text then
                local page = tonumber(clipping.page)
                local chapter_title = trim(clipping.chapter)
                table.insert(source.highlights, {
                    content = text,
                    note = trim(clipping.note),
                    date = clipping.time and os.date("!%Y-%m-%dT%H:%M:%SZ", clipping.time) or nil,
                    location = page and tostring(page) or nil,
                    metadata = (page or chapter_title) and { page = page, chapter = chapter_title } or nil,
                })
            end
        end
    end
    return #source.highlights > 0 and source or nil
end

--- Builds the target on top of the exporter's own base class.
--- @param Base the exporter plugin's BaseExporter
--- @param plugin table with getApiKey(), connect() and API_URL
local function build(Base, plugin)
    local Target = Base:new{
        name = "screvi",
        label = "Screvi",
        is_remote = true,
    }

    function Target:isReadyToExport()
        return plugin.getApiKey() ~= nil
    end

    function Target:getMenuTable()
        return {
            text = _("Screvi"),
            help_text = _("Uses the connection from Tools → Screvi."),
            checked_func = function() return self:isEnabled() end,
            callback = function()
                if self:isReadyToExport() then
                    self:toggleEnabled()
                else
                    plugin.connect()
                end
            end,
        }
    end

    function Target:sendSources(sources)
        local result = self:makeJsonRequest(plugin.API_URL, "POST",
            { type = "koreader", data = sources },
            { ["X-API-Key"] = plugin.getApiKey() })
        return result ~= nil
    end

    function Target:export(t)
        if not self:isReadyToExport() then return false end
        -- Batch books so a large library stays well under the server's request limits.
        local batch, count = {}, 0
        for _, booknotes in ipairs(t) do
            local source = createSource(booknotes)
            if source then
                if count > 0 and count + #source.highlights > MAX_HIGHLIGHTS_PER_REQUEST then
                    if not self:sendSources(batch) then return false end
                    batch, count = {}, 0
                end
                table.insert(batch, source)
                count = count + #source.highlights
            end
        end
        if #batch > 0 then return self:sendSources(batch) end
        return true
    end

    return Target
end

return {
    build = build,
    createSource = createSource,
}
