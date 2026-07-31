-- json.lua — Minimal JSON encoder/decoder for Lua 5.2
-- Bundled with Rex. No external dependencies.

local json = {}

-- Sentinel value representing JSON null. Stored in decoded tables where
-- the source contained an explicit null, so arrays keep their indices.
json.null = setmetatable({}, {__tostring = function() return "null" end})

-- ================================================================
-- Decode
-- ================================================================

local decode_value -- forward declaration

local escape_chars = {
    ['"']  = '"',  ['\\'] = '\\', ['/'] = '/',
    ['b']  = '\b', ['f']  = '\f', ['n'] = '\n',
    ['r']  = '\r', ['t']  = '\t',
}

local function skip_ws(s, pos)
    -- Advance past any whitespace. The () capture returns the new position.
    return s:match("^%s*()", pos)
end

local function decode_string(s, pos)
    -- pos is the index immediately after the opening double-quote.
    local buf = {}
    while pos <= #s do
        local c = s:byte(pos)
        if c == 34 then -- closing "
            return table.concat(buf), pos + 1
        elseif c == 92 then -- backslash
            pos = pos + 1
            local esc = s:sub(pos, pos)
            if escape_chars[esc] then
                buf[#buf + 1] = escape_chars[esc]
            elseif esc == "u" then
                local hex = s:sub(pos + 1, pos + 4)
                local code = tonumber(hex, 16)
                if not code then error("invalid \\u escape") end
                pos = pos + 4
                -- Combine a UTF-16 surrogate pair into one code point.
                if code >= 0xD800 and code <= 0xDBFF and s:sub(pos + 1, pos + 2) == "\\u" then
                    local lo = tonumber(s:sub(pos + 3, pos + 6), 16)
                    if lo and lo >= 0xDC00 and lo <= 0xDFFF then
                        code = 0x10000 + (code - 0xD800) * 0x400 + (lo - 0xDC00)
                        pos = pos + 6
                    end
                end
                -- Encode code point as UTF-8.
                if code < 0x80 then
                    buf[#buf + 1] = string.char(code)
                elseif code < 0x800 then
                    buf[#buf + 1] = string.char(
                        0xC0 + math.floor(code / 64),
                        0x80 + (code % 64))
                elseif code < 0x10000 then
                    buf[#buf + 1] = string.char(
                        0xE0 + math.floor(code / 4096),
                        0x80 + math.floor((code % 4096) / 64),
                        0x80 + (code % 64))
                else
                    buf[#buf + 1] = string.char(
                        0xF0 + math.floor(code / 262144),
                        0x80 + math.floor(code / 4096) % 64,
                        0x80 + math.floor(code / 64) % 64,
                        0x80 + (code % 64))
                end
            else
                error("invalid escape: \\" .. esc)
            end
        else
            buf[#buf + 1] = s:sub(pos, pos)
        end
        pos = pos + 1
    end
    error("unterminated string")
end

local function decode_number(s, pos)
    local num_str = s:match("^%-?%d+%.?%d*[eE]?[%+%-]?%d*", pos)
    if not num_str or num_str == "" then error("invalid number") end
    local n = tonumber(num_str)
    if not n then error("invalid number: " .. num_str) end
    return n, pos + #num_str
end

local function decode_array(s, pos)
    local arr = {}
    pos = skip_ws(s, pos)
    if s:byte(pos) == 93 then return arr, pos + 1 end -- empty ]
    local idx = 0
    while true do
        idx = idx + 1
        local val
        val, pos = decode_value(s, pos)
        -- Use rawset so json.null (non-nil sentinel) is stored correctly,
        -- and ordinary values work as expected.
        rawset(arr, idx, val)
        pos = skip_ws(s, pos)
        local c = s:byte(pos)
        if c == 93 then return arr, pos + 1 end     -- ]
        if c ~= 44 then error("expected ',' or ']'") end -- ,
        pos = skip_ws(s, pos + 1)
    end
end

local function decode_object(s, pos)
    local obj = {}
    pos = skip_ws(s, pos)
    if s:byte(pos) == 125 then return obj, pos + 1 end -- empty }
    while true do
        if s:byte(pos) ~= 34 then error("expected string key") end -- "
        local key
        key, pos = decode_string(s, pos + 1)
        pos = skip_ws(s, pos)
        if s:byte(pos) ~= 58 then error("expected ':'") end -- :
        pos = skip_ws(s, pos + 1)
        local val
        val, pos = decode_value(s, pos)
        obj[key] = val
        pos = skip_ws(s, pos)
        local c = s:byte(pos)
        if c == 125 then return obj, pos + 1 end      -- }
        if c ~= 44 then error("expected ',' or '}'") end -- ,
        pos = skip_ws(s, pos + 1)
    end
end

decode_value = function(s, pos)
    pos = skip_ws(s, pos)
    local c = s:byte(pos)
    if c == 34  then return decode_string(s, pos + 1)              end -- "
    if c == 123 then return decode_object(s, skip_ws(s, pos + 1))  end -- {
    if c == 91  then return decode_array(s, skip_ws(s, pos + 1))   end -- [
    if c == 116 then -- t
        if s:sub(pos, pos + 3) == "true" then return true, pos + 4 end
    end
    if c == 102 then -- f
        if s:sub(pos, pos + 4) == "false" then return false, pos + 5 end
    end
    if c == 110 then -- n
        if s:sub(pos, pos + 3) == "null" then return json.null, pos + 4 end
    end
    if c == 45 or (c >= 48 and c <= 57) then -- minus or digit
        return decode_number(s, pos)
    end
    error("unexpected character at position " .. tostring(pos))
end

--- Decode a JSON string into a Lua value.
--- Returns (value) on success, (nil, error_message) on failure.
function json.decode(s)
    if type(s) ~= "string" or s == "" then
        return nil, "invalid input"
    end
    local ok, result, pos = pcall(decode_value, s, 1)
    if not ok then
        return nil, tostring(result)
    end
    return result
end

-- ================================================================
-- Encode
-- ================================================================

local encode_value -- forward declaration

local encode_escapes = {
    ['"']  = '\\"',  ['\\'] = '\\\\',
    ['\n'] = '\\n',  ['\r'] = '\\r',
    ['\t'] = '\\t',  ['\b'] = '\\b',
    ['\f'] = '\\f',
}

local function encode_string(s)
    return '"' .. s:gsub('["\\\n\r\t\b\f]', encode_escapes)
                     :gsub('[%c]', function(c)
                         return string.format('\\u%04x', c:byte())
                     end) .. '"'
end

-- A table is an array when its only keys are consecutive integers 1..n.
-- Empty tables are encoded as objects (safer default for API payloads).
local function is_array(t)
    local n = #t
    if n == 0 then return false end
    local count = 0
    for _ in pairs(t) do count = count + 1 end
    return count == n
end

encode_value = function(v)
    if v == nil or v == json.null then return "null" end
    local t = type(v)
    if t == "boolean" then return v and "true" or "false" end
    if t == "number" then
        if v ~= v then return "null" end                  -- NaN
        if v == math.huge or v == -math.huge then return "null" end
        if v == math.floor(v) and math.abs(v) < 2^53 then
            return string.format("%d", v)
        end
        return tostring(v)
    end
    if t == "string" then return encode_string(v) end
    if t == "table" then
        if is_array(v) then
            local parts = {}
            for i = 1, #v do
                parts[i] = encode_value(v[i])
            end
            return "[" .. table.concat(parts, ",") .. "]"
        else
            local parts = {}
            for k, val in pairs(v) do
                if type(k) == "string" then
                    parts[#parts + 1] = encode_string(k) .. ":" .. encode_value(val)
                end
            end
            return "{" .. table.concat(parts, ",") .. "}"
        end
    end
    return "null"
end

--- Encode a Lua value as a JSON string.
--- Returns (json_string) on success, (nil, error_message) on failure.
function json.encode(v)
    local ok, result = pcall(encode_value, v)
    if not ok then
        return nil, tostring(result)
    end
    return result
end

return json
