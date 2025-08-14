return {
  {
    "nvim-telescope/telescope.nvim",
    tag = "0.1.6", -- Use a stable tag
    dependencies = {
      "nvim-lua/plenary.nvim",
      -- Fuzzy finder algorithm which requires local dependencies to be built.
      {
        "nvim-telescope/telescope-fzf-native.nvim",
        build = "make",
        cond = function() return vim.fn.executable("make") == 1 end,
      },
      { "nvim-telescope/telescope-ui-select.nvim" },
    },
    keys = {
      { "<leader>ff", "<cmd>Telescope find_files hidden=true<CR>", desc = "Telescope find files" },
      { "<leader>fg", function () require("telescope.builtin").live_grep() end, desc = "Telescope live grep" },
      { "<leader>fb", function () require("telescope.builtin").buffers() end, desc = "Telescope buffers" },
      { "<leader>fh", function () require("telescope.builtin").help_tags() end, desc = "Telescope help tags" },
      { "<leader>p", "<cmd>Telescope projects<CR>", desc = "Toggle projects" },
    },
    opts = function()
      local themes = require("telescope.themes")
      return {
        defaults = {
          -- Good general perf defaults
          file_ignore_patterns = { "%.git/", "node_modules/", "dist/", "target/" },
          path_display = { "smart" },
          dynamic_preview_title = true,
        },
        extensions = {
          fzf = {
            fuzzy = true,
            override_generic_sorter = true,
            override_file_sorter = true,
            case_mode = "smart_case",
          },
          ["ui-select"] = themes.get_dropdown({}),
        },
      }
    end,
    config = function(_, opts)
      local telescope = require("telescope")
      telescope.setup(opts)
      pcall(telescope.load_extension, "fzf")
      pcall(telescope.load_extension, "ui-select")
      pcall(telescope.load_extension, "projects") -- from project.nvim
    end,
  },
  {
    "MagicDuck/grug-far.nvim",
    cmd = "GrugFar",
    keys = { {"<leader>g", "<cmd>GrugFar<CR>", desc = "Grug" } },
  },
  {
    "folke/which-key.nvim",
    event = "VeryLazy",
    config = function()
      local wk = require("which-key")
      
      wk.setup({
        preset="helix",
      })
      
      wk.add({
        { "<leader>b", group = "Bookmarks" },
        { "<leader>f", group = "Telescope" },
        { "<leader>n", group = "EOL format" },
        { "<leader>q", group = "Persistence" },
      })
    end,
  },
}
