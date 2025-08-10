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
