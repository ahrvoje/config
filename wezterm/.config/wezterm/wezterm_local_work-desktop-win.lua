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
  leader = { key = 'q', mods = 'ALT', timeout_milliseconds = 9999 },
  front_end = 'WebGpu',

  font = wezterm.font 'Consolas',
  font_size = 12,
  window_frame = { font_size = 12 },

  keys = {
    { key = 'a', mods = 'LEADER', action = wezterm.action.SendString('C:/Python313-64/python.exe "' .. home_path('OneDrive - AVL List GmbH/AVL_AddressBook/src/address_book_main.py') .. '"') },
    { key = 'j', mods = 'LEADER', action = wezterm.action.SendString(local_appdata_path('Programs/Julia-1.11.5/bin/julia.exe')) },
    { key = 'n', mods = 'LEADER', action = wezterm.action.SendString(local_appdata_path('Programs/nu/nu.exe') .. '\r') },
    { key = 'o', mods = 'LEADER', action = wezterm.action.SendString('ls -l "' .. local_appdata_path('Microsoft/Outlook/Offline Address Books/ef1c1fc4-9c01-46f1-a73e-7fc0639bf8e3/') .. '"\r') },
    { key = 'p', mods = 'LEADER', action = wezterm.action.SendString 'C:/Python313-64/python.exe' },
    { key = 'r', mods = 'LEADER', action = wezterm.action.SendString 'C:/repos/\r' },
    { key = 't', mods = 'LEADER', action = wezterm.action.SendString 'C:/Python313-64/Scripts/ptpython.exe' },
  },
  
  launch_menu = {
    {
      label = 'zsh (msys64)',
      args = { local_appdata_path('Programs/msys64/usr/bin/zsh.exe'), '-l' },
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
        local_appdata_path('Programs/msys64/usr/bin/env.exe'),
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
  
  window_pos = { x = 450, y = 200 },
}
