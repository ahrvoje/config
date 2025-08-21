-- set terminal UserVar 'clink' to 'on'/'off' on enter/exit
local b64 = function(s)
  local t=os.tmpname()
  local f=io.open(t,'wb')
  f:write(s)
  f:close()

  local r=io.popen(('base64 "%s"'):format(t),'r'):read('*a')
  os.remove(t)

  return(r:gsub('%s+$',''))
end


local function set_user_var(name, val)
  local osc = string.format('\27]1337;SetUserVar=%s=%s\7', name, b64(val))
  if not os.getenv('TMUX') then
    io.stdout:write(osc)
  else
    io.stdout:write('\27Ptmux;\27' .. osc .. '\27\\')
  end
  io.stdout:flush()
end

local on_enter = function()
  set_user_var('clink', 'on')
end

local on_exit = function(line)
  set_user_var('clink', 'off')
end

clink.onbeginedit(on_enter)
clink.onendedit(on_exit)
