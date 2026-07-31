-- rex_provider.lua — Credentials, provider registry, model discovery,
-- HTTP transport, request execution, retry/error classification.
--
-- Owns: parsing REX_API_KEY, provider metadata, model-list fetching,
-- request-body assembly, HTTP calls via curl, response extraction,
-- retry policy, and request-time error classification.

local M = {}

-- Dependencies injected by rex.lua at load time
local json = nil
local state_mod = nil

function M.init(json_mod, st)
    json = json_mod
    state_mod = st
end

-- ================================================================
-- Provider registry
-- ================================================================

local PROVIDERS = {
    anthropic = {
        base_url      = "https://api.anthropic.com",
        chat_endpoint = "/v1/messages",
        list_endpoint = "/v1/models",
        auth_style    = "anthropic",
    },
    openai = {
        base_url      = "https://api.openai.com",
        chat_endpoint = "/v1/chat/completions",
        list_endpoint = "/v1/models",
        auth_style    = "bearer",
    },
    github = {
        base_url      = "https://models.github.ai",
        chat_endpoint = "/inference/chat/completions",
        list_endpoint = "/catalog/models",
        auth_style    = "github",
    },
    groq = {
        base_url      = "https://api.groq.com/openai",
        chat_endpoint = "/v1/chat/completions",
        list_endpoint = "/v1/models",
        auth_style    = "bearer",
    },
    xai = {
        base_url      = "https://api.x.ai",
        chat_endpoint = "/v1/chat/completions",
        list_endpoint = "/v1/models",
        auth_style    = "bearer",
    },
}

function M.get_provider_info(provider_name)
    return PROVIDERS[provider_name]
end

-- ================================================================
-- Credential parsing from REX_API_KEY
-- ================================================================

--- Auto-detect provider from a raw API key by prefix pattern.
local function detect_provider(raw_key)
    if raw_key:match("^sk%-ant%-") then return "anthropic" end
    if raw_key:match("^gsk_") then return "groq" end
    if raw_key:match("^xai%-") then return "xai" end
    if raw_key:match("^sk%-") then return "openai" end
    -- Cannot auto-detect; caller must handle
    return nil
end

--- Parse REX_API_KEY into a list of credential entries.
--- Each entry: {id, provider, key}
function M.parse_credentials(api_key_str)
    if not api_key_str or api_key_str == "" then
        return nil, "REX_API_KEY is not set"
    end

    local credentials = {}
    local idx = 0

    for entry in api_key_str:gmatch("[^,]+") do
        entry = entry:match("^%s*(.-)%s*$") -- trim
        if entry ~= "" then
            idx = idx + 1
            local label, rest = entry:match("^([%w_%-]+)=(.+)$")
            local provider, key

            if label and rest then
                -- label=provider:key format
                provider, key = rest:match("^(%w+):(.+)$")
                if not provider then
                    -- label=key — try auto-detect
                    key = rest
                    provider = detect_provider(key)
                end
            else
                -- provider:key or raw-key
                provider, key = entry:match("^(%w+):(.+)$")
                if provider and not PROVIDERS[provider] then
                    -- Not a known provider prefix, treat entire thing as raw key
                    key = entry
                    provider = detect_provider(key)
                end
                if not key then
                    key = entry
                    provider = detect_provider(key)
                end
                label = provider and (provider .. "-" .. idx) or ("key-" .. idx)
            end

            if provider and key and PROVIDERS[provider] then
                credentials[#credentials + 1] = {
                    id       = label,
                    provider = provider,
                    key      = key,
                }
            end
            -- Skip unrecognized entries silently
        end
    end

    if #credentials == 0 then
        return nil, "No valid credentials found in REX_API_KEY"
    end
    return credentials
end

--- Ensure credentials are parsed from the live environment.
--- Returns the credential list or nil + error.
function M.ensure_credentials()
    local st = state_mod.get_state()

    -- Always re-read from environment to catch changes
    local api_key = os.getenv("REX_API_KEY")
    if not api_key or api_key == "" then
        st.credentials = nil
        return nil, "REX_API_KEY environment variable is not set."
    end

    local creds, err = M.parse_credentials(api_key)
    if not creds then
        st.credentials = nil
        return nil, err
    end

    st.credentials = creds
    return creds
end

--- Find a credential entry by ID from the current parsed list.
function M.find_credential(cred_id)
    local st = state_mod.get_state()
    if not st.credentials then
        M.ensure_credentials()
    end
    if not st.credentials then return nil end
    for _, c in ipairs(st.credentials) do
        if c.id == cred_id then return c end
    end
    return nil
end

--- Resolve the active credential for making a request.
--- Uses session -> config -> first available.
function M.resolve_active_credential()
    local creds, err = M.ensure_credentials()
    if not creds then return nil, nil, err end

    -- Try session/config credential ID
    local cred_id = state_mod.resolve_credential()
    if cred_id then
        for _, c in ipairs(creds) do
            if c.id == cred_id then return c, nil, nil end
        end
        -- Configured credential not found in current env
        -- Try to find one matching the configured provider+model
        local cfg_provider = state_mod.resolve_provider()
        if cfg_provider then
            for _, c in ipairs(creds) do
                if c.provider == cfg_provider then return c, nil, nil end
            end
        end
        return nil, nil, 'Configured credential "' .. cred_id ..
            '" is not present in current REX_API_KEY. Use /model or update REX_API_KEY.'
    end

    -- No configured credential, use first available
    return creds[1], nil, nil
end

-- ================================================================
-- HTTP transport via curl
-- ================================================================

local function build_auth_headers(provider_name, api_key)
    local prov = PROVIDERS[provider_name]
    if not prov then return {} end

    if prov.auth_style == "anthropic" then
        return {
            "x-api-key: " .. api_key,
            "anthropic-version: 2023-06-01",
            "content-type: application/json",
        }
    elseif prov.auth_style == "github" then
        return {
            "Authorization: Bearer " .. api_key,
            "Accept: application/vnd.github+json",
            "X-GitHub-Api-Version: 2026-03-10",
            "content-type: application/json",
        }
    else
        -- bearer auth (openai, groq, xai)
        return {
            "Authorization: Bearer " .. api_key,
            "content-type: application/json",
        }
    end
end

local function build_temp_base()
    local temp_dir = os.getenv("TEMP") or os.getenv("TMP") or "."
    temp_dir = temp_dir:gsub("[/\\]+$", "")
    if temp_dir == "" then
        temp_dir = "."
    end

    -- Keep temp-file generation type-safe: os.clock() is numeric in Lua.
    local clock_component = tostring(os.clock()):gsub("[^%d]", "")
    if clock_component == "" then
        clock_component = "0"
    end

    return temp_dir .. "\\rex_" .. clock_component .. "_" .. math.random(10000, 99999)
end

--- Execute an HTTP request via curl.
--- Headers are passed via a temp file so API keys never appear on the
--- command line (visible to any process lister), and stderr is captured
--- separately so curl warnings cannot corrupt the JSON body.
--- Returns parsed_json, nil, http_status on success; nil + error otherwise.
function M.http_request(method, url, headers, body_str, timeout)
    timeout = timeout or 120

    local base = build_temp_base()
    local header_file = base .. ".hdr"
    local body_file   = base .. ".body"
    local err_file    = base .. ".err"

    local function cleanup()
        os.remove(header_file)
        os.remove(err_file)
        if body_str then os.remove(body_file) end
    end

    local hf = io.open(header_file, "w")
    if not hf then return nil, "Cannot write temp header file" end
    hf:write(table.concat(headers or {}, "\n") .. "\n")
    hf:close()

    if body_str then
        local f = io.open(body_file, "w")
        if not f then cleanup(); return nil, "Cannot write temp body file" end
        f:write(body_str)
        f:close()
    end

    -- Build curl command. -w appends the HTTP status on its own line so
    -- transient errors (429/5xx) can be classified reliably.
    local parts = {
        "curl", "-s", "-S",
        "--connect-timeout", "10",
        "--max-time", tostring(timeout),
        "-w", '"\\n%{http_code}"',
        "-H", '"@' .. header_file .. '"',
    }

    if method == "POST" then
        parts[#parts + 1] = "-X"
        parts[#parts + 1] = "POST"
    end

    if body_str then
        parts[#parts + 1] = "-d"
        parts[#parts + 1] = '"@' .. body_file .. '"'
    end

    parts[#parts + 1] = '"' .. url .. '"'

    local cmd = table.concat(parts, " ") .. ' 2>"' .. err_file .. '"'
    local pipe = io.popen(cmd, "r")
    if not pipe then
        cleanup()
        return nil, "Failed to execute curl"
    end

    local response = pipe:read("*a") or ""
    local ok, _, exit_code = pipe:close()
    if type(exit_code) ~= "number" then
        exit_code = ok and 0 or 1
    end

    local stderr_text = ""
    local ef = io.open(err_file, "r")
    if ef then
        stderr_text = ef:read("*a") or ""
        ef:close()
    end
    cleanup()

    if exit_code ~= 0 then
        local msg = stderr_text:match("^%s*(.-)%s*$") or ""
        if msg == "" then
            msg = "curl exited with code " .. tostring(exit_code)
        end
        return nil, "Network error: " .. (msg:match("^([^\r\n]*)") or msg)
    end

    -- Split off the trailing status line added by -w
    local body, status = response:match("^(.*)\n(%d%d%d)%s*$")
    if not body then
        body = response
        status = nil
    end
    local status_num = tonumber(status)

    if not body or body == "" then
        return nil, "Empty response from server (HTTP " .. tostring(status or "?") .. ")"
    end

    -- Parse JSON
    local parsed, parse_err = json.decode(body)
    if not parsed then
        return nil, "Failed to parse response (HTTP " .. tostring(status or "?") ..
            "): " .. tostring(parse_err)
    end

    return parsed, nil, status_num
end

-- ================================================================
-- Model listing / discovery
-- ================================================================

--- Model filter functions per provider.
local model_filters = {
    anthropic = function(model)
        return model.id and model.id:match("^claude%-")
    end,
    openai = function(model)
        -- gpt-* chat models and o-series reasoning models (o1, o3, ...)
        return model.id and (model.id:match("^gpt%-") or model.id:match("^o%d"))
    end,
    github = function(model)
        -- Include catalog entries that support text input and text output
        local has_text_in = false
        local has_text_out = false
        if model.supported_input_modalities then
            for _, m in ipairs(model.supported_input_modalities) do
                if m == "text" then has_text_in = true; break end
            end
        end
        if model.supported_output_modalities then
            for _, m in ipairs(model.supported_output_modalities) do
                if m == "text" then has_text_out = true; break end
            end
        end
        return has_text_in and has_text_out
    end,
    groq = function(_model)
        return true -- include all
    end,
    xai = function(model)
        return model.id and model.id:match("^grok%-")
    end,
}

--- Fetch model list for a given credential.
--- Returns a list of {id, name} or nil + error.
function M.fetch_models(credential)
    if not credential then return nil, "No credential" end

    local prov = PROVIDERS[credential.provider]
    if not prov then return nil, "Unknown provider: " .. tostring(credential.provider) end

    local url = prov.base_url .. prov.list_endpoint
    local headers = build_auth_headers(credential.provider, credential.key)

    local response, err = M.http_request("GET", url, headers, nil, 30)
    if not response then return nil, err end

    -- Extract model list based on provider response format
    local raw_models
    if credential.provider == "github" then
        -- GitHub returns a top-level JSON array
        if type(response) == "table" then
            -- Could be an array directly or have a wrapping structure
            if response[1] then
                raw_models = response
            elseif response.data then
                raw_models = response.data
            else
                -- Try the response itself as-is
                raw_models = response
            end
        end
    else
        -- Anthropic, OpenAI, Groq, xAI return {data: [...]}
        if type(response) == "table" and response.data then
            raw_models = response.data
        end
    end

    if not raw_models or type(raw_models) ~= "table" then
        -- Check for error in response
        if response.error then
            local msg = response.error
            if type(msg) == "table" then msg = msg.message or json.encode(msg) end
            return nil, tostring(msg)
        end
        return nil, "Unexpected model list response shape"
    end

    -- Apply filter and build clean list
    local filter = model_filters[credential.provider] or function() return true end
    local models = {}
    for _, m in ipairs(raw_models) do
        if type(m) == "table" and m.id and filter(m) then
            models[#models + 1] = {
                id   = m.id,
                name = m.name or m.id,
            }
        end
    end

    -- Sort alphabetically by id
    table.sort(models, function(a, b) return a.id < b.id end)

    return models
end

-- ================================================================
-- Model list caching (session + disk)
-- ================================================================

local MODEL_CACHE_TTL_SEC = 24 * 60 * 60

local function model_cache_path(credential)
    local dir = state_mod.get_config_dir()
    if not dir then return nil end
    return dir .. "/models_" .. credential.id:gsub("[^%w_%-]", "_") .. ".json"
end

local function read_model_disk_cache(credential)
    local path = model_cache_path(credential)
    if not path then return nil end
    local f = io.open(path, "r")
    if not f then return nil end
    local text = f:read("*a")
    f:close()
    local data = json.decode(text or "")
    if type(data) ~= "table" or type(data.models) ~= "table" or
       type(data.fetched_at) ~= "number" then
        return nil
    end
    if data.provider ~= credential.provider then return nil end
    if os.time() - data.fetched_at > MODEL_CACHE_TTL_SEC then return nil end
    if #data.models == 0 then return nil end
    return data.models
end

local function write_model_disk_cache(credential, models)
    if #models == 0 then return end
    local path = model_cache_path(credential)
    if not path then return end
    state_mod.ensure_config_dir()
    local text = json.encode({
        provider   = credential.provider,
        fetched_at = os.time(),
        models     = models,
    })
    if not text then return end
    local f = io.open(path, "w")
    if not f then return end
    f:write(text)
    f:close()
end

--- Fetch models for a credential, with session + disk caching.
--- Pass force=true to bypass both caches (used by /model refresh).
function M.fetch_models_cached(credential, force)
    if not credential then return nil, "No credential" end

    if not force then
        local cached = state_mod.get_model_cache(credential.id)
        if cached then return cached end

        local disk = read_model_disk_cache(credential)
        if disk then
            state_mod.set_model_cache(credential.id, disk)
            return disk
        end
    end

    local models, err = M.fetch_models(credential)
    if models then
        state_mod.set_model_cache(credential.id, models)
        write_model_disk_cache(credential, models)
    end
    return models, err
end

-- ================================================================
-- Request body assembly
-- ================================================================

--- Build the web search tool definition if appropriate.
--- Only the Anthropic Messages API supports a server-side web search tool
--- here; OpenAI's chat-completions endpoint does not accept one.
local function build_web_search_tool(provider, credential_id, model_id)
    if provider ~= "anthropic" then return nil end

    -- Check modes.json capabilities: only attach when explicitly enabled
    local caps = state_mod.resolve_capabilities(provider, model_id)
    if caps.web_search ~= true then return nil end

    -- Check session-level rejection
    if state_mod.is_web_search_rejected(provider, credential_id, model_id) then
        return nil
    end

    return {type = "web_search_20250305", name = "web_search"}
end

--- Deep-merge mode params into a base table.
local function deep_merge(base, overlay)
    if type(overlay) ~= "table" then return end
    for k, v in pairs(overlay) do
        if type(v) == "table" and type(base[k]) == "table" then
            deep_merge(base[k], v)
        else
            base[k] = v
        end
    end
end

--- Build the complete API request body.
--- credential_id is used to key the web-search rejection cache; falls back
--- to the configured credential when omitted (e.g., /context preview).
--- Returns body_table or nil + error.
function M.build_request(system_prompt, messages, provider, model_id, mode_id, max_tokens, credential_id)
    local prov = PROVIDERS[provider]
    if not prov then return nil, "Unknown provider: " .. tostring(provider) end

    max_tokens = max_tokens or 4096

    local body

    if provider == "anthropic" then
        body = {
            model      = model_id,
            max_tokens = max_tokens,
            system     = system_prompt,
            messages   = messages,
        }
    else
        -- OpenAI-compatible: openai, github, groq, xai
        local msgs = {}
        msgs[1] = {role = "system", content = system_prompt}
        for _, m in ipairs(messages) do
            msgs[#msgs + 1] = {role = m.role, content = m.content}
        end
        body = {
            model    = model_id,
            messages = msgs,
        }
        if provider == "openai" then
            -- OpenAI reasoning models reject max_tokens
            body.max_completion_tokens = max_tokens
        else
            body.max_tokens = max_tokens
        end
    end

    -- Apply mode params if not default
    if mode_id and mode_id ~= "default" then
        local modes = state_mod.resolve_modes_for_model(provider, model_id)
        for _, m in ipairs(modes) do
            if m.id == mode_id and m.params then
                deep_merge(body, m.params)
                break
            end
        end
    end

    -- Add web search tool if supported
    local cred_id = credential_id or state_mod.resolve_credential()
    local ws_tool = build_web_search_tool(provider, cred_id, model_id)
    if ws_tool then
        body.tools = {ws_tool}
    end

    return body
end

-- ================================================================
-- Response extraction
-- ================================================================

--- Normalize provider token-usage info to {input, output} or nil.
local function extract_usage(response)
    local u = response and response.usage
    if type(u) ~= "table" then return nil end
    local input = u.input_tokens or u.prompt_tokens
    local output = u.output_tokens or u.completion_tokens
    if type(input) ~= "number" then input = nil end
    if type(output) ~= "number" then output = nil end
    if not input and not output then return nil end
    return {input = input, output = output}
end

--- Extract assistant text from a provider response.
--- Returns text, nil, usage on success; nil + error on failure.
function M.extract_response(provider, response)
    if not response then return nil, "No response" end

    -- Check for API-level error
    if response.error then
        local msg = response.error
        if type(msg) == "table" then
            msg = msg.message or json.encode(msg) or "Unknown error"
        end
        return nil, tostring(msg)
    end

    if provider == "anthropic" then
        -- response.content[] — concatenate all text blocks
        if response.content and type(response.content) == "table" then
            local parts = {}
            for _, block in ipairs(response.content) do
                if type(block) == "table" and block.type == "text" and block.text then
                    parts[#parts + 1] = block.text
                end
            end
            if #parts > 0 then
                return table.concat(parts), nil, extract_usage(response)
            end
        end
        -- No text blocks. On thinking-by-default models (Claude Opus 5 and
        -- later) max_tokens caps thinking *and* visible text together, so a
        -- long reasoning pass can consume the whole budget and leave nothing
        -- to print. stop_reason tells us which case this is.
        local reason = response.stop_reason
        if reason == "max_tokens" then
            return nil, "Reasoning used the whole max_tokens budget before any "
                .. "text was produced. Raise it (/set max_tokens 16000) or pick "
                .. "a lower effort via /mode."
        elseif reason == "refusal" then
            return nil, "The model declined this request (stop_reason: refusal)."
        end
        return nil, "No content in Anthropic response"
            .. (reason and (" (stop_reason: " .. tostring(reason) .. ")") or "")
    else
        -- OpenAI-compatible: choices[0].message.content
        if response.choices and type(response.choices) == "table" then
            local first = response.choices[1]
            if first and first.message and first.message.content then
                return first.message.content, nil, extract_usage(response)
            end
        end
        return nil, "No content in " .. (provider or "unknown") .. " response"
    end
end

-- ================================================================
-- Error classification
-- ================================================================

--- Classify an error as transient (retryable), permanent, or a tool
--- rejection ("permanent_tool"). status is the HTTP status when known.
function M.classify_error(response, err_msg, status)
    if type(response) == "table" and type(response.error) == "table" then
        local etype = tostring(response.error.type or "")
        local emsg = tostring(response.error.message or "")
        -- Unsupported tool — permanent for this tool config only
        if emsg:match("does not support tool") or emsg:match("unsupported.*tool") then
            return "permanent_tool"
        end
        -- Anthropic overloaded
        if etype:match("[Oo]verloaded") or emsg:match("[Oo]verloaded") then
            return "transient"
        end
        -- Rate limit
        if etype:match("rate_limit") or emsg:match("rate.limit") then
            return "transient"
        end
        -- Unsupported mode/param
        if emsg:match("unsupported") or emsg:match("not supported") or
           emsg:match("invalid.*param") or emsg:match("Field required") then
            return "permanent"
        end
    end

    -- HTTP status is the most reliable signal when available
    if status == 429 or (status and status >= 500) then
        return "transient"
    end

    if err_msg then
        if err_msg:match("timed? ?out") or err_msg:match("curl") or
           err_msg:match("Network error") then
            return "transient"
        end
        if err_msg:match("429") or err_msg:match("503") or err_msg:match("529") or
           err_msg:match("[Oo]verloaded") or err_msg:match("rate.limit") then
            return "transient"
        end
    end

    -- Default to permanent for unrecognized errors
    return "permanent"
end

-- ================================================================
-- Request execution with retry
-- ================================================================

local function backoff_wait(attempt)
    -- Short backoff: ~1s, ~2s (ping to self as a portable sleep)
    os.execute("ping -n " .. (attempt + 1) .. " 127.0.0.1 >nul 2>&1")
end

--- Send a chat request to the API with retry for transient errors.
--- Returns extracted text, nil, usage — or nil + error.
function M.send_request(system_prompt, messages, options)
    options = options or {}
    local provider = options.provider or state_mod.resolve_provider()
    local model_id = options.model or state_mod.resolve_model()
    local mode_id  = options.mode or state_mod.resolve_mode()
    local max_tokens = options.max_tokens or state_mod.resolve_max_tokens()
    local timeout  = options.timeout or state_mod.resolve_timeout()

    if not provider then return nil, "No provider configured. Use /model to select one." end
    if not model_id then return nil, "No model configured. Use /model to select one." end

    -- Resolve credential for this request
    local cred, _, cred_err = M.resolve_active_credential()
    if not cred then return nil, cred_err end

    -- The resolved credential must belong to the configured provider,
    -- otherwise the request would fail with a confusing auth error.
    if cred.provider ~= provider then
        return nil, 'Credential "' .. cred.id .. '" is for provider ' .. cred.provider ..
            ' but the configured provider is ' .. provider .. '. Use /model to reselect.'
    end

    -- Build request body
    local body, build_err = M.build_request(system_prompt, messages, provider, model_id,
        mode_id, max_tokens, cred.id)
    if not body then return nil, build_err end

    local prov = PROVIDERS[provider]
    local url = prov.base_url .. prov.chat_endpoint
    local headers = build_auth_headers(provider, cred.key)

    local body_str = json.encode(body)
    if not body_str then return nil, "Failed to encode request body" end

    -- Retry loop for transient errors
    local max_retries = 3
    local last_err = nil
    for attempt = 1, max_retries do
        local response, http_err, status = M.http_request("POST", url, headers, body_str, timeout)

        if not response then
            last_err = http_err
            local class = M.classify_error(nil, http_err, status)
            if class == "transient" and attempt < max_retries then
                backoff_wait(attempt)
            else
                return nil, http_err
            end
        else
            local text, extract_err, usage = M.extract_response(provider, response)
            if text then
                return text, nil, usage
            end

            -- Check if this is a tool-rejection error
            local class = M.classify_error(response, extract_err, status)
            if class == "permanent_tool" then
                -- Retry without web search tool
                state_mod.mark_web_search_rejected(provider, cred.id, model_id)
                body.tools = nil
                body_str = json.encode(body)
                -- Immediate single retry without the tool
                local resp2, err2 = M.http_request("POST", url, headers, body_str, timeout)
                if not resp2 then return nil, err2 end
                local t2, e2, u2 = M.extract_response(provider, resp2)
                if t2 then return t2, nil, u2 end
                return nil, e2
            elseif class == "transient" and attempt < max_retries then
                last_err = extract_err
                backoff_wait(attempt)
            else
                return nil, extract_err
            end
        end
    end

    -- Build a user-friendly transient error message
    if last_err then
        local model_display = model_id or "unknown model"
        local provider_display = provider or "Unknown provider"
        if last_err:match("[Oo]verloaded") or last_err:match("rate") or
           last_err:match("429") or last_err:match("503") then
            return nil, provider_display .. " is temporarily overloaded for " ..
                model_display .. ". Try again in a moment."
        end
    end

    return nil, last_err or "Request failed after retries"
end

return M
