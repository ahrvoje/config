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

local function build_temp_json_path()
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

    return temp_dir .. "\\rex_" .. clock_component .. "_" .. math.random(10000, 99999) .. ".json"
end

--- Execute an HTTP request via curl.
--- Returns parsed JSON response, HTTP status, or nil + error.
function M.http_request(method, url, headers, body_str, timeout)
    timeout = timeout or 120

    -- Write body to temp file to avoid shell-escaping issues
    local temp_file = build_temp_json_path()

    if body_str then
        local f = io.open(temp_file, "w")
        if not f then return nil, "Cannot write temp file" end
        f:write(body_str)
        f:close()
    end

    -- Build curl command
    local parts = {"curl", "-s", "-S", "--max-time", tostring(timeout)}

    if method == "POST" then
        parts[#parts + 1] = "-X"
        parts[#parts + 1] = "POST"
    end

    for _, h in ipairs(headers or {}) do
        parts[#parts + 1] = "-H"
        parts[#parts + 1] = '"' .. h .. '"'
    end

    if body_str then
        parts[#parts + 1] = "-d"
        parts[#parts + 1] = '"@' .. temp_file .. '"'
    end

    parts[#parts + 1] = '"' .. url .. '"'

    local cmd = table.concat(parts, " ")
    local pipe = io.popen(cmd .. " 2>&1", "r")
    if not pipe then
        if body_str then os.remove(temp_file) end
        return nil, "Failed to execute curl"
    end

    local response = pipe:read("*a")
    pipe:close()

    -- Clean up temp file
    if body_str then os.remove(temp_file) end

    if not response or response == "" then
        return nil, "Empty response from curl"
    end

    -- Check for curl errors (non-JSON responses starting with "curl:")
    if response:match("^curl:") or response:match("^curl %(") then
        return nil, "Network error: " .. response:match("^(.-)[\r\n]") or response
    end

    -- Parse JSON
    local parsed, parse_err = json.decode(response)
    if not parsed then
        return nil, "Failed to parse response: " .. tostring(parse_err)
    end

    return parsed
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
        return model.id and (model.id:match("^gpt%-") or model.id:match("^o"))
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

--- Fetch models for a credential, with caching.
function M.fetch_models_cached(credential)
    if not credential then return nil, "No credential" end
    local cached = state_mod.get_model_cache(credential.id)
    if cached then return cached end

    local models, err = M.fetch_models(credential)
    if models then
        state_mod.set_model_cache(credential.id, models)
    end
    return models, err
end

-- ================================================================
-- Request body assembly
-- ================================================================

--- Build the web search tool definition if appropriate.
local function build_web_search_tool(provider, credential_id, model_id)
    -- Check modes.json capabilities
    local caps = state_mod.resolve_capabilities(provider, model_id)

    -- If explicitly false, omit
    if caps.web_search == false then return nil end

    -- If not explicitly true, omit (conservative default)
    if caps.web_search ~= true then return nil end

    -- Check session-level rejection
    if state_mod.is_web_search_rejected(provider, credential_id, model_id) then
        return nil
    end

    -- Only Anthropic and OpenAI endpoint families support web search
    if provider == "anthropic" then
        return {type = "web_search_20250305", name = "web_search"}
    elseif provider == "openai" then
        return {type = "web_search_preview"}
    end

    -- GitHub, Groq, xAI: no web search tool support
    return nil
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
--- Returns body_table, provider_name, or nil + error.
function M.build_request(system_prompt, messages, provider, model_id, mode_id, max_tokens)
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
            model      = model_id,
            max_tokens = max_tokens,
            messages   = msgs,
        }
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
    local cred_id = state_mod.resolve_credential()
    local ws_tool = build_web_search_tool(provider, cred_id, model_id)
    if ws_tool then
        body.tools = {ws_tool}
    end

    return body
end

-- ================================================================
-- Response extraction
-- ================================================================

--- Extract assistant text from a provider response.
--- Returns text or nil + error.
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
                return table.concat(parts)
            end
        end
        -- Truly no content in Anthropic response
        return nil, "No content in Anthropic response"
    else
        -- OpenAI-compatible: choices[0].message.content
        if response.choices and type(response.choices) == "table" then
            local first = response.choices[1]
            if first and first.message and first.message.content then
                return first.message.content
            end
        end
        return nil, "No content in " .. (provider or "unknown") .. " response"
    end
end

-- ================================================================
-- Error classification
-- ================================================================

--- Classify an error as transient (retryable) or permanent.
--- Returns "transient" or "permanent".
function M.classify_error(response, err_msg)
    if not response and err_msg then
        -- Check for timeout or network errors
        if err_msg:match("timed? ?out") or err_msg:match("curl") then
            return "transient"
        end
        return "permanent"
    end

    if type(response) == "table" then
        -- Check for transient HTTP error patterns
        local err = response.error
        if type(err) == "table" then
            local etype = err.type or ""
            local emsg = err.message or ""
            -- Anthropic overloaded
            if etype:match("[Oo]verloaded") or emsg:match("[Oo]verloaded") then
                return "transient"
            end
            -- Rate limit
            if etype:match("rate_limit") or emsg:match("rate.limit") then
                return "transient"
            end
            -- Unsupported tool — this is a permanent error for this tool config
            if emsg:match("does not support tool") or emsg:match("unsupported.*tool") then
                return "permanent_tool"
            end
            -- Unsupported mode/param
            if emsg:match("unsupported") or emsg:match("not supported") or
               emsg:match("invalid.*param") or emsg:match("Field required") then
                return "permanent"
            end
        end

        -- Check HTTP status via response shape
        if response.status then
            local s = tonumber(response.status)
            if s == 429 or s == 503 or s == 529 then
                return "transient"
            end
        end
    end

    -- Default to permanent for unrecognized errors
    if err_msg then
        if err_msg:match("429") or err_msg:match("503") or err_msg:match("529") or
           err_msg:match("[Oo]verloaded") or err_msg:match("rate.limit") then
            return "transient"
        end
    end

    return "permanent"
end

-- ================================================================
-- Request execution with retry
-- ================================================================

--- Send a chat request to the API with retry for transient errors.
--- Returns extracted text or nil + error.
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

    -- Build request body
    local body, build_err = M.build_request(system_prompt, messages, provider, model_id, mode_id, max_tokens)
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
        local response, http_err = M.http_request("POST", url, headers, body_str, timeout)

        if http_err then
            last_err = http_err
            local class = M.classify_error(nil, http_err)
            if class == "transient" and attempt < max_retries then
                -- Short backoff: 1s, 2s
                local wait_cmd = "ping -n " .. (attempt + 1) .. " 127.0.0.1 >nul 2>&1"
                os.execute(wait_cmd)
            else
                return nil, http_err
            end
        elseif response then
            local text, extract_err = M.extract_response(provider, response)
            if text then
                return text
            end

            -- Check if this is a tool-rejection error
            local class = M.classify_error(response, extract_err)
            if class == "permanent_tool" then
                -- Retry without web search tool
                state_mod.mark_web_search_rejected(provider, cred.id, model_id)
                body.tools = nil
                body_str = json.encode(body)
                -- Immediate single retry without the tool
                local resp2, err2 = M.http_request("POST", url, headers, body_str, timeout)
                if err2 then return nil, err2 end
                if resp2 then
                    local t2, e2 = M.extract_response(provider, resp2)
                    if t2 then return t2 end
                    return nil, e2
                end
                return nil, extract_err
            elseif class == "transient" and attempt < max_retries then
                last_err = extract_err
                local wait_cmd = "ping -n " .. (attempt + 1) .. " 127.0.0.1 >nul 2>&1"
                os.execute(wait_cmd)
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

-- ================================================================
-- Model validation
-- ================================================================

--- Validate a model selection by making a minimal test request.
--- Returns true on success, false + error on failure.
function M.validate_model(credential, model_id, mode_id)
    if not credential then return false, "No credential" end

    local provider = credential.provider
    local prov = PROVIDERS[provider]
    if not prov then return false, "Unknown provider" end

    -- Build a minimal request
    local body
    if provider == "anthropic" then
        body = {
            model      = model_id,
            max_tokens = 1,
            system     = "Reply with OK.",
            messages   = {{role = "user", content = "ping"}},
        }
    else
        body = {
            model      = model_id,
            max_tokens = 1,
            messages   = {
                {role = "system", content = "Reply with OK."},
                {role = "user", content = "ping"},
            },
        }
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

    local url = prov.base_url .. prov.chat_endpoint
    local headers = build_auth_headers(provider, credential.key)
    local body_str = json.encode(body)
    if not body_str then return false, "Encode error" end

    local response, http_err = M.http_request("POST", url, headers, body_str, 15)
    if http_err then
        local class = M.classify_error(nil, http_err)
        if class == "transient" then
            -- Transient errors do not invalidate the selection
            return true
        end
        return false, http_err
    end

    if not response then return false, "No response" end

    -- Check for API-level error
    if response.error then
        local msg = response.error
        if type(msg) == "table" then
            msg = msg.message or json.encode(msg) or "Unknown error"
        end
        local class = M.classify_error(response, tostring(msg))
        if class == "transient" then
            return true -- Transient: selection is fine
        end
        return false, tostring(msg)
    end

    return true
end

return M
