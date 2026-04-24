-- Expand a leading ~ in "cd" arguments to %USERPROFILE%.
-- Runs as a clink input filter, so the real cd handles everything else
-- (flags like /d, cd .., cd /?, tab completion, quoted paths, ...).

local function expand_tilde(line)
    local home = os.getenv("USERPROFILE")
    if not home then return line end

    -- Only rewrite when the first token is cd (or chdir), case-insensitive.
    local head, arg = line:match("^(%s*[cC][dD]%s+)(.+)$")
    if not head then
        head, arg = line:match("^(%s*[cC][hH][dD][iI][rR]%s+)(.+)$")
    end
    if not head then return line end

    -- Strip trailing whitespace from the argument for matching.
    local trimmed = arg:gsub("%s+$", "")

    if trimmed == "~" then
        return head .. '"' .. home .. '"'
    end

    -- ~/foo or ~\foo -> %USERPROFILE%\foo  (only when ~ is followed by a separator)
    if trimmed:sub(1, 2) == "~/" or trimmed:sub(1, 2) == "~\\" then
        local tail = trimmed:sub(2):gsub("/", "\\")
        return head .. '"' .. home .. tail .. '"'
    end

    return line
end

clink.onfilterinput(expand_tilde)
