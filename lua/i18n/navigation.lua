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
  vim.api.nvim_win_set_cursor(0, { loc.line or 1, (loc.col or 1) - 1 })
  vim.api.nvim_echo({ { "[i18n] definition: " .. key, "Comment" } }, false, {})
  return true
end

-- 尝试跳转，成功返回 true，失败返回 false（不抛错，供用户键位逻辑判断）
function M.i18n_definition()
  local key = display.get_key_under_cursor and display.get_key_under_cursor()
  if not key then return false end
  -- 使用当前显示语言（由 I18nNextLocale 切换）而不是固定第一个 locales
  local current_locale = display.get_current_locale and display.get_current_locale()
  local loc = parser.get_key_location(key, current_locale)
  if not loc then return false end
  return open_location(loc, key)
end

-- 兼容命名；用户可调用 require('i18n.navigation').jump_i18n_definition()
M.jump_i18n_definition = M.i18n_definition

-- 尝试在翻译文件中根据当前光标定位 key 与 locale
local function detect_key_and_locale_at_cursor()
  local locales = (config.options and config.options.locales) or {}
  if #locales == 0 then return nil, nil end
  local buf_path = vim.api.nvim_buf_get_name(0)
  if buf_path == "" then return nil, nil end
  local abs_path = vim.loop.fs_realpath(buf_path) or buf_path
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]

  -- 判断当前 buffer 属于哪个 locale
  local current_locale = nil
  for _, loc in ipairs(locales) do
    local meta_tbl = parser.meta and parser.meta[loc]
    if meta_tbl then
      for _, meta in pairs(meta_tbl) do
        if meta.file == abs_path then
          current_locale = loc
          break
        end
      end
    end
    if current_locale then break end
  end
  if not current_locale then return nil, nil end

  local meta_tbl = parser.meta[current_locale]
  if not meta_tbl then return nil, nil end

  -- 先精确匹配行号
  for k, meta in pairs(meta_tbl) do
    if meta.file == abs_path and meta.line == cursor_line then
      return k, current_locale
    end
  end

  -- 若无精确匹配，取不超过当前行的最近一个 key（适配 value 行 / 嵌套结构）
  local candidate, best_line_diff
  for k, meta in pairs(meta_tbl) do
    if meta.file == abs_path and meta.line and meta.line <= cursor_line then
      local diff = cursor_line - meta.line
      if not best_line_diff or diff < best_line_diff then
        best_line_diff = diff
        candidate = k
      end
    end
  end
  return candidate, current_locale
end

-- 跳转到下一个 locale 相同 key 的定义
function M.i18n_definition_next_locale()
  local key, cur_locale = detect_key_and_locale_at_cursor()
  if not key then
    vim.notify("[i18n] 光标处未检测到 i18n key", vim.log.levels.WARN)
    return false
  end
  local locales = (config.options and config.options.locales) or {}
  if #locales == 0 then
    vim.notify("[i18n] 未配置 locales", vim.log.levels.WARN)
    return false
  end
  local cur_index = 0
  for i, l in ipairs(locales) do
    if l == cur_locale then
      cur_index = i
      break
    end
  end
  if cur_index == 0 then
    vim.notify(string.format("[i18n] 当前 locale (%s) 不在配置列表中", tostring(cur_locale)), vim.log.levels.WARN)
    return false
  end

  local tried = 0
  local next_index = cur_index
  local target_loc
  while tried < #locales do
    next_index = (next_index % #locales) + 1
    if next_index == cur_index then
      break
    end
    local candidate_locale = locales[next_index]
    local loc_meta = parser.get_key_location(key, candidate_locale)
    if loc_meta then
      target_loc = loc_meta
      cur_locale = candidate_locale
      break
    end
    tried = tried + 1
  end

  if not target_loc then
    vim.notify(string.format("[i18n] 其它语言未找到 key: %s", key), vim.log.levels.WARN)
    return false
  end

  local ok = open_location(target_loc, key)
  return ok == true
end

return M
