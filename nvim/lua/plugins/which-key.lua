return {
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
}
