--vim.keymap.set("n", "<C-Home", "gg0", { desc = "Go to file start" })
--vim.keymap.set("i", "<C-Home", "<Esc>gg0", { desc = "Go to file start" })
vim.keymap.set("n", "<C-End", "G0", { desc = "Toggle wrap / nowrap" })
vim.keymap.set("i", "<C-End", "<Esc>G0", { desc = "Toggle wrap / nowrap" })

vim.keymap.set("n", "<C-Left>",  "<C-w>h", { desc = "Go to left pane" })
vim.keymap.set("n", "<C-Down>",  "<C-w>j", { desc = "Go to down pane" })
vim.keymap.set("n", "<C-Up>",    "<C-w>k", { desc = "Go to up pane" })
vim.keymap.set("n", "<C-Right>", "<C-w>l", { desc = "Go to right pane" })

vim.keymap.set("n", "<leader>w", "<cmd>set wrap!<CR>", { desc = "Toggle wrap / nowrap" })


-- Telescope
local builtin = require("telescope.builtin")
vim.keymap.set("n", "<leader>ff", "<cmd>Telescope find_files hidden=true<CR>", { desc = "Telescope find files" })
vim.keymap.set("n", "<leader>fg", builtin.live_grep, { desc = "Telescope live grep" })
vim.keymap.set("n", "<leader>fb", builtin.buffers, { desc = "Telescope buffers" })
vim.keymap.set("n", "<leader>fh", builtin.help_tags, { desc = "Telescope help tags" })


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
