-- rex_state.lua — Durable/session state, config I/O, recall-session files,
-- modes.json + skills loading, and effective-setting resolution.
--
-- Owns: shared state table, config parsing/writing, recall-session file
-- lifecycle, modes.json resolution, skills loading, capability lookup,
-- and effective setting resolution.
--
-- Does NOT own: turn-scoped prompt framing, shell-command protocol,
-- ANSI rendering, or response post-processing (those belong in rex_turn.lua).

local M = {}

-- ================================================================
-- Shared state — single session-scoped table
-- ================================================================

local state = {
    credential    = nil,  -- selected credential ID
    provider      = nil,  -- selected provider
    model         = nil,  -- selected model ID
    mode          = nil,  -- selected mode ID
    memory        = nil,  -- conversation-memory policy override
    history       = {},   -- conversation message history [{role, content}]
    session_path  = nil,  -- path of current recall session file
    session_date  = nil,  -- YYYYMMDD date stamp
    session_index = nil,  -- daily 1-based recall index
    credentials   = nil,  -- parsed credential entries (cache of REX_API_KEY)
    models        = nil,  -- cached model lists keyed by credential ID
    config        = nil,  -- parsed config file contents
    modes_data    = nil,  -- parsed modes.json contents
    skills_text   = nil,  -- loaded rex_skills.md contents
    system_text   = nil,  -- loaded rex_system.md contents
    -- Track whether recall session has been allocated for this instance
    session_allocated = false,
    -- Track web-search rejections: {[provider..credential..model] = true}
    web_search_rejected = {},
}

function M.get_state()
    return state
end

-- ================================================================
-- Path helpers
-- ================================================================

local script_dir = nil

function M.set_script_dir(dir)
    script_dir = dir
end

function M.get_script_dir()
    return script_dir
end

-- XDG config home, defaulting to %USERPROFILE%/.config
local function get_xdg_config_home()
    local xdg = os.getenv("XDG_CONFIG_HOME")
    if xdg and xdg ~= "" then return xdg end
    local home = os.getenv("USERPROFILE")
    if home and home ~= "" then return home .. "/.config" end
    return nil
end

function M.get_config_dir()
    local base = get_xdg_config_home()
    if not base then return nil end
    return base .. "/rex"
end

function M.get_config_path()
    local dir = M.get_config_dir()
    if not dir then return nil end
    return dir .. "/config.toml"
end

function M.get_recall_dir()
    local dir = M.get_config_dir()
    if not dir then return nil end
    return dir .. "/recall"
end

-- ================================================================
-- Config parsing — simple key = value with # comments
-- ================================================================

local function parse_config_line(line)
    -- Skip comments and blank lines
    if not line or line:match("^%s*#") or line:match("^%s*$") then
        return nil, nil
    end
    local key, value = line:match("^%s*(%w+)%s*=%s*(.-)%s*$")
    if key and value then
        -- Strip surrounding quotes
        local unquoted = value:match('^"(.*)"$') or value:match("^'(.*)'$")
        if unquoted then value = unquoted end
        return key, value
    end
    return nil, nil
end

function M.load_config()
    local path = M.get_config_path()
    if not path then return nil end
    local f = io.open(path, "r")
    if not f then return nil end
    local cfg = {}
    for line in f:lines() do
        local k, v = parse_config_line(line)
        if k then
            -- Convert integer fields
            if k == "max_tokens" or k == "timeout" then
                local n = tonumber(v)
                if n then v = n end
            end
            cfg[k] = v
        end
    end
    f:close()
    state.config = cfg
    return cfg
end

function M.get_config()
    if not state.config then
        M.load_config()
    end
    return state.config
end

-- ================================================================
-- Config writing
-- ================================================================

local function ensure_dir(path)
    -- Use mkdir -p equivalent on Windows
    os.execute('mkdir "' .. path:gsub("/", "\\") .. '" 2>nul')
end

function M.write_config(settings)
    local dir = M.get_config_dir()
    if not dir then return false, "Cannot determine config directory" end
    ensure_dir(dir)
    local path = M.get_config_path()
    if not path then return false, "Cannot determine config path" end

    local installed_at = script_dir or "unknown"
    local skills_path = script_dir and (script_dir .. "rex_skills.md") or "unknown"
    local modes_path = script_dir and (script_dir .. "modes.json") or "unknown"

    local lines = {
        "# Rex - Clink AI Agent Plugin",
        "#",
        "# Rex turns your cmd prompt into an LLM interface.",
        "# Type any text and press Ctrl+Enter to send it to the AI.",
        "# Normal Enter still executes commands in cmd.exe as usual.",
        "#",
        "# Installed at: " .. installed_at,
        "# Skills file:  " .. skills_path,
        "# Modes file:   " .. modes_path,
        "#",
        "# Settings:",
        '#   credential - Selected API-key entry ID (e.g., "github-main")',
        '#   model      - LLM model ID (e.g., "openai/gpt-5.4", "claude-sonnet-4-20250514")',
        '#   mode       - Model mode ID (e.g., "default", "high_reasoning")',
        '#   provider   - Provider of the current model (anthropic/openai/github/groq/xai)',
        '#   memory     - Conversation-memory window for API requests',
        '#   max_tokens - Maximum tokens in LLM response (default: 4096)',
        '#   timeout    - HTTP request timeout in seconds (default: 120)',
        "",
    }

    -- Write each setting
    local ordered_keys = {"credential", "provider", "model", "mode", "memory", "max_tokens", "timeout"}
    for _, k in ipairs(ordered_keys) do
        local v = settings[k]
        if v ~= nil then
            if type(v) == "number" then
                lines[#lines + 1] = k .. " = " .. tostring(v)
            else
                lines[#lines + 1] = k .. ' = "' .. tostring(v) .. '"'
            end
        end
    end

    local f = io.open(path, "w")
    if not f then return false, "Cannot write config file: " .. path end
    f:write(table.concat(lines, "\n") .. "\n")
    f:close()

    -- Refresh in-memory config
    state.config = settings
    return true
end

-- Save current effective settings to config
function M.save_current_config()
    local settings = {}
    local cfg = M.get_config() or {}

    -- Merge: session overrides, then config, then defaults
    settings.credential = state.credential or cfg.credential
    settings.provider   = state.provider or cfg.provider
    settings.model      = state.model or cfg.model
    settings.mode       = state.mode or cfg.mode
    settings.memory     = state.memory or cfg.memory or "all"
    settings.max_tokens = cfg.max_tokens or 4096
    settings.timeout    = cfg.timeout or 120

    return M.write_config(settings)
end

-- ================================================================
-- Effective setting resolution
-- Session state -> config file -> built-in defaults
-- ================================================================

local DEFAULTS = {
    mode       = "default",
    memory     = "all",
    max_tokens = 4096,
    timeout    = 120,
}

function M.resolve(key)
    -- Session state first
    if state[key] ~= nil then return state[key] end
    -- Config file second
    local cfg = M.get_config()
    if cfg and cfg[key] ~= nil then return cfg[key] end
    -- Built-in defaults
    return DEFAULTS[key]
end

function M.resolve_credential()
    return state.credential or (M.get_config() or {}).credential
end

function M.resolve_provider()
    return state.provider or (M.get_config() or {}).provider
end

function M.resolve_model()
    return state.model or (M.get_config() or {}).model
end

function M.resolve_mode()
    return state.mode or (M.get_config() or {}).mode or "default"
end

function M.resolve_memory()
    return state.memory or (M.get_config() or {}).memory or "all"
end

function M.resolve_max_tokens()
    local v = (M.get_config() or {}).max_tokens
    if type(v) == "number" then return v end
    return 4096
end

function M.resolve_timeout()
    local v = (M.get_config() or {}).timeout
    if type(v) == "number" then return v end
    return 120
end

-- ================================================================
-- Modes.json loading and resolution
-- ================================================================

function M.load_modes(json)
    if not script_dir then return nil, "script_dir not set" end
    local path = script_dir .. "modes.json"
    local f = io.open(path, "r")
    if not f then return nil, "Cannot open modes.json: " .. path end
    local text = f:read("*a")
    f:close()
    local data, err = json.decode(text)
    if not data then return nil, "Failed to parse modes.json: " .. tostring(err) end
    state.modes_data = data
    return data
end

function M.get_modes_data()
    return state.modes_data
end

--- Resolve modes for a given provider and model ID.
--- Returns a list of mode entries [{id, label, params}] or empty list.
function M.resolve_modes_for_model(provider, model_id)
    local data = state.modes_data
    if not data then return {} end

    -- Determine which format: compact (mode_sets + models) or legacy (top-level array)
    local models_list
    local mode_sets
    if data.models and type(data.models) == "table" then
        models_list = data.models
        mode_sets = data.mode_sets or {}
    elseif #data > 0 then
        -- Legacy top-level array
        models_list = data
        mode_sets = {}
    else
        return {}
    end

    -- Find matching entry: provider-specific first, then wildcard
    local function matches(entry)
        if not entry.match or not model_id then return false end
        if entry.match_type == "exact" then
            return model_id == entry.match
        elseif entry.match_type == "contains" then
            return model_id:find(entry.match, 1, true) ~= nil
        end
        return false
    end

    -- First pass: provider-specific matches
    local matched_entry = nil
    for _, entry in ipairs(models_list) do
        if entry.provider and entry.provider == provider and matches(entry) then
            matched_entry = entry
            break
        end
    end

    -- Second pass: wildcard (no provider) matches
    if not matched_entry then
        for _, entry in ipairs(models_list) do
            if not entry.provider and matches(entry) then
                matched_entry = entry
                break
            end
        end
    end

    if not matched_entry then return {} end

    -- Resolve modes from entry
    local modes
    if matched_entry.mode_set and mode_sets[matched_entry.mode_set] then
        modes = mode_sets[matched_entry.mode_set]
    elseif matched_entry.modes and type(matched_entry.modes) == "table" then
        modes = matched_entry.modes
    else
        modes = {}
    end

    return modes
end

--- Resolve capabilities for a given provider and model ID.
--- Returns a capabilities table or empty table.
function M.resolve_capabilities(provider, model_id)
    local data = state.modes_data
    if not data then return {} end

    local models_list
    if data.models and type(data.models) == "table" then
        models_list = data.models
    elseif #data > 0 then
        models_list = data
    else
        return {}
    end

    local function matches(entry)
        if not entry.match or not model_id then return false end
        if entry.match_type == "exact" then
            return model_id == entry.match
        elseif entry.match_type == "contains" then
            return model_id:find(entry.match, 1, true) ~= nil
        end
        return false
    end

    -- Provider-specific first
    for _, entry in ipairs(models_list) do
        if entry.provider and entry.provider == provider and matches(entry) then
            return entry.capabilities or {}
        end
    end

    -- Wildcard
    for _, entry in ipairs(models_list) do
        if not entry.provider and matches(entry) then
            return entry.capabilities or {}
        end
    end

    return {}
end

-- ================================================================
-- Skills / system prompt loading
-- ================================================================

function M.load_skills()
    if not script_dir then return nil end
    local path = script_dir .. "rex_skills.md"
    local f = io.open(path, "r")
    if not f then return nil end
    local text = f:read("*a")
    f:close()
    state.skills_text = text
    return text
end

function M.get_skills()
    if not state.skills_text then
        M.load_skills()
    end
    return state.skills_text
end

function M.load_system_prompt()
    if not script_dir then return nil end
    local path = script_dir .. "rex_system.md"
    local f = io.open(path, "r")
    if not f then return nil end
    local text = f:read("*a")
    f:close()
    state.system_text = text
    return text
end

function M.get_system_prompt()
    if not state.system_text then
        M.load_system_prompt()
    end
    return state.system_text
end

-- ================================================================
-- Conversation history
-- ================================================================

function M.add_history(role, content)
    state.history[#state.history + 1] = {role = role, content = content}
end

function M.get_history()
    return state.history
end

--- Build the conversation messages to include in the API request
--- based on the effective memory setting. Does NOT include the current prompt.
function M.build_memory_messages()
    local mem = M.resolve_memory()
    local hist = state.history
    local count = #hist

    if mem == "none" or count == 0 then
        return {}
    end

    if mem == "all" then
        local msgs = {}
        for i = 1, count do
            msgs[#msgs + 1] = {role = hist[i].role, content = hist[i].content}
        end
        return msgs
    end

    if mem == "last_answer" then
        -- Find the last assistant entry
        for i = count, 1, -1 do
            if hist[i].role == "assistant" then
                return {{role = "assistant", content = hist[i].content}}
            end
        end
        return {}
    end

    -- last_qa, last_2_qa, last_4_qa
    local pair_counts = {
        last_qa   = 1,
        last_2_qa = 2,
        last_4_qa = 4,
    }
    local wanted = pair_counts[mem]
    if not wanted then
        -- Unknown memory setting, treat as all
        local msgs = {}
        for i = 1, count do
            msgs[#msgs + 1] = {role = hist[i].role, content = hist[i].content}
        end
        return msgs
    end

    -- Find completed QA pairs from the end
    -- A completed pair is user followed by assistant
    local pairs_found = {}
    local i = count
    while i >= 1 and #pairs_found < wanted do
        -- Find an assistant entry
        if hist[i].role == "assistant" then
            -- Look for the preceding user entry
            local j = i - 1
            if j >= 1 and hist[j].role == "user" then
                table.insert(pairs_found, 1, {
                    {role = "user", content = hist[j].content},
                    {role = "assistant", content = hist[i].content},
                })
                i = j - 1
            else
                i = i - 1
            end
        else
            i = i - 1
        end
    end

    local msgs = {}
    for _, pair in ipairs(pairs_found) do
        msgs[#msgs + 1] = pair[1]
        msgs[#msgs + 1] = pair[2]
    end
    return msgs
end

-- ================================================================
-- Recall session file
-- ================================================================

local function ensure_recall_dir()
    local dir = M.get_recall_dir()
    if not dir then return nil end
    ensure_dir(dir)
    return dir
end

--- Allocate the recall session file for this Rex instance.
--- Called lazily on the first durable persist event.
--- Returns the session file path or nil.
function M.ensure_session_file()
    if state.session_allocated and state.session_path then
        return state.session_path
    end

    local dir = ensure_recall_dir()
    if not dir then return nil end

    local date = os.date("%Y%m%d")
    state.session_date = date

    -- Find the next available index for this date
    local index = 1
    while true do
        local name = string.format("session_%s_%03d", date, index)
        local path = dir .. "/" .. name
        local f = io.open(path, "r")
        if f then
            -- File exists, check if it belongs to this instance
            f:close()
            index = index + 1
        else
            -- Available slot
            state.session_index = index
            state.session_path = path
            state.session_allocated = true
            return path
        end
    end
end

--- Append a record to the recall session file and flush immediately.
--- record_kind: "user", "assistant", "shell", "error", "cancel"
function M.append_recall(record_kind, text)
    local path = M.ensure_session_file()
    if not path then return end

    local f = io.open(path, "a")
    if not f then return end

    -- Use a self-delimiting format with sentinel markers
    local timestamp = os.date("%Y-%m-%dT%H:%M:%S")
    f:write("<<<" .. record_kind:upper() .. " " .. timestamp .. ">>>\n")
    f:write(text or "")
    -- Ensure trailing newline
    if not text or text == "" or text:sub(-1) ~= "\n" then
        f:write("\n")
    end
    f:write("<<<END>>>\n")
    f:flush()
    f:close()
end

-- ================================================================
-- Web search rejection tracking
-- ================================================================

function M.mark_web_search_rejected(provider, credential, model)
    local key = (provider or "") .. "|" .. (credential or "") .. "|" .. (model or "")
    state.web_search_rejected[key] = true
end

function M.is_web_search_rejected(provider, credential, model)
    local key = (provider or "") .. "|" .. (credential or "") .. "|" .. (model or "")
    return state.web_search_rejected[key] == true
end

-- ================================================================
-- Session state setters
-- ================================================================

function M.set_model(credential, provider, model)
    state.credential = credential
    state.provider = provider
    state.model = model
    -- Clear mode on model change — effective mode becomes "default"
    state.mode = nil
    -- Clear web search rejection cache for new model
    state.web_search_rejected = {}
end

function M.set_mode(mode_id)
    state.mode = mode_id
end

function M.set_memory(memory_value)
    state.memory = memory_value
end

function M.clear_model_cache()
    state.models = nil
end

function M.set_model_cache(credential_id, model_list)
    if not state.models then state.models = {} end
    state.models[credential_id] = model_list
end

function M.get_model_cache(credential_id)
    if not state.models then return nil end
    return state.models[credential_id]
end

return M
