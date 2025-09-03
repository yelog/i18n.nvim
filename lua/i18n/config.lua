local M = {}

M.defaults = {
  show_translation = true,
  show_origin = false,
  mode = 'static',
  static = {
    func_pattern = {
      "t%(['\"]([^'\"]+)['\"]",
      "%$t%(['\"]([^'\"]+)['\"]",
    },
    langs = { "en", "zh" },
    files = {}
  },
  completion = {
    enable = true,
    engine = 'auto', -- 'auto' | 'cmp' | 'blink'
    max_items = 15,
    fuzzy = true,
  }
}

M.options = {}

M.setup = function(opts)
  M.options = vim.tbl_deep_extend('force', M.defaults, opts or {})
end

return M
