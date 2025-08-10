vim.g.mapleader = "\\"
vim.g.maplocalleader = "\\"

-- highlight on yank
vim.cmd [[
  augroup YankHighlight
    autocmd!
    autocmd TextYankPost * silent! lua vim.highlight.on_yank{higroup="IncSearch", timeout=200}
  augroup END
]]

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

-- Virtual EOF marker based on actual ending + newline style
-- Windows = CRLF (\r\n), POSIX = LF-only (\n), EOF = no newline at EOF or other endings

-- Define custom red highlight for EOF marker
vim.api.nvim_set_hl(0, "Windows",   { fg = "#0066FF", bold = true })
vim.api.nvim_set_hl(0, "POSIX",     { fg = "#EEEE00", bold = true })
vim.api.nvim_set_hl(0, "EOFMarker", { fg = "#FF0000", bold = true })

do
  local ns = vim.api.nvim_create_namespace("file_end_marker")

  local function marker_for(bufnr)
    local bo = vim.bo[bufnr]
    if bo.endofline == false then
      return "∎", "EOFMarker"
    end
    if bo.fileformat == "dos" then
      return "█", "Windows"
    elseif bo.fileformat == "unix" then
      return "◣", "POSIX"
    else
      return "∎", "EOFMarker"
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
