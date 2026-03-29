-- rex.lua -- Clink entrypoint: key binding, rl_buffer handling, slash-command
-- dispatch, popup orchestration, onboarding flow.
--
-- Owns: rex_submit (global), key bindings, readline buffer management,
-- popup orchestration for /model, /mode, /memory, onboarding, slash-command
-- dispatch, LLM request orchestration.
-- Does NOT own: durable state, HTTP transport, prompt framing, ANSI rendering.

-- ================================================================
-- Module loading -- explicit path via dofile() to avoid collisions
-- with clink-completions or other scripts that ship their own json.lua.
-- ================================================================

local script_dir = debug.getinfo(1, "S").source:match("@?(.+[\\/])")

local json         = dofile(script_dir .. "json.lua")
local state_mod    = dofile(script_dir .. "rex_state.lua")
local turn_mod     = dofile(script_dir .. "rex_turn.lua")
local provider_mod = dofile(script_dir .. "rex_provider.lua")

-- Initialize modules with their dependencies
state_mod.init(json, script_dir)
turn_mod.init(state_mod)
provider_mod.init(json, state_mod)

-- ================================================================
-- Deferred history helpers
-- ================================================================

--- Write a line to session-scoped Clink history via `clink history -s`.
--- Used on the deferred onboarding path where rl.invokecommand("add-history")
--- cannot be called because the buffer must stay intact through popup interaction.
local function deferred_history_add(line)
    if not line or line == "" then return end
    local clink_exe = os.getenv("CLINK_EXE")
    if not clink_exe or clink_exe == "" then
        clink_exe = "clink"
    end
    local session = clink.getsession and clink.getsession() or ""
    local escaped = line:gsub('"', '""')
    local cmd = '"' .. clink_exe .. '" history -s'
    if session and session ~= "" then
        cmd = cmd .. " --session " .. session
    end
    cmd = cmd .. ' -- "' .. escaped .. '"'
    os.execute(cmd .. " >nul 2>&1")
end

--- Flush the deferred buffer: call beginoutput to preserve the typed text
--- on screen, then clear the rl_buffer, then write the saved line to history.
local function flush_deferred(rl_buffer, saved_line)
    rl_buffer:beginoutput()
    rl_buffer:remove(1, rl_buffer:getlength() + 1)
    deferred_history_add(saved_line)
end

-- ================================================================
-- Slash-command handlers
-- ================================================================

local function cmd_help()
    clink.print("Rex commands (submit via Ctrl+Enter):")
    clink.print("  /model    Select LLM model")
    clink.print("  /mode     Select model mode")
    clink.print("  /memory   Select conversation-memory window")
    clink.print("  /context  Show current context sent to the LLM")
    clink.print("  /help     List commands")
end

local function cmd_context()
    local shell_auth = false
    local sys = turn_mod.build_system_prompt(shell_auth)
    clink.print("--- System Prompt ---")
    clink.print(sys)
    clink.print("")

    local mem = state_mod.effective_memory()
    local hist = state_mod.get_history()
    local mem_msgs = state_mod.get_memory_messages()

    clink.print("--- Memory Window: " .. mem .. " (" .. #mem_msgs .. " messages from "
        .. #hist .. " stored) ---")
    if #mem_msgs > 0 then
        for i, msg in ipairs(mem_msgs) do
            local preview = msg.content
            if #preview > 100 then preview = preview:sub(1, 100) .. "..." end
            clink.print("  [" .. i .. "] " .. msg.role .. ": " .. preview)
        end
    end

    clink.print("")
    clink.print("Model: " .. (state_mod.effective_model() or "not set"))
    clink.print("Provider: " .. (state_mod.effective_provider() or "not set"))
    clink.print("Mode: " .. state_mod.effective_mode())
    clink.print("Memory: " .. mem)
    clink.print("Max tokens: " .. state_mod.effective_max_tokens())
end

-- ================================================================
-- Model selector popup
-- ================================================================

local function open_model_selector()
    local creds, cred_err = provider_mod.ensure_credentials()
    if not creds then
        return nil, cred_err
    end

    local merged, fetch_err = provider_mod.fetch_all_models()
    if not merged or #merged == 0 then
        return nil, fetch_err or "No models available."
    end

    -- Build popup items with a lookup table mapping labels back to metadata
    local items = {}
    local lookup = {}
    for _, m in ipairs(merged) do
        local label = m.id .. "  [" .. m.credential .. "]"
        items[#items + 1] = label
        lookup[label] = m
    end

    local value = clink.popuplist("Select model", items)
    if not value or value == "" then
        return nil  -- cancelled
    end

    local selected = lookup[value]
    if not selected then
        return nil, "Selection not found in model list."
    end

    return selected
end

-- ================================================================
-- Mode selector popup
-- ================================================================

local function open_mode_selector(provider, model_id)
    local modes = state_mod.resolve_modes(provider, model_id)
    if #modes <= 1 then
        return {id = "default", label = "Default", params = {}}, "only_default"
    end

    local items = {}
    local lookup = {}
    for _, m in ipairs(modes) do
        items[#items + 1] = m.label
        lookup[m.label] = m
    end

    local value = clink.popuplist("Select mode", items)
    if not value or value == "" then
        return nil  -- cancelled
    end

    local selected = lookup[value]
    if not selected then
        return nil, "Selection not found in mode list."
    end

    return selected
end

-- ================================================================
-- Memory selector popup
-- ================================================================

-- Visible labels -> internal config values
local memory_options = {
    {label = "none",                           value = "none"},
    {label = "all",                            value = "all"},
    {label = "last answer",                    value = "last_answer"},
    {label = "last question and answer",       value = "last_qa"},
    {label = "last 2 questions and answers",   value = "last_2_qa"},
    {label = "last 4 questions and answers",   value = "last_4_qa"},
}

local function open_memory_selector()
    local items = {}
    local lookup = {}
    for _, opt in ipairs(memory_options) do
        items[#items + 1] = opt.label
        lookup[opt.label] = opt.value
    end

    local value = clink.popuplist("Select memory window", items)
    if not value or value == "" then
        return nil  -- cancelled
    end

    local internal = lookup[value]
    if not internal then
        return nil, "Selection not found."
    end

    return internal, value
end

-- ================================================================
-- /model command
-- ================================================================

local function handle_model_command(rl_buffer)
    local selected, err = open_model_selector()
    if not selected then
        rl_buffer:beginoutput()
        if err then
            clink.print(err)
        else
            clink.print("Cancelled.")
        end
        return
    end

    -- Validated: update session state (clears mode to default)
    state_mod.set_model(selected.credential, selected.provider, selected.id)

    rl_buffer:beginoutput()
    clink.print("Model: " .. selected.id .. " [" .. selected.credential .. "]. Mode: default.")
end

-- ================================================================
-- /mode command
-- ================================================================

local function handle_mode_command(rl_buffer)
    local provider = state_mod.effective_provider()
    local model_id = state_mod.effective_model()

    if not provider or not model_id then
        rl_buffer:beginoutput()
        clink.print("No model selected. Use /model first.")
        return
    end

    local selected, info = open_mode_selector(provider, model_id)
    if info == "only_default" then
        rl_buffer:beginoutput()
        clink.print("Only the default mode is available for " .. model_id .. ".")
        return
    end
    if not selected then
        rl_buffer:beginoutput()
        if info then
            clink.print(info)
        else
            clink.print("Cancelled.")
        end
        return
    end

    -- Validated: update session mode
    state_mod.set_mode(selected.id)

    rl_buffer:beginoutput()
    clink.print("Mode: " .. selected.label .. " (" .. selected.id .. ") for " .. model_id .. ".")
end

-- ================================================================
-- /memory command
-- ================================================================

local function handle_memory_command(rl_buffer)
    local internal, label = open_memory_selector()
    if not internal then
        rl_buffer:beginoutput()
        if label then
            clink.print(label)
        else
            clink.print("Cancelled.")
        end
        return
    end

    -- Update session state
    state_mod.set_memory(internal)

    -- Persist to config file
    state_mod.load_config()
    local cfg = state_mod.get_state().config or {}
    cfg.memory = internal
    state_mod.save_config(cfg)

    rl_buffer:beginoutput()
    clink.print("Memory: " .. label .. ".")
end

-- ================================================================
-- Onboarding flow
-- ================================================================

--- Run the interactive onboarding sequence.
--- Returns (true, confirmation_message) on success,
---         (false, error_or_nil) on failure/cancellation.
--- rl_buffer is kept intact during popups; the caller handles flushing.
local function run_onboarding()
    -- Step 1: Parse credentials from live REX_API_KEY
    local creds, cred_err = provider_mod.parse_credentials()
    if not creds then
        return false, cred_err or "No valid API credentials. Set REX_API_KEY."
    end

    -- Step 2: Fetch models from all credentials
    local merged, fetch_err = provider_mod.fetch_all_models()
    if not merged or #merged == 0 then
        return false, fetch_err or "Could not fetch any models."
    end

    -- Step 3: Model selection popup
    local items = {}
    local lookup = {}
    for _, m in ipairs(merged) do
        local label = m.id .. "  [" .. m.credential .. "]"
        items[#items + 1] = label
        lookup[label] = m
    end

    local value = clink.popuplist("Select model", items)
    if not value or value == "" then
        return false, nil  -- user cancelled
    end

    local selected = lookup[value]
    if not selected then
        return false, "Selection not found."
    end

    -- Step 4: Validated model (it exists in the fetched list)
    state_mod.set_model(selected.credential, selected.provider, selected.id)

    -- Step 5: Mode selection (if modes available beyond default)
    local mode_id = "default"
    local modes = state_mod.resolve_modes(selected.provider, selected.id)
    if #modes > 1 then
        local mode_items = {}
        local mode_lookup = {}
        for _, m in ipairs(modes) do
            mode_items[#mode_items + 1] = m.label
            mode_lookup[m.label] = m
        end

        local mode_value = clink.popuplist("Select mode", mode_items)
        if mode_value and mode_value ~= "" then
            local mode_selected = mode_lookup[mode_value]
            if mode_selected then
                mode_id = mode_selected.id
            end
        end
        -- If mode cancelled, fall through with default
    end

    -- Step 6: Set validated mode
    state_mod.set_mode(mode_id)

    -- Step 7: Save config with validated settings only
    local cfg = {
        credential = selected.credential,
        provider   = selected.provider,
        model      = selected.id,
        mode       = mode_id,
    }
    state_mod.save_config(cfg)

    -- Step 8: Confirmation (always includes resolved mode, even if default)
    local confirmation = "Configured " .. selected.id
        .. " on " .. selected.provider
        .. ". Mode: " .. mode_id .. "."

    return true, confirmation
end

-- ================================================================
-- LLM request execution
-- ================================================================

--- Send a prompt to the LLM and handle the response.
--- The caller is responsible for writing the user-side history and recall
--- entry BEFORE calling this function, so that the user prompt is durably
--- persisted before the network call can fail.
local function send_to_llm(prompt)
    -- Determine shell authorization for this turn
    local shell_authorized = turn_mod.is_shell_authorized(prompt)

    -- Build system prompt
    local system_prompt = turn_mod.build_system_prompt(shell_authorized)

    -- Build messages: memory window + framed current prompt
    local messages = state_mod.get_memory_messages()

    -- Frame the current prompt with turn boundary marker
    local framed = turn_mod.frame_user_prompt(prompt)
    messages[#messages + 1] = {role = "user", content = framed}

    -- Send request
    local mode_id = state_mod.effective_mode()
    local response, err, err_type = provider_mod.send_request(system_prompt, messages, mode_id)

    if not response then
        local err_text
        if err_type == "transient" then
            local model_id = state_mod.effective_model() or "unknown model"
            local provider = state_mod.effective_provider() or "Provider"
            err_text = provider .. " is temporarily overloaded for " .. model_id
                .. ". Try again in a moment."
        else
            err_text = "Error: " .. (err or "Unknown error")
        end
        clink.print(err_text)

        -- Record error outcome immediately
        state_mod.add_history("assistant", err_text)
        state_mod.recall_append("error", err_text)
        return
    end

    -- Check for shell-command protocol before post-processing.
    -- Only execute on turns where the user explicitly requested shell activity.
    if shell_authorized then
        local cmd_info = turn_mod.parse_shell_command(response)
        if cmd_info then
            -- Execute the shell command
            local exec_result = turn_mod.execute_shell_command(cmd_info)

            -- Apply session-mutating effects (cd, set) to the live session
            turn_mod.apply_session_effects(exec_result)

            -- Format and print transcript
            local transcript = turn_mod.format_shell_transcript(cmd_info, exec_result)
            clink.print(transcript)

            -- Store assistant side in history and recall
            state_mod.add_history("assistant", transcript)
            state_mod.recall_append("shell", transcript)
            return
        end
    end

    -- Process and print normal response
    local clean = response
    if not shell_authorized then
        -- Strip any erroneously included shell-command blocks on non-shell turns
        clean = turn_mod.strip_shell_command(clean)
    end

    local output = turn_mod.process_response(clean)
    if not output or output == "" then
        -- Host-side post-processing emptied the response; this is a local
        -- empty-output condition, not a provider-level "missing content" error.
        output = "(Empty response from model.)"
    end
    clink.print(output)

    -- Store assistant side in history and recall
    state_mod.add_history("assistant", response)
    state_mod.recall_append("assistant", response)
end

-- ================================================================
-- Main entry point -- rex_submit (must be global for luafunc: binding)
-- ================================================================

function rex_submit(rl_buffer)
    local line = rl_buffer:getbuffer()
    local trimmed = line:match("^%s*(.-)%s*$")

    -- Ignore empty input
    if not trimmed or trimmed == "" then return end

    -- Determine the execution path before touching the buffer
    local is_slash = trimmed:sub(1, 1) == "/"
    local is_popup_only = (trimmed == "/model") or (trimmed == "/mode") or (trimmed == "/memory")
    local needs_onboarding = not state_mod.has_model()

    -- ----------------------------------------------------------------
    -- Path selection: choose the correct history and clearing strategy
    -- ----------------------------------------------------------------

    if not is_popup_only and not needs_onboarding then
        -- PRINT PATH: beginoutput first (preserves typed text on screen),
        -- then add-history (appends to shell history and clears edit line).
        rl_buffer:beginoutput()
        rl.invokecommand("add-history")

    elseif is_popup_only then
        -- POPUP-ONLY PATH: add-history records the slash command and clears
        -- the edit line without beginoutput, so no phantom prompt appears
        -- before the popup.
        rl.invokecommand("add-history")

    else
        -- POPUP-THEN-PRINT PATH (onboarding): keep rl_buffer intact through
        -- popup interaction.  Save the trimmed line separately; the caller
        -- will flush with beginoutput + remove + deferred history later.
    end

    -- ----------------------------------------------------------------
    -- Slash command dispatch
    -- ----------------------------------------------------------------

    if is_slash then
        local cmd = trimmed:lower()

        if cmd == "/help" then
            cmd_help()
        elseif cmd == "/context" then
            cmd_context()
        elseif cmd == "/model" then
            handle_model_command(rl_buffer)
        elseif cmd == "/mode" then
            handle_mode_command(rl_buffer)
        elseif cmd == "/memory" then
            handle_memory_command(rl_buffer)
        else
            clink.print("Unknown command: " .. trimmed .. ". Type /help for available commands.")
        end
        return
    end

    -- ----------------------------------------------------------------
    -- Onboarding (if needed)
    -- ----------------------------------------------------------------

    if needs_onboarding then
        -- Append user entry to recall immediately so it is durably persisted
        -- before onboarding popups or network calls can fail.
        state_mod.recall_append("user", trimmed)

        local ok, msg = run_onboarding()

        -- Flush deferred buffer: preserve typed text, clear buffer, write
        -- the saved line to session-scoped Clink history.
        flush_deferred(rl_buffer, trimmed)

        if not ok then
            if msg then
                clink.print(msg)
                state_mod.recall_append("cancel", msg)
            else
                clink.print("Cancelled.")
                state_mod.recall_append("cancel", "Onboarding cancelled by user.")
            end
            return
        end

        -- Print onboarding confirmation (always includes the resolved mode)
        clink.print(msg)
        clink.print("")

        -- Fall through to process the original prompt
    end

    -- ----------------------------------------------------------------
    -- Send prompt to LLM
    -- ----------------------------------------------------------------

    -- Write user-side history and recall BEFORE the LLM call so the
    -- prompt is durably persisted even if the network call fails.
    -- On the onboarding path, recall was already written above.
    if not needs_onboarding then
        state_mod.recall_append("user", trimmed)
    end
    state_mod.add_history("user", trimmed)

    send_to_llm(trimmed)
end

-- ================================================================
-- Key binding registration
-- ================================================================

-- Primary: Clink's xterm modified-key format (modifier 5 = Ctrl, keycode 13 = Enter)
rl.setbinding([["\e[27;5;13~"]], [["luafunc:rex_submit"]])
-- Fallback: CSI u encoding for terminals that send it natively
rl.setbinding([["\e[13;5u"]], [["luafunc:rex_submit"]])
