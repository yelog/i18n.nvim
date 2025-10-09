local M = {}
local config = require('i18n.config')
local parser = require('i18n.parser')
local display = require('i18n.display')
local usages = require('i18n.usages')

-- 暴露全局引用，便于在按键映射等场景直接调用
rawset(_G, 'I18n', M)

local function toggle_origin()
  config.options.show_origin = not config.options.show_origin
  display.refresh()
  return config.options.show_origin
end

local function toggle_translation()
  config.options.show_translation = not config.options.show_translation
  display.refresh()
  return config.options.show_translation
end

local function toggle_locale_file_eol()
  config.options.show_locale_file_eol_translation =
      not config.options.show_locale_file_eol_translation
  display.refresh()
  return config.options.show_locale_file_eol_translation
end

local function resolve_i18n_key_picker()
  local opts = config.options or {}
  local cfg = {}
  if type(opts.i18n_keys) == 'table' then
    cfg = opts.i18n_keys
  elseif type(opts.fzf) == 'table' then
    -- backward compatibility
    cfg = opts.fzf
  else
    cfg = config.defaults.i18n_keys or {}
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

M.setup = function(opts)
  config.setup(opts)

  -- 加载所有语言文件
  parser.load_translations()

  -- 初始化源代码使用扫描
  usages.setup()

  -- 设置显示模式
  display.setup_replace_mode()

  -- 创建用户命令
  vim.api.nvim_create_user_command('I18nReload', function()
    parser.load_translations()
    usages.refresh()
    display.refresh()
  end, {})

  vim.api.nvim_create_user_command('I18nShowTranslations', function()
    display.show_popup()
  end, {})

  vim.api.nvim_create_user_command('I18nToggleOrigin', function()
    M.toggle_origin()
  end, { desc = "Toggle i18n original text display/hide" })

  vim.api.nvim_create_user_command('I18nToggleTranslation', function()
    M.toggle_translation()
  end, { desc = "Toggle inline translation overlay on/off" })

  vim.api.nvim_create_user_command('I18nToggleLocaleFileEol', function()
    M.toggle_locale_file_eol()
  end, { desc = "Toggle show translation at end of line in locale files" })

  vim.api.nvim_create_user_command('I18nDefinitionNextLocale', function()
    require('i18n.navigation').i18n_definition_next_locale()
  end, { desc = "Jump to same i18n key in next locale file" })

  vim.api.nvim_create_user_command('I18nAddKey', function()
    require('i18n.add_key').add_key_interactive()
  end, { desc = "Interactively add a missing i18n key across locales" })

  vim.api.nvim_create_user_command('I18nKeyUsages', function()
    usages.jump_under_cursor()
  end, { desc = "Jump to usages of the i18n key under cursor" })

  -- 更新外部可访问的 options 引用
  M.options = config.options
end

-- 对外统一导出辅助方法，避免用户引用内部子模块
M.reload_project_config = function()
  return config.reload_project_config()
end

M.i18n_definition = function()
  return require('i18n.navigation').i18n_definition()
end

M.show_popup = function()
  return require('i18n.display').show_popup()
end

M.next_locale = display.next_locale
M.get_current_locale = display.get_current_locale

M.toggle_origin = function()
  return toggle_origin()
end

M.toggle_translation = function()
  return toggle_translation()
end

M.toggle_locale_file_eol = function()
  return toggle_locale_file_eol()
end

M.i18n_keys = function()
  local picker = resolve_i18n_key_picker()
  return picker()
end

-- 代理 fzf 集成功能，统一从 i18n 导出
M.show_i18n_keys_with_fzf = function()
  vim.deprecate('require("i18n").show_i18n_keys_with_fzf', 'require("i18n").i18n_keys', '0.2.0')
  return require('i18n.integration.fzf').show_i18n_keys_with_fzf()
end

M.show_i18n_keys_with_telescope = function()
  vim.deprecate('require("i18n").show_i18n_keys_with_telescope', 'require("i18n").i18n_keys', '0.2.0')
  return require('i18n.integration.telescope').show_i18n_keys_with_telescope()
end

M.i18n_definition_next_locale = function()
  return require('i18n.navigation').i18n_definition_next_locale()
end

M.i18n_key_usages = function()
  return usages.jump_under_cursor()
end

M.refresh_usages = function()
  return usages.refresh()
end

-- 暴露当前配置（在 setup 后更新）
M.options = config.options

return M
