local M = {}
local config = require('i18n.config')
local utils = require('i18n.utils')

local function is_absolute_path(path)
  if not path or path == '' then return false end
  if path:match('^%a:[\\/]') then
    return true
  end
  return path:sub(1, 1) == '/'
end

local function to_absolute_pattern(pattern)
  if not pattern or pattern == '' then return nil end
  if is_absolute_path(pattern) then
    return pattern
  end
  local cwd = vim.fn.getcwd()
  if cwd:sub(-1) == '/' then
    return cwd .. pattern
  end
  return cwd .. '/' .. pattern
end

local function globify_source_pattern(pattern)
  return pattern:gsub('{[^}]+}', '*')
end

local function collect_patterns_from_sources(sources)
  local patterns = {}
  local seen = {}

  for _, source in ipairs(sources or {}) do
    local pattern = source
    if type(source) == 'table' then
      pattern = source.pattern or source.files
    end
    if type(pattern) == 'string' and pattern ~= '' then
      local glob = globify_source_pattern(pattern)
      local abs = to_absolute_pattern(glob)
      if abs and not seen[abs] then
        seen[abs] = true
        table.insert(patterns, abs)
      end
    end
  end

  return patterns
end

local function collect_patterns_from_files(files)
  local patterns = {}
  local seen = {}

  for _, file in ipairs(files or {}) do
    if file and file ~= '' then
      local dir = vim.fn.fnamemodify(file, ':h')
      local ext = file:match('%.([^%.]+)$')
      local pattern = dir .. '/*'
      if ext then
        pattern = pattern .. '.' .. ext
      end
      if not seen[pattern] then
        seen[pattern] = true
        table.insert(patterns, pattern)
      end
    end
  end

  return patterns
end

-- Neovim(LuaJIT 5.1) 没有标准 utf8.char，这里实现一个安全的 UTF-8 编码函数
local function u_char(cp)
  if type(cp) ~= "number" or cp < 0 then return "" end
  if cp <= 0x7F then
    return string.char(cp)
  elseif cp <= 0x7FF then
    local b1 = 0xC0 + math.floor(cp / 0x40)
    local b2 = 0x80 + (cp % 0x40)
    return string.char(b1, b2)
  elseif cp <= 0xFFFF then
    local b1 = 0xE0 + math.floor(cp / 0x1000)
    local b2 = 0x80 + (math.floor(cp / 0x40) % 0x40)
    local b3 = 0x80 + (cp % 0x40)
    return string.char(b1, b2, b3)
  elseif cp <= 0x10FFFF then
    local b1 = 0xF0 + math.floor(cp / 0x40000)
    local b2 = 0x80 + (math.floor(cp / 0x1000) % 0x40)
    local b3 = 0x80 + (math.floor(cp / 0x40) % 0x40)
    local b4 = 0x80 + (cp % 0x40)
    return string.char(b1, b2, b3, b4)
  end
  return ""
end

-- 记录每个文件的前缀信息与 key 元数据
-- file_prefixes[locale][absolute_file_path] = "system."
M.file_prefixes = {}
-- meta[locale][full_key] = { file = "...", line = number, col = number }
M.meta = {}

-- 已解析出的实际翻译文件绝对路径列表（用于监控变更）
M._translation_files = {}
-- 每个翻译文件的 key 集合（用于增量更新 all_keys）
M._file_keys = {}
-- key 引用计数（跨 locale/文件）
M._key_refcount = {}

-- 设置自动命令监控翻译文件的写入 / 删除 / 外部变更
function M._setup_file_watchers()
  -- 若没有文件则直接返回
  if not M._translation_files or #M._translation_files == 0 then
    return
  end
  -- 统一使用同一个 augroup，每次重建
  local group = vim.api.nvim_create_augroup('I18nTranslationFilesWatcher', { clear = true })
  local patterns = collect_patterns_from_sources(M._active_sources)
  if #patterns == 0 then
    patterns = collect_patterns_from_files(M._translation_files)
  end
  if #patterns == 0 then
    return
  end

  vim.api.nvim_create_autocmd({ 'BufWritePost', 'BufDelete', 'FileChangedShellPost' }, {
    group = group,
    pattern = patterns,
    callback = function(args)
      -- 重新加载翻译并刷新展示
      local ok_p, parser_mod = pcall(require, 'i18n.parser')
      if ok_p then
        local target = args and args.file or ''
        if target == '' then
          return
        end
        if parser_mod.reload_translation_file then
          local ok = parser_mod.reload_translation_file(target)
          if not ok and parser_mod.load_translations then
            parser_mod.load_translations()
          end
        else
          parser_mod.load_translations()
        end
      end
      local ok_d, display_mod = pcall(require, 'i18n.display')
      if ok_d and display_mod.refresh then
        display_mod.refresh()
      end
    end,
    desc = "Reload i18n translations on file change",
  })
end

local function resolve_locale_for_file(abs_path)
  if not abs_path then return nil end

  for locale, file_map in pairs(M.file_prefixes or {}) do
    local prefix = file_map[abs_path]
    if prefix then
      return locale, prefix
    end
  end

  for locale, file_map in pairs(M.file_prefixes or {}) do
    for stored_path, prefix in pairs(file_map) do
      local stored_abs = vim.loop.fs_realpath(stored_path) or vim.fn.fnamemodify(stored_path, ":p")
      if stored_abs == abs_path then
        return locale, prefix
      end
    end
  end

  return nil
end

local function clear_entries_for_file(locale, abs_path)
  local translations = M.translations[locale]
  local meta_locale = M.meta[locale]
  if not translations or not meta_locale then
    return
  end

  local file_keys = M._file_keys and M._file_keys[abs_path]
  if file_keys then
    for key in pairs(file_keys) do
      translations[key] = nil
      meta_locale[key] = nil
    end
    return
  end

  for key, meta in pairs(meta_locale) do
    if meta.file == abs_path then
      translations[key] = nil
      meta_locale[key] = nil
    end
  end
end

local function find_sorted_index(list, key)
  local low = 1
  local high = #list
  while low <= high do
    local mid = math.floor((low + high) / 2)
    local current = list[mid]
    if current == key then
      return mid, true
    end
    if current < key then
      low = mid + 1
    else
      high = mid - 1
    end
  end
  return low, false
end

local function insert_sorted(list, key)
  local idx, found = find_sorted_index(list, key)
  if not found then
    table.insert(list, idx, key)
  end
end

local function remove_sorted(list, key)
  local idx, found = find_sorted_index(list, key)
  if found then
    table.remove(list, idx)
  end
end

local function ensure_key_index()
  M._file_keys = M._file_keys or {}
  M._key_refcount = M._key_refcount or {}
  M.all_keys = M.all_keys or {}
end

local function add_key_ref(key, defer_index)
  local count = M._key_refcount[key] or 0
  M._key_refcount[key] = count + 1
  if count == 0 and not defer_index then
    insert_sorted(M.all_keys, key)
  end
end

local function remove_key_ref(key, defer_index)
  local count = M._key_refcount[key]
  if not count then
    return
  end
  if count <= 1 then
    M._key_refcount[key] = nil
    if not defer_index then
      remove_sorted(M.all_keys, key)
    end
    return
  end
  M._key_refcount[key] = count - 1
end

local function set_file_keys(abs_path, new_keys, opts)
  ensure_key_index()
  local defer_index = opts and opts.defer_index
  local old_keys = M._file_keys[abs_path]
  if old_keys then
    for key in pairs(old_keys) do
      remove_key_ref(key, defer_index)
    end
  end

  if new_keys and next(new_keys) then
    M._file_keys[abs_path] = new_keys
    for key in pairs(new_keys) do
      add_key_ref(key, defer_index)
    end
  else
    M._file_keys[abs_path] = nil
  end
end

local function rebuild_all_keys_from_refcount()
  M.all_keys = {}
  for key, _ in pairs(M._key_refcount or {}) do
    table.insert(M.all_keys, key)
  end
  table.sort(M.all_keys)
end

-- 解析 JSON 文件
local function parse_json(content)
  local ok, decoded = pcall(vim.json.decode, content)
  if not ok or type(decoded) ~= "table" then
    return nil
  end

  -- 使用 vim.split 保留空行（原实现用 gmatch 会丢失空行，导致行号偏移）
  local lines = vim.split(content, "\n", true)
  -- 去掉行尾 \r 以兼容 CRLF
  for i, l in ipairs(lines) do
    lines[i] = l:gsub("\r$", "")
  end

  local function guess_line(seg)
    for idx, l in ipairs(lines) do
      -- 匹配 "seg": 或 'seg':
      if l:match('[\'"]' .. vim.pesc(seg) .. '[\'"]%s*:') then
        return idx
      end
    end
    return 1
  end

  local flat = {}
  local line_map = {}
  local col_map = {}

  local function find_line_and_col(seg)
    for idx, l in ipairs(lines) do
      -- 匹配 "key": 或 'key':
      local pattern = '([\'"])' .. vim.pesc(seg) .. '%1%s*:'
      local s = l:find(pattern)
      if s then
        -- s 指向引号位置，列号取 key 第一个字符（引号后一位），1-based
        local col = s + 1
        local len = #l
        if len == 0 then
          col = 1
        elseif col > len then
          col = len
        end
        if col < 1 then col = 1 end
        return idx, col
      end
    end
    return 1, 1
  end

  local function traverse(tbl, prefix)
    for k, v in pairs(tbl) do
      local full_key = prefix == "" and k or (prefix .. "." .. k)
      if type(v) == "table" then
        traverse(v, full_key)
      else
        flat[full_key] = v
        local line, col = find_line_and_col(k)
        local ltxt = lines[line] or ""
        local max_col = #ltxt
        if max_col == 0 then
          col = 1
        elseif col > max_col then
          col = max_col
        elseif col < 1 then
          col = 1
        end
        line_map[full_key] = line
        col_map[full_key] = col
      end
    end
  end

  traverse(decoded, "")
  return flat, line_map, col_map
end

-- 解析 YAML 文件
local function parse_yaml(content)
  -- 简单的 YAML 解析，实际使用可能需要更复杂的解析器
  local result = {}
  local line_map = {}
  local col_map = {}
  local idx = 0
  for line in content:gmatch("[^\r\n]+") do
    idx = idx + 1
    local key, value = line:match("^%s*([%w%.]+):%s*(.+)%s*$")
    if key and value then
      value = value:gsub("^['\"]", ""):gsub("['\"]$", "")
      result[key] = value
      line_map[key] = idx
    end
  end
  return result, line_map, col_map
end

-- 解析 .properties 文件 (key=value / key:value，忽略 # 或 ! 开头注释，简单实现)
local function parse_properties(content)
  local result = {}
  local line_map = {}
  local idx = 0
  for line in content:gmatch("[^\r\n]+") do
    idx = idx + 1
    local trimmed = line:match("^%s*(.-)%s*$")
    if trimmed ~= "" and not trimmed:match("^#") and not trimmed:match("^!") then
      local key, value = trimmed:match("^([^:=%s]+)%s*[:=]%s*(.*)$")
      if not key then
        key, value = trimmed:match("^([^%s]+)%s+(.*)$")
      end
      if key and value then
        -- 去掉行尾续行反斜杠（简单处理，不做真正跨行拼接）
        value = value:gsub("\\$", "")

        -- 先处理 Unicode 代理对 (高代理+D800-DBFF, 低代理+DC00-DFFF)
        -- 形式: \uD83D\uDE02 -> 😂
        value = value:gsub("\\u(d[89ABab][0-9A-Fa-f][0-9A-Fa-f])\\u(d[CSDEcsde][0-9A-Fa-f][0-9A-Fa-f])", function(hi, lo)
          local hi_n = tonumber(hi, 16)
          local lo_n = tonumber(lo, 16)
          if hi_n and lo_n then
            local codepoint = 0x10000 + ((hi_n - 0xD800) * 0x400) + (lo_n - 0xDC00)
            if codepoint <= 0x10FFFF then
              return u_char(codepoint)
            end
          end
          return ""
        end)

        -- 再处理普通 \uXXXX
        value = value:gsub("\\u(%x%x%x%x)", function(hex)
          local cp = tonumber(hex, 16)
          if cp then
            return u_char(cp)
          end
          return ""
        end)

        -- 常见转义序列
        value = value
            :gsub("\\n", "\n")
            :gsub("\\t", "\t")
            :gsub("\\r", "\r")
            :gsub("\\f", "\f")
            :gsub("\\\\", "\\")

        result[key] = value
        line_map[key] = idx
      end
    end
  end
  return result, line_map
end

-- 解析 JS/TS 文件（使用 treesitter 支持递归任意深度）
local function parse_js(content)
  local ts = vim.treesitter
  local parser = nil
  local language = nil

  -- 自动判断语言类型
  if content:match("export%s+default") or content:match("module%.exports") then
    language = "javascript"
  else
    language = "typescript"
  end

  -- treesitter 解析
  local ok, tree = pcall(function()
    parser = ts.get_string_parser(content, language)
    return parser:parse()[1]
  end)
  if not ok or not tree then
    return {}
  end

  local root = tree:root()
  local result = {}
  local line_map = {}
  local col_map = {}

  -- 查找 export default/module.exports 的对象节点
  local function find_export_object(node)
    for child in node:iter_children() do
      if child:type() == "export_statement" or child:type() == "expression_statement" then
        for grand in child:iter_children() do
          if grand:type() == "object" then
            return grand
          elseif grand:type() == "assignment_expression" then
            for g in grand:iter_children() do
              if g:type() == "object" then
                return g
              end
            end
          end
        end
      elseif child:type() == "object" then
        return child
      else
        local found = find_export_object(child)
        if found then return found end
      end
    end
    return nil
  end

  -- 递归遍历对象节点
  local function traverse_object(node, prefix)
    prefix = prefix or ""
    for prop in node:iter_children() do
      if prop:type() == "pair" then
        local key_node = prop:field("key")[1]
        local value_node = prop:field("value")[1]
        -- 兼容不同 Neovim/treesitter 版本的 get_node_text
        local get_node_text = ts.get_node_text or vim.treesitter.get_node_text
        local key = get_node_text and get_node_text(key_node, content) or key_node and key_node:text() or ""

        -- 去除 key 两侧的引号（若有）
        if #key >= 2 then
          local kfirst = key:sub(1, 1)
          local klast = key:sub(-1)
          if (kfirst == '"' or kfirst == "'" or kfirst == "`") and klast == kfirst then
            key = key:sub(2, -2)
          end
        end

        if value_node:type() == "object" then
          traverse_object(value_node, prefix .. key .. ".")
        else
          local value = get_node_text and get_node_text(value_node, content) or value_node and value_node:text() or ""

          -- 去除 value 两侧的引号（若有）
          if #value >= 2 then
            local vfirst = value:sub(1, 1)
            local vlast = value:sub(-1)
            if (vfirst == '"' or vfirst == "'" or vfirst == "`") and vlast == vfirst then
              value = value:sub(2, -2)
            end
          end

          local full_key = prefix .. key
          result[full_key] = value
          -- key_node:start() 返回 0-based 行
          if key_node and key_node:start() then
            local row, col = key_node:start()
            line_map[full_key] = row + 1
            col_map[full_key] = (col or 0) + 1
          end
        end
      end
    end
  end

  local obj_node = find_export_object(root)
  if obj_node then
    traverse_object(obj_node, "")
  end

  return result, line_map, col_map
end

-- 根据文件扩展名解析文件
local function parse_file(filepath)
  local content = utils.read_file(filepath)
  if not content then
    return nil
  end

  local ext = filepath:match("%.([^%.]+)$")
  if ext == "json" then
    return parse_json(content)
  elseif ext == "yaml" or ext == "yml" then
    return parse_yaml(content)
  elseif ext == "properties" or ext == "prop" then
    return parse_properties(content)
  elseif ext == "js" or ext == "ts" then
    return parse_js(content)
  end

  return nil
end

function M.reload_translation_file(path)
  if not path or path == '' then return false end
  local abs_path = vim.loop.fs_realpath(path) or vim.fn.fnamemodify(path, ":p")
  local locale, prefix = resolve_locale_for_file(abs_path)
  if not locale then
    return false
  end

  clear_entries_for_file(locale, abs_path)

  local data, line_map, col_map
  if utils.file_exists(abs_path) then
    data, line_map, col_map = parse_file(abs_path)
  end

  local key_set
  if data then
    M.translations[locale] = M.translations[locale] or {}
    M.meta[locale] = M.meta[locale] or {}
    key_set = {}
    for k, v in pairs(data) do
      local final_key = (prefix or "") .. k
      M.translations[locale][final_key] = v
      local line = line_map and line_map[k] or 1
      local col = (col_map and col_map[k]) or 1
      M.meta[locale][final_key] = { file = abs_path, line = line, col = col }
      key_set[final_key] = true
    end
  end

  set_file_keys(abs_path, key_set)

  return data ~= nil
end

-- 深度合并表
-- 变更说明：不要将中间节点（table）作为独立翻译条目写入目标表，
-- 仅在遇到非 table 的叶子节点时才写入 t1。这样可以避免像 "hello" 这种
-- 只含子项的父键被错误地当作翻译条目插入。
local function deep_merge(t1, t2, prefix)
  prefix = prefix or ""
  for k, v in pairs(t2 or {}) do
    local full_key = prefix == "" and k or (prefix .. k)
    if type(v) == "table" then
      -- 仅递归展开子表，不创建中间节点条目
      deep_merge(t1, v, full_key .. ".")
    else
      t1[full_key] = v
    end
  end
end

-- 递归扫描自定义变量
local function scan_vars(pattern, vars, idx, cb)
  -- vim.notify("Scanning pattern: " ..
  --   pattern .. " with vars: " .. table.concat(vars, ", ") .. " at idx: " .. tostring(idx))
  idx = idx or 1
  if idx > #vars then
    cb(pattern)
    return
  end
  local var = vars[idx]
  local before, after = pattern:match("^(.-){" .. var .. "}(.*)$")

  -- vim.notify("Scanning pattern: " ..
  --   pattern .. " for variable: " .. var .. "\nBefore: " .. tostring(before) .. "\nAfter: " .. tostring(after))
  if not before then
    -- 变量不在 pattern 中，递归下一个
    scan_vars(pattern, vars, idx + 1, cb)
    return
  end
  -- 获取变量所在目录
  local dir = before:match("^(.-)/?$")
  -- 空字符串在 Lua 中是 truthy 的，需要显式检查
  if not dir or dir == "" then
    dir = "."
  end

  -- 判断变量后是否直接跟着扩展名（如 .ts/.js/.json），如果是则扫描文件
  -- 支持 {module}.ts 这种情况
  local ext
  -- 优先用 pattern 匹配 {var}.ext 形式
  local ext_pattern = pattern:match("{" .. var .. "}%.([%w_]+)")
  if ext_pattern then
    ext = ext_pattern
  else
    -- 其次用 after 匹配 .ext 结尾，但仅在后续不再包含占位符时才视为文件
    local has_next_placeholder = after:find('{', 1, true)
    if not has_next_placeholder then
      ext = after:match("%.([%w_]+)$")
    end
  end
  if ext then
    ext = "." .. ext
    if utils.file_exists(dir) then
      local subs = utils.scan_sub(dir, ext)
      for _, sub in ipairs(subs) do
        local sub_name = sub:gsub("%" .. ext .. "$", "")
        local replaced = pattern:gsub("{" .. var .. "}", sub_name, 1)
        scan_vars(replaced, vars, idx + 1, cb)
      end
    end
    return
  end

  -- 如果 dir 不存在，且不是文件模式，直接返回
  if not utils.file_exists(dir) then
    return
  end

  -- 目录模式，递归子目录
  local subs = utils.scan_sub(dir)
  for _, sub in ipairs(subs) do
    local replaced = pattern:gsub("{" .. var .. "}", sub, 1)
    scan_vars(replaced, vars, idx + 1, cb)
  end
end

-- 提取所有自定义变量（不包括 locales）
local function extract_vars(str)
  local vars = {}
  for var in str:gmatch("{([%w_]+)}") do
    if var ~= "locales" then
      table.insert(vars, var)
    end
  end
  return vars
end

-- actual_prefix: src/views/qds/locales/lang/en_US/system.ts
-- filepath: src/views/{bu}/locales/lang/en_US/{module}.ts
-- prefix: {bu}.{module}. -> qds.system.
local function fill_prefix(actual_file, filepath, prefix)
  local prefix_vars = extract_vars(prefix)

  -- 创建一个更精确的匹配模式
  local pattern = "^" .. filepath:gsub("([%.%-%+%*%?%[%]%(%)%^%$])", "%%%1"):gsub("{[^}]+}", "([^/]+)") .. "$"

  local matches = { actual_file:match(pattern) }

  -- 如果匹配失败，尝试更灵活的方法
  if #matches == 0 then
    -- 手动解析路径
    local actual_segments = {}
    local template_segments = {}

    for segment in actual_file:gmatch("[^/]+") do
      table.insert(actual_segments, segment)
    end

    for segment in filepath:gmatch("[^/]+") do
      table.insert(template_segments, segment)
    end

    local var_count = 1
    for i, template_seg in ipairs(template_segments) do
      if template_seg:match("^{[^}]+}$") then
        if actual_segments[i] then
          local value = actual_segments[i]:gsub("%.ts$", "")
          matches[var_count] = value
          var_count = var_count + 1
        end
      end
    end
  else
    -- 清理匹配结果（移除文件扩展名等）
    for i, match in ipairs(matches) do
      matches[i] = match:gsub("%.ts$", "")
    end
  end

  -- 替换 prefix 中的变量
  local result = prefix
  for i, var in ipairs(prefix_vars) do
    if matches[i] then
      result = result:gsub("{" .. var .. "}", matches[i])
    end
  end

  return result
end

local function record_file_data(locale, abs_path, prefix, data, line_map, col_map, index_opts)
  M.translations[locale] = M.translations[locale] or {}
  M.meta[locale] = M.meta[locale] or {}
  local key_set = {}
  for k, v in pairs(data) do
    local final_key = (prefix or "") .. k
    M.translations[locale][final_key] = v
    local line = line_map and line_map[k] or 1
    local col = (col_map and col_map[k]) or 1
    M.meta[locale][final_key] = { file = abs_path, line = line, col = col }
    key_set[final_key] = true
  end
  set_file_keys(abs_path, key_set, index_opts)
end

-- 加载单个文件配置
local function load_file_config(file_config, locale, index_opts)
  local pattern = type(file_config) == "string" and file_config
      or file_config.pattern
  local prefix = type(file_config) == "table" and file_config.prefix or ""

  -- 替换 {locales} 占位符
  local filepath = pattern:gsub("{locales}", locale)
  local vars = extract_vars(filepath)
  if #vars > 0 then
    -- 存在自定义变量，递归扫描
    scan_vars(filepath, vars, 1, function(actual_file)
      -- prefix 也需要替换变量
      local actual_prefix = fill_prefix(actual_file, filepath, prefix)
      -- vim.notify("actual_file: " .. actual_file .. "\nfilepath: " .. filepath .. "\nactual_prefix: " .. actual_prefix)
      if utils.file_exists(actual_file) then
        local data, line_map, col_map = parse_file(actual_file)
        if data then
          M.file_prefixes[locale] = M.file_prefixes[locale] or {}
          local abs_store = vim.loop.fs_realpath(actual_file) or vim.fn.fnamemodify(actual_file, ":p")
          M.file_prefixes[locale][abs_store] = actual_prefix
          table.insert(M._translation_files, abs_store)
          record_file_data(locale, abs_store, actual_prefix, data, line_map, col_map, index_opts)
        end
      end
    end)
  else
    -- 直接加载文件
    if utils.file_exists(filepath) then
      local data, line_map, col_map = parse_file(filepath)
      if data then
        M.file_prefixes[locale] = M.file_prefixes[locale] or {}
        local abs_store = vim.loop.fs_realpath(filepath) or vim.fn.fnamemodify(filepath, ":p")
        M.file_prefixes[locale][abs_store] = prefix
        table.insert(M._translation_files, abs_store)
        record_file_data(locale, abs_store, prefix, data, line_map, col_map, index_opts)
      end
    end
  end
end

-- 加载所有翻译文件
M.load_translations = function()
  M.translations = {}
  M._translation_files = {}
  M._file_keys = {}
  M._key_refcount = {}
  M.all_keys = {}
  local options = config.options

  -- Check if auto-detect should run
  local auto_detect = require('i18n.auto_detect')
  local sources = options.sources or {}
  local locales = options.locales or {}

  if auto_detect.should_auto_detect(options) then
    local detect_opts = auto_detect.get_options(options)
    local detected_sources, detected_locales = auto_detect.detect(detect_opts)
    local auto_detect_opts = options.auto_detect
    local notify_auto_detect = false
    if type(auto_detect_opts) == 'table' then
      notify_auto_detect = auto_detect_opts.notify == true
    end

    if detected_sources and #detected_sources > 0 then
      sources = detected_sources
      -- Store detected sources in options for reference
      options._detected_sources = detected_sources

      -- Only use detected locales when user hasn't configured locales (empty)
      -- This allows users to explicitly set locales while still using auto-detected sources
      if detected_locales and #detected_locales > 0 and #locales == 0 then
        locales = detected_locales
        options._detected_locales = detected_locales
        -- Update config.options.locales so other modules can access the detected locales
        options.locales = detected_locales
      end

      -- Notify user about auto-detection results (only once per session)
      if notify_auto_detect and not M._auto_detect_notified then
        local source_count = #detected_sources
        local locale_count = #locales
        -- Build source info for notification
        local source_info = {}
        for _, src in ipairs(detected_sources) do
          local pattern = type(src) == 'string' and src or src.pattern
          table.insert(source_info, pattern)
        end
        vim.notify(
          string.format('[i18n] Auto-detected %d source(s), %d locale(s)\n  Locales: %s\n  Sources: %s',
            source_count, locale_count,
            table.concat(locales, ', '),
            table.concat(source_info, '\n           ')),
          vim.log.levels.INFO
        )
        M._auto_detect_notified = true
      end
    else
      -- Auto-detect was enabled but found nothing
      if notify_auto_detect and not M._auto_detect_notified then
        vim.notify('[i18n] Auto-detect enabled but no locale directories found', vim.log.levels.WARN)
        M._auto_detect_notified = true
      end
    end
  end

  M._active_sources = sources
  local index_opts = { defer_index = true }

  for _, locale in ipairs(locales) do
    for _, source in ipairs(sources) do
      -- 判断 {module} 后面是文件后缀还是 /
      local pattern = type(source) == "string" and source
          or source.pattern
      local filepath = pattern:gsub("{locales}", locale)
      local ext = nil
      if filepath:match("{module}") then
        ext = filepath:match("{module}%.([%w_]+)")
        if ext then ext = "." .. ext end
      end
      load_file_config(source, locale, index_opts)
    end
  end

  rebuild_all_keys_from_refcount()

  -- 注册文件监控
  M._setup_file_watchers()
end

-- Convert flattened key-value pairs to nested table structure
-- Input:  { "name" = "xiaoming", "detail.age" = 18, "detail.city" = "Beijing" }
-- Output: { name = "xiaoming", detail = { age = 18, city = "Beijing" } }
local function build_nested_object(flat_table)
  local result = {}
  for key, value in pairs(flat_table) do
    local parts = vim.split(key, '.', { plain = true })
    local current = result
    for i = 1, #parts - 1 do
      local part = parts[i]
      if current[part] == nil then
        current[part] = {}
      end
      current = current[part]
    end
    current[parts[#parts]] = value
  end
  return result
end

-- 获取特定语言的翻译
M.get_translation = function(key, locale)
  local locales = config.options.locales
  locale = locale or (locales and locales[1])
  if not M.translations[locale] then
    return nil
  end

  -- 1. Try exact match first (leaf node)
  if M.translations[locale][key] then
    return M.translations[locale][key]
  end

  -- 2. Check if key is a prefix of other keys
  local prefix = key .. '.'
  local children = {}
  for full_key, value in pairs(M.translations[locale]) do
    if full_key:sub(1, #prefix) == prefix then
      -- Extract the remaining key part after the prefix
      local child_key = full_key:sub(#prefix + 1)
      children[child_key] = value
    end
  end

  -- 3. If children found, build nested object and return as JSON
  if not vim.tbl_isempty(children) then
    local nested = build_nested_object(children)
    local ok, json = pcall(vim.json.encode, nested)
    if ok then
      return json
    end
  end

  return nil
end

-- 获取所有语言的翻译
M.get_all_translations = function(key)
  local result = {}
  for locale, translations in pairs(M.translations) do
    -- Try exact match first
    if translations[key] then
      result[locale] = translations[key]
    else
      -- Try prefix match
      local prefix = key .. '.'
      local children = {}
      for full_key, value in pairs(translations) do
        if full_key:sub(1, #prefix) == prefix then
          local child_key = full_key:sub(#prefix + 1)
          children[child_key] = value
        end
      end
      if not vim.tbl_isempty(children) then
        local nested = build_nested_object(children)
        local ok, json = pcall(vim.json.encode, nested)
        if ok then
          result[locale] = json
        end
      end
    end
  end
  return result
end

-- 获取某个 key 在默认或指定语言下的位置信息 { file=..., line=... }
M.get_key_location = function(key, locale)
  locale = locale or (config.options.locales and config.options.locales[1])
  if not locale then return nil end
  local meta_locale = M.meta[locale]
  if meta_locale and meta_locale[key] then
    return meta_locale[key]
  end
  return nil
end

M.get_all_keys = function()
  if not M.all_keys then return {} end
  return M.all_keys
end

-- 增量重新解析当前翻译缓冲区（未保存内容也能即时刷新行号）
-- abs_path: 绝对路径
-- locale: 语言
-- bufnr: buffer 编号
function M.reload_translation_buffer(abs_path, locale, bufnr)
  if not abs_path or not locale or not bufnr then return false end
  if not M.file_prefixes[locale] or not M.file_prefixes[locale][abs_path] then
    return false
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local content = table.concat(lines, "\n")
  local ext = abs_path:match("%.([%w_]+)$")
  if not ext then return false end

  local data, line_map, col_map
  if ext == "json" then
    data, line_map, col_map = parse_json(content)
  elseif ext == "yaml" or ext == "yml" then
    data, line_map, col_map = parse_yaml(content)
  elseif ext == "properties" or ext == "prop" then
    data, line_map = parse_properties(content)
    col_map = {}
  elseif ext == "js" or ext == "ts" then
    data, line_map, col_map = parse_js(content)
  else
    return false
  end
  -- 若当前内容暂时无效（如 JSON 未完成输入），返回 false，调用方据此跳过渲染避免错位
  if not data then return false end

  local prefix = M.file_prefixes[locale][abs_path] or ""

  M.translations[locale] = M.translations[locale] or {}
  M.meta[locale] = M.meta[locale] or {}

  -- 记录旧 meta（保留 mark_id 以避免行内插入时闪烁 / 丢失跟踪）
  local old_file_meta = {}
  for key, meta in pairs(M.meta[locale]) do
    if meta.file == abs_path then
      old_file_meta[key] = meta
    end
  end
  -- 清除旧的该文件条目
  for key, _ in pairs(old_file_meta) do
    M.translations[locale][key] = nil
    M.meta[locale][key] = nil
  end

  -- 写入新数据（复用旧 mark_id）
  local key_set = {}
  for k, v in pairs(data) do
    local final_key = prefix .. k
    M.translations[locale][final_key] = v
    local line = line_map and line_map[k] or 1
    local col = (col_map and col_map[k]) or 1
    local old = old_file_meta[final_key]
    if old and old.mark_id then
      M.meta[locale][final_key] = { file = abs_path, line = line, col = col, mark_id = old.mark_id }
    else
      M.meta[locale][final_key] = { file = abs_path, line = line, col = col }
    end
    key_set[final_key] = true
  end

  set_file_keys(abs_path, key_set)

  return true
end

return M
