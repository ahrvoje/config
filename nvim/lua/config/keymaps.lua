vim.keymap.set("n", "<C-h>", "<C-w>h", { desc = "Go to left pane" })
vim.keymap.set("n", "<C-j>", "<C-w>j", { desc = "Go to down pane" })
vim.keymap.set("n", "<C-k>", "<C-w>k", { desc = "Go to up pane" })
vim.keymap.set("n", "<C-l>", "<C-w>l", { desc = "Go to right pane" })

vim.keymap.set("n", "<A-h>", "<C-w><", { desc = "Resize pane left" })
vim.keymap.set("n", "<A-j>", "<C-w>-", { desc = "Resize pane down" })
vim.keymap.set("n", "<A-k>", "<C-w>+", { desc = "Resize pane up" })
vim.keymap.set("n", "<A-l>", "<C-w>>", { desc = "Resize pane right" })

vim.keymap.set("n", "<C-A-h>", "<cmd>leftabove vsplit<CR>",  { desc = "Split pane left" })
vim.keymap.set("n", "<C-A-j>", "<cmd>rightbelow split<CR>",  { desc = "Split pane down" })
vim.keymap.set("n", "<C-A-k>", "<cmd>leftabove split<CR>",   { desc = "Split pane up" })
vim.keymap.set("n", "<C-A-l>", "<cmd>rightbelow vsplit<CR>", { desc = "Split pane right" })

vim.keymap.set("n", "<Tab>",   "<cmd>tabn<CR>", { desc = "Next tab" })
vim.keymap.set("n", "<S-Tab>", "<cmd>tabp<CR>", { desc = "Previous tab" })

vim.keymap.set("n", "<leader>w", "<cmd>set wrap!<CR>", { desc = "Toggle wrap / nowrap" })


-- Telescope
local builtin = require("telescope.builtin")
vim.keymap.set("n", "<leader>ff", "<cmd>Telescope find_files hidden=true<CR>", { desc = "Telescope find files" })
vim.keymap.set("n", "<leader>fg", builtin.live_grep, { desc = "Telescope live grep" })
vim.keymap.set("n", "<leader>fb", builtin.buffers, { desc = "Telescope buffers" })
vim.keymap.set("n", "<leader>fh", builtin.help_tags, { desc = "Telescope help tags" })


-- ezBookmarks
vim.keymap.set("n", "<leader>ba", function() require("ezbookmarks").AddBookmark() end,    { desc = "Add bookmark" })
vim.keymap.set("n", "<leader>br", function() require("ezbookmarks").RemoveBookmark() end, { desc = "Remove bookmark" })
vim.keymap.set("n", "<leader>bo", function() require("ezbookmarks").OpenBookmark() end,   { desc = "Open bookmark" })
vim.keymap.set("n", "<leader>bi", function() require("ezbookmarks").AddIgnore()end,       { desc = "Ignore file" })
vim.keymap.set("n", "<leader>bu", function() require("ezbookmarks").RemoveIgnore()end,    { desc = "Unignore file" })


-- grug-far
vim.keymap.set("n", "<leader>g", "<cmd>GrugFar<CR>", { desc = "Grug" })


-- Persistence
-- load the session for the current directory
vim.keymap.set("n", "<leader>qs", function() require("persistence").load() end,
  { desc = "Peristence load session" })

-- select a session to load
vim.keymap.set("n", "<leader>qS", function() require("persistence").select() end,
  { desc = "Peristence select session" })

-- load the last session
vim.keymap.set("n", "<leader>ql", function() require("persistence").load({ last = true }) end,
  { desc = "Peristence load last session" })

-- stop Persistence => session won"t be saved on exit
vim.keymap.set("n", "<leader>qd", function() require("persistence").stop() end,
  { desc = "Peristence stop session" })


-- Open parent directory in oil
vim.keymap.set("n", "-", "<cmd>Oil<CR>", { desc = "Open parent directory" })

-- Toggle undotree
vim.keymap.set("n", "<leader>u", "<cmd>UndotreeToggle<CR>", { desc = "Toggle Undotree" })

-- Toggle neotree
vim.keymap.set("n", "<leader>t", "<cmd>Neotree<CR>", { desc = "Toggle Neotree" })

-- Toggle projects
vim.keymap.set("n", "<leader>p", "<cmd>Telescope projects<CR>", { desc = "Toggle projects" })
