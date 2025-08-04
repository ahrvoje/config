return {
  "catppuccin/nvim",
  lazy=false,
  name = "catppuccin",
  priority = 1000,
  config = function()
    vim.api.nvim_create_autocmd('ColorScheme', {
        pattern = '*',
        callback = function()
          vim.api.nvim_set_hl(0, 'LineNr', { fg = '#888466' })
          vim.api.nvim_set_hl(0, 'CursorLineNr', { fg = '#998477', bold = true })
        end,
      })

    vim.cmd.colorscheme "catppuccin"
    -- Available flavours: "latte", "frappe", "macchiato", "mocha"
    -- require("catppuccin").setup({ flavour = "mocha" })
  end,
}
