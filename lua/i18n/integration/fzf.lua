-- 集成 fzf-lua 查询 & 操作 i18n key（增强：多动作 + 跳转）
local parser = require("i18n.parser")
local fzf = require("fzf-lua")
local display = require("i18n.display")
local config = require("i18n.config")
local navigation = require("i18n.navigation")

local M = {}

---------------------------------------------------------------------
-- 工具函数
---------------------------------------------------------------------
local function get_cfg()
  return (config.options and config.options.fzf) or {}
end

local function get_locales()
  return (config.options and config.options.locales) or {}
end

local function get_current_locale()
  local ok, d = pcall(display.get_current_locale)
  if ok then return d end
  local locales = get_locales()
  return locales[1]
end

local function disp_width(str)
  if not str or str == "" then return 0 end
  local w = 0
  for ch in str:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    if ch:byte() > 127 then
      w = w + 2
    else
      w = w + 1
    end
  end
  return w
end

local function pad_right(str, width)
  str = str or ""
  local cur = disp_width(str)
  if cur >= width then return str end
  return str .. string.rep(" ", width - cur)
end

local function truncate(str, width)
  if not str or str == "" then return "" end
  if disp_width(str) <= width then return str end
  local out, w = "", 0
  for ch in str:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    local cw = ch:byte() > 127 and 2 or 1
    if w + cw > width - 3 then
      out = out .. "..."
      break
    end
    out = out .. ch
    w = w + cw
  end
  return out
end

local function normalize_keymaps(tbl)
  local function to_fzf_key(k)
    if type(k) ~= "string" then return k end
    local lower = k:lower()
    if lower == "<cr>" then return "enter" end
    local ctrl = lower:match("^<c%-(%a)>$")
    if ctrl then return "ctrl-" .. ctrl end
    return k
  end

  local map = {}
  for action, keys in pairs(tbl or {}) do
    if type(keys) == "string" then
      map[to_fzf_key(keys)] = action
    elseif type(keys) == "table" then
      for _, k in ipairs(keys) do
        map[to_fzf_key(k)] = action
      end
    end
  end
  return map
end

local function open_location(loc, key, open_cmd)
  if not loc or not loc.file then
    vim.notify("[i18n] No location for key: " .. key, vim.log.levels.WARN)
    return false
  end
  open_cmd = open_cmd or "edit"
  if vim.fn.filereadable(loc.file) ~= 1 then
    vim.notify("[i18n] File not readable: " .. loc.file, vim.log.levels.WARN)
    return false
  end
  if open_cmd ~= "edit" then
    vim.cmd(string.format("%s %s", open_cmd, vim.fn.fnameescape(loc.file)))
  else
    vim.cmd("edit " .. vim.fn.fnameescape(loc.file))
  end
  vim.api.nvim_win_set_cursor(0, { loc.line or 1, (loc.col or 1) - 1 })
  vim.api.nvim_echo({ { "[i18n] jumped: " .. key, "Comment" } }, false, {})
  return true
end

local function jump_key(key, locale, open_cmd)
  local loc = parser.get_key_location(key, locale)
  if not loc then return false end
  return open_location(loc, key, open_cmd)
end

---------------------------------------------------------------------
-- 预览内容
---------------------------------------------------------------------
local function build_preview(key)
  if not key then return " " end
  local locales = get_locales()
  local all = parser.get_all_translations(key) or {}
  local meta = parser.meta or {}
  local cur = get_current_locale()
  local def = locales[1]
  local cfg = get_cfg()
  local show_missing = cfg.show_missing ~= false
  local missing_placeholder = "<Missing translation>"

  local order_mode = (cfg.preview_order or "config")
  local ordered = {}
  if order_mode == "current_first" and cur then
    table.insert(ordered, cur)
    for _, l in ipairs(locales) do
      if l ~= cur then table.insert(ordered, l) end
    end
  elseif order_mode == "default_first" and def then
    table.insert(ordered, def)
    for _, l in ipairs(locales) do
      if l ~= def then table.insert(ordered, l) end
    end
  else
    ordered = locales
  end

  local lines = {}
  table.insert(lines, "Key: " .. key)
  table.insert(lines, string.rep("-", math.max(10, #key + 5)))
  for _, l in ipairs(ordered) do
    local val = all[l]
    local text = val
    if (val == nil or val == "") and show_missing then
      text = missing_placeholder
    end
    local mark = (l == cur) and " *" or ""
    local pos = ""
    if meta[l] and meta[l][key] then
      local m = meta[l][key]
      local rel = vim.fn.fnamemodify(m.file, ":.")
      pos = string.format(" (%s:%d)", rel, m.line or 1)
    end
    table.insert(lines, string.format("%s:%s %s%s", l, mark, text or "", pos))
  end
  return table.concat(lines, "\n")
end

---------------------------------------------------------------------
-- Locale 选择器（二级 fzf）
---------------------------------------------------------------------
local function choose_locale_and_jump(key)
  local locales = get_locales()
  local meta = parser.meta or {}
  local items = {}
  local current = get_current_locale()
  for _, l in ipairs(locales) do
    local has = (meta[l] and meta[l][key]) and "✔" or "✖"
    local mark = (l == current) and "*" or " "
    table.insert(items, string.format("%s [%s] %s", l, has, mark))
  end
  fzf.fzf_exec(items, {
    prompt = "Locale > ",
    actions = {
      ["default"] = function(sel)
        if not sel or not sel[1] then return end
        local line = sel[1]
        local locale = line:match("^(%S+)%s")
        if not locale then return end
        if not (meta[locale] and meta[locale][key]) then
          vim.notify("[i18n] No location for key in locale: " .. locale, vim.log.levels.WARN)
          return
        end
        jump_key(key, locale, "edit")
      end
    },
    previewer = function(_)
      return build_preview(key)
    end,
  })
end

---------------------------------------------------------------------
-- 动作执行
---------------------------------------------------------------------
local function extract_key_from_selected(selected, display_list, index_to_key)
  if not selected or not selected[1] then return nil end
  local selected_line = selected[1]
  for idx, line in ipairs(display_list) do
    if line == selected_line then
      return index_to_key[idx]
    end
  end
  return nil
end

local function perform_action(action, key, open_variant)
  if not key then return end
  local locales = get_locales()
  local cfg = get_cfg()
  local jump_cfg = cfg.jump or {}
  if action == "copy_key" then
    vim.fn.setreg("+", key)
    vim.notify("[i18n] Copied key: " .. key, vim.log.levels.INFO)
  elseif action == "copy_translation" then
    local cur = get_current_locale()
    local text = parser.get_translation(key, cur)
    if text then
      vim.fn.setreg("+", text)
      vim.notify(string.format("[i18n] Copied [%s] translation", cur), vim.log.levels.INFO)
    else
      vim.notify("[i18n] Missing translation in current locale", vim.log.levels.WARN)
    end
  elseif action == "jump_current" then
    local cur = get_current_locale()
    local tried = false
    if jump_cfg.prefer_current_locale and cur then
      tried = true
      if jump_key(key, cur, open_variant or jump_cfg.open_cmd_default or "edit") then
        return
      end
    end
    local def = locales[1]
    if def and (not tried or def ~= cur) then
      if jump_key(key, def, open_variant or jump_cfg.open_cmd_default or "edit") then
        return
      end
    end
    vim.notify("[i18n] Cannot jump: no location found", vim.log.levels.WARN)
  elseif action == "jump_default" then
    local def = locales[1]
    if not def or not jump_key(key, def, open_variant or "edit") then
      vim.notify("[i18n] Default locale location not found", vim.log.levels.WARN)
    end
  elseif action == "choose_locale" then
    choose_locale_and_jump(key)
  elseif action == "split_jump" then
    perform_action("jump_current", key, "split")
  elseif action == "vsplit_jump" then
    perform_action("jump_current", key, "vsplit")
  elseif action == "tab_jump" then
    perform_action("jump_current", key, "tabedit")
  end
end

-- 注意：此处已在文件前部实现带 <c-*> 转换的 normalize_keymaps，避免重复定义
-- （保留空块以免大块 diff 影响可读性）

---------------------------------------------------------------------
-- 主入口
---------------------------------------------------------------------
function M.show_i18n_keys_with_fzf()
  local translations = parser.translations or {}
  local keys_map = {}
  for _, locale_tbl in pairs(translations) do
    for k, _ in pairs(locale_tbl) do
      keys_map[k] = true
    end
  end

  local key_list = {}
  for k in pairs(keys_map) do
    table.insert(key_list, k)
  end
  table.sort(key_list)

  local locales = get_locales()
  local cur_locale = get_current_locale()
  local total_columns = vim.o.columns or 120
  local padding = 4
  local available_width = total_columns - padding
  local key_col_width = math.min(50, math.max(20, math.floor(available_width * 0.55)))
  local val_col_width = math.min(50, math.max(15, available_width - key_col_width - 3))

  local display_list = {}
  local index_to_key = {}

  for idx, key in ipairs(key_list) do
    index_to_key[idx] = key
    local val = parser.get_translation(key, cur_locale) or ""
    local row = pad_right(truncate(key, key_col_width), key_col_width) ..
        " │ " .. pad_right(truncate(val, val_col_width), val_col_width)
    table.insert(display_list, row)
  end

  local header = pad_right("Key", key_col_width) ..
      " │ " .. pad_right(cur_locale .. " (current)", val_col_width)

  local cfg = get_cfg()
  local keymap_rev = normalize_keymaps(cfg.keys or {})
  local actions = {}

  actions["default"] = function(selected)
    local key = extract_key_from_selected(selected, display_list, index_to_key)
    perform_action("copy_key", key)
  end

  local function register_action_key(fzf_key, action_name)
    actions[fzf_key] = function(selected)
      local key = extract_key_from_selected(selected, display_list, index_to_key)
      perform_action(action_name, key)
    end
  end

  for fzf_key, action_name in pairs(keymap_rev) do
    if action_name ~= "copy_key" then
      register_action_key(fzf_key, action_name)
    end
  end

  fzf.fzf_exec(display_list, {
    prompt = "I18n Key > ",
    header = header,
    header_lines = 1,
    actions = actions,
    previewer = function(item)
      if not item then return " " end
      for idx, line in ipairs(display_list) do
        if line == item then
          local key = index_to_key[idx]
          return build_preview(key)
        end
      end
      return " "
    end,
    fzf_opts = {
      ["--no-multi"] = "",
      ["--no-sort"] = "",
      ["--layout"] = "reverse",
      ["--info"] = "inline",
      ["--border"] = "rounded",
      ["--ansi"] = "",
      ["--tabstop"] = "1",
      ["--preview-window"] = "right:60%",
    },
    winopts = {
      width = 0.9,
      height = 0.85,
      row = 0.5,
      col = 0.5,
    },
  })
end

return M
