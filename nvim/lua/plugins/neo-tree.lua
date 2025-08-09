return {
  "nvim-neo-tree/neo-tree.nvim",
  branch = "v3.x",
  dependencies = {
    "nvim-lua/plenary.nvim",
    "MunifTanjim/nui.nvim",
    "nvim-tree/nvim-web-devicons", -- optional, but recommended
  },
  cmd = "Neotree",
  keys = { { "<leader>t", "<cmd>Neotree toggle<CR>", desc = "Toggle neo-tree" } },
  filesystem = { follow_current_file = { enabled = true } },
}
