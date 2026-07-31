-- rex.lua — Clink entrypoint: key binding, rl_buffer handling,
-- slash-command dispatch, popup orchestration, onboarding flow.
--
-- This file is the Clink-facing layer only. It loads the three sibling
-- implementation files by explicit path and delegates all non-UI logic
-- to them.

-- ================================================================
-- Module loading by explicit sibling path
-- ================================================================

local script_dir = debug.getinfo(1, "S").source:match("@?(.+[\\/])")

--- Load a sibling file, degrading gracefully instead of killing every
--- Clink script when one file has a syntax error.
local function load_sibling(name)
    local ok, mod = pcall(dofile, script_dir .. name)
    if ok and mod then return mod end
    local msg = "rex: failed to load " .. name .. ": " .. tostring(mod)
    if clink and clink.print then clink.print(msg) else print(msg) end
    return nil
end

local json         = load_sibling("json.lua")
local state_mod    = load_sibling("rex_state.lua")
local turn_mod     = load_sibling("rex_turn.lua")
local provider_mod = load_sibling("rex_provider.lua")

if not (json and state_mod and turn_mod and provider_mod) then
    return
end

-- Seed once so temp-file names differ across concurrent sessions
math.randomseed(os.time())
math.random(); math.random(); math.random()

-- Initialize modules with shared dependencies
state_mod.set_script_dir(script_dir)
provider_mod.init(json, state_mod)
turn_mod.init(json, state_mod, provider_mod)

-- Load modes.json and skills at startup
state_mod.load_modes(json)
state_mod.load_skills()
state_mod.load_config()

-- ================================================================
-- Helpers
-- ================================================================

local ESC = string.char(27)

-- Output must be preceded by exactly one rl_buffer:beginoutput() per
-- Ctrl+Enter invocation: it ends the prompt line (so printed text starts
-- on a fresh line instead of gluing to the typed command) and tells Clink
-- to redraw the prompt when the binding returns. It is done lazily on the
-- first print because popup interaction (clink.popuplist) must happen
-- BEFORE the prompt is ended.
local active_rl_buffer = nil
local output_begun = false

local function begin_output()
    if active_rl_buffer and not output_begun then
        output_begun = true
        active_rl_buffer:beginoutput()
    end
end

local function print_output(text)
    begin_output()
    if clink and clink.print then
        clink.print(text)
    else
        print(text)
    end
end

-- Marker used when recording /run transcripts into conversation memory,
-- so /retry can skip them when looking for the last real prompt.
local RUN_RECORD_PREFIX = "I ran this shell command:"

-- ================================================================
-- Popup wrapper with terminal user-var signalling
-- ================================================================

-- WezTerm's Esc/PageUp/PageDown bindings are context-sensitive and cannot
-- see a Clink popup (the foreground process is still cmd.exe, and the
-- popup frame defeats line heuristics). Flag popup ownership via an
-- OSC 1337 user var — the same contract the zsh fzf wrappers use — so the
-- terminal forwards those keys to the popup. Terminals that don't know
-- the OSC ignore it.
local function set_user_var(name, b64val)
    local osc = "\27]1337;SetUserVar=" .. name .. "=" .. b64val .. "\7"
    if os.getenv("TMUX") then
        osc = "\27Ptmux;\27" .. osc .. "\27\\"
    end
    -- clink.print reaches the terminal even mid-keybinding (NONL avoids
    -- the newline); raw stdout covers non-Clink contexts.
    if clink and clink.print and NONL then
        clink.print(osc, NONL)
    else
        io.stdout:write(osc)
        io.stdout:flush()
    end
end

--- clink.popuplist with the clink_popup user var held 'on' for the whole
--- interaction. pcall guarantees the flag is cleared even if the popup
--- errors, so a stale flag cannot hijack Esc at the prompt.
local function popuplist(title, items)
    set_user_var("clink_popup", "b24=")  -- base64('on')
    local ok, value = pcall(clink.popuplist, title, items)
    set_user_var("clink_popup", "b2Zm")  -- base64('off')
    if not ok then error(value, 0) end
    return value
end

-- Clear a stale flag left by a hard-killed session in this pane
if clink.onbeginedit then
    clink.onbeginedit(function()
        set_user_var("clink_popup", "b2Zm")
    end)
end

-- ================================================================
-- Main turn processing
-- ================================================================

--- Process a normal prompt (not a slash command).
local function process_prompt(trimmed, rl_buffer)
    -- Determine if this is a shell request
    local is_shell_req = turn_mod.is_shell_request(trimmed)

    -- Capture context
    local ctx = turn_mod.capture_context()

    -- Build system prompt
    local system_prompt = turn_mod.build_system_prompt(ctx, is_shell_req)

    -- Build messages with memory window
    local messages = turn_mod.build_messages(trimmed)

    -- Record the user turn only AFTER the request is built, so the memory
    -- window does not include a duplicate of the current prompt.
    state_mod.add_history("user", trimmed)

    -- Progress indicator — the terminal is otherwise silent until the
    -- response arrives.
    print_output(ESC .. "[2m… " .. (state_mod.resolve_model() or "model") .. ESC .. "[0m")

    -- Send request
    local raw_text, send_err, usage = provider_mod.send_request(system_prompt, messages, {})
    if not raw_text then
        local err_msg = "Error: " .. (send_err or "Unknown request error.")
        print_output(err_msg)
        -- Record error in history and recall
        state_mod.add_history("assistant", err_msg)
        state_mod.append_recall("error", err_msg)
        return
    end

    -- Process response
    local processed, shell_cmd, proc_err = turn_mod.process_response(raw_text, is_shell_req, rl_buffer)

    if proc_err and (not processed or processed == "") then
        local err_msg = "Error: " .. proc_err
        print_output(err_msg)
        state_mod.add_history("assistant", err_msg)
        state_mod.append_recall("error", err_msg)
        return
    end

    -- Print the result
    if processed and processed ~= "" then
        print_output(processed)
    end

    -- Token usage line (dim, best effort)
    if usage then
        print_output(ESC .. "[2m↳ " .. tostring(usage.input or "?") .. " in / " ..
            tostring(usage.output or "?") .. " out" .. ESC .. "[0m")
    end

    -- Record in history and recall. Note: an injected shell command yields
    -- an empty transcript, and empty assistant messages poison follow-up
    -- requests, so fall back to a description of what happened.
    if shell_cmd then
        local record = (processed and processed ~= "") and processed
            or ("Executed: " .. shell_cmd.command)
        state_mod.add_history("assistant", record)
        state_mod.append_recall("shell", record)
    else
        local record = (processed and processed ~= "") and processed or raw_text
        state_mod.add_history("assistant", record)
        state_mod.append_recall("assistant", record)
        state_mod.set_last_answer(record)
    end
end

-- ================================================================
-- Slash command handlers
-- ================================================================

--- /help — list available commands
local function cmd_help()
    local lines = {
        "Rex Commands:",
        "",
        "  /model [filter]  Select LLM model; a unique filter match selects directly",
        "  /model refresh   Re-fetch the model list (bypass cache)",
        "  /mode            Select model mode",
        "  /memory          Select conversation-memory window",
        "  /set <k> <v>     Set max_tokens, timeout, or memory",
        "  /run <command>   Run a shell command; output joins conversation memory",
        "  !<command>       Shorthand for /run",
        "  /retry           Resend the last prompt",
        "  /clear           Clear conversation memory",
        "  /copy            Copy the last answer to the clipboard",
        "  /settings        Show current settings",
        "  /context         Show text sent to LLM; /context <prompt> includes prompt",
        "  /help            Show this help",
        "",
        "Type any text and press Ctrl+Enter to send it to Rex.",
        "Normal Enter executes commands in cmd.exe as usual.",
    }
    print_output(table.concat(lines, "\n"))
end

--- /settings — print effective settings
local function cmd_settings()
    local lines = {
        "Rex Settings:",
        "",
        "  Credential: " .. (state_mod.resolve_credential() or "not set"),
        "  Provider:   " .. (state_mod.resolve_provider() or "not set"),
        "  Model:      " .. (state_mod.resolve_model() or "not set"),
        "  Mode:       " .. (state_mod.resolve_mode() or "default"),
        "  Memory:     " .. (state_mod.resolve_memory() or "all"),
        "  Max tokens: " .. tostring(state_mod.resolve_max_tokens()),
        "  Timeout:    " .. tostring(state_mod.resolve_timeout()) .. "s",
    }
    print_output(table.concat(lines, "\n"))
end

--- /context — show the text sent to the LLM
local function cmd_context(preview_prompt)
    local display = turn_mod.format_context_display(preview_prompt)
    print_output(display)
end

--- /clear — reset conversation memory
local function cmd_clear()
    state_mod.clear_history()
    print_output("Conversation cleared.")
end

--- /copy — copy the last answer to the clipboard, without ANSI sequences
local function cmd_copy()
    local text = state_mod.get_last_answer()
    if not text or text == "" then
        print_output("No answer to copy.")
        return
    end
    -- Strip CSI sequences and OSC 8 hyperlink wrappers
    text = text:gsub(ESC .. "%[[0-9;:]*[@-~]", "")
    text = text:gsub(ESC .. "%]8;;.-" .. ESC .. "\\", "")
    text = text:gsub(ESC .. "%]8;;.-\7", "")
    -- Clipboard-friendly line endings
    text = text:gsub("\r?\n", "\r\n")
    local pipe = io.popen("clip", "w")
    if not pipe then
        print_output("Error: cannot launch clip.exe.")
        return
    end
    pipe:write(text)
    pipe:close()
    print_output("Copied last answer to clipboard.")
end

--- /retry — resend the last prompt, dropping it and everything after it
--- from history so the model regenerates from the same state.
local function cmd_retry(rl_buffer)
    local hist = state_mod.get_history()
    local idx = nil
    for i = #hist, 1, -1 do
        if hist[i].role == "user" and
           hist[i].content:sub(1, #RUN_RECORD_PREFIX) ~= RUN_RECORD_PREFIX then
            idx = i
            break
        end
    end
    if not idx then
        print_output("Nothing to retry.")
        return
    end
    local prompt = hist[idx].content
    for i = #hist, idx, -1 do
        hist[i] = nil
    end
    print_output(ESC .. "[2mRetrying: " .. prompt .. ESC .. "[0m")
    state_mod.append_recall("user", prompt)
    process_prompt(prompt, rl_buffer)
end

--- /run <cmd> (or !<cmd>) — execute a shell command directly, no LLM
--- round-trip, and record the transcript into conversation memory so
--- follow-up questions ("why did that fail?") have real context.
local function cmd_run(cmdline, rl_buffer)
    cmdline = cmdline and cmdline:match("^%s*(.-)%s*$") or ""
    if cmdline == "" then
        print_output("Usage: /run <command>   (or !<command>)")
        return
    end

    local parsed = {shell = "cmd", cwd = ".", command = cmdline}
    local result, exec_err = turn_mod.execute_shell_command(parsed, rl_buffer)
    if not result then
        print_output("Error: " .. (exec_err or "command failed"))
        return
    end

    local transcript = turn_mod.format_shell_transcript(cmdline, result)
    if transcript ~= "" then
        print_output(transcript)
    end

    local out = (result.output or ""):match("^(.-)%s*$")
    if #out > 8000 then
        -- Keep the tail; errors usually appear at the end
        out = "...(output truncated)\n" .. out:sub(-8000)
    end

    local record
    if result.injected then
        record = RUN_RECORD_PREFIX .. "\n> " .. cmdline .. "\n(executed in the live session)"
    else
        record = RUN_RECORD_PREFIX .. "\n> " .. cmdline ..
            "\nExit code: " .. tostring(result.exit_code) ..
            (out ~= "" and ("\nOutput:\n" .. out) or "\n(no output)")
    end
    state_mod.add_history("user", record)
    state_mod.append_recall("shell", "> " .. cmdline .. (out ~= "" and ("\n" .. out) or ""))
end

--- /set <key> <value> — adjust settings without editing config.toml
local VALID_MEMORY = {
    none = true, all = true, last_answer = true,
    last_qa = true, last_2_qa = true, last_4_qa = true,
}

local function cmd_set(args)
    local key, value = (args or ""):match("^(%S+)%s+(%S+)")
    if not key then
        print_output("Usage: /set <max_tokens|timeout|memory> <value>")
        return
    end

    if key == "max_tokens" or key == "timeout" then
        local n = tonumber(value)
        if not n or n <= 0 then
            print_output("Error: " .. key .. " must be a positive number.")
            return
        end
        n = math.floor(n)
        if key == "max_tokens" then
            state_mod.set_max_tokens(n)
        else
            state_mod.set_timeout(n)
        end
        value = tostring(n)
    elseif key == "memory" then
        if not VALID_MEMORY[value] then
            print_output("Error: memory must be one of: none, all, last_answer, last_qa, last_2_qa, last_4_qa.")
            return
        end
        state_mod.set_memory(value)
    else
        print_output("Unknown setting: " .. key .. ". Valid: max_tokens, timeout, memory.")
        return
    end

    state_mod.save_current_config()
    print_output(key .. " = " .. value)
end

-- ================================================================
-- Model selector — used by /model and onboarding
-- ================================================================

--- Fetch and merge models from all credentials.
--- Returns items list, lookup table, or nil + error.
local function build_model_selector(force)
    local creds, err = provider_mod.ensure_credentials()
    if not creds then return nil, nil, err end

    local items = {}
    local lookup = {}
    local any_success = false

    for _, cred in ipairs(creds) do
        local models = provider_mod.fetch_models_cached(cred, force)
        if models then
            any_success = true
            for _, m in ipairs(models) do
                local label = m.id .. "  [" .. cred.id .. "]"
                items[#items + 1] = label
                lookup[label] = {
                    id         = m.id,
                    credential = cred.id,
                    provider   = cred.provider,
                }
            end
        end
        -- Continue with other credentials even if one fails
    end

    if not any_success then
        return nil, nil, "Failed to fetch models from all credentials."
    end

    if #items == 0 then
        return nil, nil, "No models available from configured credentials."
    end

    return items, lookup
end

--- /model [filter|refresh] — select model via popup or direct match
local function cmd_model(arg)
    local force = false
    if arg == "refresh" then
        force = true
        arg = nil
    end

    local items, lookup, err = build_model_selector(force)
    if not items then
        print_output("Error: " .. (err or "Cannot build model list."))
        return
    end

    local value
    if arg then
        -- Fuzzy filter: unique match selects directly, several matches
        -- narrow the popup, none reports back.
        local needle = arg:lower()
        local matches = {}
        for _, label in ipairs(items) do
            if label:lower():find(needle, 1, true) then
                matches[#matches + 1] = label
            end
        end
        if #matches == 0 then
            print_output('No model matches "' .. arg .. '".')
            return
        elseif #matches == 1 then
            value = matches[1]
        else
            value = popuplist("Select model (" .. arg .. ")", matches)
        end
    else
        value = popuplist("Select model", items)
    end

    -- Dismissed with Esc: exit silently, no output
    if not value or value == "" then
        return
    end

    local selected = lookup[value]
    if not selected then
        print_output("Error: Selection not found in lookup.")
        return
    end

    -- Update session state (resets mode to default)
    state_mod.set_model(selected.credential, selected.provider, selected.id)

    -- Save to config
    state_mod.save_current_config()

    -- Print confirmation
    local mode = state_mod.resolve_mode()
    print_output("Model: " .. selected.id .. " on " .. selected.provider ..
        " [" .. selected.credential .. "]. Mode: " .. mode .. ".")
end

--- /mode — select mode via popup
local function cmd_mode()
    local provider = state_mod.resolve_provider()
    local model_id = state_mod.resolve_model()

    if not provider or not model_id then
        print_output("No model selected. Use /model first.")
        return
    end

    local modes = state_mod.resolve_modes_for_model(provider, model_id)

    -- Build items: always include "default" plus any modes from modes.json
    local items = {"default"}
    local mode_lookup = {["default"] = "default"}

    for _, m in ipairs(modes) do
        if m.label and m.id then
            items[#items + 1] = m.label
            mode_lookup[m.label] = m.id
        end
    end

    if #items <= 1 then
        print_output("Only default mode available for " .. model_id .. ".")
        return
    end

    local value = popuplist("Select mode", items)
    -- Dismissed with Esc: exit silently, no output
    if not value or value == "" then
        return
    end

    local mode_id = mode_lookup[value]
    if not mode_id then
        print_output("Error: Mode not found.")
        return
    end

    -- Set mode
    state_mod.set_mode(mode_id)
    state_mod.save_current_config()
    print_output("Mode: " .. value .. ".")
end

--- /memory — select memory window via popup
local function cmd_memory()
    local items = {
        "none",
        "all",
        "last answer",
        "last question and answer",
        "last 2 questions and answers",
        "last 4 questions and answers",
    }

    local label_to_value = {
        ["none"]                          = "none",
        ["all"]                           = "all",
        ["last answer"]                   = "last_answer",
        ["last question and answer"]      = "last_qa",
        ["last 2 questions and answers"]  = "last_2_qa",
        ["last 4 questions and answers"]  = "last_4_qa",
    }

    local value = popuplist("Select memory window", items)
    -- Dismissed with Esc: exit silently, no output
    if not value or value == "" then
        return
    end

    local mem_value = label_to_value[value]
    if not mem_value then
        print_output("Error: Unknown memory option.")
        return
    end

    state_mod.set_memory(mem_value)
    state_mod.save_current_config()
    print_output("Memory: " .. value .. ".")
end

-- ================================================================
-- Onboarding flow
-- ================================================================

--- Run the onboarding sequence. Returns true on success, false on cancel/error.
local function run_onboarding()
    -- Step 1: Parse credentials
    local creds, cred_err = provider_mod.ensure_credentials()
    if not creds then
        print_output("Error: " .. (cred_err or "No valid credentials."))
        print_output("Set REX_API_KEY and try again.")
        return false
    end

    -- Step 2: Fetch models
    local items, lookup, fetch_err = build_model_selector()
    if not items then
        print_output("Error: " .. (fetch_err or "Cannot fetch models."))
        return false
    end

    -- Step 3: Model selection popup. Unlike the slash commands, a silent
    -- exit here would swallow the typed prompt without explanation.
    local value = popuplist("Select model", items)
    if not value or value == "" then
        print_output(ESC .. "[2mCancelled — prompt not sent." .. ESC .. "[0m")
        return false
    end

    local selected = lookup[value]
    if not selected then
        print_output("Error: Selection not found.")
        return false
    end

    -- Step 4: Set tentative state (a broken selection will fail at request time)
    state_mod.set_model(selected.credential, selected.provider, selected.id)

    -- Step 5: Mode selection
    local resolved_mode = "default"
    local modes = state_mod.resolve_modes_for_model(selected.provider, selected.id)

    if #modes > 0 then
        -- Build mode items with default
        local mode_items = {"default"}
        local ml = {["default"] = "default"}
        for _, m in ipairs(modes) do
            if m.label and m.id then
                mode_items[#mode_items + 1] = m.label
                ml[m.label] = m.id
            end
        end

        if #mode_items > 1 then
            local mode_value = popuplist("Select mode", mode_items)
            if mode_value and mode_value ~= "" then
                local mid = ml[mode_value]
                if mid then
                    state_mod.set_mode(mid)
                    resolved_mode = mid
                end
            end
            -- Escape from mode selection just uses default, not a cancel of onboarding
        end
    end

    -- Step 6: Save config
    local ok, write_err = state_mod.save_current_config()
    if not ok then
        print_output("Warning: Could not save config: " .. (write_err or "unknown"))
    end

    -- Step 7: Print confirmation (always includes resolved mode)
    print_output("Configured " .. selected.id .. " on " .. selected.provider ..
        " [" .. selected.credential .. "]. Mode: " .. resolved_mode .. ".")

    return true
end

-- ================================================================
-- rex_submit — the global function bound to Ctrl+Enter
-- ================================================================

local function rex_submit_impl(rl_buffer)
    local line = rl_buffer:getbuffer()
    local trimmed = line:match("^%s*(.-)%s*$")

    -- Ignore empty input
    if not trimmed or trimmed == "" then return end

    -- Determine the execution path
    local model_arg = trimmed:match("^/model%s+(.+)$")
    local is_popup_only = (trimmed == "/model") or (model_arg ~= nil)
        or (trimmed == "/mode") or (trimmed == "/memory")
    local is_command = trimmed:match("^[/!]") ~= nil
    -- Commands never trigger onboarding: /help, /settings, etc. must work
    -- (or fail with their own message) before a model is configured.
    local needs_onboarding = (not is_command) and (not state_mod.resolve_model())

    if not is_popup_only and not needs_onboarding then
        -- ============================================================
        -- PRINT PATH: normal prompt, non-popup commands, errors
        -- ============================================================
        -- begin_output() preserves the typed text on screen, then
        -- add-history records it in shell history and clears the buffer.
        begin_output()
        rl.invokecommand("add-history")

        -- Persist the prompt durably right away; conversation history is
        -- recorded in process_prompt after the request is built.
        if not is_command then
            state_mod.append_recall("user", trimmed)
        end

        -- Dispatch
        if trimmed == "/help" then
            cmd_help()
        elseif trimmed == "/settings" then
            cmd_settings()
        elseif trimmed == "/context" then
            cmd_context()
        elseif trimmed:match("^/context%s+") then
            cmd_context(trimmed:match("^/context%s+(.+)$"))
        elseif trimmed == "/clear" then
            cmd_clear()
        elseif trimmed == "/copy" then
            cmd_copy()
        elseif trimmed == "/retry" then
            cmd_retry(rl_buffer)
        elseif trimmed == "/run" or trimmed:match("^/run%s") then
            cmd_run(trimmed:match("^/run%s+(.+)$"), rl_buffer)
        elseif trimmed:match("^!") then
            cmd_run(trimmed:match("^!%s*(.*)$"), rl_buffer)
        elseif trimmed == "/set" or trimmed:match("^/set%s") then
            cmd_set(trimmed:match("^/set%s+(.+)$"))
        elseif trimmed:match("^/") then
            -- Unrecognized slash command
            print_output("Unknown command: " .. trimmed .. ". Type /help for available commands.")
        else
            process_prompt(trimmed, rl_buffer)
        end

    elseif is_popup_only then
        -- ============================================================
        -- POPUP-ONLY PATH: /model [arg], /mode, /memory
        -- ============================================================
        -- The popup interacts with an intact edit line, so nothing is
        -- flushed up front. The handler's first print (confirmation,
        -- cancellation, or error) lazily calls begin_output(), which ends
        -- the prompt line while the buffer still holds the typed command —
        -- preserving it on screen. Only then does add-history record the
        -- line and clear the buffer.
        if trimmed == "/model" or model_arg then
            cmd_model(model_arg)
        elseif trimmed == "/mode" then
            cmd_mode()
        elseif trimmed == "/memory" then
            cmd_memory()
        end

        begin_output()
        rl.invokecommand("add-history")

    else
        -- ============================================================
        -- POPUP-THEN-PRINT PATH: onboarding triggered by a normal prompt
        -- ============================================================
        -- Do NOT call beginoutput() or add-history yet.
        -- Keep rl_buffer intact through popup interaction.
        local saved_line = trimmed

        -- Persist the prompt durably before onboarding can fail.
        state_mod.append_recall("user", saved_line)

        -- Run onboarding. Its prints lazily trigger begin_output(), so
        -- messages land on a fresh line below the typed prompt.
        local onboarding_ok = run_onboarding()

        -- Flush: ensure the prompt line is ended even if onboarding
        -- printed nothing, then record the line in shell history (which
        -- also clears the edit buffer).
        begin_output()
        rl.invokecommand("add-history")

        if onboarding_ok then
            -- Process the original prompt
            process_prompt(saved_line, rl_buffer)
        else
            -- Onboarding failed or was cancelled — record in recall
            state_mod.append_recall("cancel", "Onboarding cancelled or failed.")
        end
    end
end

-- Must be global for Clink's luafunc: binding to find it.
-- Wrapped so an internal error prints one line instead of surfacing a raw
-- Lua traceback through Clink with the input line in an odd state.
function rex_submit(rl_buffer)
    active_rl_buffer = rl_buffer
    output_begun = false
    local ok, err = xpcall(function()
        rex_submit_impl(rl_buffer)
    end, debug.traceback)
    if not ok then
        local first_line = tostring(err):match("^[^\r\n]*") or "unknown error"
        print_output("Rex internal error: " .. first_line)
        pcall(state_mod.append_recall, "error", tostring(err))
    end
    active_rl_buffer = nil
end

-- ================================================================
-- Key bindings
-- ================================================================

-- Primary: Clink xterm modified-key format (modifier 5 = Ctrl, keycode 13 = Enter)
rl.setbinding([["\e[27;5;13~"]], [["luafunc:rex_submit"]])
-- Fallback: CSI u encoding for terminals that send it natively
rl.setbinding([["\e[13;5u"]], [["luafunc:rex_submit"]])
