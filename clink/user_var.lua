-- set terminal UserVar 'clink' to 'on'/'off' on enter/exit
-- b64 utility just in case
-- local function b64(s)
--   local enc = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
--   local t, l = {}, #s
--   for i = 1, l, 3 do
--     local a = s:byte(i)     or 0
--     local b = s:byte(i + 1) or 0
--     local c = s:byte(i + 2) or 0
--     local n = a * 65536 + b * 256 + c
-- 
--     local c1 = math.floor(n / 262144) % 64  -- 2^18
--     local c2 = math.floor(n / 4096)   % 64  -- 2^12
--     local c3 = math.floor(n / 64)     % 64  -- 2^6
--     local c4 = n % 64
-- 
--     local out3 = (i + 1 <= l) and enc:sub(c3 + 1, c3 + 1) or '='
--     local out4 = (i + 2 <= l) and enc:sub(c4 + 1, c4 + 1) or '='
-- 
--     t[#t + 1] = enc:sub(c1 + 1, c1 + 1)
--     t[#t + 1] = enc:sub(c2 + 1, c2 + 1)
--     t[#t + 1] = out3
--     t[#t + 1] = out4
--   end
-- 
--   return table.concat(t)
-- end

local function set_user_var(name, b64val)
  local osc = string.format('\27]1337;SetUserVar=%s=%s\7', name, b64val)
  if not os.getenv('TMUX') then
    io.stdout:write(osc)
  else
    io.stdout:write('\27Ptmux;\27' .. osc .. '\27\\')
  end
  io.stdout:flush()
end

local on_enter = function()
  set_user_var('clink', 'b24=')  -- base64('on') = 'b24='
end

local on_exit = function(line)
  set_user_var('clink', 'b2Zm')  -- base64('off') = 'b2Zm'
end

clink.onbeginedit(on_enter)
clink.onendedit(on_exit)
