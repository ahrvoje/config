return {
  "nvim-telescope/telescope.nvim",
  tag = "0.1.6", -- Use a stable tag
  dependencies = {
    "nvim-lua/plenary.nvim",
    -- Fuzzy finder algorithm which requires local dependencies to be built.
    {
      "nvim-telescope/telescope-fzf-native.nvim",
      build = "make",
      cond = function()
        return vim.fn.executable("make") == 1
      end,
    },
    { "nvim-telescope/telescope-ui-select.nvim" },
  },
  config = function()
    local telescope = require("telescope")

    telescope.setup({
      -- This defaults table is where you configure fzf-native
      defaults = {
        -- This is the new section to enable fzf-native
        fzf = {
          fuzzy = true, -- Toggles fuzzy finding on/off.
          override_generic_sorter = true, -- Override the generic sorter
          override_file_sorter = true, -- Override the file sorter
          case_mode = "smart_case", -- "smart_case", "respect_case", "ignore_case"
        },
      },
      extensions = {
        ["ui-select"] = {
          require("telescope.themes").get_dropdown({}),
        },
      },
    })
    
    -- We still need to load the ui-select extension
    telescope.load_extension("ui-select")
  end,
}
