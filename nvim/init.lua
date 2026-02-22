vim.g.mapleader = " "
vim.g.maplocalleader = " "

vim.opt.fileformats = { "dos", "unix", "mac" } -- detection order
vim.opt.fixeol = false

-- set terminal UserVar 'nvim' to 'on'/'off' on enter/exit
local function set_user_var(name, b64val)
  local osc = string.format('\27]1337;SetUserVar=%s=%s\7', name, b64val)
  if os.getenv('TMUX') then
    osc = '\27Ptmux;\27' .. osc .. '\27\\'
  end
  vim.api.nvim_chan_send(2, osc)
end

local grp = vim.api.nvim_create_augroup('NvimVar', { clear = true })
vim.api.nvim_create_autocmd('VimEnter', {
  group = grp,
  callback = function()
    if os.getenv('WEZTERM_PANE') then set_user_var('nvim', 'b24=') end  -- base64('on') = 'b24='
  end,
})
vim.api.nvim_create_autocmd({ 'VimLeavePre', 'VimLeave' }, {
  group = grp,
  callback = function()
    if os.getenv('WEZTERM_PANE') then set_user_var('nvim', 'b2Zm') end  -- base64('off') = 'b2Zm'
  end,
})

-- highlight on yank
local group = vim.api.nvim_create_augroup('YankHighlight', { clear = true })
vim.api.nvim_create_autocmd('TextYankPost', {
  group = group,
  pattern = '*',
  callback = function()
    vim.highlight.on_yank { higroup = 'IncSearch', timeout = 200 }
  end,
  desc = 'Briefly highlight yanked text',
})

-- autosave files on focus lost
local autosave_grp = vim.api.nvim_create_augroup("autosave_buffer", { clear = true })
vim.api.nvim_create_autocmd("FocusLost", {
  group = autosave_grp,
  callback = function()
    vim.cmd("silent! wall")
  end,
})

-- persistent undo across sessions
vim.opt.undofile = true

-------------------------------------------------------------------------------
-- Config modules (loaded before plugins so they always apply)
-------------------------------------------------------------------------------

require("config.options")
require("config.keymaps")

-------------------------------------------------------------------------------
-- Virtual EOF marker based on actual ending
--   dos = CRLF (\r\n)
--   unix = LF-only (\n)
--   mac = CR-only (\r)
--   EOF = no newline at EOF or other endings
-------------------------------------------------------------------------------

-- custom highlights (re-applied on every colorscheme change)
local function set_marker_highlights()
  vim.api.nvim_set_hl(0, "dos",  { fg = "#0066FF", bold = true })
  vim.api.nvim_set_hl(0, "unix", { fg = "#EEEE00", bold = true })
  vim.api.nvim_set_hl(0, "mac",  { fg = "#00FF00", bold = true })
  vim.api.nvim_set_hl(0, "EOF",  { fg = "#FF0000", bold = true })
end
set_marker_highlights()
vim.api.nvim_create_autocmd("ColorScheme", { callback = set_marker_highlights })

do
  local ns = vim.api.nvim_create_namespace("file_end_marker")

  local function marker_for(bufnr)
    local bo = vim.bo[bufnr]
    if bo.endofline == false then
      return "X", "EOF"
    end
    if bo.fileformat == "dos" then
      return "█", "dos"
    elseif bo.fileformat == "unix" then
      return "◣", "unix"
    elseif bo.fileformat == "mac" then
      return "⬤", "mac"
    else
      return "X", "EOF"
    end
  end

  local last_line_count = {}

  local function place_marker(bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then
      return
    end
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
    local line_count = vim.api.nvim_buf_line_count(bufnr)
    last_line_count[bufnr] = line_count
    if line_count < 1 then return end

    local mark, hl = marker_for(bufnr)
    vim.api.nvim_buf_set_extmark(bufnr, ns, line_count - 1, -1, {
      virt_text = { { mark, hl } },
      virt_text_pos = "eol",
      hl_mode = "combine",
    })
  end

  vim.api.nvim_create_autocmd(
    { "BufReadPost", "BufNewFile", "BufWritePost", "BufEnter", "WinEnter", "OptionSet" },
    {
      callback = function(args)
        if args.event == "OptionSet" and args.match ~= "fileformat" and args.match ~= "endofline" then
          return
        end
        place_marker(args.buf)
      end,
    }
  )

  -- lightweight: only re-place when line count actually changed
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    callback = function(args)
      local bufnr = args.buf
      local cur = vim.api.nvim_buf_line_count(bufnr)
      if cur ~= last_line_count[bufnr] then
        place_marker(bufnr)
      end
    end,
  })
end

-------------------------------------------------------------------------------
-- Plugin management via vim.pack (Neovim 0.12+)
-------------------------------------------------------------------------------

local gh = function(x) return 'https://github.com/' .. x end

vim.pack.add({
  -- UI: colorscheme, statusline, notifications
  gh('catppuccin/nvim'),
  gh('nvim-lualine/lualine.nvim'),
  gh('nvim-tree/nvim-web-devicons'),
  gh('folke/noice.nvim'),
  gh('MunifTanjim/nui.nvim'),
  gh('rcarriga/nvim-notify'),

  -- Editing: treesitter, git, indentation, session, resize
  gh('nvim-treesitter/nvim-treesitter'),
  gh('lewis6991/gitsigns.nvim'),
  gh('tpope/vim-sleuth'),
  gh('kwkarlwang/bufresize.nvim'),
  gh('folke/persistence.nvim'),
  gh('ahmedkhalf/project.nvim'),
  gh('nvim-lua/plenary.nvim'),

  -- Deferred: loaded on demand via keymaps/events/commands
  { src = gh('nvim-telescope/telescope.nvim'), version = '0.1.6', load = false },
  { src = gh('nvim-telescope/telescope-fzf-native.nvim'), load = false },
  { src = gh('nvim-telescope/telescope-ui-select.nvim'), load = false },
  { src = gh('nvim-neo-tree/neo-tree.nvim'), version = 'v3.x', load = false },
  { src = gh('stevearc/oil.nvim'), load = false },
  { src = gh('MagicDuck/grug-far.nvim'), load = false },
  { src = gh('mbbill/undotree'), load = false },
  { src = gh('folke/which-key.nvim'), load = false },
  { src = gh('windwp/nvim-autopairs'), load = false },
  { src = gh('lifer0se/ezbookmarks.nvim'), load = false },
  { src = gh('mg979/vim-visual-multi'), load = false },
})

-- Build hooks
vim.api.nvim_create_autocmd('PackChanged', {
  callback = function(ev)
    local name, kind = ev.data.spec.name, ev.data.kind
    if kind ~= 'install' and kind ~= 'update' then return end

    if name == 'nvim-treesitter' then
      if not ev.data.active then vim.cmd.packadd('nvim-treesitter') end
      vim.cmd('TSUpdate')
    elseif name == 'telescope-fzf-native.nvim' then
      if vim.fn.executable('make') == 1 then
        vim.system({ 'make' }, { cwd = ev.data.path })
      end
    end
  end,
})

-------------------------------------------------------------------------------
-- Plugin configs (scheduled after vim.pack finishes loading rtp)
-------------------------------------------------------------------------------

vim.schedule(function()

  -- Deferred-loading helpers
  local loaded = {}

  local function ensure_loaded(name, config_fn)
    if loaded[name] then return end
    loaded[name] = true
    vim.cmd.packadd(name)
    if config_fn then config_fn() end
  end

  local function defer_keys(name, keys, config_fn)
    for _, k in ipairs(keys) do
      local mode = k.mode or "n"
      vim.keymap.set(mode, k[1], function()
        for _, k2 in ipairs(keys) do
          pcall(vim.keymap.del, k2.mode or "n", k2[1])
        end
        ensure_loaded(name, config_fn)
        local feed = vim.api.nvim_replace_termcodes(k[1], true, false, true)
        vim.api.nvim_feedkeys(feed, "m", false)
      end, { desc = k.desc or ("Lazy: " .. name) })
    end
  end

  local function defer_event(name, events, config_fn)
    vim.api.nvim_create_autocmd(events, {
      once = true,
      callback = function()
        ensure_loaded(name, config_fn)
      end,
    })
  end

  local function defer_cmd(name, cmds, config_fn)
    for _, c in ipairs(cmds) do
      vim.api.nvim_create_user_command(c, function(a)
        vim.api.nvim_del_user_command(c)
        ensure_loaded(name, config_fn)
        vim.cmd(c .. " " .. (a.args or ""))
      end, { nargs = "*", desc = "Lazy: " .. c })
    end
  end

  ---------------------------------------------------------------------------
  -- Eager plugin configs — packadd first, then configure
  ---------------------------------------------------------------------------

  -- Load all eager plugins into rtp
  vim.cmd.packadd("nvim")            -- catppuccin
  vim.cmd.packadd("nvim-web-devicons")
  vim.cmd.packadd("lualine.nvim")
  vim.cmd.packadd("nui.nvim")
  vim.cmd.packadd("nvim-notify")
  vim.cmd.packadd("noice.nvim")
  vim.cmd.packadd("nvim-treesitter")
  vim.cmd.packadd("gitsigns.nvim")
  vim.cmd.packadd("vim-sleuth")
  vim.cmd.packadd("bufresize.nvim")
  vim.cmd.packadd("persistence.nvim")
  vim.cmd.packadd("project.nvim")
  vim.cmd.packadd("plenary.nvim")

  -- Catppuccin
  do
    local theme_grp = vim.api.nvim_create_augroup("MyThemeFixes", { clear = true })
    vim.api.nvim_create_autocmd("ColorScheme", {
      group = theme_grp,
      callback = function()
        vim.api.nvim_set_hl(0, "LineNr",       { fg = "#888466" })
        vim.api.nvim_set_hl(0, "CursorLineNr", { fg = "#998477", bold = true })
        set_marker_highlights()
      end,
    })
    require("catppuccin").setup({ flavour = "mocha" })
    vim.cmd.colorscheme "catppuccin"
  end

  -- Lualine
  require('lualine').setup({
    options = {
      refresh = { statusline = 500, tabline = 500, winbar = 500 },
      icons_enabled = true,
      globalstatus = true,
      theme = 'auto',
      component_separators = { left = '', right = ''},
      section_separators = { left = '', right = ''},
      disabled_filetypes = {
        statusline = {},
        winbar = {},
      },
    },
    sections = {
      lualine_a = {
        function()
          local reg = vim.fn.reg_recording()
          return reg ~= "" and ("Recording @%s"):format(reg) or require("lualine.components.mode")():upper()
        end,
      },
      lualine_b = {'branch', 'diff', 'diagnostics'},
      lualine_c = {{
        'filename',
        path = 2,
      }},
      lualine_x = {
        {
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

  -- Noice
  require("noice").setup({
    timeout = 7000,
    lsp = {
      override = {
        ["vim.lsp.util.convert_input_to_markdown_lines"] = true,
        ["vim.lsp.util.stylize_markdown"] = true,
        ["cmp.entry.get_documentation"] = true,
      },
    },
    presets = {
      bottom_search = true,
      command_palette = true,
      long_message_to_split = true,
      inc_rename = false,
      lsp_doc_border = true,
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
        filter = {
          any = { { event = "msg_show" }, { event = "notify" } },
          find = "vim%.tbl_islist.*deprecated",
        },
        opts = { skip = true },
      },
      {
        filter = {
          any = { { event = "msg_show" }, { event = "notify" } },
          find = "EPERM",
        },
        opts = { skip = true },
      },
      {
        filter = { event = "msg_show", any = {
          { find = "Visual%-Multi" },
          { find = "VM " },
          { find = "V%-M" },
        }},
        opts = { skip = true },
      },
    },
  })

  -- Treesitter (new API: require("nvim-treesitter").setup)
  require("nvim-treesitter").setup({
    ensure_installed = {
      "bash","c","cpp","diff","go","html","javascript","json","julia","lua","markdown",
      "python","rust","toml","typescript","vim","vimdoc","xml","yaml","zig","csv",
    },
    sync_install = false,
    auto_install = false,
    highlight = {
      enable = true,
      additional_vim_regex_highlighting = false,
    },
    indent = { enable = true },
    incremental_selection = {
      enable = true,
      keymaps = {
        init_selection = "gnn",
        node_incremental = "grn",
        node_decremental = "grm",
        scope_incremental = "grc",
      },
    },
  })

  -- Gitsigns
  require("gitsigns").setup({})

  -- Persistence
  require("persistence").setup({
    options = { "buffers", "curdir", "tabpages", "winsize" },
    pre_save = function()
      pcall(vim.cmd, "Neotree close")
      pcall(vim.cmd, "Oil close")
    end,
  })
  vim.keymap.set("n", "<leader>qs", function() require("persistence").load() end,              { desc = "Persistence load session" })
  vim.keymap.set("n", "<leader>qS", function() require("persistence").select() end,            { desc = "Persistence select session" })
  vim.keymap.set("n", "<leader>ql", function() require("persistence").load({ last = true }) end, { desc = "Persistence load last session" })
  vim.keymap.set("n", "<leader>qd", function() require("persistence").stop() end,              { desc = "Persistence stop session" })

  -- Project.nvim
  require("project_nvim").setup({})

  -- Bufresize
  require("bufresize").setup({})

  ---------------------------------------------------------------------------
  -- Deferred plugin configs
  ---------------------------------------------------------------------------

  -- Telescope (keys)
  local function telescope_config()
    local telescope = require("telescope")
    local themes = require("telescope.themes")
    telescope.setup({
      defaults = {
        file_ignore_patterns = { "%.git/", "node_modules/", "dist/", "target/" },
        path_display = { "smart" },
        dynamic_preview_title = true,
      },
      extensions = {
        fzf = {
          fuzzy = true,
          override_generic_sorter = true,
          override_file_sorter = true,
          case_mode = "smart_case",
        },
        ["ui-select"] = themes.get_dropdown({}),
      },
    })
    pcall(telescope.load_extension, "fzf")
    pcall(telescope.load_extension, "ui-select")
    pcall(telescope.load_extension, "projects")
  end

  defer_keys("telescope.nvim", {
    { "<leader>ff", desc = "Telescope find files" },
    { "<leader>fg", desc = "Telescope live grep" },
    { "<leader>fb", desc = "Telescope buffers" },
    { "<leader>fh", desc = "Telescope help tags" },
    { "<leader>p",  desc = "Toggle projects" },
  }, function()
    vim.cmd.packadd("telescope-fzf-native.nvim")
    vim.cmd.packadd("telescope-ui-select.nvim")
    telescope_config()
    vim.keymap.set("n", "<leader>ff", "<cmd>Telescope find_files hidden=true<CR>", { desc = "Telescope find files" })
    vim.keymap.set("n", "<leader>fg", function() require("telescope.builtin").live_grep() end, { desc = "Telescope live grep" })
    vim.keymap.set("n", "<leader>fb", function() require("telescope.builtin").buffers() end, { desc = "Telescope buffers" })
    vim.keymap.set("n", "<leader>fh", function() require("telescope.builtin").help_tags() end, { desc = "Telescope help tags" })
    vim.keymap.set("n", "<leader>p", "<cmd>Telescope projects<CR>", { desc = "Toggle projects" })
  end)

  -- Neo-tree (keys)
  defer_keys("neo-tree.nvim", {
    { "<leader>t", desc = "Toggle neo-tree" },
  }, function()
    require("neo-tree").setup({
      filesystem = {
        follow_current_file = { enabled = true },
        filtered_items = {
          visible = false,
          hide_dotfiles = false,
          hide_gitignored = false,
          hide_hidden = false,
          always_show = { ".config", ".zshrc" },
        },
      },
    })
    vim.keymap.set("n", "<leader>t", "<cmd>Neotree toggle<CR>", { desc = "Toggle neo-tree" })
  end)

  -- Oil (keys)
  defer_keys("oil.nvim", {
    { "-", desc = "Open parent directory" },
  }, function()
    require("oil").setup({
      view_options = { show_hidden = true },
      case_insensitive = true,
    })
    vim.keymap.set("n", "-", "<cmd>Oil<CR>", { desc = "Open parent directory" })
  end)

  -- Grug-far (keys + cmd)
  defer_keys("grug-far.nvim", {
    { "<leader>g", desc = "Grug" },
  }, function()
    vim.keymap.set("n", "<leader>g", "<cmd>GrugFar<CR>", { desc = "Grug" })
  end)
  defer_cmd("grug-far.nvim", { "GrugFar" })

  -- Undotree (keys + cmd)
  defer_keys("undotree", {
    { "<leader>u", desc = "Toggle undotree" },
  }, function()
    vim.keymap.set("n", "<leader>u", "<cmd>UndotreeToggle<CR>", { desc = "Toggle undotree" })
  end)
  defer_cmd("undotree", { "UndotreeToggle" })

  -- Which-key (immediate — we're already deferred via vim.schedule)
  ensure_loaded("which-key.nvim", function()
    local wk = require("which-key")
    wk.setup({ preset = "helix" })
    wk.add({
      { "<leader>b", group = "Bookmarks" },
      { "<leader>f", group = "Telescope" },
      { "<leader>n", group = "EOL format" },
      { "<leader>q", group = "Persistence" },
      { "<leader>t", desc = "Toggle neo-tree" },
      { "<leader>g", desc = "Grug search/replace" },
      { "<leader>u", desc = "Toggle undotree" },
      { "<leader>p", desc = "Projects" },
      { "<leader>w", desc = "Toggle wrap" },
      { "<leader>e", desc = "Toggle EOF" },
    })
  end)

  -- Nvim-autopairs (InsertEnter)
  defer_event("nvim-autopairs", "InsertEnter", function()
    require("nvim-autopairs").setup({})
  end)

  -- Ezbookmarks (keys)
  defer_keys("ezbookmarks.nvim", {
    { "<leader>ba", desc = "Add bookmark" },
    { "<leader>br", desc = "Remove bookmark" },
    { "<leader>bo", desc = "Open bookmark" },
    { "<leader>bi", desc = "Ignore file" },
    { "<leader>bu", desc = "Unignore file" },
  }, function()
    vim.keymap.set("n", "<leader>ba", function() require("ezbookmarks").AddBookmark() end,    { desc = "Add bookmark" })
    vim.keymap.set("n", "<leader>br", function() require("ezbookmarks").RemoveBookmark() end, { desc = "Remove bookmark" })
    vim.keymap.set("n", "<leader>bo", function() require("ezbookmarks").OpenBookmark() end,   { desc = "Open bookmark" })
    vim.keymap.set("n", "<leader>bi", function() require("ezbookmarks").AddIgnore() end,      { desc = "Ignore file" })
    vim.keymap.set("n", "<leader>bu", function() require("ezbookmarks").RemoveIgnore() end,   { desc = "Unignore file" })
  end)

  -- Vim-visual-multi (keys)
  vim.g.VM_sublime_mappings = true
  vim.g.VM_default_mappings = false
  vim.g.VM_maps = {
    ['Find Under'] = '<C-d>',
    ['Find Subword Under'] = '<C-d>',
  }
  defer_keys("vim-visual-multi", {
    { "<C-d>", desc = "VM Find Under" },
  }, function() end)

end) -- vim.schedule
