vim.keymap.set("n", "<C-PageUp>", "gg", { desc = "Go to Start of File" })
vim.keymap.set("i", "<C-PageUp>", "<Esc>gg", { desc = "Go to Start of File" })
vim.keymap.set("v", "<C-PageUp>", "gg", { desc = "Select to Start of File" })

vim.keymap.set("n", "<C-PageDown>", "G", { desc = "Go to End of File" })
vim.keymap.set("i", "<C-PageDown>", "<Esc>G", { desc = "Go to End of File" })
vim.keymap.set("v", "<C-PageDown>", "G", { desc = "Select to End of File" })

-- Telescope
local builtin = require("telescope.builtin")
vim.keymap.set("n", "<leader>ff", builtin.find_files, { desc = "Telescope find files" })
vim.keymap.set("n", "<leader>fg", builtin.live_grep, { desc = "Telescope live grep" })
vim.keymap.set("n", "<leader>fb", builtin.buffers, { desc = "Telescope buffers" })
vim.keymap.set("n", "<leader>fh", builtin.help_tags, { desc = "Telescope help tags" })

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
