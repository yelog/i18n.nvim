local M = {}
local config = require('i18n.config')
local parser = require('i18n.parser')
local display = require('i18n.display')
local utils = require('i18n.utils')

M.setup = function(opts)
  config.setup(opts)

  if config.options.mode == 'static' then
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

    -- 注册补全源
    require('i18n.completion').setup()
  end
end

return M
