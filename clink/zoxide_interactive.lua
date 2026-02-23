-- zoxide_interactive: Alt-Z — interactive zoxide directory history.

function zoxide_interactive(rl_buffer)
    local tmp = (os.getenv("TEMP") or ".") .. "\\zoxide_zi_out.txt"

    -- Set fzf height for inline display
    local height = (settings and settings.get and settings.get("fzf.height")) or "40%"
    os.setenv("_ZO_FZF_OPTS", "--height " .. height .. " --reverse")

    os.execute('zoxide query --interactive < CON > "' .. tmp .. '" 2>nul')

    local dir
    local fh = io.open(tmp, "r")
    if fh then
        dir = fh:read("*l")
        if dir then
            dir = dir:gsub("[%z\r\n]+", "")
            dir = dir:gsub("^%s+", ""):gsub("%s+$", "")
            if #dir == 0 then dir = nil end
        end
        fh:close()
    end
    pcall(os.remove, tmp)

    if dir then
        rl_buffer:beginundogroup()
        rl_buffer:remove(0, -1)
        rl_buffer:insert('pushd "' .. dir .. '"')
        rl_buffer:endundogroup()
        rl_buffer:refreshline()
        rl.invokecommand("accept-line")
    else
        rl_buffer:refreshline()
    end
end
