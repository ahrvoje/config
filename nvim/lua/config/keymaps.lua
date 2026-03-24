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

vim.keymap.set("n", "<Tab>",   "<cmd>BufferLineCycleNext<CR>", { desc = "Next buffer" })
vim.keymap.set("n", "<S-Tab>", "<cmd>BufferLineCyclePrev<CR>", { desc = "Previous buffer" })

vim.keymap.set("n", "<leader>w", "<cmd>setlocal wrap!<CR>", { desc = "Toggle wrap / nowrap" })
vim.keymap.set("n", "<leader>e", "<cmd>setlocal noendofline!<CR>", { desc = "Toggle EOF" })

vim.keymap.set("n", "<leader>nd", "<cmd>setlocal ff=dos<CR>",  { desc = "DOS format" })
vim.keymap.set("n", "<leader>nu", "<cmd>setlocal ff=unix<CR>", { desc = "Unix format" })
vim.keymap.set("n", "<leader>nm", "<cmd>setlocal ff=mac<CR>",  { desc = "Mac format" })

vim.keymap.set("n", "<leader>s", function()
  vim.o.background = vim.o.background == "dark" and "light" or "dark"
end, { desc = "Toggle solarized dark/light" })

vim.keymap.set("n", "<leader>x", "<cmd>bd<CR>", { desc = "Close buffer" })

vim.keymap.set("n", "<Esc>", ":nohlsearch<CR>", { silent = true, desc = "Clear search highlight" })

-- PageUp/PageDown: scroll full page, move cursor
vim.keymap.set("n", "<PageUp>",   "<C-b>", { desc = "Page up" })
vim.keymap.set("n", "<PageDown>", "<C-f>", { desc = "Page down" })
vim.keymap.set("i", "<PageUp>",   "<C-\\><C-o><C-b>", { desc = "Page up in insert mode" })
vim.keymap.set("i", "<PageDown>", "<C-\\><C-o><C-f>", { desc = "Page down in insert mode" })
