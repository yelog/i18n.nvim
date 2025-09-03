local config = require('i18n.config')

local M = {}

M.setup = function()
  local opts = (config.options or {}).completion
  if not (opts and opts.enable) then
    return
  end

  local engine = opts.engine or 'auto'
  if engine == 'auto' then
    if package.loaded['blink.cmp'] then
      engine = 'blink'
    elseif package.loaded['cmp'] then
      engine = 'cmp'
    else
      return
    end
  end

  if engine == 'cmp' and package.loaded['cmp'] then
    local cmp = require('cmp')
    local source_mod = require('i18n.completion.cmp_source')
    cmp.register_source('i18n', source_mod.new())
  elseif engine == 'blink' and package.loaded['blink.cmp'] then
    -- blink.cmp 目前未提供运行时动态注册源的公共 API
    -- 引导用户在其 blink.cmp.setup 中手动加入 provider:
    -- sources = {
    --   providers = {
    --     i18n = require('i18n.completion.blink_source'),
    --     ... 其它 ...
    --   },
    --   default = { 'i18n', 'lsp', ... }
    -- }
    vim.schedule(function()
      vim.notify("[i18n] 请在 blink.cmp.setup 的 sources.providers 中手动添加 i18n = require('i18n.completion.blink_source') 并在 sources.default 列表中加入 'i18n'", vim.log.levels.INFO)
    end)
  end
end

return M
