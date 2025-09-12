local M = {}

local config = require('i18n.config')
local parser = require('i18n.parser')
local utils = require('i18n.utils')

-- 简单获取光标下的 i18n key（基于 func_pattern）
local function get_key_under_cursor()
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2] + 1
  for _, pat in ipairs(config.options.func_pattern or {}) do
    local init = 1
    while true do
      local s, e, cap = line:find(pat, init)
      if not s then break end
      if col >= s and col <= e then
        return cap
      end
      init = e + 1
    end
  end
  return nil
end

-- 判断 key 是否已存在（任一 locale）
local function key_exists(key)
  for locale, translations in pairs(parser.translations or {}) do
    if translations[key] ~= nil then
      return true, locale
    end
  end
  return false, nil
end

-- 找到每个 locale 对应的文件（最长前缀匹配）
local function resolve_files_for_key(key)
  local mapping = {}
  for _, locale in ipairs(config.options.locales or {}) do
    local prefixes = parser.file_prefixes[locale] or {}
    local best_len = -1
    local best_file = nil
    local best_prefix = ""
    for file, prefix in pairs(prefixes) do
      if prefix == "" or key:sub(1, #prefix) == prefix then
        local plen = #prefix
        if plen > best_len then
          best_len = plen
          best_file = file
          best_prefix = prefix
        end
      end
    end
    if best_file then
      mapping[locale] = { file = best_file, prefix = best_prefix }
    end
  end
  return mapping
end

-- 读取 JSON -> table（空或失败返回 {}）
local function read_json_table(path)
  local content = utils.read_file(path)
  if not content or content == "" then return {} end
  local ok, decoded = pcall(vim.json.decode, content)
  if ok and type(decoded) == "table" then return decoded end
  return {}
end

-- 嵌套写入 path a.b.c
local function assign_nested(tbl, keypath, value)
  local parts = {}
  for seg in keypath:gmatch("[^%.]+") do
    table.insert(parts, seg)
  end
  local node = tbl
  for i = 1, #parts do
    local k = parts[i]
    if i == #parts then
      node[k] = value
    else
      if type(node[k]) ~= "table" then
        node[k] = {}
      end
      node = node[k]
    end
  end
end

-- 简单 pretty JSON（避免依赖外部库）
local function encode_pretty(tbl, indent, depth)
  indent = indent or "  "
  depth = depth or 0
  if type(tbl) ~= "table" then
    return vim.json.encode(tbl)
  end
  local is_array = (#tbl > 0)
  local pieces = {}
  if is_array then
    table.insert(pieces, "[")
    for i, v in ipairs(tbl) do
      local comma = (i < #tbl) and "," or ""
      if type(v) == "table" then
        table.insert(pieces, string.rep(indent, depth + 1) .. encode_pretty(v, indent, depth + 1) .. comma)
      else
        table.insert(pieces, string.rep(indent, depth + 1) .. vim.json.encode(v) .. comma)
      end
    end
    table.insert(pieces, string.rep(indent, depth) .. "]")
  else
    table.insert(pieces, "{")
    local keys = {}
    for k, _ in pairs(tbl) do table.insert(keys, k) end
    table.sort(keys)
    for i, k in ipairs(keys) do
      local v = tbl[k]
      local comma = (i < #keys) and "," or ""
      if type(v) == "table" then
        table.insert(pieces,
          string.format("%s%q: %s%s", string.rep(indent, depth + 1), k,
            encode_pretty(v, indent, depth + 1), comma))
      else
        table.insert(pieces,
          string.format("%s%q: %s%s", string.rep(indent, depth + 1), k, vim.json.encode(v), comma))
      end
    end
    table.insert(pieces, string.rep(indent, depth) .. "}")
  end
  return table.concat(pieces, "\n")
end

local function ensure_dir(path)
  local dir = vim.fn.fnamemodify(path, ":h")
  if dir ~= "" and vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, "p")
  end
end

local function write_key_to_files(key, values, filemap)
  for locale, data in pairs(filemap) do
    local file = data.file
    if file and values[locale] and values[locale] ~= "" then
      local ext = file:match("%.([%w_]+)$") or ""
      if ext == "json" then
        ensure_dir(file)
        local tbl = read_json_table(file)
        assign_nested(tbl, key:gsub("^" .. vim.pesc(data.prefix), ""), values[locale])
        local encoded = encode_pretty(tbl)
        local ok_write = pcall(function()
          local f = assert(io.open(file, "w"))
          f:write(encoded)
          f:close()
        end)
        if not ok_write then
          vim.notify("[i18n] Failed writing file: " .. file, vim.log.levels.ERROR)
        end
      elseif ext == "yml" or ext == "yaml" then
        vim.notify("[i18n] YAML write not yet supported (skipped): " .. file, vim.log.levels.WARN)
      else
        vim.notify("[i18n] Unsupported target file type for automatic insertion: " .. file, vim.log.levels.WARN)
      end
    end
  end
end

-- 弹窗编辑
function M.add_key_interactive()
  local locales = config.options.locales or {}
  if #locales == 0 then
    vim.notify("[i18n] No locales configured", vim.log.levels.WARN)
    return
  end

  local key = get_key_under_cursor()
  if not key or key == "" then
    vim.notify("[i18n] No i18n key under cursor", vim.log.levels.WARN)
    return
  end

  local exists = key_exists(key)
  if exists then
    vim.notify("[i18n] Key already exists: " .. key, vim.log.levels.INFO)
    return
  end

  local filemap = resolve_files_for_key(key)
  if vim.tbl_isempty(filemap) then
    vim.notify("[i18n] Cannot resolve target translation files for key (check prefixes): " .. key,
      vim.log.levels.ERROR)
    return
  end

  -- 创建浮动窗口
  local width = math.max(60, #key + 20)
  local height = #locales + 8
  local buf = vim.api.nvim_create_buf(false, true)
  local ui = vim.api.nvim_list_uis()[1]
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((ui.height - height) / 2),
    col = math.floor((ui.width - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " Add i18n Key ",
    title_pos = "center",
  })

  local lines = {}
  table.insert(lines, "Add key: " .. key)
  table.insert(lines, string.rep("-", width - 2))
  for _, locale in ipairs(locales) do
    table.insert(lines, locale .. ": ")
  end
  table.insert(lines, "")
  table.insert(lines, "Files:")
  for _, locale in ipairs(locales) do
    local fm = filemap[locale]
    if fm then
      table.insert(lines, string.format("  %s -> %s", locale, fm.file))
    else
      table.insert(lines, string.format("  %s -> (unresolved)", locale))
    end
  end
  table.insert(lines, "")
  table.insert(lines, "[Tab] Next  [S-Tab] Prev  [Enter] Save  [Esc] Cancel")

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(buf, "modifiable", true)
  vim.bo[buf].filetype = "i18n_add_key"

  -- 记录可输入的行号
  local first_input_line = 3
  local locale_line_index = {}
  for idx, locale in ipairs(locales) do
    locale_line_index[locale] = first_input_line + idx - 1
  end
  local last_input_line = first_input_line + #locales - 1

  local touched = {}
  local default_locale = locales[1]

  -- 将光标移到默认语言输入位置末尾
  vim.api.nvim_win_set_cursor(win, { locale_line_index[default_locale], (#default_locale + 3) })

  local function extract_value(line)
    local _, _, val = line:find("^[^:]+:%s*(.*)$")
    return val or ""
  end

  local function set_line(locale, value)
    local lnum = locale_line_index[locale]
    local prefix = locale .. ": "
    vim.api.nvim_buf_set_lines(buf, lnum - 1, lnum, false, { prefix .. value })
  end

  local function get_line(locale)
    local lnum = locale_line_index[locale]
    return vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1] or ""
  end

  local function get_all_values()
    local out = {}
    for _, loc in ipairs(locales) do
      out[loc] = extract_value(get_line(loc))
    end
    return out
  end

  local function move_input(delta)
    local pos = vim.api.nvim_win_get_cursor(win)
    local line = pos[1]
    local new_line = line + delta
    if new_line < first_input_line then new_line = last_input_line end
    if new_line > last_input_line then new_line = first_input_line end
    local cur_line_text = vim.api.nvim_buf_get_lines(buf, new_line - 1, new_line, false)[1] or ""
    vim.api.nvim_win_set_cursor(win, { new_line, #cur_line_text })
  end

  -- Keymaps
  local function map(lhs, rhs)
    vim.keymap.set({ "i", "n" }, lhs, rhs, { buffer = buf, nowait = true, silent = true })
  end

  map("<Tab>", function()
    move_input(1)
  end)
  map("<S-Tab>", function()
    move_input(-1)
  end)

  local function cancel()
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end

  map("<Esc>", cancel)
  map("<C-c>", cancel)

  local function save_and_close()
    local values = get_all_values()
    -- 若所有值为空则取消
    local any_non_empty = false
    for _, v in pairs(values) do
      if v ~= "" then any_non_empty = true break end
    end
    if not any_non_empty then
      vim.notify("[i18n] All translations empty; cancelled", vim.log.levels.WARN)
      cancel()
      return
    end
    write_key_to_files(key, values, filemap)
    parser.load_translations()
    local ok_d, display_mod = pcall(require, 'i18n.display')
    if ok_d and display_mod.refresh then
      display_mod.refresh()
    end
    vim.notify("[i18n] Added key: " .. key, vim.log.levels.INFO)
    cancel()
  end

  map("<CR>", function()
    -- 仅当光标在输入区域才保存；否则忽略
    local cur = vim.api.nvim_win_get_cursor(win)[1]
    if cur >= first_input_line and cur <= last_input_line then
      save_and_close()
    end
  end)

  -- 自动同步默认语言输入到未 touch 的其它 locale
  vim.api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, {
    buffer = buf,
    callback = function()
      local pos = vim.api.nvim_win_get_cursor(win)
      local cur_line = pos[1]
      for loc, lno in pairs(locale_line_index) do
        if lno == cur_line then
          touched[loc] = true
        end
      end
      if cur_line == locale_line_index[default_locale] then
        local default_val = extract_value(get_line(default_locale))
        for _, loc in ipairs(locales) do
          if loc ~= default_locale and not touched[loc] then
            set_line(loc, default_val)
          end
        end
      end
    end,
  })
end

return M
