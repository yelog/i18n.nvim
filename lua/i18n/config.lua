local M = {}

M.defaults = {
  show_translation = true,
  show_origin = false,
  -- Whether to display the default language translation as virtual text at the end of key lines in locale files
  show_locale_file_eol_translation = true,
  diagnostics = true,
  -- func_pattern:
  -- Use frontier (%f) to ensure t / $t is not preceded by a letter, digit, or underscore,
  -- avoiding false matches like split('/'), last("...
  -- %f[^%w_]t means t is not preceded by %w_ (alphanumeric or underscore)
  -- Examples that will match: t("a.b"), t('x'), (t("x"), $t("x")
  -- Examples that won't match: split("..."), data.last("..."), my_t("x")
  func_pattern = {
    -- Use frontier: %f[%w_]t ensures t is not preceded by letter/digit/underscore
    -- Matches examples: t('a.b'), title: t("x.y"), (t("x")), {{$t('k')}}
    -- Non-matching examples: split('x'), my_t('x'), last("x")
    "%f[%w_]t%(['\"]([^'\"]+)['\"]",
    -- $t form (preceded by any non-$ character or start of line); %f[%$] asserts the following char is $
    -- and the previous char is not $
    "%f[%$]%$t%(['\"]([^'\"]+)['\"]",
  },
  locales = { "en", "zh" },
  sources = {
    "src/locales/{locales}.json",
  },
  navigation = {},
  -- Filetypes/extensions to scan when collecting key usages in project source files
  func_file_type = { 'vue', 'typescript' },
  fzf = {
    -- Action key mappings (multiple trigger keys allowed as multiple strings in the array)
    -- Use Vim-style notation (<cr>, <c-j>, etc.); they will be converted to keys recognized by fzf
    keys = {
      copy_key           = { "<cr>" },  -- Copy i18n key
      copy_translation   = { "<c-y>" }, -- Copy translation of current display language
      jump               = { "<c-j>" }, -- Jump to current display language (fallback to default language if failed)
      split_jump         = { "<c-x>" }, -- Horizontal split jump
      vsplit_jump        = { "<c-v>" }, -- Vertical split jump
      tab_jump           = { "<c-t>" }, -- Tab page jump
      choose_locale_jump = { "<c-l>" }, -- Jump after choosing language
    },
    jump = {
      prefer_current_locale = true,
      open_cmd_default = "edit", -- edit|split|vsplit|tabedit
    },
    show_missing = true,
    missing_style = "Error",
    preview_order = "config", -- config|current_first|default_first
  }
}

-- Project-level configuration cache
M.project_config = nil
M.options = {}

-- Attempt to load project-level configuration from current working directory
local function load_project_config()
  local config_files = { '.i18nrc.json', 'i18n.config.json', '.i18nrc.lua' }
  local cwd = vim.fn.getcwd()
  for _, filename in ipairs(config_files) do
    local full = cwd .. '/' .. filename
    if vim.fn.filereadable(full) == 1 then
      if filename:match('%.json$') then
        local ok_read, content = pcall(vim.fn.readfile, full)
        if ok_read and content and #content > 0 then
          local joined = table.concat(content, '\n')
          local ok_decode, decoded = pcall(vim.json.decode, joined)
          if ok_decode and type(decoded) == "table" then
            return decoded, full
          else
            vim.notify("[i18n] Failed to parse JSON config: " .. full, vim.log.levels.WARN)
          end
        else
          vim.notify("[i18n] Failed to read config file: " .. full, vim.log.levels.WARN)
        end
      elseif filename:match('%.lua$') then
        local ok_dofile, lua_tbl = pcall(dofile, full)
        if ok_dofile and type(lua_tbl) == "table" then
          return lua_tbl, full
        else
          vim.notify("[i18n] Failed to run Lua config: " .. full, vim.log.levels.WARN)
        end
      end
    end
  end
  return nil, nil
end

-- Allow external callers to force reload the project configuration
function M.reload_project_config()
  local project_cfg = load_project_config()
  if project_cfg then
    M.project_config = project_cfg
  end
  return M.project_config
end

-- Expected shape of opts (removed default layer; user passes config directly):
-- require('i18n').setup({
--   locales = {...},
--   sources = {...},
-- })
M.setup = function(opts)
  opts = opts or {}
  local user_config = opts

  local project_cfg = M.reload_project_config()

  M.options = vim.tbl_deep_extend('force', M.defaults, user_config, project_cfg or {})

  return M.options
end

return M
