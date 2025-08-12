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
  opts = {
    filesystem = {
      follow_current_file = {
        enabled = true,
      },

      filtered_items = {
        visible = false,
        hide_dotfiles = false,
        hide_gitignored = false,
        hide_hidden = false,

        always_show = {
          ".config",
          ".zshrc",
        }
      },
    },
  },
}
