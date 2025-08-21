vim.g.mapleader = " "
vim.g.maplocalleader = " "

vim.opt.fileformats = { "dos", "unix", "mac" } -- detection order
vim.opt.fixeol = false

-- set terminal UserVar 'nvim' to 'on'/'off' on enter/exit
local function b64(s)
  local out = vim.fn.system({ 'base64' }, s)
  return (out:gsub('[\r\n]+$', ''))
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

local grp = vim.api.nvim_create_augroup('WezTermNvimVar', { clear = true })
vim.api.nvim_create_autocmd('VimEnter', {
  group = grp,
  callback = function()
    if os.getenv('WEZTERM_PANE') then set_user_var('nvim', 'on') end
  end,
})
vim.api.nvim_create_autocmd({ 'VimLeavePre', 'VimLeave' }, {
  group = grp,
  callback = function()
    if os.getenv('WEZTERM_PANE') then set_user_var('nvim', 'off') end
  end,
})

-- highlight on yank
local group = vim.api.nvim_create_augroup('YankHighlight', { clear = true })
vim.api.nvim_create_autocmd('TextYankPost', {
  group = group,
  pattern = '*',
  callback = function()
    vim.highlight.on_yank { higroup = 'IncSearch', timeout = 200 }
  end,
  desc = 'Briefly highlight yanked text',
})

-- autosave files on focus lost
local grp = vim.api.nvim_create_augroup("autosave_buffer", { clear = true })
vim.api.nvim_create_autocmd("FocusLost", {
  group = grp,
  callback = function()
    local buf = vim.api.nvim_get_current_buf()
    local bo = vim.bo[buf]
    if bo.buftype ~= "" or not bo.modifiable or bo.readonly then return end
    if vim.api.nvim_buf_get_name(buf) == "" then return end
    vim.cmd("silent! update")
  end,
})

-- persistent undo across sessions
vim.opt.undofile = true

-- ensure Lazy
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not vim.loop.fs_stat(lazypath) then
  vim.fn.system({
    "git",
    "clone",
    "--filter=blob:none",
    "https://github.com/folke/lazy.nvim.git",
    "--branch=stable", -- latest stable release
    lazypath,
  })
end
vim.opt.rtp:prepend(lazypath)

require("lazy").setup("plugins")

require("config.options")
require("config.keymaps")

-- Virtual EOF marker based on actual ending
--   dos = CRLF (\r\n)
--   unix = LF-only (\n)
--   mac = CR-only (\r)
--   EOF = no newline at EOF or other endings

-- custom highlights
vim.api.nvim_set_hl(0, "dos",  { fg = "#0066FF", bold = true })
vim.api.nvim_set_hl(0, "unix", { fg = "#EEEE00", bold = true })
vim.api.nvim_set_hl(0, "mac",  { fg = "#00FF00", bold = true })
vim.api.nvim_set_hl(0, "EOF",  { fg = "#FF0000", bold = true })

do
  local ns = vim.api.nvim_create_namespace("file_end_marker")

  local function marker_for(bufnr)
    local bo = vim.bo[bufnr]
    if bo.endofline == false then
      return "X", "EOF"
    end
    if bo.fileformat == "dos" then
      return "█", "dos"
    elseif bo.fileformat == "unix" then
      return "◣", "unix"
    elseif bo.fileformat == "mac" then
      return "⬤", "mac"
    else
      return "X", "EOF"
    end
  end

  local function place_marker(bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then
      return
    end
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
    local line_count = vim.api.nvim_buf_line_count(bufnr)
    if line_count < 1 then return end

    local mark, hl = marker_for(bufnr)
    vim.api.nvim_buf_set_extmark(bufnr, ns, line_count - 1, -1, {
      virt_text = { { mark, hl } }, -- color depends on marker
      virt_text_pos = "eol",
      hl_mode = "combine",
    })
  end

  local events = {
    "BufReadPost", "BufNewFile", "BufWritePost", "TextChanged",
    "TextChangedI", "OptionSet", "WinEnter", "BufEnter",
  }

  vim.api.nvim_create_autocmd(events, {
    callback = function(args)
      if args.event == "OptionSet" and args.match ~= "fileformat" and args.match ~= "endofline" then
        return
      end
      place_marker(args.buf)
    end,
  })
end
