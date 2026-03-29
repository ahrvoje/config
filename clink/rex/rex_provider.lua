-- rex_provider.lua -- Credentials, provider registry, model discovery,
-- HTTP transport, request execution, retry/error classification.
--
-- Owns: parsing REX_API_KEY credentials, provider metadata (endpoints, auth,
-- filters), model-list fetching, request-body assembly per provider,
-- HTTP calls via curl, response extraction, retry policy, error classification,
-- web-search tool resolution.
-- Does NOT own: durable state, config I/O, prompt framing, ANSI rendering.

local json       -- injected via init()
local state_mod  -- injected via init()

local M = {}

function M.init(json_mod, state_module)
    json = json_mod
    state_mod = state_module
end

-- ================================================================
-- Provider registry
-- ================================================================

local providers = {
    anthropic = {
        base_url     = "https://api.anthropic.com",
        models_path  = "/v1/models",
        chat_path    = "/v1/messages",
        auth_type    = "x-api-key",
        filter       = function(id) return id:find("^claude%-") ~= nil end,
    },
    openai = {
        base_url     = "https://api.openai.com",
        models_path  = "/v1/models",
        chat_path    = "/v1/chat/completions",
        auth_type    = "bearer",
        filter       = function(id) return id:find("^gpt%-") ~= nil or id:find("^o") ~= nil end,
    },
    github = {
        base_url     = "https://models.github.ai",
        models_path  = "/catalog/models",
        chat_path    = "/inference/chat/completions",
        auth_type    = "bearer-github",
        -- GitHub filter runs on full catalog entry objects, not bare ID strings.
        -- Includes entries that support text input and text output.
        filter       = function(entry)
            if type(entry) ~= "table" then return false end
            local inp = entry.supported_input_modalities or {}
            local out = entry.supported_output_modalities or {}
            local has_text_in, has_text_out = false, false
            for _, v in ipairs(inp) do if v == "text" then has_text_in = true end end
            for _, v in ipairs(out) do if v == "text" then has_text_out = true end end
            return has_text_in and has_text_out
        end,
    },
    groq = {
        base_url     = "https://api.groq.com/openai",
        models_path  = "/v1/models",
        chat_path    = "/v1/chat/completions",
        auth_type    = "bearer",
        filter       = function() return true end,
    },
    xai = {
        base_url     = "https://api.x.ai",
        models_path  = "/v1/models",
        chat_path    = "/v1/chat/completions",
        auth_type    = "bearer",
        filter       = function(id) return id:find("^grok%-") ~= nil end,
    },
}

function M.get_provider_info(name)
    return providers[name]
end

-- ================================================================
-- Credential parsing
-- ================================================================

--- Parse REX_API_KEY into an array of credential entries.
--- Each entry: {id, provider, key}
function M.parse_credentials()
    local raw = os.getenv("REX_API_KEY")
    if not raw or raw == "" then
        return nil, "REX_API_KEY is not set."
    end

    local creds = {}
    local idx = 0
    for entry in raw:gmatch("[^,]+") do
        entry = entry:match("^%s*(.-)%s*$")
        if entry ~= "" then
            idx = idx + 1
            local cred = M._parse_single_credential(entry, idx)
            if cred then
                creds[#creds + 1] = cred
            end
        end
    end

    if #creds == 0 then
        return nil, "No valid credentials found in REX_API_KEY."
    end

    state_mod.set_credentials(creds)
    return creds
end

function M._parse_single_credential(entry, idx)
    local label, rest

    -- Check for label=provider:key format
    label, rest = entry:match("^([%w_%-]+)=(.+)$")
    if not label then
        rest = entry
    end

    -- Check for provider:key format
    local provider_tag, key = rest:match("^(%w+):(.+)$")

    if provider_tag then
        local prov = provider_tag:lower()
        if not providers[prov] then
            clink.print("Warning: unknown provider '" .. prov .. "' in REX_API_KEY entry, skipping.")
            return nil
        end
        local id = label or (prov .. "-" .. idx)
        return {id = id, provider = prov, key = key}
    end

    -- Auto-detect from key pattern
    key = rest
    local prov = M._detect_provider(key)
    if not prov then
        clink.print("Warning: could not detect provider for REX_API_KEY entry, skipping.")
        return nil
    end
    local id = label or (prov .. "-" .. idx)
    return {id = id, provider = prov, key = key}
end

function M._detect_provider(key)
    if key:find("^sk%-ant%-") then return "anthropic" end
    if key:find("^gsk_")     then return "groq" end
    if key:find("^xai%-")    then return "xai" end
    if key:find("^sk%-")     then return "openai" end
    return nil
end

-- ================================================================
-- Credential resolution
-- ================================================================

--- Ensure credentials are parsed from the live REX_API_KEY.
--- Returns the credentials array, parsing on demand if the cache is empty.
--- This is the critical path that prevents "No valid credential found"
--- when REX_API_KEY is set but the in-memory cache hasn't been populated.
function M.ensure_credentials()
    local creds = state_mod.get_credentials()
    if creds and #creds > 0 then
        return creds
    end
    return M.parse_credentials()
end

--- Get a credential by ID from the current in-memory cache.
function M.get_credential(cred_id)
    local creds = state_mod.get_credentials()
    if not creds then return nil end
    for _, c in ipairs(creds) do
        if c.id == cred_id then return c end
    end
    return nil
end

--- Resolve the credential for the current effective selection.
--- Always ensures credentials are parsed from the live environment first.
function M.resolve_credential()
    local creds, err = M.ensure_credentials()
    if not creds or #creds == 0 then
        return nil, err
    end

    local eff_cred = state_mod.effective_credential()
    if eff_cred then
        local c = M.get_credential(eff_cred)
        if c then return c end
        -- Configured credential not found in current REX_API_KEY
        return nil, 'Configured credential "' .. eff_cred
            .. '" is not present in current REX_API_KEY. Use /model or update REX_API_KEY.'
    end

    -- Fallback: first credential
    return creds[1]
end

-- ================================================================
-- Model listing
-- ================================================================

--- Fetch models from a single credential's provider API.
--- Returns an array of {id, credential, provider} or nil + error.
function M.fetch_models(cred)
    if not cred then return nil, "No credential" end

    local cached = state_mod.get_cached_models(cred.id)
    if cached then return cached end

    local prov = providers[cred.provider]
    if not prov then return nil, "Unknown provider: " .. (cred.provider or "nil") end

    local url = prov.base_url .. prov.models_path
    local headers = M._build_auth_headers(cred)

    if cred.provider == "github" then
        headers[#headers + 1] = {name = "Accept", value = "application/vnd.github+json"}
        headers[#headers + 1] = {name = "X-GitHub-Api-Version", value = "2026-03-10"}
    end

    local body, err = M._http_get(url, headers)
    if not body then return nil, err end

    local data, parse_err = json.decode(body)
    if not data then return nil, "JSON parse error: " .. (parse_err or "unknown") end

    local models = {}

    if cred.provider == "github" then
        -- GitHub returns a top-level array of catalog entries
        if type(data) ~= "table" then
            return nil, "Unexpected GitHub model response format"
        end
        for _, entry in ipairs(data) do
            if type(entry) == "table" and prov.filter(entry) then
                local model_id = entry.id or entry.name
                if model_id then
                    models[#models + 1] = {
                        id = model_id,
                        credential = cred.id,
                        provider = cred.provider,
                    }
                end
            end
        end
    else
        -- Standard {data: [...]} format (Anthropic, OpenAI, Groq, xAI)
        local items = data.data
        if not items or type(items) ~= "table" then
            return nil, "Unexpected model response format"
        end
        for _, item in ipairs(items) do
            if type(item) == "table" and item.id then
                if prov.filter(item.id) then
                    models[#models + 1] = {
                        id = item.id,
                        credential = cred.id,
                        provider = cred.provider,
                    }
                end
            end
        end
    end

    table.sort(models, function(a, b) return a.id < b.id end)
    state_mod.set_cached_models(cred.id, models)
    return models
end

--- Fetch models from all configured credentials, merge into one sorted list.
function M.fetch_all_models()
    local creds, cred_err = M.ensure_credentials()
    if not creds or #creds == 0 then
        return nil, cred_err or "No credentials configured."
    end

    local merged = {}
    local errors = {}
    local any_ok = false

    for _, cred in ipairs(creds) do
        local models, err = M.fetch_models(cred)
        if models then
            for _, m in ipairs(models) do
                merged[#merged + 1] = m
            end
            any_ok = true
        else
            errors[cred.id] = err
        end
    end

    if not any_ok then
        return nil, "Failed to fetch models from all credentials."
    end

    return merged, errors
end

-- ================================================================
-- HTTP transport
-- ================================================================

function M._build_auth_headers(cred)
    local headers = {}
    local prov = providers[cred.provider]
    if not prov then return headers end

    if prov.auth_type == "x-api-key" then
        headers[#headers + 1] = {name = "x-api-key", value = cred.key}
        headers[#headers + 1] = {name = "anthropic-version", value = "2023-06-01"}
    elseif prov.auth_type == "bearer" then
        headers[#headers + 1] = {name = "Authorization", value = "Bearer " .. cred.key}
    elseif prov.auth_type == "bearer-github" then
        headers[#headers + 1] = {name = "Authorization", value = "Bearer " .. cred.key}
        headers[#headers + 1] = {name = "Accept", value = "application/vnd.github+json"}
        headers[#headers + 1] = {name = "X-GitHub-Api-Version", value = "2026-03-10"}
    end
    return headers
end

function M._headers_to_curl_args(headers)
    local args = {}
    for _, h in ipairs(headers) do
        args[#args + 1] = '-H "' .. h.name .. ": " .. h.value .. '"'
    end
    return table.concat(args, " ")
end

--- HTTP GET request via curl.
function M._http_get(url, headers, timeout)
    timeout = timeout or 30
    local header_args = M._headers_to_curl_args(headers)
    local cmd = 'curl -s --max-time ' .. timeout .. ' ' .. header_args .. ' "' .. url .. '"'
    local pipe = io.popen(cmd .. " 2>nul")
    if not pipe then return nil, "Failed to execute curl" end
    local body = pipe:read("*a")
    pipe:close()
    if not body or body == "" then
        return nil, "Empty response from " .. url
    end
    return body
end

--- HTTP POST request via curl, using a temp file for the body to
--- avoid shell-escaping issues on Windows.
function M._http_post(url, headers, body_str, timeout)
    timeout = timeout or 120

    local temp_dir = os.getenv("TEMP") or os.getenv("TMP") or "."
    local temp_path = temp_dir .. "\\rex_" .. os.time() .. "_" .. math.random(10000, 99999) .. ".json"
    local tf = io.open(temp_path, "w")
    if not tf then return nil, "Failed to write temp file" end
    tf:write(body_str)
    tf:close()

    local header_args = M._headers_to_curl_args(headers)
    local cmd = 'curl -s --max-time ' .. timeout .. ' -X POST '
        .. header_args
        .. ' -H "Content-Type: application/json"'
        .. ' -d @"' .. temp_path .. '"'
        .. ' "' .. url .. '"'

    local pipe = io.popen(cmd .. " 2>nul")
    local response = ""
    if pipe then
        response = pipe:read("*a") or ""
        pipe:close()
    end

    os.remove(temp_path)

    if response == "" then
        return nil, "Empty response from API"
    end
    return response
end

-- ================================================================
-- Request body assembly
-- ================================================================

--- Build the request body table for a given provider.
function M.build_request_body(provider, model_id, messages, system_prompt, mode_params, tools)
    local max_tokens = state_mod.effective_max_tokens()
    local body = {}

    if provider == "anthropic" then
        body.model = model_id
        body.max_tokens = max_tokens
        body.system = system_prompt
        body.messages = messages
        if tools and #tools > 0 then
            body.tools = tools
        end
    else
        -- OpenAI-compatible: openai, github, groq, xai
        body.model = model_id
        body.max_tokens = max_tokens
        local all_msgs = {{role = "system", content = system_prompt}}
        for _, m in ipairs(messages) do
            all_msgs[#all_msgs + 1] = m
        end
        body.messages = all_msgs
        if tools and #tools > 0 then
            body.tools = tools
        end
    end

    -- Deep-merge mode params into the request body
    if mode_params then
        M._deep_merge(body, mode_params)
    end

    return body
end

--- Deep-merge src into dst (modifies dst in place).
function M._deep_merge(dst, src)
    for k, v in pairs(src) do
        if type(v) == "table" and type(dst[k]) == "table" then
            M._deep_merge(dst[k], v)
        else
            dst[k] = v
        end
    end
end

-- ================================================================
-- Web search tool resolution
-- ================================================================

--- Determine whether to attach web-search tools for the current request.
--- Conservative: only attaches when model-level and endpoint-level support
--- are both confirmed.  Returns an array of tool definitions, or nil.
function M.resolve_web_search_tools(provider, credential_id, model_id)
    -- Session-level denial (from a prior unsupported-tool error)
    if state_mod.is_web_search_denied(provider, credential_id, model_id) then
        return nil
    end

    local caps = state_mod.resolve_capabilities(provider, model_id)

    -- Explicit false or omitted (unknown) -> no web search
    if caps.web_search ~= true then
        return nil
    end

    -- Check endpoint family support
    if provider == "anthropic" then
        return {{type = "web_search_20250305", name = "web_search"}}
    elseif provider == "openai" then
        return {{type = "web_search_preview"}}
    end

    -- GitHub, Groq, xAI: no web search support at the endpoint level
    return nil
end

-- ================================================================
-- Request execution with retry
-- ================================================================

--- Send a chat request and return the extracted text response.
--- Returns (text, nil) on success, (nil, error_msg, error_type) on failure.
--- Retries transient failures with bounded backoff.
function M.send_request(system_prompt, messages, mode_id)
    local provider = state_mod.effective_provider()
    local model_id = state_mod.effective_model()

    if not provider or not model_id then
        return nil, "No model configured. Use /model to select one."
    end

    -- Resolve credential from live environment -- never fail without checking
    local cred, cred_err = M.resolve_credential()
    if not cred then
        return nil, cred_err or "No valid credential found."
    end

    local prov = providers[cred.provider]
    if not prov then
        return nil, "Unknown provider: " .. cred.provider
    end

    -- Resolve mode params from modes.json
    local mode_params = nil
    if mode_id and mode_id ~= "default" then
        local modes = state_mod.resolve_modes(provider, model_id)
        for _, m in ipairs(modes) do
            if m.id == mode_id then
                mode_params = m.params
                break
            end
        end
    end

    -- Resolve web search tools
    local tools = M.resolve_web_search_tools(provider, cred.id, model_id)

    local body = M.build_request_body(provider, model_id, messages, system_prompt, mode_params, tools)
    local body_str = json.encode(body)
    if not body_str then
        return nil, "Failed to encode request body."
    end

    local url = prov.base_url .. prov.chat_path
    local headers = M._build_auth_headers(cred)
    local timeout = state_mod.effective_timeout()

    -- Send with retry for transient failures
    local max_retries = 3
    local backoff = 2

    for attempt = 1, max_retries do
        local response, http_err = M._http_post(url, headers, body_str, timeout)
        if not response then
            if attempt < max_retries then
                -- Use ping as a portable sleep on Windows
                os.execute("ping -n " .. (backoff + 1) .. " 127.0.0.1 >nul 2>&1")
                backoff = backoff * 2
            else
                return nil, "Network error: " .. (http_err or "unknown")
            end
        else
            local data, parse_err = json.decode(response)
            if not data then
                return nil, "Failed to parse API response."
            end

            local err_type, err_msg = M._classify_error(data, provider)

            if err_type == "transient" then
                if attempt < max_retries then
                    os.execute("ping -n " .. (backoff + 1) .. " 127.0.0.1 >nul 2>&1")
                    backoff = backoff * 2
                else
                    return nil, err_msg, "transient"
                end

            elseif err_type == "unsupported_tool" then
                -- Retry once without web search tools
                state_mod.deny_web_search(provider, cred.id, model_id)
                body.tools = nil
                body_str = json.encode(body)
                local resp2, err2 = M._http_post(url, headers, body_str, timeout)
                if not resp2 then
                    return nil, "Network error on retry: " .. (err2 or "unknown")
                end
                local data2 = json.decode(resp2)
                if not data2 then
                    return nil, "Failed to parse API response on retry."
                end
                local err_type2, err_msg2 = M._classify_error(data2, provider)
                if err_type2 then
                    return nil, err_msg2, err_type2
                end
                return M._extract_response(data2, provider)

            elseif err_type then
                return nil, err_msg, err_type
            end

            return M._extract_response(data, provider)
        end
    end

    return nil, "Request failed after retries."
end

-- ================================================================
-- Error classification
-- ================================================================

--- Classify an API error response.
--- Returns (error_type, message) or (nil, nil) if no error detected.
function M._classify_error(data, provider)
    if not data then return "invalid", "Empty response" end

    if provider == "anthropic" then
        if data.error then
            local err = data.error
            local msg = err.message or "Unknown error"
            local etype = err.type or ""

            if etype == "overloaded_error" or etype == "rate_limit_error" then
                return "transient", msg
            end
            if msg:find("does not support tool types") then
                return "unsupported_tool", msg
            end
            if msg:find("web_search") and msg:find("tool") then
                return "unsupported_tool", msg
            end
            return "invalid", msg
        end
    else
        -- OpenAI-compatible error format (openai, github, groq, xai)
        if data.error then
            local err = data.error
            local msg = type(err) == "table" and (err.message or "Unknown error") or tostring(err)
            local code = type(err) == "table" and err.code or nil

            if code == "rate_limit_exceeded" or code == "server_error"
                or msg:find("overloaded") or msg:find("rate limit")
                or msg:find("503") or msg:find("529") then
                return "transient", msg
            end
            if msg:find("tool") and (msg:find("unsupported") or msg:find("not supported")) then
                return "unsupported_tool", msg
            end
            return "invalid", msg
        end
    end

    return nil, nil
end

-- ================================================================
-- Response extraction
-- ================================================================

--- Extract the assistant text from a successful API response.
--- Provider-level "missing content" is reported only when the parsed
--- response truly lacks usable text in that provider's documented fields.
function M._extract_response(data, provider)
    if not data then return nil, "Empty response data" end

    if provider == "anthropic" then
        local content = data.content
        if not content or type(content) ~= "table" then
            return nil, "No content in Anthropic response"
        end
        local parts = {}
        for _, block in ipairs(content) do
            if type(block) == "table" and block.type == "text" and block.text then
                parts[#parts + 1] = block.text
            end
        end
        if #parts == 0 then
            return nil, "No text content in Anthropic response"
        end
        return table.concat(parts)
    else
        -- OpenAI-compatible: response.choices[0].message.content
        local choices = data.choices
        if not choices or type(choices) ~= "table" or #choices == 0 then
            return nil, "No choices in response"
        end
        local msg = choices[1].message
        if not msg or not msg.content then
            return nil, "No message content in response"
        end
        return msg.content
    end
end

return M
