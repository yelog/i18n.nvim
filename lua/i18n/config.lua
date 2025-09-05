local M = {}

M.defaults = {
  show_translation = true,
  show_origin = false,
  func_pattern = {
    "t%(['\"]([^'\"]+)['\"]",
    "%$t%(['\"]([^'\"]+)['\"]",
  },
  locales = { "en", "zh" },
  files = {
    "src/locales/{locales}.json",
  }
}

M.options = {}

M.setup = function(opts)
  M.options = vim.tbl_deep_extend('force', M.defaults, opts or {})
end

return M
