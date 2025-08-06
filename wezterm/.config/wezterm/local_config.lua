local wezterm = require 'wezterm'

return {
  keys = {
    { key = 'j', mods = 'LEADER', action = wezterm.action.SendString 'c:/Julia-1.10.4/bin/julia.exe' },
    { key = 'p', mods = 'LEADER', action = wezterm.action.SendString 'c:/Python313_64/python.exe' },
    { key = 't', mods = 'LEADER', action = wezterm.action.SendString 'c:/Python313_64/Scripts/ptpython.exe' },
  },
  
  window_pos = {
    x = 450,
    y = 200,
  },
}
