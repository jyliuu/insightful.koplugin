local Renderer = {}

local function escapeHtml(text)
    return tostring(text or "")
        :gsub("&", "&amp;")
        :gsub("<", "&lt;")
        :gsub(">", "&gt;")
        :gsub('"', "&quot;")
        :gsub("'", "&#39;")
end

local function plainText(text)
    return escapeHtml(text):gsub("\n", "<br/>")
end

local function renderTables(html)
    return (html:gsub("<p>([%s%S]-)</p>", function(block)
        if not block:match("^%s*|") then return nil end
        local rows = {}
        for line in block:gmatch("[^\r\n]+") do
            local row = line:match("^%s*(.-)%s*$")
            if row ~= "" then table.insert(rows, row) end
        end
        if #rows < 3 or not rows[2]:match("^|?[%s%-:|]+|$") then return nil end
        local output = { "<table>" }
        for index, row in ipairs(rows) do
            if index ~= 2 then
                local tag = index == 1 and "th" or "td"
                local inner = row:match("^|?(.+)|?$") or ""
                table.insert(output, "<tr>")
                for cell in (inner .. "|"):gmatch("(.-)|") do
                    local value = cell:match("^%s*(.-)%s*$")
                    if value ~= "" then
                        table.insert(output, string.format("<%s>%s</%s>", tag, value, tag))
                    end
                end
                table.insert(output, "</tr>")
            end
        end
        table.insert(output, "</table>")
        return table.concat(output)
    end))
end

local function defaultMarkdown(text)
    local ok_module, markdown = pcall(require, "apps/filemanager/lib/md")
    local metatable = ok_module and getmetatable(markdown)
    local callable = type(markdown) == "function"
        or (type(metatable) == "table" and type(metatable.__call) == "function")
    if callable then
        local ok_render, html = pcall(markdown, tostring(text or ""))
        if ok_render and type(html) == "string" then return renderTables(html) end
    end
    return "<p>" .. plainText(text) .. "</p>"
end

local function selectionHtml(selection)
    if type(selection) ~= "table" or not selection.text or selection.text == "" then return "" end
    local location = selection.section or selection.page or selection.locator
    local label = "Selected passage"
    if location then label = label .. " — " .. tostring(location) end
    return table.concat({
        '<div class="selection-label">', escapeHtml(label), "</div>",
        '<div class="selection-text">', plainText(selection.text), "</div>",
    })
end

local function userMessage(message)
    local content = message.content or ""
    return table.concat({
        '<div class="user-message">',
        '<div class="role-label">YOU</div>',
        selectionHtml(message.selection),
        '<div class="user-text">', plainText(content), "</div>",
        "</div>",
        '<hr class="message-separator"/>',
    })
end

local function assistantLabel(model)
    model = tostring(model or "")
    if model == "" then return "AI" end
    return "AI — " .. escapeHtml(model)
end

local function assistantMessage(content, markdown, streaming, model)
    local class = streaming and "ai-message streaming" or "ai-message"
    return table.concat({
        '<div class="', class, '">',
        '<div class="role-label">', assistantLabel(model), "</div>",
        '<div class="ai-text">', markdown(content or ""), "</div>",
        "</div>",
        '<hr class="message-separator"/>',
    })
end

local function toolMessage(status)
    local state = status.state or "calling"
    local verb = state == "calling" and "Calling" or "Finished"
    local suffix = state == "finished_waiting" and " — waiting for model response" or ""
    local detail = ""
    if status.detail and status.detail ~= "" then
        detail = '<div class="tool-detail">' .. escapeHtml(status.detail) .. "</div>"
    end
    return table.concat({
        '<div class="tool-message">',
        '<div class="role-label">AGENT ACTION</div>',
        '<div class="tool-call"><strong>', verb, '</strong> <code>',
        escapeHtml(status.name or "book tool"), "</code>", escapeHtml(suffix), "</div>",
        detail,
        "</div>",
        '<hr class="message-separator"/>',
    })
end

function Renderer.render(messages, stream_text, status, markdown, model)
    markdown = type(markdown) == "function" and markdown or defaultMarkdown
    local html = {}
    for _, message in ipairs(messages or {}) do
        if message.role == "user" then
            table.insert(html, userMessage(message))
        elseif message.role == "assistant" and type(message.content) == "string" then
            table.insert(html, assistantMessage(message.content, markdown, false, message.model))
        end
    end
    if stream_text and stream_text ~= "" then
        table.insert(html, assistantMessage(stream_text, markdown, true, model))
    elseif type(status) == "table" and status.kind == "tool" then
        table.insert(html, toolMessage(status))
    elseif status and status ~= "" then
        local body = '<p class="stream-status">' .. escapeHtml(status) .. "</p>"
        table.insert(html, table.concat({
            '<div class="ai-message streaming">',
            '<div class="role-label">', assistantLabel(model), "</div>",
            '<div class="ai-text">', body, "</div>",
            "</div>",
            '<hr class="message-separator"/>',
        }))
    end
    if #html == 0 then
        return '<p class="empty-conversation">No conversation yet.</p>'
    end
    return table.concat(html, "\n")
end

Renderer.escapeHtml = escapeHtml

return Renderer
