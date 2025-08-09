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
vim.cmd [[
  augroup autosave_buffer
    au!
    au FocusLost * if expand('%') != '' | w | endif
  augroup END
]]

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
