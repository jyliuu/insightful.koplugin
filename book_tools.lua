local BookTools = {}
BookTools.__index = BookTools

local MAX_RETURNED_HITS = 15
local SEARCH_SCAN_LIMIT = 200
local MAX_SNIPPET_CHARS = 250
local MAX_READ_CHARS = 8000
local MAX_TOC_ENTRIES = 120
local MAX_LINKS = 40
local MAX_LINK_LABEL_CHARS = 200
local MAX_LINK_TARGET_CHARS = 500

local function trim(text)
    return tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function squeeze(text)
    return trim(tostring(text or ""):gsub("%s+", " "))
end

local function utf8Prefix(text, limit)
    text = tostring(text or "")
    if #text <= limit then return text end
    local cut = text:sub(1, math.max(0, limit - 3))
    local i = #cut
    while i > 0 do
        local byte = cut:byte(i)
        if byte < 128 or byte >= 192 then break end
        i = i - 1
    end
    if i > 0 then
        local lead = cut:byte(i)
        local expected = lead < 128 and 1
            or (lead < 224 and 2)
            or (lead < 240 and 3)
            or 4
        if #cut - i + 1 < expected then
            cut = cut:sub(1, i - 1)
        end
    end
    return cut .. "..."
end

local function call(object, method, ...)
    if not object or type(object[method]) ~= "function" then return nil end
    local ok, result = pcall(object[method], object, ...)
    if ok then return result end
    return nil
end

local function pageTextToString(value)
    if type(value) == "string" then return value end
    if type(value) ~= "table" then return "" end
    local words = {}
    local function visit(item)
        if type(item) ~= "table" then return end
        if type(item.word) == "string" then
            table.insert(words, item.word)
            return
        end
        for _, child in ipairs(item) do visit(child) end
    end
    visit(value)
    return table.concat(words, " ")
end

function BookTools:new(context)
    local instance = setmetatable({}, self)
    instance.context = context or {}
    instance.ui = instance.context.ui
    instance.document = instance.context.document or (instance.ui and instance.ui.document)
    instance.last_hits = {}
    instance.last_links = {}
    instance.next_link_id = 0
    return instance
end

function BookTools:isCurrentDocument()
    if not self.document then return false end
    if self.ui and self.ui.document ~= self.document then return false end
    return true
end

function BookTools:totalPages()
    local info = self.document and self.document.info
    local pages = info and tonumber(info.number_of_pages)
    return pages or tonumber(call(self.document, "getPageCount")) or 0
end

function BookTools:currentPage()
    local page = tonumber(call(self.ui, "getCurrentPage"))
    page = page or tonumber(self.ui and self.ui.view and self.ui.view.state and self.ui.view.state.page)
    if not page and self.document then
        local locator = call(self.document, "getXPointer")
        page = locator and tonumber(call(self.document, "getPageFromXPointer", locator))
    end
    local total = self:totalPages()
    if not page then return total > 0 and 1 or nil end
    if total > 0 then page = math.max(1, math.min(page, total)) end
    return page
end

function BookTools:sectionForPage(page)
    local toc = self.ui and self.ui.toc
    if toc and type(toc.fillToc) == "function" then pcall(toc.fillToc, toc) end
    local title = call(toc, "getTocTitleByPage", page)
    return type(title) == "string" and title or nil
end

function BookTools:locatorForPage(page)
    if self.document and self.document.info and not self.document.info.has_pages then
        local xp = call(self.document, "getPageXPointer", page)
        if type(xp) == "string" then return xp end
    end
    return page and tostring(page) or nil
end

function BookTools:currentPosition()
    if not self:isCurrentDocument() then
        return { ok = false, error = "The open document changed." }
    end
    local page = self:currentPage()
    local pages = self:totalPages()
    local locator = call(self.document, "getXPointer") or self:locatorForPage(page)
    local result = {
        ok = true,
        page = page,
        pages = pages > 0 and pages or nil,
        section = page and self:sectionForPage(page) or nil,
        locator = type(locator) == "string" and locator or nil,
    }
    if page and pages > 0 then result.progress = page / pages end
    return result
end

function BookTools:_resultPage(item)
    if self.document and self.document.info and self.document.info.has_pages then
        return tonumber(item.start or item.page)
    end
    return tonumber(item.page) or tonumber(call(self.document, "getPageFromXPointer", item.start))
end

function BookTools:_searchOne(query, query_index, max_returned)
    local ok, raw = pcall(function()
        return self.document:findAllText(query, true, 8, SEARCH_SCAN_LIMIT, false)
    end)
    if not ok then
        return nil, tostring(raw)
    end
    raw = type(raw) == "table" and raw or {}
    local hits = {}
    max_returned = math.max(0, tonumber(max_returned) or MAX_RETURNED_HITS)
    for index, item in ipairs(raw) do
        if #hits >= max_returned then break end
        local page = self:_resultPage(item)
        local locator = type(item.start) == "string" and item.start or self:locatorForPage(page)
        local snippet = table.concat({
            item.prev_text or "",
            item.matched_word_prefix or "",
            item.matched_text or "",
            item.matched_word_suffix or "",
            item.next_text or "",
        }, " ")
        local hit_id = string.format("q%d:h%d", query_index, index)
        local hit = {
            id = hit_id,
            query = query,
            page = page,
            section = page and self:sectionForPage(page) or nil,
            locator = locator,
            snippet = utf8Prefix(squeeze(snippet), MAX_SNIPPET_CHARS),
        }
        self.last_hits[hit_id] = hit
        table.insert(hits, hit)
    end
    return {
        query = query,
        hits = hits,
        total_hits = #raw,
        truncated = #raw >= SEARCH_SCAN_LIMIT or #raw > #hits,
        total_is_lower_bound = #raw >= SEARCH_SCAN_LIMIT,
    }
end

function BookTools:searchBook(args)
    if not self:isCurrentDocument() then
        return { ok = false, error = "The open document changed." }
    end
    if type(self.document.findAllText) ~= "function" then
        return { ok = false, error = "No searchable text is available for this document." }
    end
    args = type(args) == "table" and args or {}
    local queries, seen = {}, {}
    local function add(value)
        value = trim(value)
        local key = value:lower()
        if value ~= "" and not seen[key] then
            seen[key] = true
            table.insert(queries, value)
        end
    end
    if type(args.query) == "string" then add(args.query) end
    if type(args.queries) == "table" then
        for _, query in ipairs(args.queries) do
            if type(query) == "string" then add(query) end
        end
    end
    if #queries == 0 then
        return { ok = false, error = "query or queries is required" }
    end

    self.last_hits = {}
    local blocks, all_hits, total = {}, {}, 0
    local remaining = MAX_RETURNED_HITS
    for index, query in ipairs(queries) do
        local block, err = self:_searchOne(query, index, remaining)
        if not block then
            return { ok = false, error = "Book search failed: " .. tostring(err) }
        end
        table.insert(blocks, block)
        total = total + block.total_hits
        for _, hit in ipairs(block.hits) do
            table.insert(all_hits, hit)
            remaining = remaining - 1
        end
    end
    return {
        ok = true,
        queries = blocks,
        hits = all_hits,
        total_hits = total,
    }
end

function BookTools:_extractRange(start_page, end_page)
    local document = self.document
    if document.info and document.info.has_pages then
        local parts = {}
        for page = start_page, end_page do
            table.insert(parts, pageTextToString(call(document, "getPageText", page)))
        end
        return table.concat(parts, "\n")
    end
    local start_xp = call(document, "getPageXPointer", start_page)
    local total = self:totalPages()
    local end_xp = call(document, "getPageXPointer", math.min(end_page + 1, total))
    if not start_xp or not end_xp then return nil end
    return call(document, "getTextFromXPointers", start_xp, end_xp)
end

function BookTools:readAround(args)
    if not self:isCurrentDocument() then
        return { ok = false, error = "The open document changed." }
    end
    args = type(args) == "table" and args or {}
    local hit = type(args.hit_id) == "string" and self.last_hits[args.hit_id] or nil
    local link = type(args.link_id) == "string" and self.last_links[args.link_id] or nil
    if type(args.link_id) == "string" and not link then
        return { ok = false, error = "Unknown link_id. Call list_links again." }
    end
    if link and link.kind ~= "internal" then
        return { ok = false, error = "External links cannot be read as book locations." }
    end
    local locator = type(args.locator) == "string" and args.locator
        or (link and link.target_locator)
        or (hit and hit.locator)
    local page = tonumber(args.page) or (link and link.target_page) or (hit and hit.page)
    if not page and type(locator) == "string" then
        page = tonumber(call(self.document, "getPageFromXPointer", locator))
    end
    if not page then
        return { ok = false, error = "hit_id, link_id, page, or locator is required" }
    end
    local total = self:totalPages()
    if total <= 0 then
        return { ok = false, error = "No readable text is available for this document." }
    end
    page = math.max(1, math.min(page, total))
    local before = math.max(0, math.min(tonumber(args.before_pages) or 1, 2))
    local after = math.max(0, math.min(tonumber(args.after_pages) or 1, 2))
    local start_page = math.max(1, page - before)
    local end_page = math.min(total, page + after)
    local ok, text = pcall(self._extractRange, self, start_page, end_page)
    if not ok or type(text) ~= "string" or text == "" then
        return { ok = false, error = "No readable text is available near that location." }
    end
    text = utf8Prefix(text, MAX_READ_CHARS)
    return {
        ok = true,
        hit_id = hit and args.hit_id or nil,
        link_id = link and args.link_id or nil,
        section = self:sectionForPage(page),
        page = page,
        page_start = start_page,
        page_end = end_page,
        locator = locator or self:locatorForPage(page),
        chars = #text,
        text = text,
    }
end

function BookTools:_linkLabel(raw)
    for _, key in ipairs({ "text", "title", "label" }) do
        if type(raw[key]) == "string" and trim(raw[key]) ~= "" then
            return utf8Prefix(squeeze(raw[key]), MAX_LINK_LABEL_CHARS)
        end
    end
    if type(raw.a_xpointer) == "string" then
        local text = call(self.document, "getTextFromXPointer", raw.a_xpointer)
        if type(text) == "string" and trim(text) ~= "" then
            return utf8Prefix(squeeze(text), MAX_LINK_LABEL_CHARS)
        end
    end
end

function BookTools:_pageLinks(page, locator, include_external)
    local document = self.document
    if document.info and document.info.has_pages then
        local ok, links = pcall(document.getPageLinks, document, page)
        if not ok then return nil, tostring(links) end
        return type(links) == "table" and links or {}
    end

    local restore_locator = call(document, "getXPointer")
    if type(restore_locator) ~= "string" or type(document.gotoXPointer) ~= "function" then
        return nil, "The rolling document position cannot be restored after inspecting links."
    end
    local ok, links = pcall(function()
        if type(locator) == "string" and locator ~= "" then
            document:gotoXPointer(locator)
        elseif type(document.gotoPage) == "function" then
            document:gotoPage(page)
        else
            error("The requested page cannot be rendered for link inspection.")
        end
        return document:getPageLinks(not include_external)
    end)
    local restored, restore_error = pcall(document.gotoXPointer, document, restore_locator)
    if not restored then
        return nil, "Could not restore the reading position: " .. tostring(restore_error)
    end
    if not ok then return nil, tostring(links) end
    return type(links) == "table" and links or {}
end

function BookTools:listLinks(args)
    if not self:isCurrentDocument() then
        return { ok = false, error = "The open document changed." }
    end
    if type(self.document.getPageLinks) ~= "function" then
        return { ok = false, error = "Hyperlinks are not available for this document." }
    end
    args = type(args) == "table" and args or {}
    local hit = type(args.hit_id) == "string" and self.last_hits[args.hit_id] or nil
    if type(args.hit_id) == "string" and not hit then
        return { ok = false, error = "Unknown hit_id. Call search_book again." }
    end
    local locator = type(args.locator) == "string" and args.locator or (hit and hit.locator)
    local page = tonumber(args.page) or (hit and hit.page)
    if not page and locator then
        page = tonumber(call(self.document, "getPageFromXPointer", locator))
    end
    page = page or self:currentPage()
    if not page then
        return { ok = false, error = "No readable page is available for hyperlink inspection." }
    end
    local total = self:totalPages()
    if total > 0 then page = math.max(1, math.min(page, total)) end
    locator = locator or self:locatorForPage(page)
    local include_external = args.include_external ~= false
    local raw, err = self:_pageLinks(page, locator, include_external)
    if not raw then
        return { ok = false, error = "Hyperlink inspection failed: " .. tostring(err) }
    end

    local links = {}
    local total_links = 0
    for _, item in ipairs(raw) do
        local link
        if self.document.info and self.document.info.has_pages then
            local zero_based_page = tonumber(item.page)
            local uri = type(item.uri) == "string" and trim(item.uri) or ""
            if zero_based_page then
                link = {
                    kind = "internal",
                    target_page = zero_based_page + 1,
                    target_locator = tostring(zero_based_page + 1),
                }
            elseif include_external and uri ~= "" then
                link = {
                    kind = "external",
                    target_uri = utf8Prefix(uri, MAX_LINK_TARGET_CHARS),
                }
            end
        else
            local section = type(item.section) == "string" and trim(item.section) or ""
            local target = section
            if target == "" and type(item.uri) == "string" then target = trim(item.uri) end
            local internal = target ~= "" and (section ~= ""
                or call(self.document, "isXPointerInDocument", target) == true)
            if internal then
                link = {
                    kind = "internal",
                    target_page = tonumber(call(self.document, "getPageFromXPointer", target)),
                    target_locator = target,
                }
            elseif include_external and target ~= "" then
                link = {
                    kind = "external",
                    target_uri = utf8Prefix(target, MAX_LINK_TARGET_CHARS),
                }
            end
        end
        if link then
            total_links = total_links + 1
            if #links < MAX_LINKS then
                self.next_link_id = self.next_link_id + 1
                link.id = "l" .. tostring(self.next_link_id)
                link.source_page = page
                link.source_locator = type(item.a_xpointer) == "string"
                    and utf8Prefix(item.a_xpointer, MAX_LINK_TARGET_CHARS) or locator
                link.label = self:_linkLabel(item)
                self.last_links[link.id] = {
                    kind = link.kind,
                    target_page = link.target_page,
                    target_locator = link.target_locator,
                }
                if link.target_locator then
                    link.target_locator = utf8Prefix(link.target_locator, MAX_LINK_TARGET_CHARS)
                end
                table.insert(links, link)
            end
        end
    end
    return {
        ok = true,
        page = page,
        locator = utf8Prefix(locator, MAX_LINK_TARGET_CHARS),
        links = links,
        total_links = total_links,
        truncated = total_links > #links,
    }
end

function BookTools:toc()
    if not self:isCurrentDocument() then
        return { ok = false, error = "The open document changed." }
    end
    local toc_module = self.ui and self.ui.toc
    if toc_module and type(toc_module.fillToc) == "function" then pcall(toc_module.fillToc, toc_module) end
    local raw = toc_module and toc_module.toc
    if type(raw) ~= "table" then raw = call(self.document, "getToc") end
    if type(raw) ~= "table" then
        return { ok = false, error = "No table of contents is available for this document." }
    end
    local entries = {}
    for _, entry in ipairs(raw) do
        if #entries >= MAX_TOC_ENTRIES then break end
        local page = tonumber(entry.page)
        table.insert(entries, {
            title = tostring(entry.title or ""),
            depth = tonumber(entry.depth) or 1,
            page = page,
            locator = type(entry.xpointer) == "string" and entry.xpointer or self:locatorForPage(page),
        })
    end
    return {
        ok = true,
        entries = entries,
        total_entries = #raw,
        truncated = #raw > MAX_TOC_ENTRIES,
    }
end

function BookTools:execute(name, args)
    if name == "search_book" then return self:searchBook(args) end
    if name == "read_around" then return self:readAround(args) end
    if name == "list_links" then return self:listLinks(args) end
    if name == "toc" then return self:toc(args) end
    if name == "current_position" then return self:currentPosition(args) end
    return { ok = false, error = "Unknown book tool: " .. tostring(name) }
end

BookTools.limits = {
    returned_hits = MAX_RETURNED_HITS,
    search_scan = SEARCH_SCAN_LIMIT,
    snippet_chars = MAX_SNIPPET_CHARS,
    read_chars = MAX_READ_CHARS,
    toc_entries = MAX_TOC_ENTRIES,
    links = MAX_LINKS,
    link_label_chars = MAX_LINK_LABEL_CHARS,
    link_target_chars = MAX_LINK_TARGET_CHARS,
}

return BookTools
