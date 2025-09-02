local wezterm = require 'wezterm'

return {
  leader = { key = 'q', mods = 'ALT', timeout_milliseconds = 9999 },

  font = wezterm.font 'Consolas',
  font_size = 12,
  window_frame = { font_size = 12 },

  keys = {
    { key = 'a', mods = 'LEADER', action = wezterm.action.SendString 'C:/Python313-64/python.exe \"C:/Users/u14e48/OneDrive - AVL List GmbH/AVL_AddressBook/src/address_book_main.py\"' },
    { key = 'j', mods = 'LEADER', action = wezterm.action.SendString 'C:/Users/u14e48/AppData/Local/Programs/Julia-1.11.5/bin/julia.exe' },
    { key = 'n', mods = 'LEADER', action = wezterm.action.SendString 'C:/Users/u14e48/AppData/Local/Programs/nu/nu.exe\r' },
    { key = 'o', mods = 'LEADER', action = wezterm.action.SendString 'ls -l \"C:/Users/u14e48/AppData/Local/Microsoft/Outlook/Offline Address Books/ef1c1fc4-9c01-46f1-a73e-7fc0639bf8e3/\"\r' },
    { key = 'p', mods = 'LEADER', action = wezterm.action.SendString 'C:/Python313-64/python.exe' },
    { key = 'r', mods = 'LEADER', action = wezterm.action.SendString 'C:/repos/\r' },
    { key = 't', mods = 'LEADER', action = wezterm.action.SendString 'C:/Python313-64/Scripts/ptpython.exe' },
  },
  
  launch_menu = {
    {
      label = 'zsh (msys64)',
      args = { 'C:/Users/u14e48/AppData/Local/Programs/msys64/usr/bin/zsh.exe', '-l' },
    },
    {
      label = 'Neovim',
      args = { 'nvim.bat' },
    },
    {
      label = 'Git Bash',
      args = { 'C:/Program Files/Git/bin/bash.exe', '-i', '-l' },
    },
    {
      label = 'PowerShell 7',
      args = { 'pwsh.exe', '-NoLogo'},
    },
    {
      label = 'MSYS2',
      args = {
        'C:/Users/u14e48/AppData/Local/Programs/msys64/usr/bin/env.exe',
          'MSYSTEM=MSYS',
          '/bin/bash',
          '--login'
      },
    },
    {
      label = 'Nu',
      args = { 'C:/Users/u14e48/AppData/Local/Programs/nu/nu.exe' },
    }
  },

  default_prog = {
    'cmd.exe', '/s', '/k',
      -- and inject clink into the command prompt
      'clink', 'inject', '-q', '&&',
      -- set cmd aliases
      'C:/Users/u14e48/cmdrc.cmd'
  },
  
  window_pos = { x = 450, y = 200 },
}
