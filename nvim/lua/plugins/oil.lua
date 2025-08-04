return {
  'stevearc/oil.nvim',
  opts = {},
  -- Optional dependencies for toggling oil with nvim-tree-like binds
  dependencies = { "nvim-tree/nvim-web-devicons" },
  config = function()
    require('oil').setup({
      -- To behave like a traditional file explorer, you may want to
      -- skip showing the preview of files and directories.
      view_options = {
        show_hidden = true,
        case_insensitive = true,
      }
    })

    -- Open parent directory in oil
    vim.keymap.set("n", "-", "<CMD>Oil<CR>", { desc = "Open parent directory" })
  end
}
