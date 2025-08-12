return {
  "folke/noice.nvim",
  dependencies = {
    -- if you lazy-load any of these, make sure to add `event = "VeryLazy"` for them
    "MunifTanjim/nui.nvim",
    "rcarriga/nvim-notify",
  },
  opts = {
    timeout = 7000,

    lsp = {
      -- override markdown rendering so that **cmp** and other plugins use **noice**
      override = {
        ["vim.lsp.util.convert_input_to_markdown_lines"] = true,
        ["vim.lsp.util.stylize_markdown"] = true,
        ["cmp.entry.get_documentation"] = true,
      },
    },

    -- you can enable a preset configuration here
    presets = {
      bottom_search = true, -- use a classic bottom search bar
      command_palette = true, -- gives you a command palette for ":" and "/"
      long_message_to_split = true, -- long messages will be sent to a split
      inc_rename = false, -- enables an experimental feature for incremental rename
      lsp_doc_border = true, -- add a border to lsp doc hovers
    },

    routes = {
      {
        filter = {
          any = { { event = "msg_show" }, { event = "notify" } },
          find = "vim%.lsp%..*deprecated",
        },
        opts = { skip = true },
      },
    },
  },
}
