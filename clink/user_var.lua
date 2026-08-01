-- Publish authoritative shell state to WezTerm without process inspection.
-- Values are display/routing hints only; no destructive action trusts them.

local enabled = os.getenv('WEZTERM_PANE') ~= nil
local in_tmux = os.getenv('TMUX') ~= nil
local command_seq = 0
local state_seq = 0

local function b64(s)
  local enc = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
  local out, len = {}, #s
  for i = 1, len, 3 do
    local a = s:byte(i) or 0
    local b = s:byte(i + 1) or 0
    local c = s:byte(i + 2) or 0
    local n = a * 65536 + b * 256 + c
    local c1 = math.floor(n / 262144) % 64
    local c2 = math.floor(n / 4096) % 64
    local c3 = math.floor(n / 64) % 64
    local c4 = n % 64
    out[#out + 1] = enc:sub(c1 + 1, c1 + 1)
    out[#out + 1] = enc:sub(c2 + 1, c2 + 1)
    out[#out + 1] = i + 1 <= len and enc:sub(c3 + 1, c3 + 1) or '='
    out[#out + 1] = i + 2 <= len and enc:sub(c4 + 1, c4 + 1) or '='
  end
  return table.concat(out)
end

local function osc(body)
  local sequence = '\27]' .. body .. '\7'
  if in_tmux then
    -- The prefix ESC plus the OSC's leading ESC produces tmux's required
    -- doubled inner ESC.
    return '\27Ptmux;\27' .. sequence .. '\27\\'
  end
  return sequence
end

local function user_var(name, value)
  return osc(string.format('1337;SetUserVar=%s=%s', name, b64(value)))
end

local function emit(parts)
  if not enabled then return end
  io.stdout:write(table.concat(parts))
  io.stdout:flush()
end

local function encode_uri_path(path)
  path = tostring(path or ''):gsub('\\', '/')
  return (path:gsub('[^%w/._~:-]', function(ch)
    return string.format('%%%02X', string.byte(ch))
  end))
end

local function current_cwd_osc()
  local cwd = os.getcwd and os.getcwd() or nil
  if type(cwd) ~= 'string' or cwd == '' then return nil end
  -- Empty authority plus /C:/... yields the canonical file:///C:/... URI.
  return osc('7;file:///' .. encode_uri_path(cwd):gsub('^/', ''))
end

local function command_label(line)
  line = tostring(line or ''):gsub('^%s*@?', '')
  local first = line:match('^"([^"]+)"') or line:match('^([^%s&|<>]+)') or 'cmd'
  first = first:gsub('^.*[\\/]', ''):gsub('%.%w+$', ''):lower()
  first = first:gsub('[^%w_.+-]', '')
  return first ~= '' and first or 'cmd'
end

local function on_begin_edit()
  local parts = {}
  local cwd = current_cwd_osc()
  if cwd then
    parts[#parts + 1] = cwd
    -- Marker follows OSC 7 in the same write. The WezTerm consumer therefore
    -- never invokes get_current_working_dir until terminal state owns the URI.
    parts[#parts + 1] = user_var('cwd_ready', tostring(state_seq + 1))
  end
  local state = {
    user_var('shell_integration', 'on'),
    user_var('shell_name', 'cmd'),
    user_var('shell_prompt', 'on'),
    user_var('process_name', 'cmd'),
    user_var('command_token', ''),
    user_var('nvim', 'off'),
    user_var('clink', 'on'),
  }
  for _, sequence in ipairs(state) do
    parts[#parts + 1] = sequence
  end
  state_seq = state_seq + 1
  parts[#parts + 1] = user_var('state_serial', tostring(state_seq))
  emit(parts)
end

local function on_end_edit(line)
  command_seq = command_seq + 1
  state_seq = state_seq + 1
  emit {
    user_var('shell_prompt', 'off'),
    user_var('process_name', command_label(line)),
    -- Opaque per-shell identity. WezTerm starts its own reliable elapsed clock
    -- when this changes; this is deliberately not an epoch timestamp.
    user_var('command_token', tostring(command_seq)),
    user_var('clink', 'off'),
    user_var('state_serial', tostring(state_seq)),
  }
end

clink.onbeginedit(on_begin_edit)
clink.onendedit(on_end_edit)
