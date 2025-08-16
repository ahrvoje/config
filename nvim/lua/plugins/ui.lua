-- catppuccin color scheme
-- lualine
-- noice
-- notify
return {
  {
    "catppuccin/nvim",
    lazy=false,
    name = "catppuccin",
    priority = 1000,
    config = function()
      local grp = vim.api.nvim_create_augroup("MyThemeFixes", { clear = true })
      vim.api.nvim_create_autocmd("ColorScheme", {
        group = grp,
        callback = function()
          vim.api.nvim_set_hl(0, "LineNr",       { fg = "#888466" })
          vim.api.nvim_set_hl(0, "CursorLineNr", { fg = "#998477", bold = true })
        end,
      })
      require("catppuccin").setup({ flavour = "mocha" })
      
      vim.cmd.colorscheme "catppuccin"
      -- Available flavours: "latte", "frappe", "macchiato", "mocha"
      -- require("catppuccin").setup({ flavour = "mocha" })
    end,
  },
  {
    'nvim-lualine/lualine.nvim',
    dependencies = { 'nvim-tree/nvim-web-devicons' },
    event = "VeryLazy",
    config = function()
      require('lualine').setup({
        options = {
          refresh = { statusline = 50, tabline = 50, winbar = 50 },
          icons_enabled = true,
          globalstatus = true,

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
          lualine_x = {
            {
              -- indicate no EOF newline is present as expected
              function()
                if vim.bo.eol then return '' else return '[No EOF]' end
              end,
              color = { fg = '#FFAAAA', gui = 'bold' }
            },
            'encoding', 'fileformat', 'filetype', 'filesize'
          },
          lualine_y = {'progress'},
          lualine_z = {'location'}
        },
        inactive_sections = {
          lualine_c = {{'filename', path = 1}},
          lualine_x = {'location'},
        },
      })
    end,
  },
  {
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
        {
          -- inhibit EPERM error during Oil preview
          filter = {
            any = { { event = "msg_show" }, { event = "notify" } },
            find = "EPERM",
          },
          opts = { skip = true },
        },
      },
    },
  },
  {
    "rcarriga/nvim-notify",
  },
}
