return {
  {
    "folke/persistence.nvim",
    event = "BufReadPre", -- this will only start session saving when an actual file was opened
    keys = {
      -- load the session for the current directory
      { "<leader>qs", function() require("persistence").load() end, desc = "Peristence load session" },
      -- select a session to load
      { "<leader>qS", function() require("persistence").select() end, desc = "Peristence select session" },
      -- load the last session
      { "<leader>ql", function() require("persistence").load({ last = true }) end, desc = "Peristence load last session" },
      -- stop Persistence => session won"t be saved on exit
      { "<leader>qd", function() require("persistence").stop() end, desc = "Peristence stop session" },
    },
    opts = {
      options = { "buffers", "curdir", "tabpages", "winsize" },
      pre_save = function()
        -- close sidebars before saving sessions
        pcall(vim.cmd, "Neotree close")
      end,
    }
  },
  {
    "kwkarlwang/bufresize.nvim",
    event = "UIEnter",
  },
}
