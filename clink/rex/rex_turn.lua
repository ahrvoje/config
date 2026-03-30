-- rex_turn.lua — Turn-scoped helpers: context capture, prompt framing,
-- shell-command protocol, response cleanup/output shaping.
--
-- Owns: context capture, shell-authorization checks, shell-command
-- parsing/execution helpers, prompt construction, ANSI rendering,
-- markdown stripping, and response post-processing.
--
-- Does NOT own: durable state, config, recall files, modes resolution,
-- or capability lookup (those belong in rex_state.lua).

local M = {}

-- Dependencies injected by rex.lua at load time
local json = nil
local state_mod = nil
local provider_mod = nil

function M.init(json_mod, st, prov)
    json = json_mod
    state_mod = st
    provider_mod = prov
end

-- ================================================================
-- Context capture
-- ================================================================

--- Capture current terminal/shell context for the system prompt.
--- Returns a table with cwd, git_branch, term_width, term_height.
function M.capture_context()
    local ctx = {}

    -- Working directory
    ctx.cwd = os.getenv("CD")
    if not ctx.cwd or ctx.cwd == "" then
        -- Fallback: try clink.get_cwd() if available
        if clink and clink.get_cwd then
            ctx.cwd = clink.get_cwd()
        end
    end

    -- Terminal size
    ctx.term_width = tonumber(os.getenv("COLUMNS")) or 120
    ctx.term_height = tonumber(os.getenv("LINES")) or 30

    -- Git branch (best effort, fail silently)
    local pipe = io.popen("git rev-parse --abbrev-ref HEAD 2>nul", "r")
    if pipe then
        local branch = pipe:read("*l")
        pipe:close()
        if branch and branch ~= "" and not branch:match("^fatal:") then
            ctx.git_branch = branch
        end
    end

    return ctx
end

-- ================================================================
-- Shell-request detection
-- ================================================================

--- Determine whether the user prompt is an explicit shell request.
--- Returns true if the user is asking Rex to execute something.
function M.is_shell_request(prompt)
    if not prompt or prompt == "" then return false end
    local lower = prompt:lower()

    -- Direct command patterns — terse imperatives that mean "run this"
    local direct_commands = {
        "^dir%s*",  "^dir$",
        "^ls%s*",   "^ls$",
        "^pwd$",
        "^cd%s+",   "^cd$",
        "^mkdir%s+",
        "^rmdir%s+",
        "^type%s+",
        "^more%s+",
        "^del%s+",  "^erase%s+",
        "^copy%s+", "^xcopy%s+",
        "^move%s+", "^rename%s+", "^ren%s+",
        "^git%s+",
        "^npm%s+",  "^node%s+",  "^python%s+",  "^pip%s+",
        "^cargo%s+", "^rustc%s+",
        "^where%s+", "^which%s+",
        "^echo%s+",
        "^set%s+%w+%s*=",  -- set VAR=value
        "^pushd%s+", "^popd$",
        "^cls$",
    }

    for _, pat in ipairs(direct_commands) do
        if lower:match(pat) then return true end
    end

    -- Explicit shell-request phrases
    local shell_phrases = {
        "^run ",   "^run%s*:", "^execute ",
        "^check ",
        "^show files", "^list files", "^list dir",
        "^show current dir", "^show cwd", "^print cwd",
        "^change cwd", "^change dir", "^switch dir",
        "^go to ", "^navigate to ",
        "^inspect ", "^verify ",
        "^set env", "^set the env",
        "^create dir", "^create folder",
        "^remove dir", "^remove folder",
        "^delete files",
        "^install ",
    }

    for _, pat in ipairs(shell_phrases) do
        if lower:match(pat) then return true end
    end

    -- Phrases containing shell-execution keywords
    if lower:match("run.+command") or lower:match("execute.+command") or
       lower:match("in the shell") or lower:match("via shell") or
       lower:match("check with the shell") or lower:match("inspect the repo") or
       lower:match("list.+files.+larger") or lower:match("files.+bigger") or
       lower:match("list.+files.+in") or lower:match("show.+files.+in") then
        return true
    end

    return false
end

-- ================================================================
-- System prompt composition
-- ================================================================

--- Build the complete system prompt for the API request.
function M.build_system_prompt(ctx, is_shell_req)
    local parts = {}

    -- 1. Base instruction
    parts[#parts + 1] = "You are Rex, a concise terminal AI assistant running inside cmd.exe with Clink. " ..
        "Output is printed directly via clink.print(). " ..
        "Use \\e[ notation for ANSI sequences; the host converts it to real ESC bytes. " ..
        "Be concise, lead with the answer, and never wrap the whole response in markdown code fences, " ..
        "backticks, or a decorative outer box."

    -- 2. Turn-framing block
    parts[#parts + 1] = "Earlier conversation in this request is background only. " ..
        "Answer the newest user message now. " ..
        "Carry forward earlier topics only when the newest message clearly depends on them " ..
        "(e.g., 'above', 'continue', 'same units', 'same file', 'again'). " ..
        "If the newest turn is independent, prefer a focused answer over revisiting stale topics."

    -- 3. Shell-capability block
    if is_shell_req then
        parts[#parts + 1] = "The newest user message is an explicit shell request. " ..
            "You may emit exactly one Rex shell-command block to execute in the live shell. " ..
            "The host will execute the command, capture output, and print the transcript. " ..
            "Prefer shell=cmd unless the user explicitly asks for PowerShell."
    else
        parts[#parts + 1] = "Rex can execute shell commands when the user explicitly asks. " ..
            "The current request is not a shell request, so answer normally without the shell-command block."
    end

    -- 4. Skills block
    local skills = state_mod.get_skills()
    if skills then
        parts[#parts + 1] = skills
    end

    -- 5. System prompt (runtime contract)
    local sys = state_mod.get_system_prompt()
    if sys then
        parts[#parts + 1] = sys
    end

    -- 6. Context block
    local ctx_lines = {"## Current Environment"}
    if ctx.cwd then
        ctx_lines[#ctx_lines + 1] = "- Working directory: " .. ctx.cwd
    end
    if ctx.git_branch then
        ctx_lines[#ctx_lines + 1] = "- Git branch: " .. ctx.git_branch
    end
    ctx_lines[#ctx_lines + 1] = "- Terminal: " .. ctx.term_width .. "x" .. ctx.term_height

    -- Provider/model info
    local prov = state_mod.resolve_provider()
    local model = state_mod.resolve_model()
    if prov and model then
        ctx_lines[#ctx_lines + 1] = "- Provider: " .. prov .. ", Model: " .. model
    end

    parts[#parts + 1] = table.concat(ctx_lines, "\n")

    return table.concat(parts, "\n\n")
end

-- ================================================================
-- Prompt framing for the newest user turn
-- ================================================================

--- Frame the current user prompt with turn-boundary markers.
function M.frame_prompt(user_text)
    return "Current request (answer this now):\n" ..
        user_text .. "\n\n" ..
        "Previous conversation in this request is background only.\n" ..
        "Use it only if the current request clearly depends on it."
end

-- ================================================================
-- Message assembly for API request
-- ================================================================

--- Build the messages array for the API request.
--- Includes memory-windowed history + framed current prompt.
function M.build_messages(user_text)
    local history_msgs = state_mod.build_memory_messages()
    local messages = {}

    -- Add prior conversation
    for _, m in ipairs(history_msgs) do
        messages[#messages + 1] = {role = m.role, content = m.content}
    end

    -- Add framed current prompt as the final user message
    messages[#messages + 1] = {role = "user", content = M.frame_prompt(user_text)}

    return messages
end

-- ================================================================
-- Shell-command protocol parsing
-- ================================================================

local SHELL_SENTINEL_START = "<<<REX_SHELL_COMMAND>>>"
local SHELL_SENTINEL_END   = "<<<END_REX_SHELL_COMMAND>>>"

--- Parse a shell-command block from assistant text.
--- Returns {shell, cwd, timeout_sec, command} or nil if not found.
function M.parse_shell_command(text)
    if not text or text == "" then return nil end

    -- Find the first well-formed block
    local start_pos = text:find(SHELL_SENTINEL_START, 1, true)
    if not start_pos then return nil end

    local end_pos = text:find(SHELL_SENTINEL_END, start_pos, true)
    if not end_pos then return nil end

    -- Extract the block content between sentinels
    local block = text:sub(start_pos + #SHELL_SENTINEL_START, end_pos - 1)

    -- Trim leading newline
    block = block:gsub("^\n", "")

    -- Parse headers and command body, separated by a blank line
    local headers_part, command_part = block:match("^(.-)%f[\r\n]%s*\n(.*)")
    if not headers_part then
        -- Maybe no blank line separator — try just headers
        headers_part = block
        command_part = ""
    end

    local result = {
        shell       = nil,
        cwd         = ".",
        timeout_sec = nil,
        command     = nil,
    }

    -- Parse header lines
    for line in headers_part:gmatch("[^\r\n]+") do
        local key, value = line:match("^(%w+)%s*=%s*(.-)%s*$")
        if key then
            if key == "shell" then
                result.shell = value
            elseif key == "cwd" then
                result.cwd = value
            elseif key == "timeout_sec" then
                result.timeout_sec = tonumber(value)
            end
        end
    end

    -- Trim command body
    if command_part then
        result.command = command_part:match("^%s*(.-)%s*$")
    end

    -- Validate: shell is required
    if not result.shell then return nil end
    if result.shell ~= "cmd" and result.shell ~= "powershell" then return nil end

    -- Command must be non-empty
    if not result.command or result.command == "" then return nil end

    return result
end

--- Strip the shell-command block from the assistant text.
--- Returns the text with the block removed.
function M.strip_shell_command(text)
    if not text then return text end
    local start_pos = text:find(SHELL_SENTINEL_START, 1, true)
    if not start_pos then return text end
    local end_pos = text:find(SHELL_SENTINEL_END, start_pos, true)
    if not end_pos then return text end
    local before = text:sub(1, start_pos - 1)
    local after = text:sub(end_pos + #SHELL_SENTINEL_END)
    return (before .. after):match("^%s*(.-)%s*$")
end

-- ================================================================
-- Shell command execution
-- ================================================================

--- Execute a parsed shell command in the live session context.
--- For session-mutating commands (cd, set), applies effects to main session.
--- Returns {exit_code, output, final_cwd} or nil + error.
function M.execute_shell_command(parsed_cmd, rl_buffer)
    if not parsed_cmd then return nil, "No command to execute" end

    local cmd_text = parsed_cmd.command
    local shell = parsed_cmd.shell or "cmd"
    local timeout = parsed_cmd.timeout_sec or 30

    -- Determine working directory
    local cwd = parsed_cmd.cwd
    if cwd == "." or not cwd or cwd == "" then
        cwd = os.getenv("CD") or ""
    end

    -- Detect session-mutating commands that need main-session execution
    local lower_cmd = cmd_text:lower():match("^%s*(.-)%s*$")

    -- Check for cd/chdir/pushd/popd/set commands that mutate session
    local is_session_mutating = false
    if shell == "cmd" then
        is_session_mutating = lower_cmd:match("^cd%s") or lower_cmd:match("^cd$") or
            lower_cmd:match("^cd%s*/d%s") or
            lower_cmd:match("^chdir%s") or lower_cmd:match("^chdir$") or
            lower_cmd:match("^pushd%s") or lower_cmd:match("^pushd$") or
            lower_cmd:match("^popd$") or lower_cmd:match("^popd%s") or
            lower_cmd:match("^set%s+%w")
    end

    if is_session_mutating and rl_buffer then
        -- Inject the command into the active Clink edit line and accept it
        -- so cmd.exe applies its own builtin semantics in the current session.
        -- This is the reliable path for session-mutating commands.
        --
        -- We set the buffer to the command text and then accept the line,
        -- which causes Clink/cmd.exe to execute it in the live session.
        rl_buffer:setbuffer(cmd_text)
        rl.invokecommand("accept-line")

        return {
            exit_code = 0,
            output    = "",
            final_cwd = nil,  -- Will be updated by cmd.exe itself
            injected  = true, -- Signal that this was injected, not captured
        }
    end

    -- Non-session-mutating: execute via io.popen and capture output
    local full_cmd
    if shell == "powershell" then
        -- Escape for powershell
        local escaped = cmd_text:gsub('"', '\\"')
        full_cmd = 'powershell -NoProfile -NonInteractive -Command "' .. escaped .. '" 2>&1'
    else
        -- cmd
        if cwd ~= "" and cwd ~= "." then
            full_cmd = 'cd /d "' .. cwd .. '" && ' .. cmd_text .. ' 2>&1'
        else
            full_cmd = cmd_text .. " 2>&1"
        end
    end

    local pipe = io.popen(full_cmd, "r")
    if not pipe then
        return nil, "Failed to launch command"
    end

    local output = pipe:read("*a") or ""
    local ok, exit_type, exit_code = pipe:close()

    -- Normalize exit code
    if type(exit_code) ~= "number" then
        exit_code = ok and 0 or 1
    end

    -- Get final cwd after execution
    local final_cwd = os.getenv("CD")

    return {
        exit_code = exit_code,
        output    = output,
        final_cwd = final_cwd,
        injected  = false,
    }
end

--- Format a shell transcript for display.
function M.format_shell_transcript(cmd_text, result)
    if not result then return "Command execution failed." end

    if result.injected then
        -- Command was injected into the live session
        return ""  -- The command itself will be visible as it runs in the session
    end

    local lines = {}
    -- Show the command
    lines[#lines + 1] = "> " .. cmd_text

    -- Show output
    if result.output and result.output:match("%S") then
        -- Trim trailing whitespace
        local trimmed = result.output:match("^(.-)%s*$")
        lines[#lines + 1] = trimmed
    else
        -- No output — show completion message
        if result.exit_code == 0 then
            lines[#lines + 1] = "Command completed."
        else
            lines[#lines + 1] = "Command exited with code " .. tostring(result.exit_code) .. "."
        end
    end

    -- Show exit code if non-zero and there was output
    if result.exit_code ~= 0 and result.output and result.output:match("%S") then
        lines[#lines + 1] = "(exit code " .. tostring(result.exit_code) .. ")"
    end

    return table.concat(lines, "\n")
end

-- ================================================================
-- ANSI escape rendering
-- ================================================================

--- Convert literal escape notations to real ESC bytes.
--- Handles \e[, \033[, and \x1b[ notations.
function M.render_ansi(text)
    if not text then return text end
    local ESC = string.char(27)
    -- \e[ notation
    text = text:gsub("\\e%[", ESC .. "[")
    -- \e] for OSC sequences
    text = text:gsub("\\e%]", ESC .. "]")
    -- \e_ for APC sequences
    text = text:gsub("\\e_", ESC .. "_")
    -- \e\\ for ST (string terminator)
    text = text:gsub("\\e\\\\", ESC .. "\\")
    -- \033[ notation
    text = text:gsub("\\033%[", ESC .. "[")
    text = text:gsub("\\033%]", ESC .. "]")
    -- \x1b[ notation
    text = text:gsub("\\x1b%[", ESC .. "[")
    text = text:gsub("\\x1b%]", ESC .. "]")
    return text
end

-- ================================================================
-- Markdown stripping
-- ================================================================

--- Strip leading/trailing markdown code fences from LLM output.
--- Safety net for models that ignore the "no markdown" instruction.
function M.strip_markdown_fences(text)
    if not text then return text end

    -- Strip leading code fence: ```ansi, ```text, ```
    text = text:gsub("^%s*```%w*%s*\n?", "")
    -- Strip trailing code fence
    text = text:gsub("\n?%s*```%s*$", "")

    return text
end

-- ================================================================
-- Response post-processing
-- ================================================================

--- Process raw assistant response text for display.
--- Applies shell-command extraction, markdown stripping, and ANSI rendering.
--- Returns processed_text, shell_command_parsed_or_nil.
function M.process_response(raw_text, is_shell_req, rl_buffer)
    if not raw_text or raw_text == "" then
        return nil, nil, "Empty response from model"
    end

    -- 1. Check for shell-command block BEFORE any other processing
    local shell_cmd = nil
    if is_shell_req then
        shell_cmd = M.parse_shell_command(raw_text)
    end

    if shell_cmd then
        -- Execute the shell command
        local result, exec_err = M.execute_shell_command(shell_cmd, rl_buffer)
        if not result then
            return "Shell command error: " .. (exec_err or "unknown"), nil, nil
        end
        local transcript = M.format_shell_transcript(shell_cmd.command, result)
        return transcript, shell_cmd, nil
    end

    -- 2. Normal text response — strip shell block if present but not a shell request
    local text = raw_text
    if M.parse_shell_command(text) then
        -- Shell block in a non-shell-request response: strip it and use remaining text
        text = M.strip_shell_command(text)
    end

    -- 3. Strip markdown fences
    text = M.strip_markdown_fences(text)

    -- 4. Render ANSI escapes
    text = M.render_ansi(text)

    -- 5. Check if post-processing left us with empty text
    if not text or text:match("^%s*$") then
        -- This is a post-processing emptiness, not a provider no-content error
        return "(Response was empty after processing.)", nil, nil
    end

    return text, nil, nil
end

-- ================================================================
-- Context display for /context command
-- ================================================================

--- Build a display string showing what context is being sent to the LLM.
function M.format_context_display()
    local lines = {}

    lines[#lines + 1] = "Rex Context:"
    lines[#lines + 1] = ""

    -- Effective settings
    lines[#lines + 1] = "Provider:   " .. (state_mod.resolve_provider() or "not set")
    lines[#lines + 1] = "Model:      " .. (state_mod.resolve_model() or "not set")
    lines[#lines + 1] = "Mode:       " .. (state_mod.resolve_mode() or "default")
    lines[#lines + 1] = "Memory:     " .. (state_mod.resolve_memory() or "all")
    lines[#lines + 1] = "Max tokens: " .. tostring(state_mod.resolve_max_tokens())
    lines[#lines + 1] = "Timeout:    " .. tostring(state_mod.resolve_timeout()) .. "s"
    lines[#lines + 1] = ""

    -- Environment context
    local ctx = M.capture_context()
    lines[#lines + 1] = "Environment:"
    lines[#lines + 1] = "  CWD:       " .. (ctx.cwd or "unknown")
    lines[#lines + 1] = "  Git:       " .. (ctx.git_branch or "none")
    lines[#lines + 1] = "  Terminal:  " .. ctx.term_width .. "x" .. ctx.term_height
    lines[#lines + 1] = ""

    -- Memory window contents
    local mem = state_mod.resolve_memory()
    local hist = state_mod.get_history()
    lines[#lines + 1] = "Memory window (" .. mem .. "):"
    local mem_msgs = state_mod.build_memory_messages()
    if #mem_msgs == 0 then
        lines[#lines + 1] = "  (empty)"
    else
        for i, m in ipairs(mem_msgs) do
            local preview = m.content:sub(1, 80)
            if #m.content > 80 then preview = preview .. "..." end
            preview = preview:gsub("\n", " ")
            lines[#lines + 1] = "  [" .. i .. "] " .. m.role .. ": " .. preview
        end
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Stored history: " .. #hist .. " entries"

    return table.concat(lines, "\n")
end

return M
