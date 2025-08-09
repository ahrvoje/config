return {
  "lifer0se/ezbookmarks.nvim",
  keys = {
    { "<leader>ba", function() require("ezbookmarks").AddBookmark() end,    desc = "Add bookmark" },
    { "<leader>br", function() require("ezbookmarks").RemoveBookmark() end, desc = "Remove bookmark" },
    { "<leader>bo", function() require("ezbookmarks").OpenBookmark() end,   desc = "Open bookmark" },
    { "<leader>bi", function() require("ezbookmarks").AddIgnore()end,       desc = "Ignore file" },
    { "<leader>bu", function() require("ezbookmarks").RemoveIgnore()end,    desc = "Unignore file" },
  },
}
