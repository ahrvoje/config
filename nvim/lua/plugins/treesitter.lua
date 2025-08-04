return {
  "nvim-treesitter/nvim-treesitter",
  build = ":TSUpdate",
  config = function()
    require("nvim-treesitter.configs").setup({
      -- A list of parser names, or "all" to install every parser
      -- NOTE: "all" can take a long time to complete
      ensure_installed = {
        "bash", "c", "cpp", "csv", "diff", "html", "javascript", "json", "julia", "lua", "markdown",
        "python", "rust", "toml", "typescript", "tsv", "vim", "vimdoc", "xml", "yaml", "zig"},

      -- Install parsers synchronously (only applied to `ensure_installed`)
      sync_install = false,

      -- Automatically install missing parsers when entering a buffer
      auto_install = true,

      -- Enable syntax highlighting
      highlight = {
        enable = true,
      },
    })
  end,
}
