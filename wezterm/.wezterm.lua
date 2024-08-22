local wezterm = require 'wezterm'
local act = wezterm.action

local config = wezterm.config_builder()


config.adjust_window_size_when_changing_font_size = false
config.audible_bell = 'Disabled'
config.check_for_updates = false
config.disable_default_key_bindings = true
config.font = wezterm.font 'Consolas'
config.font_size = 11
config.inactive_pane_hsb = { hue = 1.0, saturation = 0.3, brightness = 0.4 }
config.initial_cols = 124
config.initial_rows = 33
config.window_decorations = 'RESIZE'

-- Selection of dark themes with acceptable contrast
--
config.color_scheme = 'Bright (base16)'
-- config.color_scheme = 'Brogrammer'
-- config.color_scheme = 'Brogrammer (Gogh)'
-- config.color_scheme = 'Frontend Delight (Gogh)'
-- config.color_scheme = 'Gigavolt (base16)'
-- config.color_scheme = 'Gruber (base16)'
-- config.color_scheme = 'synthwave-everything'
-- config.color_scheme = 'Vs Code Dark+ (Gogh)'
-- config.color_scheme = 'Windows NT (base16)'

-- Scrollbar
config.enable_scroll_bar     = true
config.min_scroll_bar_height = '2cell'
config.colors                = { scrollbar_thumb = '#556666' }
config.window_padding        = { left = 8, right = 16, top = 4, bottom = 4 }  -- right padding is scrollbar width


get_process_name = function(pane)
  name = pane:get_foreground_process_name()
  return name:match("([^/\\]+)%.exe$") or name:match("([^/\\]+)$")
end


----------------------------------------------------------------------------------
-- 'Ctrl+c' key has a double role:
--   KeyboardInterrupt if there is no selection
--   Copy to clipboard if selection is available
action_ctrl_c = function(window, pane)
  local sel = window:get_selection_text_for_pane(pane)
  if (not sel or sel == '') then
    window:perform_action(act.SendKey{ key='c', mods='CTRL' }, pane)
  else
    window:perform_action(act.CopyTo 'ClipboardAndPrimarySelection', pane)
  end
end
----------------------------------------------------------------------------------

----------------------------------------------------------------------------------
-- 'Home'/'Up'/'Down' keys have a double role
--   Default line-start/history-up/history-down if shell is active
--   Scroll-top/scroll-up/scroll-down if no shell/prompt is active
action_home = function(window, pane)
  shells = {cmd = 1, bash = 2, powershell = 3}

  process_name = get_process_name(pane)
  if (shells[process_name] ~= nil) then
    window:perform_action(act.SendKey{ key='Home', mods='NONE' }, pane)
  else
    window:perform_action(act.ScrollToTop, pane)
  end
end

action_up = function(window, pane)
  shells = {cmd = 1, bash = 2, powershell = 3}

  process_name = get_process_name(pane)
  if (shells[process_name] ~= nil) then
    window:perform_action(act.SendKey{ key='UpArrow', mods='NONE' }, pane)
  else
    window:perform_action(act.ScrollByLine(-1), pane)
  end
end

action_down = function(window, pane)
  shells = {cmd = 1, bash = 2, powershell = 3}

  process_name = get_process_name(pane)
  if (shells[process_name] ~= nil) then
    window:perform_action(act.SendKey{ key='DownArrow', mods='NONE' }, pane)
  else
    window:perform_action(act.ScrollByLine(1), pane)
  end
end
----------------------------------------------------------------------------------

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
  { key = 'Home',       mods = 'NONE',       action = wezterm.action_callback(action_home) },
  { key = 'UpArrow',    mods = 'NONE',       action = wezterm.action_callback(action_up) },
  { key = 'DownArrow',  mods = 'NONE',       action = wezterm.action_callback(action_down) },
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


if wezterm.target_triple == 'x86_64-pc-windows-msvc' then
  config.set_environment_variables = {
    prompt = '$E[92m$P$E[36m $E[93m$+$E[37m$G$G$G$E[0m ',
  }

  config.default_prog = {
    'cmd.exe', '/s', '/k',
      -- set Unicode coding page 65001
      'chcp', '65001', '>', 'nul', '&&',

      -- and inject clink into the command prompt
      'c:/utils/clink/clink_x64.exe', 'inject', '-q', '&&',

      -- disable history-based autosuggest
      'c:/utils/clink/clink_x64.exe', 'set', 'autosuggest.enable', 'false', '>', 'nul',
  }
end

return config
