local wezterm = require 'wezterm'
local act = wezterm.action

local config = wezterm.config_builder()

config.adjust_window_size_when_changing_font_size = false
config.audible_bell = 'Disabled'
config.check_for_updates = false
config.disable_default_key_bindings = true
config.enable_scroll_bar = true
config.font = wezterm.font 'Consolas'
config.font_size = 11
config.inactive_pane_hsb = { hue = 1.0, saturation = 0.3, brightness = 0.4 }
config.initial_cols = 120
config.initial_rows = 33
config.window_decorations = 'RESIZE'
config.window_padding = { left = 8, right = 8, top = 8, bottom = 8 }

-- Selection of dark themes with acceptable contrast
--
-- config.color_scheme = 'Bright (base16)'
config.color_scheme = 'Brogrammer'
-- config.color_scheme = 'Brogrammer (Gogh)'
-- config.color_scheme = 'Frontend Delight (Gogh)'
-- config.color_scheme = 'Gigavolt (base16)'
-- config.color_scheme = 'Gruber (base16)'
-- config.color_scheme = 'synthwave-everything'
-- config.color_scheme = 'Vs Code Dark+ (Gogh)'
-- config.color_scheme = 'Windows NT (base16)'


-- Ctrl+c has a double role:
--    KeyboardInterrupt if there is no selection
--    Copy to clipboard if selection is available
action_ctrl_c = function(window, pane)
  local sel = window:get_selection_text_for_pane(pane)
  if (not sel or sel == '') then
    window:perform_action(act.SendKey{ key='c', mods='CTRL' }, pane)
  else
    window:perform_action(act.CopyTo 'ClipboardAndPrimarySelection', pane)
  end
end

config.keys = {
  { key = 't',          mods = 'CTRL',       action = act.SpawnTab 'CurrentPaneDomain' },
  { key = 'w',          mods = 'CTRL',       action = act.CloseCurrentTab{ confirm = true } },
  { key = 'Tab',        mods = 'CTRL',       action = act.ActivateTabRelative(1) },
  { key = 'Tab',        mods = 'CTRL|SHIFT', action = act.ActivateTabRelative(-1) },
  { key = 'LeftArrow',  mods = 'CTRL',       action = act.ActivateTabRelative(-1) },
  { key = 'RightArrow', mods = 'CTRL',       action = act.ActivateTabRelative(1) },
  { key = 'RightArrow', mods = 'ALT',        action = act.SplitHorizontal{ domain =  'CurrentPaneDomain' } },
  { key = 'DownArrow',  mods = 'ALT',        action = act.SplitVertical{ domain =  'CurrentPaneDomain' } },
  { key = 'LeftArrow',  mods = 'SHIFT',      action = act.ActivatePaneDirection 'Left', },
  { key = 'RightArrow', mods = 'SHIFT',      action = act.ActivatePaneDirection 'Right', },
  { key = 'UpArrow',    mods = 'SHIFT',      action = act.ActivatePaneDirection 'Up', },
  { key = 'DownArrow',  mods = 'SHIFT',      action = act.ActivatePaneDirection 'Down', },
  { key = '1',          mods = 'ALT',        action = act.ActivateTab(0) },
  { key = '2',          mods = 'ALT',        action = act.ActivateTab(1) },
  { key = '3',          mods = 'ALT',        action = act.ActivateTab(2) },
  { key = '4',          mods = 'ALT',        action = act.ActivateTab(3) },
  { key = '5',          mods = 'ALT',        action = act.ActivateTab(4) },
  { key = '6',          mods = 'ALT',        action = act.ActivateTab(5) },
  { key = '7',          mods = 'ALT',        action = act.ActivateTab(6) },
  { key = '8',          mods = 'ALT',        action = act.ActivateTab(7) },
  { key = '9',          mods = 'ALT',        action = act.ActivateTab(8) },
  { key = 'Enter',      mods = 'ALT',        action = act.ShowLauncher },
  { key = 'Enter',      mods = 'CTRL',       action = act.ShowTabNavigator },
  { key = 'l',          mods = 'CTRL',       action = act.ShowDebugOverlay },
  { key = '=',          mods = 'CTRL',       action = act.IncreaseFontSize },
  { key = '-',          mods = 'CTRL',       action = act.DecreaseFontSize },
  { key = '0',          mods = 'CTRL',       action = act.ResetFontSize },
  { key = 'c',          mods = 'CTRL',       action = wezterm.action_callback(action_ctrl_c)},
  { key = 'v',          mods = 'CTRL',       action = act.PasteFrom 'Clipboard' },
  { key = 'x',          mods = 'CTRL',       action = act.ActivateCopyMode },
  { key = 's',          mods = 'CTRL',       action = act.Search 'CurrentSelectionOrEmptyString' },
  { key = 'Home',       mods = 'CTRL',       action = act.ScrollToTop },
  { key = 'End',        mods = 'CTRL',       action = act.ScrollToBottom },
  { key = 'PageUp',     mods = 'NONE',       action = act.ScrollByPage(-0.5) },
  { key = 'PageDown',   mods = 'NONE',       action = act.ScrollByPage(0.5) },
}

config.key_tables = {
  copy_mode = {
    { key = 'Escape',     mods = 'NONE', action = act.CopyMode 'Close' },
    { key = 'b',          mods = 'ALT',  action = act.CopyMode{ SetSelectionMode = 'Block' } },
    { key = 'c',          mods = 'ALT',  action = act.CopyMode{ SetSelectionMode = 'Cell' } },
    { key = 'w',          mods = 'ALT',  action = act.CopyMode{ SetSelectionMode = 'Word' } },
    { key = 'l',          mods = 'ALT',  action = act.CopyMode{ SetSelectionMode = 'Line' } },
    { key = 's',          mods = 'ALT',  action = act.CopyMode{ SetSelectionMode = 'SemanticZone' } },
    { key = 'LeftArrow',  mods = 'NONE', action = act.CopyMode 'MoveLeft' },
    { key = 'RightArrow', mods = 'NONE', action = act.CopyMode 'MoveRight' },
    { key = 'UpArrow',    mods = 'NONE', action = act.CopyMode 'MoveUp' },
    { key = 'DownArrow',  mods = 'NONE', action = act.CopyMode 'MoveDown' },
    { key = 'Enter',      mods = 'NONE', action = act.Multiple{
      { CopyTo   = 'Clipboard' },
      { CopyMode = 'ClearPattern' },
      { CopyMode = 'Close' } },
    },
  },
  
  search_mode = {
    { key = 'Escape',     mods = 'NONE', action = act.Multiple{
      { CopyMode = 'ClearPattern' },
      { CopyMode = 'Close' } },
    },
    { key = 'b',          mods = 'ALT',  action = act.CopyMode{ SetSelectionMode = 'Block' } },
    { key = 'c',          mods = 'ALT',  action = act.CopyMode{ SetSelectionMode = 'Cell' } },
    { key = 'w',          mods = 'ALT',  action = act.CopyMode{ SetSelectionMode = 'Word' } },
    { key = 'l',          mods = 'ALT',  action = act.CopyMode{ SetSelectionMode = 'Line' } },
    { key = 's',          mods = 'ALT',  action = act.CopyMode{ SetSelectionMode = 'SemanticZone' } },
    { key = 'PageUp',     mods = 'NONE', action = act.CopyMode 'PriorMatch' },
    { key = 'PageDown',   mods = 'NONE', action = act.CopyMode 'NextMatch' },
    { key = 'LeftArrow',  mods = 'NONE', action = act.CopyMode 'MoveLeft' },
    { key = 'RightArrow', mods = 'NONE', action = act.CopyMode 'MoveRight' },
    { key = 'UpArrow',    mods = 'NONE', action = act.CopyMode 'MoveUp' },
    { key = 'DownArrow',  mods = 'NONE', action = act.CopyMode 'MoveDown' },
    { key = 'Enter',      mods = 'NONE', action = act.Multiple{
      { CopyTo   = 'Clipboard' },
      { CopyMode = 'ClearPattern' },
      { CopyMode = 'Close' } },
    },
  },
}

if wezterm.target_triple == 'x86_64-pc-windows-msvc' then
  config.set_environment_variables = {
    prompt = '$E[92m$P$E[36m $E[93m$+$E[37m$G$G$G$E[0m ',
  }

  -- set Unicode coding page 65001
  -- and inject clink into the command prompt
  config.default_prog = {
    'cmd.exe', '/s', '/k', 'chcp 65001 > nul && c:/utils/clink/clink_x64.exe', 'inject', '-q',
  }
end


local launch_menu = {}

if wezterm.target_triple == 'x86_64-pc-windows-msvc' then
  table.insert(launch_menu, {
    label = 'Git Bash',
    args = { 'c:/Program Files/Git/bin/bash.exe', '-i', '-l' },
  })
  
  table.insert(launch_menu, {
    label = 'PowerShell',
    args = { 'powershell.exe', '-NoLogo'},
  })
end

config.launch_menu = launch_menu

return config
