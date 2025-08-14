-- neo-tree
-- oil
-- project
-- ezbookmarks
return {
  {
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
  },
  {
    'stevearc/oil.nvim',
    dependencies = { "nvim-tree/nvim-web-devicons" },
    keys = {
      { "-", "<cmd>Oil<CR>", desc = "Open parent directory" },
    },
    opts = {
      view_options = {
        show_hidden = true,
      },
      case_insensitive = true,
    },
  },
  {
    "ahmedkhalf/project.nvim",
    event = "VeryLazy",
    opts = {},
    config = function()
      require("project_nvim").setup({
      })
    end,
  },
  {
    "lifer0se/ezbookmarks.nvim",
    keys = {
      { "<leader>ba", function() require("ezbookmarks").AddBookmark() end,    desc = "Add bookmark" },
      { "<leader>br", function() require("ezbookmarks").RemoveBookmark() end, desc = "Remove bookmark" },
      { "<leader>bo", function() require("ezbookmarks").OpenBookmark() end,   desc = "Open bookmark" },
      { "<leader>bi", function() require("ezbookmarks").AddIgnore()end,       desc = "Ignore file" },
      { "<leader>bu", function() require("ezbookmarks").RemoveIgnore()end,    desc = "Unignore file" },
    },
  },
}
