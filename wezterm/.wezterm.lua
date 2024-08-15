local wezterm = require 'wezterm'
local act = wezterm.action

local config = wezterm.config_builder()

config.audible_bell = 'Disabled'
config.check_for_updates = false
config.disable_default_key_bindings = true
config.enable_scroll_bar = true
config.font = wezterm.font 'Consolas'
config.inactive_pane_hsb = { hue = 1.0, saturation = 0.3, brightness = 0.4 }
config.initial_cols = 101
config.initial_rows = 36
config.window_decorations = 'RESIZE'
config.window_padding = { left = 0, right = 0, top = 0, bottom = 0 }

config.colors = {
  background = '#000B07',
}

config.keys = {
  { key = 't',          mods = 'CTRL',  action = act.SpawnTab 'CurrentPaneDomain' },
  { key = 'w',          mods = 'CTRL',  action = act.CloseCurrentTab{ confirm = true } },
  { key = 'LeftArrow',  mods = 'CTRL',  action = act.ActivateTabRelative(-1) },
  { key = 'RightArrow', mods = 'CTRL',  action = act.ActivateTabRelative(1) },
  { key = 'RightArrow', mods = 'ALT',   action = act.SplitHorizontal{ domain =  'CurrentPaneDomain' } },
  { key = 'DownArrow',  mods = 'ALT',   action = act.SplitVertical{ domain =  'CurrentPaneDomain' } },
  { key = 'LeftArrow',  mods = 'SHIFT', action = act.ActivatePaneDirection 'Left', },
  { key = 'RightArrow', mods = 'SHIFT', action = act.ActivatePaneDirection 'Right', },
  { key = 'UpArrow',    mods = 'SHIFT', action = act.ActivatePaneDirection 'Up', },
  { key = 'DownArrow',  mods = 'SHIFT', action = act.ActivatePaneDirection 'Down', },
  { key = '1',          mods = 'ALT',   action = act.ActivateTab(0) },
  { key = '2',          mods = 'ALT',   action = act.ActivateTab(1) },
  { key = '3',          mods = 'ALT',   action = act.ActivateTab(2) },
  { key = '4',          mods = 'ALT',   action = act.ActivateTab(3) },
  { key = '5',          mods = 'ALT',   action = act.ActivateTab(4) },
  { key = '6',          mods = 'ALT',   action = act.ActivateTab(5) },
  { key = '7',          mods = 'ALT',   action = act.ActivateTab(6) },
  { key = '8',          mods = 'ALT',   action = act.ActivateTab(7) },
  { key = '9',          mods = 'ALT',   action = act.ActivateTab(8) },
  { key = 'Enter',      mods = 'ALT',   action = act.ShowLauncher },
  { key = 'Enter',      mods = 'CTRL',  action = act.ShowTabNavigator },
  { key = 'l',          mods = 'CTRL',  action = act.ShowDebugOverlay },
  { key = '+',          mods = 'CTRL',  action='IncreaseFontSize' },
  { key = '-',          mods = 'CTRL',  action='DecreaseFontSize' },
  { key = '0',          mods = 'CTRL',  action='ResetFontSize' },
}

if wezterm.target_triple == 'x86_64-pc-windows-msvc' then
  config.set_environment_variables = {
    prompt = '$E[92m$P$E[36m $E[93m$+$E[36m$G$G$G$E[0m ',
  }

  -- And inject clink into the command prompt
  config.default_prog =
    { 'cmd.exe', '/s', '/k', 'c:/utils/clink/clink_x64.exe', 'inject', '-q' }
end


local launch_menu = {}

if wezterm.target_triple == 'x86_64-pc-windows-msvc' then
  table.insert(launch_menu, {
	label = 'Git Bash',
    args = { 'c:/Program Files/Git/bin/bash.exe', '-i', '-l' },
  })
	
  table.insert(launch_menu, {
    label = 'PowerShell',
    args = { 'powershell.exe', '-NoLogo'}
  })
end

config.launch_menu = launch_menu

return config
