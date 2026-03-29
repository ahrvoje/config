-- rex_state.lua -- Durable/session state, config I/O, recall-session files,
-- modes.json + skills loading, effective-setting resolution.
--
-- Owns: shared state table, config parsing/writing, recall-session file
-- lifecycle, modes.json resolution, skills file loading, capability lookup,
-- effective setting resolution, conversation history, web-search denial.
-- Does NOT own: turn-scoped prompt framing, shell-command protocol, ANSI
-- rendering, HTTP transport, credential parsing.

local json  -- injected by rex.lua via init()

local M = {}

-- ================================================================
-- Shared session state
-- ================================================================

local state = {
    credential    = nil,   -- selected credential ID
    provider      = nil,   -- selected provider string
    model         = nil,   -- selected model ID
    mode          = nil,   -- selected mode ID
    memory        = nil,   -- selected memory window policy
    history       = {},    -- conversation message history {role, content}
    session_path  = nil,   -- path of the current durable recall session file
    session_date  = nil,   -- session file date stamp YYYYMMDD
    session_index = nil,   -- daily 1-based recall-session index
    credentials   = nil,   -- parsed credential entries from REX_API_KEY
    models        = nil,   -- cached model lists keyed by credential ID
    config        = nil,   -- parsed config file table
    modes_data    = nil,   -- parsed modes.json
    skills_text   = nil,   -- cached rex_skills.md content
    script_dir    = nil,   -- directory containing the plugin files
    web_search_deny = {},  -- {provider|credential|model} combos that rejected web search
}

function M.get_state()
    return state
end

-- ================================================================
-- Initialization -- called once by rex.lua
-- ================================================================

function M.init(json_mod, script_dir)
    json = json_mod
    state.script_dir = script_dir
    M.load_modes()
    M.load_skills()
    M.load_config()
    -- Recall session is allocated lazily on first recall_append() to avoid
    -- consuming a session index for startups that never use Rex.
end

-- ================================================================
-- XDG config directory
-- ================================================================

local function config_dir()
    local xdg = os.getenv("XDG_CONFIG_HOME")
    if xdg and xdg ~= "" then
        return xdg .. "/rex"
    end
    local home = os.getenv("USERPROFILE") or os.getenv("HOME") or "."
    return home .. "/.config/rex"
end

local function config_path()
    return config_dir() .. "/config.toml"
end

local function recall_dir()
    return config_dir() .. "/recall"
end

-- ================================================================
-- Config parsing (simple key = value)
-- ================================================================

local function parse_config(text)
    local cfg = {}
    for line in text:gmatch("[^\r\n]+") do
        local trimmed = line:match("^%s*(.-)%s*$")
        if trimmed ~= "" and trimmed:sub(1, 1) ~= "#" then
            local key, val = trimmed:match("^(%S+)%s*=%s*(.+)$")
            if key and val then
                local unquoted = val:match('^"(.*)"$') or val:match("^'(.*)'$")
                if unquoted then val = unquoted end
                local num = tonumber(val)
                if num then val = num end
                cfg[key] = val
            end
        end
    end
    return cfg
end

function M.load_config()
    local f = io.open(config_path(), "r")
    if not f then
        state.config = nil
        return
    end
    local text = f:read("*a")
    f:close()
    if not text or text == "" then
        state.config = nil
        return
    end
    state.config = parse_config(text)
end

function M.save_config(cfg)
    local dir = config_dir()
    os.execute('mkdir "' .. dir:gsub("/", "\\") .. '" 2>nul')

    local f = io.open(config_path(), "w")
    if not f then
        clink.print("Warning: could not write config to " .. config_path())
        return false
    end

    local install_dir = state.script_dir or "."
    f:write("# Rex - Clink AI Agent Plugin\n")
    f:write("#\n")
    f:write("# Rex turns your cmd prompt into an LLM interface.\n")
    f:write("# Type any text and press Ctrl+Enter to send it to the AI.\n")
    f:write("# Normal Enter still executes commands in cmd.exe as usual.\n")
    f:write("#\n")
    f:write("# Installed at: " .. install_dir .. "\n")
    f:write("# Skills file:  " .. install_dir .. "rex_skills.md\n")
    f:write("# Modes file:   " .. install_dir .. "modes.json\n")
    f:write("#\n")
    f:write("# Settings:\n")
    f:write('#   credential - Selected API-key entry ID (e.g., "github-main")\n')
    f:write('#   model      - LLM model ID (e.g., "openai/gpt-5.4", "claude-sonnet-4-20250514")\n')
    f:write('#   mode       - Model mode ID (e.g., "default", "high_reasoning")\n')
    f:write("#   provider   - Provider of the current model (anthropic/openai/github/groq/xai)\n")
    f:write('#   memory     - Conversation-memory window for API requests\n')
    f:write("#   max_tokens - Maximum tokens in LLM response (default: 4096)\n")
    f:write("#   timeout    - HTTP request timeout in seconds (default: 120)\n")
    f:write("\n")

    -- Write keys in deterministic order
    local ordered = {"credential", "provider", "model", "mode", "memory", "max_tokens", "timeout"}
    local written = {}
    for _, key in ipairs(ordered) do
        if cfg[key] ~= nil then
            local val = cfg[key]
            if type(val) == "string" then
                f:write(key .. ' = "' .. val .. '"\n')
            else
                f:write(key .. " = " .. tostring(val) .. "\n")
            end
            written[key] = true
        end
    end
    for key, val in pairs(cfg) do
        if not written[key] then
            if type(val) == "string" then
                f:write(key .. ' = "' .. val .. '"\n')
            else
                f:write(key .. " = " .. tostring(val) .. "\n")
            end
        end
    end

    f:close()
    state.config = cfg
    return true
end

-- ================================================================
-- Recall session file lifecycle
-- ================================================================

--- Lazily allocate the recall session file for this Rex instance.
--- Called on the first recall_append(); creates a new session_<DATE>_<NNN>
--- file with the next available index.  By deferring allocation until
--- the first durable write, we never consume an index for startups
--- that never interact with Rex.
local function ensure_recall_session()
    if state.session_path then return true end

    local dir = recall_dir()
    os.execute('mkdir "' .. dir:gsub("/", "\\") .. '" 2>nul')

    local date = os.date("%Y%m%d")
    state.session_date = date

    -- Find the next available index for today
    local index = 1
    while true do
        local name = string.format("session_%s_%03d", date, index)
        local path = dir .. "/" .. name
        local f = io.open(path, "r")
        if f then
            f:close()
            index = index + 1
        else
            break
        end
    end

    state.session_index = index
    local name = string.format("session_%s_%03d", date, index)
    state.session_path = dir .. "/" .. name

    -- Create the file so parallel Clink instances see it as taken.
    local f = io.open(state.session_path, "w")
    if f then
        f:close()
        return true
    end
    return false
end

--- Append a record to the current recall session file and flush immediately.
--- kind: "user", "assistant", "shell", "error", or "cancel"
--- text: the payload string
function M.recall_append(kind, text)
    if not kind or not text then return end

    -- Lazily allocate the session file on first write.
    if not ensure_recall_session() then return end

    local f = io.open(state.session_path, "a")
    if not f then return end

    -- Self-delimiting format: header line with kind, then indented payload,
    -- then a blank line separator. Multi-line payloads are preserved by
    -- indenting every line with two spaces.
    f:write("--- " .. kind .. " ---\n")
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        f:write("  " .. line .. "\n")
    end
    f:write("\n")
    f:flush()
    f:close()
end

-- ================================================================
-- modes.json loading and resolution
-- ================================================================

function M.load_modes()
    local path = (state.script_dir or "") .. "modes.json"
    local f = io.open(path, "r")
    if not f then
        state.modes_data = nil
        return
    end
    local text = f:read("*a")
    f:close()
    if not text or text == "" then
        state.modes_data = nil
        return
    end
    local data = json.decode(text)
    if not data then
        state.modes_data = nil
        return
    end
    state.modes_data = data
end

--- Resolve modes for a given provider + model ID.
--- Returns an array of mode entries, always with implicit "default" at front.
function M.resolve_modes(provider, model_id)
    local default_mode = {id = "default", label = "Default", params = {}}
    if not state.modes_data or not model_id then
        return {default_mode}
    end

    local data = state.modes_data
    local entries
    if data.models then
        entries = data.models
    elseif type(data) == "table" and #data > 0 then
        entries = data  -- legacy top-level array
    else
        return {default_mode}
    end

    -- Provider-specific match first, then wildcard fallback
    local wildcard_match = nil
    for _, entry in ipairs(entries) do
        if entry.match and model_id then
            local matched = false
            if entry.match_type == "exact" then
                matched = (model_id == entry.match)
            else
                matched = (model_id:find(entry.match, 1, true) ~= nil)
            end
            if matched then
                if entry.provider == provider then
                    return M._extract_modes(data, entry, default_mode)
                elseif not entry.provider and not wildcard_match then
                    wildcard_match = entry
                end
            end
        end
    end

    if wildcard_match then
        return M._extract_modes(data, wildcard_match, default_mode)
    end

    return {default_mode}
end

function M._extract_modes(data, entry, default_mode)
    local modes_list = nil
    if entry.mode_set and data.mode_sets then
        modes_list = data.mode_sets[entry.mode_set]
    elseif entry.modes then
        modes_list = entry.modes
    end

    if not modes_list or #modes_list == 0 then
        return {default_mode}
    end

    local result = {default_mode}
    for _, m in ipairs(modes_list) do
        result[#result + 1] = m
    end
    return result
end

--- Resolve capability flags for a given provider + model ID.
function M.resolve_capabilities(provider, model_id)
    if not state.modes_data or not model_id then
        return {}
    end

    local data = state.modes_data
    local entries = data.models or (type(data) == "table" and #data > 0 and data) or {}

    local wildcard_match = nil
    for _, entry in ipairs(entries) do
        if entry.match and model_id then
            local matched = false
            if entry.match_type == "exact" then
                matched = (model_id == entry.match)
            else
                matched = (model_id:find(entry.match, 1, true) ~= nil)
            end
            if matched then
                if entry.provider == provider then
                    return entry.capabilities or {}
                elseif not entry.provider and not wildcard_match then
                    wildcard_match = entry
                end
            end
        end
    end

    if wildcard_match then
        return wildcard_match.capabilities or {}
    end
    return {}
end

-- ================================================================
-- Skills file loading
-- ================================================================

function M.load_skills()
    local path = (state.script_dir or "") .. "rex_skills.md"
    local f = io.open(path, "r")
    if not f then
        state.skills_text = nil
        return
    end
    state.skills_text = f:read("*a")
    f:close()
end

function M.get_skills()
    return state.skills_text or ""
end

-- ================================================================
-- Effective setting resolution (session -> config -> default)
-- ================================================================

function M.effective_credential()
    return state.credential
        or (state.config and state.config.credential)
        or nil
end

function M.effective_provider()
    return state.provider
        or (state.config and state.config.provider)
        or nil
end

function M.effective_model()
    return state.model
        or (state.config and state.config.model)
        or nil
end

function M.effective_mode()
    return state.mode
        or (state.config and state.config.mode)
        or "default"
end

function M.effective_memory()
    return state.memory
        or (state.config and state.config.memory)
        or "all"
end

function M.effective_max_tokens()
    local v = (state.config and state.config.max_tokens) or 4096
    return tonumber(v) or 4096
end

function M.effective_timeout()
    local v = (state.config and state.config.timeout) or 120
    return tonumber(v) or 120
end

--- Returns true if the current session has a usable model selection.
function M.has_model()
    return M.effective_model() ~= nil and M.effective_provider() ~= nil
end

-- ================================================================
-- Session state mutation helpers
-- ================================================================

function M.set_model(credential, provider, model_id)
    state.credential = credential
    state.provider = provider
    state.model = model_id
    -- Changing model clears explicit mode; falls back to default
    state.mode = nil
end

function M.set_mode(mode_id)
    state.mode = mode_id
end

function M.set_memory(value)
    state.memory = value
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

--- Build the message array for the current memory window.
--- Returns only prior completed history; the caller appends the current
--- prompt separately.  A trailing unpaired user message (the current turn)
--- is excluded so it does not duplicate the framed current prompt.
function M.get_memory_messages()
    local mem = M.effective_memory()
    local hist = state.history
    local count = #hist

    if mem == "none" or count == 0 then
        return {}
    end

    -- Determine the effective end of prior history: if the last entry is
    -- an unpaired user message (the current turn just added), exclude it.
    local eff_count = count
    if count > 0 and hist[count].role == "user" then
        eff_count = count - 1
    end

    if eff_count <= 0 then
        return {}
    end

    if mem == "all" then
        local msgs = {}
        for i = 1, eff_count do
            msgs[#msgs + 1] = {role = hist[i].role, content = hist[i].content}
        end
        return msgs
    end

    if mem == "last_answer" then
        for i = eff_count, 1, -1 do
            if hist[i].role == "assistant" then
                return {{role = "assistant", content = hist[i].content}}
            end
        end
        return {}
    end

    -- last_qa, last_2_qa, last_4_qa: extract N trailing completed pairs
    local pair_count = 1
    if mem == "last_2_qa" then pair_count = 2
    elseif mem == "last_4_qa" then pair_count = 4
    elseif mem == "last_qa" then pair_count = 1
    else
        -- Unknown value, fall back to all
        local msgs = {}
        for i = 1, eff_count do
            msgs[#msgs + 1] = {role = hist[i].role, content = hist[i].content}
        end
        return msgs
    end

    -- Walk backward from eff_count collecting completed QA pairs.
    local pairs_found = {}
    local i = eff_count
    while i >= 2 and #pairs_found < pair_count do
        if hist[i].role == "assistant" and hist[i - 1].role == "user" then
            table.insert(pairs_found, 1, {
                {role = "user", content = hist[i - 1].content},
                {role = "assistant", content = hist[i].content},
            })
            i = i - 2
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
-- Web-search denial tracking
-- ================================================================

function M.deny_web_search(provider, credential, model_id)
    local key = (provider or "") .. "|" .. (credential or "") .. "|" .. (model_id or "")
    state.web_search_deny[key] = true
end

function M.is_web_search_denied(provider, credential, model_id)
    local key = (provider or "") .. "|" .. (credential or "") .. "|" .. (model_id or "")
    return state.web_search_deny[key] == true
end

-- ================================================================
-- Model cache management
-- ================================================================

function M.invalidate_models(credential_id)
    if state.models then
        state.models[credential_id] = nil
    end
end

function M.set_cached_models(credential_id, model_list)
    if not state.models then state.models = {} end
    state.models[credential_id] = model_list
end

function M.get_cached_models(credential_id)
    return state.models and state.models[credential_id]
end

function M.set_credentials(creds)
    state.credentials = creds
end

function M.get_credentials()
    return state.credentials
end

return M
