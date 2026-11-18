if vim.fn.has("win32") == 1 then
  if vim.v.ctype == "C" then vim.cmd("language ctype .UTF-8") end

  local programs = vim.env.LOCALAPPDATA .. "/Programs/"
  local python = programs .. "neovim-python/Scripts/python.exe"
  local node_host = programs .. "neovim-node/node_modules/neovim/bin/cli.js"
  if vim.fn.executable(python) == 1 then vim.g.python3_host_prog = python end
  if vim.fn.filereadable(node_host) == 1 then vim.g.node_host_prog = node_host end

  -- This profile has no Ruby or Perl remote plugins.
  if vim.fn.executable("ruby") == 0 then vim.g.loaded_ruby_provider = 0 end
  if vim.fn.executable("perl") == 0 then vim.g.loaded_perl_provider = 0 end
end

vim.o.cursorline = true
vim.o.cursorlineopt = "number"

vim.o.wrap = false
vim.o.startofline = true

vim.opt.number = true
vim.opt.relativenumber = true

vim.o.tabstop = 4       -- A TAB character looks like 4 spaces
vim.o.expandtab = true  -- Pressing the TAB key will insert spaces instead of a TAB character
vim.o.softtabstop = 4   -- Number of spaces inserted instead of a TAB character
vim.o.shiftwidth = 4    -- Number of spaces inserted when indenting

vim.opt.ignorecase = true
vim.opt.smartcase = true   -- Case-sensitive only if capital letters are used
vim.opt.mouse = "a"        -- Mouse support in all modes
vim.opt.splitbelow = true
vim.opt.splitright = true
vim.opt.termguicolors = true
vim.opt.signcolumn = "yes" -- Always show sign column to avoid text shift

vim.opt.list = true
vim.opt.listchars = "tab:🡆 ,trail:-,eol:◄"

vim.opt.whichwrap = "b,s,<,>,[,],h,l"
