--------------------------------------------------------------------------------
-- fzf_disks: Ctrl-Y — search all local fixed disks via fzf's built-in walker.
--
-- Mirrors fzf_file (Ctrl-T) but targets all drives:
--   - Word at cursor pre-fills fzf query (editable)
--   - Selected result(s) replace the word at cursor
--
-- Uses fzf --walker (no dir/pipe/batch). os.execute + temp output file avoids
-- the io.popen pipe-blocking issue on Windows.
--
-- Binding:  "\C-y": "luafunc:fzf_disks"
--------------------------------------------------------------------------------

local function need_quote(word)
    return word and word:find("[ &()[%]{}^=;!%%'+,`~]") and true
end

function fzf_disks(rl_buffer, line_state)

    -- 1. Parse word at cursor and insertion bounds
    local word, first, last, has_quote

    if line_state
        and line_state.getwordcount
        and line_state:getwordcount() > 0
    then
        local info = line_state:getwordinfo(line_state:getwordcount())
        if info then
            local buf = line_state:getline()
            word = buf:sub(info.offset, line_state:getcursor() - 1)
            word = word and word:gsub('["\']', '')
            if word == "" then word = nil end
            first = info.offset
            last  = line_state:getcursor() - 1
            if info.quoted then
                first = first - 1
                has_quote = buf:sub(first, first)
            end
        end
    end

    if not first then
        first = rl_buffer:getcursor()
        last  = first - 1
    end

    -- 2. Discover drives (C:/ .. Z:/)
    local drives = {}
    for c = string.byte("C"), string.byte("Z") do
        local d = string.char(c) .. ":/"
        if os.isdir and os.isdir(d) then
            drives[#drives + 1] = d
        end
    end
    if #drives == 0 then
        rl_buffer:ding()
        return
    end

    -- 3. Resolve fzf binary and height
    local fzf = "fzf.exe"
    if settings and settings.get then
        local loc = settings.get("fzf.exe_location")
        if loc and loc ~= "" then
            fzf = '"' .. loc:gsub('"', '') .. '"'
        end
    end

    local height = (settings and settings.get and settings.get("fzf.height")) or "40%"

    -- 4. Build command
    local cmd = string.format(
        "%s --height %s --reverse --scheme=path -i -m"
        .. " --walker=file --walker-root %s"
        .. " --bind esc:abort",
        fzf, height, table.concat(drives, " ")
    )

    local extra = os.getenv("FZF_CTRL_T_OPTS")
    if extra and extra ~= "" then
        cmd = cmd .. " " .. extra
    end

    if word then
        -- Strip characters unsafe for cmd.exe embedding
        local q = word:gsub('[%%"^|&<>]', "")
        if q ~= "" then
            cmd = cmd .. ' -q "' .. q .. '"'
        end
    end

    -- 5. Execute — os.execute returns as soon as fzf exits (no pipe to drain)
    --    < CON  = keyboard input for walker mode
    --    > file = capture selections without io.popen pipe-blocking
    local tmp = (os.getenv("TEMP") or ".") .. "\\fzf_disks_out.txt"
    os.execute('2>nul ' .. cmd .. ' < CON > "' .. tmp .. '"')

    -- 6. Read selections
    local matches = {}
    local fh = io.open(tmp, "r")
    if fh then
        for entry in fh:lines() do
            entry = entry:gsub("[\r\n]+", ""):gsub("%s+$", "")
            if #entry > 0 then
                matches[#matches + 1] = entry
            end
        end
        fh:close()
    end
    pcall(os.remove, tmp)

    -- 7. Insert matches replacing the word at cursor
    if #matches > 0 then
        local quote = has_quote or '"'
        rl_buffer:beginundogroup()
        rl_buffer:remove(first, last + 1)
        rl_buffer:setcursor(first)
        for _, m in ipairs(matches) do
            local q = ((has_quote or need_quote(m)) and quote) or ""
            rl_buffer:insert(q .. m .. q .. " ")
        end
        rl_buffer:endundogroup()
    end

    rl_buffer:refreshline()
end
