local wezterm = require 'wezterm'

return {
  leader = { key = '“', mods = 'SUPER', timeout_milliseconds = 9999 },
  
  font = nil,
  font_size = 14,
  window_frame = { font_size = 18 },

  launch_menu = nil,
  default_prog = nil,
      
  window_pos = {
    x = 450,
    y = 200,
  },
}
