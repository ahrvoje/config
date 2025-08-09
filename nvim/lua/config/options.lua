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
