vim.keymap.set("n", "<C-h>", "<C-w>h", { desc = "Go to left pane" })
vim.keymap.set("n", "<C-j>", "<C-w>j", { desc = "Go to down pane" })
vim.keymap.set("n", "<C-k>", "<C-w>k", { desc = "Go to up pane" })
vim.keymap.set("n", "<C-l>", "<C-w>l", { desc = "Go to right pane" })

vim.keymap.set("n", "<M-h>", "<C-w><", { desc = "Resize pane left" })
vim.keymap.set("n", "<M-j>", "<C-w>-", { desc = "Resize pane down" })
vim.keymap.set("n", "<M-k>", "<C-w>+", { desc = "Resize pane up" })
vim.keymap.set("n", "<M-l>", "<C-w>>", { desc = "Resize pane right" })

vim.keymap.set("n", "<C-M-h>", "<cmd>leftabove vsplit<CR>",  { desc = "Split pane left" })
vim.keymap.set("n", "<C-M-j>", "<cmd>rightbelow split<CR>",  { desc = "Split pane down" })
vim.keymap.set("n", "<C-M-k>", "<cmd>leftabove split<CR>",   { desc = "Split pane up" })
vim.keymap.set("n", "<C-M-l>", "<cmd>rightbelow vsplit<CR>", { desc = "Split pane right" })

vim.keymap.set("n", "<Tab>",   "<cmd>tabn<CR>", { desc = "Next tab" })
vim.keymap.set("n", "<S-Tab>", "<cmd>tabp<CR>", { desc = "Previous tab" })

vim.keymap.set("n", "<leader>w", "<cmd>set wrap!<CR>", { desc = "Toggle wrap / nowrap" })

vim.keymap.set("n", "<Esc>", ":nohlsearch<CR>", { silent = true, desc = "Clear search highlight" })
