return {
  "mg979/vim-visual-multi",
  init = function()
    vim.g.VM_sublime_mappings = true
    vim.g.VM_default_mappings = false
    vim.g.VM_maps = {
      ['Find Under'] = '<C-d>',
      ['Find Subword Under'] = '<C-d>',
    }
  end,
}
