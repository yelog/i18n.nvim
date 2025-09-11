local M = {}
local config = require('i18n.config')
local parser = require('i18n.parser')
local display = require('i18n.display')

M.setup = function(opts)
  config.setup(opts)

  -- 加载所有语言文件
  parser.load_translations()

  -- 设置显示模式
  display.setup_replace_mode()

  -- 创建用户命令
  vim.api.nvim_create_user_command('I18nReload', function()
    parser.load_translations()
    display.refresh()
  end, {})

  vim.api.nvim_create_user_command('I18nShowTranslations', function()
    display.show_popup()
  end, {})

  vim.api.nvim_create_user_command('I18nToggleOrigin', function()
    config.options.show_origin = not config.options.show_origin
    display.refresh()
  end, { desc = "Toggle i18n original text display/hide" })

  vim.api.nvim_create_user_command('I18nToggleTranslation', function()
    config.options.show_translation = not config.options.show_translation
    display.refresh()
  end, { desc = "Toggle inline translation overlay on/off" })

  vim.api.nvim_create_user_command('I18nToggleLocaleFileEol', function()
    config.options.show_locale_file_eol_translation =
        not config.options.show_locale_file_eol_translation
    display.refresh()
  end, { desc = "Toggle show translation at end of line in locale files" })

  vim.api.nvim_create_user_command('I18nDefinitionNextLocale', function()
    require('i18n.navigation').i18n_definition_next_locale()
  end, { desc = "Jump to same i18n key in next locale file" })

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

-- 代理 fzf 集成功能，统一从 i18n 导出
M.show_i18n_keys_with_fzf = function()
  return require('i18n.integration.fzf').show_i18n_keys_with_fzf()
end

M.show_i18n_keys_with_telescope = function()
  return require('i18n.integration.telescope').show_i18n_keys_with_telescope()
end

M.i18n_definition_next_locale = function()
  return require('i18n.navigation').i18n_definition_next_locale()
end

-- 暴露当前配置（在 setup 后更新）
M.options = config.options

return M
