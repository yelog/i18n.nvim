local M = {}

-- Activation state
M._activated = false
M._setup_done = false
M._activation_pending = false

-- Lazy-loaded module references (avoid loading until activation)
local config
local parser
local display
local usages
local framework

local function get_config()
  if not config then
    config = require('i18n.config')
  end
  return config
end

local function get_parser()
  if not parser then
    parser = require('i18n.parser')
  end
  return parser
end

local function get_display()
  if not display then
    display = require('i18n.display')
  end
  return display
end

local function get_usages()
  if not usages then
    usages = require('i18n.usages')
  end
  return usages
end

local function get_framework()
  if not framework then
    framework = require('i18n.framework')
  end
  return framework
end

-- Expose global reference for keymaps
rawset(_G, 'I18n', M)

local valid_show_modes = {
  both = true,
  translation = true,
  translation_conceal = true,
  origin = true,
}

local function current_show_mode()
  local opts = get_config().options or {}
  local mode = opts.show_mode
  if type(mode) ~= 'string' then
    return 'both'
  end
  mode = mode:lower()
  if not valid_show_modes[mode] then
    return 'both'
  end
  return mode
end

local function last_non_origin_mode()
  local opts = get_config().options or {}
  local last = opts._last_non_origin_show_mode
  local normalized = get_config().normalize_show_mode(last)
  if normalized and normalized ~= 'origin' then
    return normalized
  end
  return 'both'
end

local function set_show_mode(mode)
  local cfg = get_config()
  local normalized = cfg.normalize_show_mode(mode)
  if not normalized then
    vim.notify(string.format('[i18n] Invalid show_mode: %s', tostring(mode)), vim.log.levels.WARN)
    return current_show_mode()
  end
  cfg.options = cfg.options or {}
  if normalized == cfg.options.show_mode then
    return normalized
  end
  cfg.options.show_mode = normalized
  if normalized ~= 'origin' then
    cfg.options._last_non_origin_show_mode = normalized
  elseif not cfg.options._last_non_origin_show_mode
      or not valid_show_modes[cfg.options._last_non_origin_show_mode]
      or cfg.options._last_non_origin_show_mode == 'origin' then
    cfg.options._last_non_origin_show_mode = 'both'
  end
  if M._activated then
    get_display().refresh()
  end
  return normalized
end

local function toggle_origin()
  local mode = current_show_mode()
  local target
  if mode == 'both' then
    target = 'translation_conceal'
  elseif mode == 'translation' or mode == 'translation_conceal' then
    target = 'both'
  elseif mode == 'origin' then
    local last = last_non_origin_mode()
    if last == 'both' then
      target = 'translation_conceal'
    else
      target = last
    end
  else
    target = 'both'
  end
  return set_show_mode(target)
end

local function toggle_translation()
  local mode = current_show_mode()
  local cfg = get_config()
  if mode == 'origin' then
    return set_show_mode(last_non_origin_mode())
  end
  cfg.options = cfg.options or {}
  if mode ~= 'origin' then
    cfg.options._last_non_origin_show_mode = mode
  end
  return set_show_mode('origin')
end

local function toggle_locale_file_eol()
  local cfg = get_config()
  cfg.options.show_locale_file_eol_translation =
      not cfg.options.show_locale_file_eol_translation
  if M._activated then
    get_display().refresh()
  end
  return cfg.options.show_locale_file_eol_translation
end

local function resolve_i18n_key_picker()
  local opts = get_config().options or {}
  local cfg = {}
  if type(opts.i18n_keys) == 'table' then
    cfg = opts.i18n_keys
  elseif type(opts.fzf) == 'table' then
    -- backward compatibility
    cfg = opts.fzf
  else
    cfg = get_config().defaults.i18n_keys or {}
  end

  local popup_type = (cfg and cfg.popup_type) or 'fzf-lua'

  local function fallback_warn(message)
    vim.notify(message, vim.log.levels.WARN)
  end

  if popup_type == 'vim_ui' then
    local ok_picker, key_picker = pcall(require, 'i18n.key_picker')
    if ok_picker and key_picker.show_with_native then
      return function()
        return key_picker.show_with_native()
      end
    end
  elseif popup_type == 'snacks' then
    local ok_picker, key_picker = pcall(require, 'i18n.key_picker')
    if ok_picker and key_picker.show_with_snacks then
      return function()
        return key_picker.show_with_snacks()
      end
    end
  end

  if popup_type == 'telescope' then
    local ok, telescope = pcall(require, 'i18n.integration.telescope')
    if ok and telescope.show_i18n_keys_with_telescope then
      return function()
        return telescope.show_i18n_keys_with_telescope({ suppress_deprecation = true })
      end
    else
      fallback_warn('[i18n] telescope picker unavailable; falling back to fzf-lua implementation')
    end
  end

  local ok_fzf, fzf_mod = pcall(require, 'i18n.integration.fzf')
  if ok_fzf and fzf_mod.show_i18n_keys_with_fzf then
    return function()
      return fzf_mod.show_i18n_keys_with_fzf({ suppress_deprecation = true })
    end
  end

  local ok_tel, telescope_mod = pcall(require, 'i18n.integration.telescope')
  if ok_tel and telescope_mod.show_i18n_keys_with_telescope then
    return function()
      return telescope_mod.show_i18n_keys_with_telescope({ suppress_deprecation = true })
    end
  end

  return function()
    vim.notify('[i18n] No i18n key picker available (install fzf-lua or telescope)', vim.log.levels.WARN)
    return false
  end
end

-- Apply framework suggestions to config
local function apply_framework_suggestions(fw_result)
  if not fw_result or not fw_result.detected then
    return
  end

  local cfg = get_config()
  local opts = cfg.options

  -- Only apply suggestions if user hasn't explicitly configured these options
  local suggestions = fw_result.suggestions or {}

  -- Apply func_pattern if not explicitly set by user
  if suggestions.func_pattern and opts._user_func_pattern == nil then
    opts._framework_func_pattern = suggestions.func_pattern
  end

  -- Apply func_type if not explicitly set by user
  if suggestions.func_type and opts._user_func_type == nil then
    opts._framework_func_type = suggestions.func_type
  end

  -- Apply namespace_resolver if not explicitly set by user
  if suggestions.namespace_resolver ~= nil and opts._user_namespace_resolver == nil then
    opts.namespace_resolver = suggestions.namespace_resolver
  end

  -- Store detected framework info
  opts._detected_framework = fw_result.framework_name
  opts._detected_framework_display = fw_result.framework and fw_result.framework.display_name
end

-- Actual activation: load translations, setup display, setup usages
local function do_activate(opts)
  if M._activated then
    return true
  end

  opts = opts or {}
  local cfg = get_config()

  -- Detect framework and apply suggestions
  local fw_result = get_framework().detect()
  if fw_result then
    apply_framework_suggestions(fw_result)
  end

  -- Load all translation files
  get_parser().load_translations()

  -- Initialize usage scanner (delayed)
  get_usages().setup()

  -- Setup display mode
  get_display().setup_replace_mode()

  M._activated = true

  -- Notify user about activation
  if not opts.silent then
    local msg = '[i18n] Activated'
    if fw_result and fw_result.detected then
      msg = msg .. ' (' .. fw_result.framework.display_name .. ' detected)'
    end
    vim.notify(msg, vim.log.levels.INFO)
  end

  -- Refresh current buffer immediately
  vim.schedule(function()
    local bufnr = vim.api.nvim_get_current_buf()
    if vim.api.nvim_buf_is_valid(bufnr) then
      get_display().refresh_buffer(bufnr)
    end
  end)

  return true
end

-- Check if we should activate based on current context
local function should_activate_for_buffer(bufnr)
  local cfg = get_config()
  local opts = cfg.options or {}

  -- Check if this filetype is supported
  local ft = vim.bo[bufnr].filetype
  local func_types = opts.func_type or cfg.defaults.func_type or {}

  -- Also check default supported filetypes
  local supported = {
    vue = true, javascript = true, typescript = true,
    typescriptreact = true, javascriptreact = true,
    tsx = true, jsx = true, java = true,
    json = true, yaml = true,
  }

  local is_supported = supported[ft]
  if not is_supported then
    for _, t in ipairs(func_types) do
      if t == ft then
        is_supported = true
        break
      end
    end
  end

  return is_supported
end

-- Register user commands
local function register_commands()
  vim.api.nvim_create_user_command('I18nEnable', function()
    M.activate({ silent = false })
  end, { desc = 'Enable i18n plugin for current project' })

  vim.api.nvim_create_user_command('I18nDisable', function()
    M.deactivate()
  end, { desc = 'Disable i18n plugin' })

  vim.api.nvim_create_user_command('I18nReload', function()
    if not M._activated then
      M.activate({ silent = true })
    end
    get_parser().load_translations()
    get_usages().refresh()
    get_display().refresh()
  end, {})

  vim.api.nvim_create_user_command('I18nShowTranslations', function()
    if not M._activated then M.activate({ silent = true }) end
    get_display().show_popup()
  end, {})

  vim.api.nvim_create_user_command('I18nToggleOrigin', function()
    M.toggle_origin()
  end, { desc = 'Toggle i18n original text display/hide' })

  vim.api.nvim_create_user_command('I18nToggleTranslation', function()
    M.toggle_translation()
  end, { desc = 'Toggle inline translation overlay on/off' })

  vim.api.nvim_create_user_command('I18nToggleLocaleFileEol', function()
    M.toggle_locale_file_eol()
  end, { desc = 'Toggle show translation at end of line in locale files' })

  vim.api.nvim_create_user_command('I18nDefinitionNextLocale', function()
    if not M._activated then M.activate({ silent = true }) end
    require('i18n.navigation').i18n_definition_next_locale()
  end, { desc = 'Jump to same i18n key in next locale file' })

  vim.api.nvim_create_user_command('I18nAddKey', function()
    if not M._activated then M.activate({ silent = true }) end
    require('i18n.add_key').add_key_interactive()
  end, { desc = 'Interactively add a missing i18n key across locales' })

  vim.api.nvim_create_user_command('I18nKeyUsages', function()
    if not M._activated then M.activate({ silent = true }) end
    get_usages().jump_under_cursor()
  end, { desc = 'Jump to usages of the i18n key under cursor' })

  vim.api.nvim_create_user_command('I18nDetectFramework', function()
    get_framework().debug()
  end, { desc = 'Show detected i18n framework' })

  vim.api.nvim_create_user_command('I18nStatus', function()
    M.status()
  end, { desc = 'Show i18n plugin status' })
end

-- Setup activation hooks based on activation mode
local function setup_activation_hooks(activation_mode)
  local group = vim.api.nvim_create_augroup('I18nActivation', { clear = true })

  if activation_mode == 'eager' then
    -- Immediate activation (legacy behavior)
    vim.schedule(function()
      do_activate({ silent = true })
    end)

  elseif activation_mode == 'auto' then
    -- Activate when i18n project detected
    local function check_and_activate()
      if M._activated or M._activation_pending then return end
      M._activation_pending = true

      vim.schedule(function()
        if M._activated then
          M._activation_pending = false
          return
        end

        if get_framework().is_i18n_project() then
          do_activate({ silent = true })
        end
        M._activation_pending = false
      end)
    end

    -- If vim already entered (e.g., lazy.nvim deferred setup), check immediately
    if vim.v.vim_did_enter == 1 then
      vim.defer_fn(check_and_activate, 10)
    else
      -- Check on VimEnter
      vim.api.nvim_create_autocmd('VimEnter', {
        group = group,
        once = true,
        callback = function()
          vim.defer_fn(check_and_activate, 100)
        end,
        desc = 'i18n: Check and activate after VimEnter',
      })
    end

  elseif activation_mode == 'lazy' then
    -- Activate when opening supported filetype in i18n project
    local function check_buffer_and_activate(bufnr)
      if M._activated then return end
      if should_activate_for_buffer(bufnr) then
        vim.schedule(function()
          if M._activated then return end
          if get_framework().is_i18n_project() then
            do_activate({ silent = true })
          end
        end)
      end
    end

    -- If vim already entered, check current buffer immediately
    if vim.v.vim_did_enter == 1 then
      vim.defer_fn(function()
        check_buffer_and_activate(vim.api.nvim_get_current_buf())
      end, 10)
    end

    -- Also listen for future FileType events
    vim.api.nvim_create_autocmd('FileType', {
      group = group,
      pattern = '*',
      callback = function(args)
        check_buffer_and_activate(args.buf)
      end,
      desc = 'i18n: Lazy activate on supported filetype',
    })

  elseif activation_mode == 'manual' then
    -- Do nothing, user must call :I18nEnable
    -- Just show a hint on first supported file
    local hint_shown = false
    local function show_hint()
      if M._activated or hint_shown then return end
      if get_framework().is_i18n_project() then
        hint_shown = true
        vim.notify('[i18n] i18n project detected. Run :I18nEnable to activate.', vim.log.levels.INFO)
      end
    end

    -- If vim already entered, check immediately
    if vim.v.vim_did_enter == 1 then
      vim.defer_fn(show_hint, 100)
    else
      vim.api.nvim_create_autocmd('VimEnter', {
        group = group,
        once = true,
        callback = function()
          vim.defer_fn(show_hint, 100)
        end,
        desc = 'i18n: Hint about manual activation',
      })
    end
  end
end

-- Public API

M.setup = function(opts)
  if M._setup_done then
    vim.notify('[i18n] setup() already called', vim.log.levels.WARN)
    return
  end
  M._setup_done = true

  opts = opts or {}
  local cfg = get_config()

  -- Track which options user explicitly set (for framework suggestion merging)
  if opts.func_pattern ~= nil then
    opts._user_func_pattern = true
  end
  if opts.func_type ~= nil then
    opts._user_func_type = true
  end
  if opts.namespace_resolver ~= nil then
    opts._user_namespace_resolver = true
  end

  -- Setup config (merges defaults, user opts, project config)
  cfg.setup(opts)

  -- Register commands (always available)
  register_commands()

  -- Determine activation mode
  local activation_mode = cfg.options.activation or 'auto'
  if type(activation_mode) ~= 'string' then
    activation_mode = 'auto'
  end

  -- Setup activation hooks
  setup_activation_hooks(activation_mode)

  -- Update external reference
  M.options = cfg.options
end

-- Manual activation
M.activate = function(opts)
  if M._activated then
    if not (opts and opts.silent) then
      vim.notify('[i18n] Already activated', vim.log.levels.INFO)
    end
    return true
  end

  if not M._setup_done then
    -- Auto-setup with defaults if not done
    M.setup({})
  end

  return do_activate(opts)
end

-- Deactivate plugin
M.deactivate = function()
  if not M._activated then
    vim.notify('[i18n] Not activated', vim.log.levels.INFO)
    return
  end

  -- Clear display
  get_display().clear_all()

  -- Clear autocmds
  pcall(vim.api.nvim_del_augroup_by_name, 'I18nDisplay')
  pcall(vim.api.nvim_del_augroup_by_name, 'I18nUsageScanner')
  pcall(vim.api.nvim_del_augroup_by_name, 'I18nTranslationFilesWatcher')

  -- Reset state
  M._activated = false
  if usages then
    usages._setup_done = false
  end

  vim.notify('[i18n] Deactivated', vim.log.levels.INFO)
end

-- Show plugin status
M.status = function()
  local cfg = get_config()
  local opts = cfg.options or {}

  print('=== i18n.nvim Status ===')
  print('')
  print('Activated: ' .. tostring(M._activated))
  print('Activation mode: ' .. (opts.activation or 'auto'))
  print('')

  if opts._detected_framework then
    print('Detected framework: ' .. (opts._detected_framework_display or opts._detected_framework))
  else
    print('Detected framework: (none)')
  end

  print('')
  print('Locales: ' .. table.concat(opts.locales or {}, ', '))
  print('Show mode: ' .. (opts.show_mode or 'both'))

  if M._activated and parser then
    local keys = parser.all_keys or {}
    print('')
    print('Loaded keys: ' .. #keys)
    print('Translation files: ' .. #(parser._translation_files or {}))
  end
end

-- Reload project config
M.reload_project_config = function()
  return get_config().reload_project_config()
end

M.i18n_definition = function()
  if not M._activated then M.activate({ silent = true }) end
  return require('i18n.navigation').i18n_definition()
end

M.show_popup = function()
  if not M._activated then M.activate({ silent = true }) end
  return get_display().show_popup()
end

M.next_locale = function()
  if not M._activated then M.activate({ silent = true }) end
  return get_display().next_locale()
end

M.get_current_locale = function()
  return get_display().get_current_locale()
end

M.toggle_origin = function()
  return toggle_origin()
end

M.toggle_translation = function()
  return toggle_translation()
end

M.toggle_locale_file_eol = function()
  return toggle_locale_file_eol()
end

M.set_show_mode = function(mode)
  return set_show_mode(mode)
end

M.get_show_mode = function()
  return current_show_mode()
end

M.i18n_keys = function()
  if not M._activated then M.activate({ silent = true }) end
  local picker = resolve_i18n_key_picker()
  return picker()
end

-- Deprecated API (for backward compatibility)
M.show_i18n_keys_with_fzf = function()
  vim.deprecate('require("i18n").show_i18n_keys_with_fzf', 'require("i18n").i18n_keys', '0.2.0')
  return require('i18n.integration.fzf').show_i18n_keys_with_fzf()
end

M.show_i18n_keys_with_telescope = function()
  vim.deprecate('require("i18n").show_i18n_keys_with_telescope', 'require("i18n").i18n_keys', '0.2.0')
  return require('i18n.integration.telescope').show_i18n_keys_with_telescope()
end

M.i18n_definition_next_locale = function()
  if not M._activated then M.activate({ silent = true }) end
  return require('i18n.navigation').i18n_definition_next_locale()
end

M.i18n_key_usages = function()
  if not M._activated then M.activate({ silent = true }) end
  return get_usages().jump_under_cursor()
end

M.refresh_usages = function()
  if not M._activated then M.activate({ silent = true }) end
  return get_usages().refresh()
end

-- Check if activated
M.is_activated = function()
  return M._activated
end

-- Framework detection
M.detect_framework = function()
  return get_framework().detect()
end

-- Expose options reference
M.options = {}

return M
