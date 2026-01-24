local M = {}

local valid_show_modes = {
  both = true,
  translation = true,
  translation_conceal = true,
  origin = true,
}

local function trim(value)
  if type(value) ~= 'string' then return value end
  return (value:gsub('^%s*(.-)%s*$', '%1'))
end

local function normalize_show_mode_value(value)
  if type(value) ~= 'string' then return nil end
  local normalized = trim(value):lower()
  if valid_show_modes[normalized] then
    return normalized
  end
  return nil
end

local function derive_show_mode(opts)
  if type(opts) ~= 'table' then
    return 'both'
  end

  local mode = normalize_show_mode_value(opts.show_mode)
  if mode then
    return mode
  end

  local st = opts.show_translation
  local so = opts.show_origin
  if st ~= nil or so ~= nil then
    if st == false then
      return 'origin'
    end
    if so == true then
      return 'both'
    end
    if st == true and so == false then
      return 'translation_conceal'
    end
    if st == true and so == nil then
      return 'translation_conceal'
    end
    if so == false then
      return 'translation_conceal'
    end
  end

  return 'both'
end

local function escape_lua_pattern(str)
  return (str:gsub('([%^%$%(%)%%%.%[%]%*%+%-%?])', '%%%1'))
end

local function escape_for_set(char)
  if type(char) ~= 'string' or char == '' then
    return char
  end
  local first = char:sub(1, 1)
  if first == '-' then
    return '%-'
  elseif first == '^' then
    return '%^'
  elseif first == ']' then
    return '%]'
  elseif first == '%' then
    return '%%'
  end
  return first
end

local function add_pattern(result, seen, pattern)
  if type(pattern) ~= 'string' or pattern == '' then
    return
  end
  if not seen[pattern] then
    table.insert(result, pattern)
    seen[pattern] = true
  end
end

local function is_likely_lua_pattern(str)
  return str:find('%%') or str:find('%(') or str:find('%)') or str:find('%[') or str:find('%]')
end

local function default_boundary_for_call(call)
  if type(call) ~= 'string' or call == '' then return '' end
  local first = call:sub(1, 1)
  if not first or first == '' then return '' end
  if first:match('[%w_]') then
    return '%f[%w_]'
  end
  local escaped = escape_for_set(first)
  return '%f[' .. escaped .. ']'
end

local function build_argument_patterns(spec)
  if type(spec.argument_pattern) == 'string' then
    return { spec.argument_pattern }
  elseif type(spec.argument_pattern) == 'table' then
    local patterns = {}
    for _, arg_pat in ipairs(spec.argument_pattern) do
      if type(arg_pat) == 'string' and arg_pat ~= '' then
        table.insert(patterns, arg_pat)
      end
    end
    if #patterns > 0 then
      return patterns
    end
  end

  local quotes = spec.quotes
  if type(quotes) == 'string' then
    quotes = { quotes }
  elseif type(quotes) ~= 'table' or vim.tbl_isempty(quotes) then
    quotes = { "'", '"' }
  end

  local allow_arg_ws = spec.allow_arg_whitespace
  if allow_arg_ws == nil then allow_arg_ws = true end
  local arg_space = allow_arg_ws and '%s*' or ''

  local patterns = {}
  for _, quote in ipairs(quotes) do
    if type(quote) == 'string' and quote ~= '' then
      local q = quote:sub(1, 1)
      if q and q ~= '' then
        local literal_quote = escape_lua_pattern(q)
        local class_quote = escape_for_set(q)
        local capture = spec.capture_pattern
        if type(capture) ~= 'string' or capture == '' then
          capture = '([^' .. class_quote .. ']+)'
        end
        table.insert(patterns, '%(' .. arg_space .. literal_quote .. capture .. literal_quote)
      end
    end
  end
  return patterns
end

local function build_patterns_from_spec(spec)
  if type(spec) ~= 'table' then return {} end

  local call = spec.call or spec.name or spec.func or spec.function_name
  call = trim(call)
  if type(call) ~= 'string' or call == '' then
    return {}
  end

  local boundary = spec.boundary
  if boundary == false then
    boundary = ''
  elseif type(boundary) ~= 'string' or boundary == '' then
    boundary = default_boundary_for_call(call)
  end

  local call_pattern = spec.call_pattern
  if type(call_pattern) ~= 'string' or call_pattern == '' then
    call_pattern = escape_lua_pattern(call)
  end

  local allow_ws = spec.allow_whitespace
  if allow_ws == nil then allow_ws = true end
  local space_pattern = allow_ws and '%s*' or ''

  local argument_patterns = build_argument_patterns(spec)

  local patterns = {}
  for _, arg_pattern in ipairs(argument_patterns) do
    table.insert(patterns, boundary .. call_pattern .. space_pattern .. arg_pattern)
  end
  return patterns
end

local function extract_calls(spec)
  local calls = {}
  local seen = {}

  local function push(value)
    value = trim(value)
    if type(value) == 'string' and value ~= '' and not seen[value] then
      seen[value] = true
      table.insert(calls, value)
    end
  end

  if type(spec.call) == 'string' then push(spec.call) end
  if type(spec.name) == 'string' then push(spec.name) end
  if type(spec.func) == 'string' then push(spec.func) end
  if type(spec.function_name) == 'string' then push(spec.function_name) end

  if type(spec.calls) == 'table' then
    for _, call in ipairs(spec.calls) do push(call) end
  end

  if type(spec.aliases) == 'table' then
    for _, call in ipairs(spec.aliases) do push(call) end
  end

  if #calls == 0 then
    push(spec[1])
  end

  return calls
end

local function normalize_func_patterns(raw)
  local normalized = {}
  local seen = {}

  local items = {}
  if type(raw) == 'table' then
    items = raw
  end

  for _, entry in ipairs(items) do
    local entry_type = type(entry)
    if entry_type == 'string' then
      local value = trim(entry)
      if value and value ~= '' then
        if is_likely_lua_pattern(value) then
          add_pattern(normalized, seen, value)
        else
          local generated = build_patterns_from_spec({ call = value })
          for _, pat in ipairs(generated) do
            add_pattern(normalized, seen, pat)
          end
        end
      end
    elseif entry_type == 'table' then
      local direct_patterns = entry.patterns or entry.pattern
      if type(direct_patterns) == 'string' then
        add_pattern(normalized, seen, direct_patterns)
      elseif type(direct_patterns) == 'table' then
        for _, pat in ipairs(direct_patterns) do
          add_pattern(normalized, seen, pat)
        end
      end

      local calls = extract_calls(entry)
      for _, call in ipairs(calls) do
        local spec_copy = vim.tbl_deep_extend('force', {}, entry)
        spec_copy.pattern = nil
        spec_copy.patterns = nil
        spec_copy.calls = nil
        spec_copy.aliases = nil
        spec_copy.call = call
        spec_copy[1] = nil
        spec_copy.name = nil
        spec_copy.func = nil
        spec_copy.function_name = nil

        local generated = build_patterns_from_spec(spec_copy)
        for _, pat in ipairs(generated) do
          add_pattern(normalized, seen, pat)
        end
      end
    end
  end

  if #normalized == 0 then
    local fallback = { 't', '$t' }
    for _, call in ipairs(fallback) do
      local generated = build_patterns_from_spec({ call = call })
      for _, pat in ipairs(generated) do
        add_pattern(normalized, seen, pat)
      end
    end
    vim.notify('[i18n] No func_pattern entries generated any patterns; falling back to defaults (t/$t).',
      vim.log.levels.WARN)
  end

  return normalized
end

M.defaults = {
  -- Activation strategy for the plugin
  -- Options:
  --   'auto'   : Activate when i18n project detected (recommended, checks package.json/config files)
  --   'lazy'   : Activate when opening a supported filetype in an i18n project
  --   'manual' : Only activate via :I18nEnable command
  --   'eager'  : Activate immediately on setup (legacy behavior)
  activation = 'auto',

  -- Inline rendering behaviour:
  --   'both'                : always show original key + translation inline
  --   'translation'         : hide key except on cursor line (shows key+translation)
  --   'translation_conceal' : hide key and conceal translation on cursor line
  --   'origin'              : disable translation overlay (show key only)
  show_mode = 'both',
  -- Whether to display the default language translation as virtual text at the end of key lines in locale files
  show_locale_file_eol_translation = true,
  -- Whether to append usage counts in locale files alongside translations
  show_locale_file_eol_usage = true,
  display = {
    -- Debounce delay (ms) for TextChanged refresh
    refresh_debounce_ms = 100,
  },
  diagnostics = true,
  -- Namespace resolver for frameworks like react-i18next that use useTranslation('namespace')
  -- Options:
  --   false           : disabled (default)
  --   'auto'          : auto-detect based on filetype
  --   'react_i18next' : React i18next (useTranslation)
  --   'vue_i18n'      : Vue i18n (useI18n)
  --   function        : custom function(bufnr, key, line, col) -> namespace|nil
  --   table           : per-filetype config, e.g. { { filetypes = {'tsx'}, resolver = 'react_i18next' } }
  namespace_resolver = 'auto',
  -- Separator between namespace and key (default ':' for i18next standard)
  namespace_separator = '.',
  -- func_pattern accepts user-friendly function descriptors or raw Lua patterns.
  -- Examples:
  --   { 't', '$t' }
  --   { { call = 'i18n.t' }, { call = '$t', quotes = { "'", '"' } } }
  --   { { pattern = "%f[%w_]custom%(['\"]([^'\"]+)['\"]" } }
  func_pattern = {
    't',
    '$t',
  },
  locales = {},
  sources = {
    "src/locales/{locales}.json",
  },
  -- Auto-detect sources from project structure
  -- When enabled (or when sources is empty), scans for locale directories automatically
  -- Options:
  --   false           : disabled
  --   true            : enabled with default settings
  --   { enabled = true, ... } : enabled with custom settings
  -- Available settings:
  --   root_dirs       : directories to scan (default: { 'src', 'app', 'lib', '.' })
  --   locale_dir_names: names of locale directories (default: { 'locales', 'locale', 'i18n', 'lang', ... })
  --   known_locales   : known locale codes for detection (default: { 'en', 'zh', 'en-US', 'zh-CN', ... })
  --   extensions      : supported file extensions (default: { 'json', 'ts', 'js', 'yaml', 'yml', 'properties' })
  --   max_depth       : max directory depth to scan (default: 6)
  auto_detect = true,
  navigation = {},
  usage = {
    -- Popup provider used when choosing between multiple usage locations
    -- Available values: 'vim_ui', 'telescope', 'fzf-lua', 'snacks'
    popup_type = 'fzf-lua',
    -- 是否在未检测到光标下 key 时提示
    notify_no_key = true,
    -- Maximum file size (bytes) to scan for usages; 0 disables the limit
    max_file_size = 0,
    -- Run a full usage scan on VimEnter
    scan_on_startup = true,
  },
  -- Filetypes/extensions to scan when collecting key usages in project source files
  func_type = {
    'vue',
    'typescript',
    'javascript',
    'typescriptreact',
    'javascriptreact',
    'tsx',
    'jsx',
    'java',
  },
  i18n_keys = {
    popup_type = 'fzf-lua', -- fzf-lua | telescope
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

local function has_sources(cfg)
  if not cfg then return false end
  local sources = cfg.sources
  if type(sources) == 'string' then
    return sources ~= ''
  end
  if type(sources) == 'table' then
    return #sources > 0
  end
  return false
end

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
  local project_has_sources = has_sources(project_cfg)

  M.options = vim.tbl_deep_extend('force', M.defaults, user_config, project_cfg or {})
  M.options._project_config_sources = project_has_sources
  local raw_func_spec = M.options.func_pattern
  M.options._func_pattern_spec = raw_func_spec
  M.options.func_pattern = normalize_func_patterns(raw_func_spec)
  M.options.show_mode = derive_show_mode(M.options)
  if M.options.show_mode ~= 'origin' then
    M.options._last_non_origin_show_mode = M.options.show_mode
  else
    M.options._last_non_origin_show_mode = 'both'
  end
  M.options.show_translation = nil
  M.options.show_origin = nil

  return M.options
end

function M.normalize_show_mode(mode)
  return normalize_show_mode_value(mode)
end

return M
