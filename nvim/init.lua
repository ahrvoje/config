vim.loader.enable()
vim.g.mapleader = " "
vim.g.maplocalleader = " "

vim.opt.fileformats = { "dos", "unix", "mac" } -- detection order
vim.opt.fixeol = false

-- Publish Neovim state and OSC 7 CWD without spawning helpers. This is a
-- display/routing protocol; destructive WezTerm actions never trust it.
if vim.env.WEZTERM_PANE then
  local wezterm_in_tmux = os.getenv('TMUX') ~= nil
  local wezterm_state_seq = 0

  local function osc(body)
    local sequence = '\27]' .. body .. '\7'
    if wezterm_in_tmux then
      -- Prefix ESC plus the OSC's own ESC gives tmux the doubled inner ESC.
      sequence = '\27Ptmux;\27' .. sequence .. '\27\\'
    end
    return sequence
  end

  local function user_var(name, value)
    return osc(string.format('1337;SetUserVar=%s=%s', name, vim.base64.encode(value)))
  end

  local function cwd_state()
    -- Vim's logical CWD respects :lcd/:tcd; libuv's process CWD does not always
    -- represent the active window after a scoped directory change.
    local ok, cwd = pcall(vim.fn.getcwd)
    if not ok or type(cwd) ~= 'string' or cwd == '' then return {} end
    return {
      osc('7;' .. (vim.uri and vim.uri.from_fname or vim.uri_from_fname)(cwd)),
      -- The status bar reads this var; OSC 7 serves WezTerm itself.
      user_var('cwd', cwd),
      -- Kept after OSC 7, in the same terminal write, so WezTerm's CWD getter
      -- can only be called after its in-memory URI has been updated.
      user_var('cwd_ready', tostring(wezterm_state_seq + 1)),
    }
  end

  local function commit_state(parts)
    wezterm_state_seq = wezterm_state_seq + 1
    parts[#parts + 1] = user_var('state_serial', tostring(wezterm_state_seq))
    vim.api.nvim_chan_send(2, table.concat(parts))
  end

  local grp = vim.api.nvim_create_augroup('NvimVar', { clear = true })
  vim.api.nvim_create_autocmd('VimEnter', {
    group = grp,
    callback = function()
      local parts = {
        user_var('shell_prompt', 'off'),
        user_var('process_name', 'nvim'),
        user_var('nvim', 'on'),
        user_var('nvim_win32', vim.fn.has('win32') == 1 and 'on' or 'off'),
      }
      vim.list_extend(parts, cwd_state())
      commit_state(parts)
    end,
  })
  vim.api.nvim_create_autocmd('DirChanged', {
    group = grp,
    callback = function()
      commit_state(cwd_state())
    end,
  })
  local nvim_exit_state_sent = false
  vim.api.nvim_create_autocmd({ 'VimLeavePre', 'VimLeave' }, {
    group = grp,
    callback = function()
      if nvim_exit_state_sent then return end
      nvim_exit_state_sent = true
      commit_state {
        user_var('nvim', 'off'),
        user_var('process_name', ''),
      }
    end,
  })
end

-- highlight on yank
local group = vim.api.nvim_create_augroup('YankHighlight', { clear = true })
vim.api.nvim_create_autocmd('TextYankPost', {
  group = group,
  pattern = '*',
  callback = function()
    vim.hl.on_yank { higroup = 'IncSearch', timeout = 200 }
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
    local line_count = vim.api.nvim_buf_line_count(bufnr)
    last_line_count[bufnr] = line_count
    if line_count < 1 then return end

    local mark, hl = marker_for(bufnr)
    vim.api.nvim_buf_set_extmark(bufnr, ns, line_count - 1, -1, {
      id = 1,
      virt_text = { { mark, hl } },
      virt_text_pos = "eol",
      hl_mode = "combine",
    })
  end

  local function refresh_marker(ev) place_marker(ev.buf) end
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile", "BufEnter" }, { callback = refresh_marker })
  vim.api.nvim_create_autocmd("OptionSet", {
    pattern = { "fileformat", "endofline" }, callback = refresh_marker,
  })

  vim.api.nvim_create_autocmd("BufWipeout", { callback = function(ev) last_line_count[ev.buf] = nil end })

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

-- Native parser and fuzzy finder builds need a compiler in the editor's PATH.
if vim.fn.has('win32') == 1 and vim.fn.executable('gcc') == 0 and vim.fn.executable('C:/msys64/ucrt64/bin/gcc.exe') == 1 then
  -- GCC's child processes must resolve DLLs from the same toolchain.
  vim.env.PATH = 'C:/msys64/ucrt64/bin;' .. vim.env.PATH
end

-- Build hooks
vim.api.nvim_create_autocmd('PackChanged', {
  callback = function(ev)
    local name, kind = ev.data.spec.name, ev.data.kind
    if kind ~= 'install' and kind ~= 'update' then return end

    if name == 'nvim-treesitter' then
      vim.cmd.packadd('nvim-treesitter')
      local ts = require('nvim-treesitter')
      if kind == 'install' then
        ts.install(vim.split('bash c cpp diff go html javascript json julia lua markdown python regex rust toml typescript vim vimdoc xml yaml zig csv', ' '))
      else
        ts.update()
      end
    elseif name == 'telescope-fzf-native.nvim' then
      local command
      if vim.fn.has('win32') == 1 and vim.fn.executable('gcc') == 1 then
        -- The Windows make rule fails when the build directory already exists.
        vim.fn.mkdir(ev.data.path .. '/build', 'p')
        command = { 'gcc', '-O3', '-std=gnu99', '-shared', 'src/fzf.c', '-o', 'build/libfzf.dll' }
      elseif vim.fn.executable('make') == 1 then
        command = { 'make' }
      end
      if command then
        local result = vim.system(command, { cwd = ev.data.path, text = true }):wait()
        if result.code ~= 0 then vim.notify(result.stderr, vim.log.levels.ERROR) end
      end
    end
  end,
})

vim.pack.add({
  -- UI: colorscheme, statusline, notifications
  gh('folke/which-key.nvim'),
  gh('nvim-mini/mini.icons'),
  gh('maxmx03/solarized.nvim'),
  gh('nvim-lualine/lualine.nvim'),
  gh('nvim-tree/nvim-web-devicons'),
  gh('folke/noice.nvim'),
  gh('MunifTanjim/nui.nvim'),
  gh('rcarriga/nvim-notify'),

  -- Editing: treesitter, git, indentation, session, resize
  gh('nvim-treesitter/nvim-treesitter'),
  gh('tpope/vim-sleuth'),
  gh('kwkarlwang/bufresize.nvim'),
  gh('folke/persistence.nvim'),
  gh('ahmedkhalf/project.nvim'),
  gh('nvim-lua/plenary.nvim'),
})

vim.pack.add({
  -- Deferred until the first matching buffer, key or command.
  gh('lewis6991/gitsigns.nvim'),
  gh('nvim-telescope/telescope.nvim'),
  gh('nvim-telescope/telescope-fzf-native.nvim'),
  gh('nvim-telescope/telescope-ui-select.nvim'),
  { src = gh('nvim-neo-tree/neo-tree.nvim'), version = 'v3.x' },
  gh('stevearc/oil.nvim'),
  gh('MagicDuck/grug-far.nvim'),
  gh('mbbill/undotree'),
  gh('windwp/nvim-autopairs'),
  gh('lifer0se/ezbookmarks.nvim'),
  gh('mg979/vim-visual-multi'),
  gh('folke/flash.nvim'),
}, { load = function() end }) -- Add to runtimepath only at the first trigger.

-------------------------------------------------------------------------------
-- Plugin setup and first-use triggers
-------------------------------------------------------------------------------

-- Start highlighting for filetypes with an installed parser.
vim.api.nvim_create_autocmd("FileType", {
  callback = function(ev)
    local lang = vim.treesitter.language.get_lang(ev.match)
    if lang and vim.treesitter.language.add(lang) then
      vim.treesitter.start(ev.buf, lang)
      if vim.treesitter.query.get(lang, "indents") then
        vim.bo[ev.buf].indentexpr = "v:lua.require'nvim-treesitter'.indentexpr()"
      end
    end
  end,
})

do
  -- CmdUndefined loads the real command for both typed commands and mappings.
  local function load_on_command(name, command, configure)
    vim.api.nvim_create_autocmd("CmdUndefined", {
      pattern = command,
      once = true,
      callback = function()
        vim.cmd.packadd(name)
        if configure then configure() end
      end,
    })
  end

  -- Solarized
  do
    require("solarized").setup({})
    vim.o.background = "dark"
    vim.cmd.colorscheme "solarized"
  end

  -- Lualine
  require('lualine').setup({
    options = {
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
    tabline = {
      lualine_a = { 'buffers' },
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
            return vim.wo.wrap and '↩' or ''
          end,
        },
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
    lsp = {
      override = {
        ["vim.lsp.util.convert_input_to_markdown_lines"] = true,
        ["vim.lsp.util.stylize_markdown"] = true,
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
        filter = { event = "msg_show", any = {
          { find = "Visual%-Multi" },
          { find = "VM " },
          { find = "V%-M" },
        }},
        opts = { skip = true },
      },
    },
  })

  -- Gitsigns attaches on BufRead; skip its setup for an empty start.
  vim.api.nvim_create_autocmd({ "BufReadPre", "BufNewFile" }, {
    once = true,
    callback = function() vim.cmd.packadd("gitsigns.nvim") end,
  })

  -- Persistence
  vim.opt.sessionoptions = { "buffers", "curdir", "tabpages", "winsize" }
  require("persistence").setup({})
  vim.api.nvim_create_autocmd("User", {
    pattern = "PersistenceSavePre",
    callback = function()
      if package.loaded["neo-tree"] then vim.cmd("Neotree close") end
      if vim.bo.filetype == "oil" then require("oil").close() end
    end,
  })
  vim.keymap.set("n", "<leader>qs", function() require("persistence").load() end,              { desc = "Persistence load session" })
  vim.keymap.set("n", "<leader>qS", function() require("persistence").select() end,            { desc = "Persistence select session" })
  vim.keymap.set("n", "<leader>ql", function() require("persistence").load({ last = true }) end, { desc = "Persistence load last session" })
  vim.keymap.set("n", "<leader>qd", function() require("persistence").stop() end,              { desc = "Persistence stop session" })

  -- Project.nvim
  -- The LSP detector calls buf_get_clients(), removed in Neovim 0.13.
  require("project_nvim").setup({ detection_methods = { "pattern" } })

  -- Bufresize
  require("bufresize").setup({})

  ---------------------------------------------------------------------------
  -- Deferred plugin configs
  ---------------------------------------------------------------------------

  -- Telescope (keys)
  load_on_command("telescope.nvim", "Telescope", function()
    vim.cmd.packadd("telescope-fzf-native.nvim")
    vim.cmd.packadd("telescope-ui-select.nvim")
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
  end)
  vim.keymap.set("n", "<leader>ff", "<cmd>Telescope find_files hidden=true<CR>", { desc = "Telescope find files" })
  vim.keymap.set("n", "<leader>fg", "<cmd>Telescope live_grep<CR>", { desc = "Telescope live grep" })
  vim.keymap.set("n", "<leader>fb", "<cmd>Telescope buffers<CR>", { desc = "Telescope buffers" })
  vim.keymap.set("n", "<leader>fh", "<cmd>Telescope help_tags<CR>", { desc = "Telescope help tags" })
  vim.keymap.set("n", "<leader>p", "<cmd>Telescope projects<CR>", { desc = "Projects" })

  load_on_command("neo-tree.nvim", "Neotree", function()
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
  end)
  vim.keymap.set("n", "<leader>t", "<cmd>Neotree toggle<CR>", { desc = "Toggle neo-tree" })

  -- Oil (keys)
  load_on_command("oil.nvim", "Oil", function()
    require("oil").setup({
      view_options = { show_hidden = true },
      case_insensitive = true,
    })
  end)
  vim.keymap.set("n", "-", "<cmd>Oil<CR>", { desc = "Open parent directory" })

  -- Grug-far (keys + cmd)
  load_on_command("grug-far.nvim", "GrugFar")
  vim.keymap.set("n", "<leader>g", "<cmd>GrugFar<CR>", { desc = "Grug" })

  -- Git and MSYS2 shells normally supply diff; native Windows shells may not.
  if vim.fn.has("win32") == 1 and vim.fn.executable("diff") == 0 and vim.fn.executable("C:/msys64/usr/bin/diff.exe") == 1 then
    vim.g.undotree_DiffCommand = "C:/msys64/usr/bin/diff.exe"
  end
  -- Undotree (keys + cmd)
  load_on_command("undotree", "Undotree*")
  vim.keymap.set("n", "<leader>u", "<cmd>UndotreeToggle<CR>", { desc = "Toggle undotree" })

  -- Which-key
  do
    local wk = require("which-key")
    wk.setup({ preset = "helix" })
    wk.add({
      { "<leader>b", group = "Bookmarks" },
      { "<leader>f", group = "Telescope" },
      { "<leader>n", group = "EOL format" },
      { "<leader>q", group = "Persistence" },
    })
  end

  -- Nvim-autopairs (InsertEnter)
  vim.api.nvim_create_autocmd("InsertEnter", {
    once = true,
    callback = function()
      vim.cmd.packadd("nvim-autopairs")
      require("nvim-autopairs").setup({})
    end,
  })

  local function plugin_action(name, module, configure)
    local plugin
    return function(action)
      return function()
        if not plugin then
          vim.cmd.packadd(name)
          plugin = require(module)
          if configure then plugin.setup({}) end
        end
        plugin[action]()
      end
    end
  end

  local bookmark = plugin_action("ezbookmarks.nvim", "ezbookmarks")
  vim.keymap.set("n", "<leader>ba", bookmark("AddBookmark"), { desc = "Add bookmark" })
  vim.keymap.set("n", "<leader>br", bookmark("RemoveBookmark"), { desc = "Remove bookmark" })
  vim.keymap.set("n", "<leader>bo", bookmark("OpenBookmark"), { desc = "Open bookmark" })
  vim.keymap.set("n", "<leader>bi", bookmark("AddIgnore"), { desc = "Ignore file" })
  vim.keymap.set("n", "<leader>bu", bookmark("RemoveIgnore"), { desc = "Unignore file" })

  local flash = plugin_action("flash.nvim", "flash", true)
  vim.keymap.set({ "n", "x", "o" }, "s", flash("jump"), { desc = "Flash" })
  vim.keymap.set({ "n", "x", "o" }, "S", flash("treesitter"), { desc = "Flash Treesitter" })
  vim.keymap.set("o", "r", flash("remote"), { desc = "Remote Flash" })
  vim.keymap.set({ "o", "x" }, "R", flash("treesitter_search"), { desc = "Treesitter Search" })
  vim.keymap.set("c", "<C-s>", flash("toggle"), { desc = "Toggle Flash Search" })

  -- Vim-visual-multi (keys)
  vim.g.VM_sublime_mappings = true
  vim.g.VM_default_mappings = false
  vim.g.VM_maps = {
    ['Find Under'] = '<C-d>',
    ['Find Subword Under'] = '<C-d>',
  }
  local vm_modes = { "n", "x" }
  vim.keymap.set(vm_modes, "<C-d>", function()
    vim.keymap.del(vm_modes, "<C-d>")
    vim.cmd.packadd("vim-visual-multi")
    vim.api.nvim_feedkeys(vim.keycode("<C-d>"), "im", false)
  end, { desc = "VM Find Under" })
end
