local wezterm = require 'wezterm'

local home = wezterm.home_dir:gsub('\\', '/')
local local_appdata = (os.getenv('LOCALAPPDATA') or (home .. '/AppData/Local')):gsub('\\', '/')

local function home_path(path)
  return home .. '/' .. path
end

local function local_appdata_path(path)
  return local_appdata .. '/' .. path
end

return {
  front_end = 'WebGpu',

  font = wezterm.font 'Consolas',
  font_size = 12,
  window_frame = { font_size = 12 },
  window_pos = { x = 450, y = 200 },

  keys = {
    { key = 'j', mods = 'LEADER', action = wezterm.action.SendString 'C:/Julia-1.11.5/bin/julia.exe' },
    { key = 'p', mods = 'LEADER', action = wezterm.action.SendString(local_appdata_path('Programs/Python/Python314/python.exe')) },
    { key = 't', mods = 'LEADER', action = wezterm.action.SendString(local_appdata_path('Programs/Python/Python314/Scripts/ptpython.exe')) },
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
      args = { 'C:/Program Files/Git/bin/bash.exe', '-i', '-l' },
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
      args = { local_appdata_path('Programs/nu/nu.exe') },
    }
  },
  
  default_prog = {
    'cmd.exe', '/s', '/k',
      -- and inject clink into the command prompt
      'clink', 'inject', '-q', '&&',
      -- set cmd aliases
      home_path('cmdrc.cmd')
  },
}
