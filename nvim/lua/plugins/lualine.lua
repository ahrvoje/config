return {
  'nvim-lualine/lualine.nvim',
  dependencies = { 'nvim-tree/nvim-web-devicons' },
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
        lualine_a = {function()
					local reg = vim.fn.reg_recording()
					-- If a macro is being recorded, show "Recording @<register>"
					if reg ~= "" then
						return "Recording @" .. reg
					end

          -- https://github.com/nvim-lualine/lualine.nvim/blob/master/lua/lualine/utils/mode.lua
          local mode_map = {
            ['n']      = 'NORMAL',
            ['no']     = 'O-PENDING',
            ['nov']    = 'O-PENDING',
            ['noV']    = 'O-PENDING',
            ['no\22']  = 'O-PENDING',
            ['niI']    = 'NORMAL',
            ['niR']    = 'NORMAL',
            ['niV']    = 'NORMAL',
            ['nt']     = 'NORMAL',
            ['ntT']    = 'NORMAL',
            ['v']      = 'VISUAL',
            ['vs']     = 'VISUAL',
            ['V']      = 'V-LINE',
            ['Vs']     = 'V-LINE',
            ['\22']    = 'V-BLOCK',
            ['\22s']   = 'V-BLOCK',
            ['s']      = 'SELECT',
            ['S']      = 'S-LINE',
            ['\19']    = 'S-BLOCK',
            ['i']      = 'INSERT',
            ['ic']     = 'INSERT',
            ['ix']     = 'INSERT',
            ['R']      = 'REPLACE',
            ['Rc']     = 'REPLACE',
            ['Rx']     = 'REPLACE',
            ['Rv']     = 'V-REPLACE',
            ['Rvc']    = 'V-REPLACE',
            ['Rvx']    = 'V-REPLACE',
            ['c']      = 'COMMAND',
            ['cv']     = 'EX',
            ['ce']     = 'EX',
            ['r']      = 'REPLACE',
            ['rm']     = 'MORE',
            ['r?']     = 'CONFIRM',
            ['!']      = 'SHELL',
            ['t']      = 'TERMINAL',
          }

          -- Get the full mode name using nvim_get_mode()
          local mode = vim.api.nvim_get_mode().mode

          -- Return the full mode name
          return mode_map[mode] or mode:upper()
				end
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
