-- rex_turn.lua -- Turn-scoped helpers: context capture, prompt framing,
-- shell-command protocol parsing/execution, ANSI rendering, markdown
-- stripping, and response post-processing.
--
-- Owns: context capture, shell-authorization checks, shell-command parsing,
-- shell-command execution helpers, session-effect application, prompt
-- construction, ANSI rendering, markdown stripping, response shaping.
-- Does NOT own: durable state, config I/O, modes.json loading, HTTP transport.

local state_mod  -- injected via init()

local M = {}

function M.init(state_module)
    state_mod = state_module
end

-- ================================================================
-- Context capture
-- ================================================================

function M.capture_context()
    local ctx = {}

    -- Working directory
    ctx.cwd = clink.get_cwd and clink.get_cwd() or os.getenv("CD") or "."

    -- Terminal size
    ctx.columns = tonumber(os.getenv("COLUMNS")) or 120
    ctx.lines   = tonumber(os.getenv("LINES"))   or 30

    -- Git branch (best-effort, silent failure)
    local git_pipe = io.popen("git rev-parse --abbrev-ref HEAD 2>nul")
    if git_pipe then
        local branch = git_pipe:read("*l")
        git_pipe:close()
        if branch and branch ~= "" and not branch:find("fatal") then
            ctx.git_branch = branch
        end
    end

    return ctx
end

-- ================================================================
-- System prompt composition
-- ================================================================

--- Build the full system prompt for the current turn.
--- shell_authorized: boolean indicating if the user explicitly asked for
--- shell activity in this turn.
function M.build_system_prompt(shell_authorized)
    local parts = {}

    -- Part 1: Base instruction
    parts[#parts + 1] = "You are Rex, a terminal AI assistant. " ..
        "Your output is printed raw via clink.print() into a cmd.exe terminal. " ..
        "Be concise and lead with the answer. " ..
        "Never wrap your entire response in markdown code fences, backticks, or a decorative border box. " ..
        "Use \\e[ notation for ANSI escape sequences (the host converts them to real ESC bytes)."

    -- Part 2: Turn-framing block
    parts[#parts + 1] = "The conversation below may contain earlier turns. " ..
        "Those earlier turns are background context only. " ..
        "Answer the newest user message now. " ..
        "Do not continue or revisit earlier topics unless the newest message explicitly refers to them " ..
        "(e.g., 'above', 'continue', 'same units', 'same file', 'again')."

    -- Part 3: Shell-capability block
    -- No user-facing "shell not allowed" phrasing.  The block tells the model
    -- when it may use the shell-command protocol without introducing a denial mode.
    if shell_authorized then
        parts[#parts + 1] = "Rex can execute one shell command when the newest user message " ..
            "explicitly asks for shell activity. You may return the shell-command protocol " ..
            "block defined in the skills section below."
    else
        parts[#parts + 1] = "Rex can execute one shell command when the newest user message " ..
            "explicitly asks for shell activity. The current request does not appear to be " ..
            "an explicit shell request, so answer normally or suggest a command the user can run."
    end

    -- Part 4: Skills block
    local skills = state_mod.get_skills()
    if skills and skills ~= "" then
        parts[#parts + 1] = skills
    end

    -- Part 5: Context block (environment facts, not conversation)
    local ctx = M.capture_context()
    local ctx_lines = {"--- Terminal Context ---"}
    ctx_lines[#ctx_lines + 1] = "Working directory: " .. ctx.cwd
    ctx_lines[#ctx_lines + 1] = "Terminal size: " .. ctx.columns .. "x" .. ctx.lines
    if ctx.git_branch then
        ctx_lines[#ctx_lines + 1] = "Git branch: " .. ctx.git_branch
    end
    parts[#parts + 1] = table.concat(ctx_lines, "\n")

    return table.concat(parts, "\n\n")
end

-- ================================================================
-- Shell authorization check
-- ================================================================

-- Heuristic: does the user prompt explicitly ask Rex to do shell work?
-- Terse imperatives like "dir", "git status", "cd <path>" count.
local shell_keywords = {
    "^run%s", "^execute%s", "^check%s", "^inspect%s",
    "^dir$", "^dir%s", "^ls$", "^ls%s", "^pwd$",
    "^git%s", "^list%s+files", "^list%s+dir", "^show%s+files",
    "^show%s+current%s+dir", "^show%s+cwd",
    "^change%s+cwd", "^change%s+dir", "^cd%s", "^cd$",
    "run%s+.+for%s+me", "check%s+with%s+the%s+shell",
    "inspect%s+the%s+repo", "run%s+this",
    "set%s+%w+%s*=", "^set%s+%w+$",
    "^mkdir%s", "^rmdir%s", "^del%s", "^copy%s", "^move%s",
    "^ren%s", "^type%s", "^more%s", "^find%s", "^findstr%s",
    "^tree$", "^tree%s", "^where%s", "^whoami$",
    "^pushd%s", "^popd$", "^popd%s",
    "list%s+all%s+files", "show%s+directory",
}

function M.is_shell_authorized(prompt)
    if not prompt then return false end
    local lower = prompt:lower():match("^%s*(.-)%s*$")
    for _, pattern in ipairs(shell_keywords) do
        if lower:find(pattern) then
            return true
        end
    end
    return false
end

-- ================================================================
-- Prompt framing for the newest user message
-- ================================================================

--- Wrap the user prompt with turn-boundary framing so the model knows
--- which message is the active request vs. background context.
function M.frame_user_prompt(raw_prompt)
    return "Current request (answer this now):\n" .. raw_prompt .. "\n\n" ..
        "Previous conversation in this request is background only.\n" ..
        "Use it only if the current request clearly depends on it."
end

-- ================================================================
-- Shell-command protocol parsing
-- ================================================================

local SHELL_CMD_START = "<<<REX_SHELL_COMMAND>>>"
local SHELL_CMD_END   = "<<<END_REX_SHELL_COMMAND>>>"

--- Parse the first well-formed shell-command block from raw assistant text.
--- Returns a table {shell, cwd, timeout_sec, command} or nil.
function M.parse_shell_command(text)
    if not text then return nil end

    local start_pos = text:find(SHELL_CMD_START, 1, true)
    if not start_pos then return nil end

    local end_pos = text:find(SHELL_CMD_END, start_pos, true)
    if not end_pos then return nil end

    -- Extract the block content between sentinels
    local block = text:sub(start_pos + #SHELL_CMD_START, end_pos - 1)
    block = block:gsub("^\n", "")

    -- Parse headers and command body, separated by blank line
    local headers_text, command_body = block:match("^(.-)\n\n(.*)")
    if not headers_text then
        return nil
    end

    local result = {
        shell = nil,
        cwd = ".",
        timeout_sec = nil,
        command = nil,
    }

    for line in headers_text:gmatch("[^\r\n]+") do
        local key, val = line:match("^(%S+)=(.+)$")
        if key and val then
            if key == "shell" then
                result.shell = val
            elseif key == "cwd" then
                result.cwd = val
            elseif key == "timeout_sec" then
                result.timeout_sec = tonumber(val)
            end
        end
    end

    -- shell is required and must be cmd or powershell
    if not result.shell or (result.shell ~= "cmd" and result.shell ~= "powershell") then
        return nil
    end

    command_body = command_body:match("^(.-)%s*$")
    if not command_body or command_body == "" then
        return nil
    end
    result.command = command_body

    return result
end

--- Remove the shell-command block from assistant text (for non-shell turns
--- where the model erroneously included one).
function M.strip_shell_command(text)
    if not text then return "" end
    local start_pos = text:find(SHELL_CMD_START, 1, true)
    if not start_pos then return text end
    local end_pos = text:find(SHELL_CMD_END, start_pos, true)
    if not end_pos then return text end
    local before = text:sub(1, start_pos - 1)
    local after  = text:sub(end_pos + #SHELL_CMD_END)
    local result = before .. after
    result = result:gsub("\n\n\n+", "\n\n")
    result = result:match("^%s*(.-)%s*$")
    return result or ""
end

-- ================================================================
-- Session-mutating command detection
-- ================================================================

--- Determine whether a cmd command is session-mutating (cd, set, pushd, popd).
--- These commands must affect the live interactive session, not just a child
--- shell.
function M.is_session_mutating(cmd_info)
    if not cmd_info or cmd_info.shell ~= "cmd" then return false end
    local lower = cmd_info.command:lower():match("^%s*(.-)%s*$")
    return lower:find("^cd%s") or lower:find("^cd$")
        or lower:find("^cd%s*/d%s") or lower:find("^chdir%s")
        or lower:find("^chdir$") or lower:find("^pushd%s")
        or lower:find("^pushd$") or lower:find("^popd")
        or lower:find("^set%s+%w")
end

-- ================================================================
-- Shell-command execution
-- ================================================================

--- Execute a parsed shell command in a child shell and capture results.
--- Returns {output, exit_code, final_cwd, env_changes, inject_command}.
---
--- For session-mutating commands (cd, set, pushd, popd):
---   - Runs in a child shell for validation and output capture.
---   - Sets inject_command to the original command so the caller can inject
---     it into the live interactive session via rl_buffer:setbuffer() +
---     rl.invokecommand("accept-line").
function M.execute_shell_command(cmd_info)
    if not cmd_info or not cmd_info.command then
        return {output = "", exit_code = -1, final_cwd = nil, env_changes = nil}
    end

    local command = cmd_info.command
    local result = {output = "", exit_code = 0, final_cwd = nil, env_changes = nil,
                    inject_command = nil}

    if cmd_info.shell == "cmd" then
        local cwd_part = ""
        if cmd_info.cwd and cmd_info.cwd ~= "." then
            cwd_part = 'cd /d "' .. cmd_info.cwd .. '" && '
        end

        -- Detect session-mutating commands
        local lower_cmd = command:lower():match("^%s*(.-)%s*$")
        local is_cd = lower_cmd:find("^cd%s") or lower_cmd:find("^cd$")
                   or lower_cmd:find("^cd%s*/d%s")
                   or lower_cmd:find("^chdir%s") or lower_cmd:find("^chdir$")
                   or lower_cmd:find("^pushd%s") or lower_cmd:find("^pushd$")
                   or lower_cmd:find("^popd")
        local is_set = lower_cmd:find("^set%s+%w")

        if is_cd then
            -- Run cd/pushd/popd in a child shell to validate and capture the
            -- resulting directory.  Append "cd" after the command to print the
            -- final working directory on the last output line.
            local full_cmd = 'cmd /c "' .. cwd_part .. command .. ' && cd" 2>&1'
            local pipe = io.popen(full_cmd)
            if pipe then
                result.output = pipe:read("*a") or ""
                pipe:close()
            end
            -- Last non-empty line is the final directory
            local lines = {}
            for line in result.output:gmatch("[^\r\n]+") do
                lines[#lines + 1] = line
            end
            if #lines > 0 then
                result.final_cwd = lines[#lines]
                table.remove(lines)
                result.output = table.concat(lines, "\n")
            end
            -- The actual command must be injected into the live session so
            -- cmd.exe applies its own builtin cd/pushd/popd semantics.
            result.inject_command = command

        elseif is_set then
            -- Parse the set command to extract variable assignment
            local var_assign = command:match("^%s*[Ss][Ee][Tt]%s+(.+)$")
            if var_assign then
                local var_name, var_val = var_assign:match("^(%w+)=(.*)$")
                if var_name then
                    -- "set VAR=value" or "set VAR=" (clear)
                    result.env_changes = {{name = var_name, value = var_val}}
                    -- Inject into the live session so the env var persists.
                    result.inject_command = command
                else
                    -- "set VAR" without = just displays the variable
                    local full_cmd = 'cmd /c "' .. cwd_part .. command .. '" 2>&1'
                    local pipe = io.popen(full_cmd)
                    if pipe then
                        result.output = pipe:read("*a") or ""
                        pipe:close()
                    end
                end
            end

        else
            -- General (non-mutating) command execution
            local full_cmd = 'cmd /c "' .. cwd_part .. command .. '" 2>&1'
            local pipe = io.popen(full_cmd)
            if pipe then
                result.output = pipe:read("*a") or ""
                pipe:close()
            end
        end

    elseif cmd_info.shell == "powershell" then
        local ps_cmd = 'powershell -NoProfile -NonInteractive -Command "'
            .. command:gsub('"', '\\"') .. '" 2>&1'
        local pipe = io.popen(ps_cmd)
        if pipe then
            result.output = pipe:read("*a") or ""
            pipe:close()
        end
    end

    -- Trim trailing whitespace from output
    if result.output then
        result.output = result.output:match("^(.-)%s*$") or ""
    end

    return result
end

--- Format a shell transcript for terminal display.
--- Always produces visible output, even for side-effect-only commands.
function M.format_shell_transcript(cmd_info, exec_result)
    local shell_label = cmd_info.shell == "powershell" and "PS>" or ">"
    local parts = {shell_label .. " " .. cmd_info.command}

    if exec_result.output and exec_result.output ~= "" then
        parts[#parts + 1] = exec_result.output
    else
        -- Side-effect-only command with no stdout -- provide visible completion
        if exec_result.final_cwd then
            parts[#parts + 1] = "Changed directory to " .. exec_result.final_cwd
        elseif exec_result.env_changes and #exec_result.env_changes > 0 then
            local c = exec_result.env_changes[1]
            if c.value == "" then
                parts[#parts + 1] = "Cleared " .. c.name
            else
                parts[#parts + 1] = "Set " .. c.name .. "=" .. c.value
            end
        else
            parts[#parts + 1] = "Command completed."
        end
    end

    return table.concat(parts, "\n")
end

-- ================================================================
-- ANSI escape rendering
-- ================================================================

--- Convert literal \e[, \033[, \x1b[ text notation to real ESC bytes.
--- Also handles OSC (\e]), ST (\e\\), and APC (\e_) sequences.
function M.render_ansi(text)
    if not text then return "" end
    -- CSI sequences
    text = text:gsub("\\e%[", "\x1b[")
    text = text:gsub("\\033%[", "\x1b[")
    text = text:gsub("\\x1b%[", "\x1b[")
    -- OSC sequences
    text = text:gsub("\\e%]", "\x1b]")
    text = text:gsub("\\033%]", "\x1b]")
    text = text:gsub("\\x1b%]", "\x1b]")
    -- ST (string terminator)
    text = text:gsub("\\e\\\\", "\x1b\\")
    text = text:gsub("\\033\\\\", "\x1b\\")
    text = text:gsub("\\x1b\\\\", "\x1b\\")
    -- APC
    text = text:gsub("\\e_", "\x1b_")
    text = text:gsub("\\033_", "\x1b_")
    text = text:gsub("\\x1b_", "\x1b_")
    return text
end

-- ================================================================
-- Markdown stripping
-- ================================================================

--- Strip leading/trailing markdown code fences from LLM responses.
--- Safety net for models that ignore the "no fences" instruction.
function M.strip_markdown_fences(text)
    if not text then return "" end
    text = text:gsub("^%s*```%w*%s*\n?", "")
    text = text:gsub("\n?%s*```%s*$", "")
    return text
end

-- ================================================================
-- Response post-processing pipeline
-- ================================================================

--- Process raw LLM response text for terminal output:
--- strip markdown fences, convert ANSI notation to real escapes.
function M.process_response(text)
    if not text then return "" end
    text = M.strip_markdown_fences(text)
    text = M.render_ansi(text)
    return text
end

return M
