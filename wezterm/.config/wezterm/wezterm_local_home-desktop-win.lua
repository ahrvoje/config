local wezterm = require 'wezterm'

return {
  leader = { key = '`', mods = 'ALT', timeout_milliseconds = 9999 },

  font = wezterm.font 'Consolas',
  font_size = 12,
  window_frame = { font_size = 12 },

  keys = {
    { key = 'j', mods = 'LEADER', action = wezterm.action.SendString 'c:/Julia-1.10.4/bin/julia.exe' },
    { key = 'p', mods = 'LEADER', action = wezterm.action.SendString 'c:/Python313_64/python.exe' },
    { key = 't', mods = 'LEADER', action = wezterm.action.SendString 'c:/Python313_64/Scripts/ptpython.exe' },
  },
  
  launch_menu = {
    {
      label = 'zsh (msys64)',
      args = { 'C:/msys64/usr/bin/zsh.exe', '-l' },
    },
    {
      label = 'Neovim',
      args = { 'nvim.bat' },
    },
    {
      label = 'Git Bash',
      args = { 'c:/Program Files/Git/bin/bash.exe', '-i', '-l' },
    },
    {
      label = 'PowerShell 7',
      args = { 'pwsh.exe', '-NoLogo'},
    },
    {
      label = 'MSYS2',
      args = {
        'C:/msys64/usr/bin/env.exe',
          'MSYSTEM=MSYS',
          '/bin/bash',
          '--login'
      },
    },
    {
      label = 'Nu',
      args = { 'nu.bat' },
    }
  },

  default_prog = {
    'cmd.exe', '/s', '/k',
      -- set Unicode coding page 65001
      'chcp', '65001', '>', 'nul', '&&',
      
      -- and inject clink into the command prompt
      'clink', 'inject', '-q'
  },
  
  window_pos = { x = 450, y = 200 },
}
