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
local json         = dofile(script_dir .. "json.lua")
local state_mod    = dofile(script_dir .. "rex_state.lua")
local turn_mod     = dofile(script_dir .. "rex_turn.lua")
local provider_mod = dofile(script_dir .. "rex_provider.lua")

-- Initialize modules with shared dependencies
state_mod.set_script_dir(script_dir)
provider_mod.init(json, state_mod)
turn_mod.init(json, state_mod, provider_mod)

-- Load modes.json and skills at startup
state_mod.load_modes(json)
state_mod.load_skills()
state_mod.load_config()

-- ================================================================
-- Session-scoped history append helper
-- ================================================================

--- Append a line to Clink history using the session-scoped fallback.
--- Used on the deferred onboarding path where rl.invokecommand("add-history")
--- cannot be called because the buffer must stay intact through popup interaction.
local function deferred_history_add(line)
    if not line or line == "" then return end
    -- Resolve clink executable path
    local clink_exe = os.getenv("CLINK_EXE")
    if not clink_exe or clink_exe == "" then
        -- Fallback: try "clink" on PATH
        clink_exe = "clink"
    end
    -- Get the current session ID
    local session_id = ""
    if clink and clink.getsession then
        session_id = clink.getsession() or ""
    end
    -- Escape the line for cmd shell
    local escaped = line:gsub('"', '""')
    local cmd
    if session_id ~= "" then
        cmd = '"' .. clink_exe .. '" history -s --session ' .. session_id .. ' add "' .. escaped .. '"'
    else
        cmd = '"' .. clink_exe .. '" history add "' .. escaped .. '"'
    end
    os.execute(cmd .. " 2>nul")
end

-- ================================================================
-- Helpers
-- ================================================================

local function print_output(text)
    if clink and clink.print then
        clink.print(text)
    else
        print(text)
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
        "  /model     Select LLM model",
        "  /mode      Select model mode",
        "  /memory    Select conversation-memory window",
        "  /settings  Show current settings",
        "  /context   Show text sent to LLM; /context <prompt> includes prompt",
        "  /help      Show this help",
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

-- ================================================================
-- Model selector — used by /model and onboarding
-- ================================================================

--- Fetch and merge models from all credentials.
--- Returns items list, lookup table, or nil + error.
local function build_model_selector()
    local creds, err = provider_mod.ensure_credentials()
    if not creds then return nil, nil, err end

    local items = {}
    local lookup = {}
    local any_success = false

    for _, cred in ipairs(creds) do
        local models, fetch_err = provider_mod.fetch_models_cached(cred)
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

--- /model — select model via popup
local function cmd_model()
    local items, lookup, err = build_model_selector()
    if not items then
        print_output("Error: " .. (err or "Cannot build model list."))
        return
    end

    local value = clink.popuplist("Select model", items)
    if not value or value == "" then
        -- Popup-only path: beginoutput before printing cancellation
        if clink and clink.print then
            -- Already past popup, safe to print
        end
        print_output("Cancelled.")
        return
    end

    local selected = lookup[value]
    if not selected then
        print_output("Error: Selection not found in lookup.")
        return
    end

    -- Update session state (clears mode to default)
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

    local value = clink.popuplist("Select mode", items)
    if not value or value == "" then
        print_output("Cancelled.")
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

    local value = clink.popuplist("Select memory window", items)
    if not value or value == "" then
        print_output("Cancelled.")
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

    -- Step 3: Model selection popup
    local value = clink.popuplist("Select model", items)
    if not value or value == "" then
        print_output("Cancelled.")
        return false
    end

    local selected = lookup[value]
    if not selected then
        print_output("Error: Selection not found.")
        return false
    end

    -- Step 4: Validate model selection (skip full validation for speed; will fail at request time if broken)
    -- Set tentative state
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
            local mode_value = clink.popuplist("Select mode", mode_items)
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

    -- Step 7: Save config
    local ok, write_err = state_mod.save_current_config()
    if not ok then
        print_output("Warning: Could not save config: " .. (write_err or "unknown"))
    end

    -- Step 8: Print confirmation (always includes resolved mode)
    print_output("Configured " .. selected.id .. " on " .. selected.provider ..
        " [" .. selected.credential .. "]. Mode: " .. resolved_mode .. ".")

    return true
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

    -- Send request
    local raw_text, send_err = provider_mod.send_request(system_prompt, messages, {})
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

    -- Record in history and recall
    if shell_cmd then
        -- Shell transcript
        local record = processed or "(shell command executed)"
        state_mod.add_history("assistant", record)
        state_mod.append_recall("shell", record)
    else
        -- Normal response
        local record = processed or raw_text
        state_mod.add_history("assistant", record)
        state_mod.append_recall("assistant", record)
    end
end

-- ================================================================
-- rex_submit — the global function bound to Ctrl+Enter
-- ================================================================

-- Must be global for Clink's luafunc: binding to find it.
function rex_submit(rl_buffer)
    local line = rl_buffer:getbuffer()
    local trimmed = line:match("^%s*(.-)%s*$")

    -- Ignore empty input
    if not trimmed or trimmed == "" then return end

    -- Determine the execution path
    local is_popup_only = (trimmed == "/model") or (trimmed == "/mode") or (trimmed == "/memory")
    local needs_onboarding = not state_mod.resolve_model()

    if not is_popup_only and not needs_onboarding then
        -- ============================================================
        -- PRINT PATH: normal prompt, /help, /settings, /context, errors
        -- ============================================================
        -- beginoutput() preserves the typed text on screen, then
        -- add-history records it in shell history and clears the buffer.
        rl_buffer:beginoutput()
        rl.invokecommand("add-history")

        -- Record user entry in history and recall immediately
        if not trimmed:match("^/") then
            state_mod.add_history("user", trimmed)
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
            local preview_prompt = trimmed:match("^/context%s+(.+)$")
            cmd_context(preview_prompt)
        elseif trimmed:match("^/") then
            -- Unrecognized slash command
            print_output("Unknown command: " .. trimmed .. ". Type /help for available commands.")
        else
            process_prompt(trimmed, rl_buffer)
        end

    elseif is_popup_only then
        -- ============================================================
        -- POPUP-ONLY PATH: /model, /mode, /memory
        -- ============================================================
        -- add-history without beginoutput() to avoid phantom prompt.
        rl.invokecommand("add-history")

        -- Run the popup command. Confirmation printing happens inside
        -- each handler; they call beginoutput() before their first print
        -- implicitly through clink.print().
        if trimmed == "/model" then
            cmd_model()
        elseif trimmed == "/mode" then
            cmd_mode()
        elseif trimmed == "/memory" then
            cmd_memory()
        end

    else
        -- ============================================================
        -- POPUP-THEN-PRINT PATH: onboarding triggered by a normal prompt
        -- ============================================================
        -- Do NOT call beginoutput() or add-history yet.
        -- Keep rl_buffer intact through popup interaction.
        -- Save the trimmed line for deferred history append.
        local saved_line = trimmed

        -- Record user entry to recall immediately — before onboarding
        -- can fail, so the prompt is durably persisted.
        state_mod.add_history("user", saved_line)
        state_mod.append_recall("user", saved_line)

        -- Run onboarding
        local onboarding_ok = run_onboarding()

        -- Now flush: beginoutput() preserves the original prompt on screen,
        -- then remove() clears the edit buffer for the next prompt.
        rl_buffer:beginoutput()
        rl_buffer:remove(1, rl_buffer:getlength() + 1)

        -- Append the saved line to shell history via session-scoped fallback
        deferred_history_add(saved_line)

        if onboarding_ok then
            -- Process the original prompt
            process_prompt(saved_line, rl_buffer)
        else
            -- Onboarding failed or was cancelled — record in recall
            state_mod.append_recall("cancel", "Onboarding cancelled or failed.")
        end
    end
end

-- ================================================================
-- Key bindings
-- ================================================================

-- Primary: Clink xterm modified-key format (modifier 5 = Ctrl, keycode 13 = Enter)
rl.setbinding([["\e[27;5;13~"]], [["luafunc:rex_submit"]])
-- Fallback: CSI u encoding for terminals that send it natively
rl.setbinding([["\e[13;5u"]], [["luafunc:rex_submit"]])
