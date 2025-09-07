local M = {}
local parser = require('i18n.parser')
local display = require('i18n.display')
local config = require('i18n.config')

local function open_location(loc, key)
  if not loc or not loc.file then return false end
  local open_cmd = (config.options.navigation and config.options.navigation.open_cmd) or "edit"
  local file = loc.file
  if vim.fn.filereadable(file) ~= 1 then
    return false
  end
  if open_cmd ~= "edit" then
    vim.cmd(string.format("%s %s", open_cmd, vim.fn.fnameescape(file)))
  else
    vim.cmd("edit " .. vim.fn.fnameescape(file))
  end
  vim.api.nvim_win_set_cursor(0, { loc.line or 1, 0 })
  vim.api.nvim_echo({ { "[i18n] definition: " .. key, "Comment" } }, false, {})
  return true
end

-- 尝试跳转，成功返回 true，失败返回 false（不抛错，供用户键位逻辑判断）
function M.try_definition()
  local key = display.get_key_under_cursor and display.get_key_under_cursor()
  if not key then return false end
  local loc = parser.get_key_location(key)
  if not loc then return false end
  return open_location(loc, key)
end

-- 兼容命名；用户可调用 require('i18n.navigation').jump_i18n_definition()
M.jump_i18n_definition = M.try_definition

return M
