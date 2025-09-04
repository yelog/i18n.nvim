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
end

return M
