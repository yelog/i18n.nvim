local M = {}

M.defaults = {
    display = 'replace',
    mode = 'static',
    static = {
        func_pattern = { "t('%s')", "$t('%s')", "intl.formatMessage({ id: '%s' })" },
        langs = { "en", "zh" },
        default_lang = { "en" },
        files = {}
    }
}

M.options = {}

M.setup = function(opts)
    M.options = vim.tbl_deep_extend('force', M.defaults, opts or {})
end

return M

