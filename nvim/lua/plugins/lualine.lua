return {
  'nvim-lualine/lualine.nvim',
  dependencies = { 'nvim-tree/nvim-web-devicons' },
  event = "VeryLazy",
  config = function()
    require('lualine').setup({
      options = {
        icons_enabled = true,
        -- The theme of the statusline.
        -- 'auto' will automatically use your colorscheme's lualine theme
        -- if it exists, otherwise it will use 'default'
        theme = 'auto',
        
        -- Separators for statusline components.
        -- Nerd Font required for these.
        component_separators = { left = '', right = ''},
        section_separators = { left = '', right = ''},
        
        -- We are not using a statusline for some filetypes
        disabled_filetypes = {
          statusline = {},
          winbar = {},
        },
      },
      sections = {
        -- https://github.com/nvim-lualine/lualine.nvim/issues/1355
        lualine_a = {
          function()
            local reg = vim.fn.reg_recording()
            return reg ~= "" and ("Recording @%s"):format(reg) or require("lualine.components.mode")():upper()
          end,
        },
        lualine_b = {'branch', 'diff', 'diagnostics'},
        lualine_c = {{
          'filename',
          path = 2, -- 0 = just filename, 1 = relative path, 2 = absolute path
        }},
        lualine_x = {'encoding', 'fileformat', 'filetype', 'filesize'},
        lualine_y = {'progress'},
        lualine_z = {'location'}
      },
      inactive_sections = {
        lualine_c = {{'filename', path = 1}},
        lualine_x = {'location'},
      },
    })
  end,
}
