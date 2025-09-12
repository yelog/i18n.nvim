local M = {}
local config = require('i18n.config')
local utils = require('i18n.utils')

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

-- 设置自动命令监控翻译文件的写入 / 删除 / 外部变更
function M._setup_file_watchers()
  -- 若没有文件则直接返回
  if not M._translation_files or #M._translation_files == 0 then
    return
  end
  -- 统一使用同一个 augroup，每次重建
  local group = vim.api.nvim_create_augroup('I18nTranslationFilesWatcher', { clear = true })
  local patterns_added = {}
  for _, file in ipairs(M._translation_files) do
    if file and file ~= "" and not patterns_added[file] then
      patterns_added[file] = true
      vim.api.nvim_create_autocmd({ 'BufWritePost', 'BufDelete', 'FileChangedShellPost' }, {
        group = group,
        pattern = file,
        callback = function()
          -- 重新加载翻译并刷新展示
          local ok_p, parser_mod = pcall(require, 'i18n.parser')
          if ok_p then
            parser_mod.load_translations()
          end
          local ok_d, display_mod = pcall(require, 'i18n.display')
            if ok_d and display_mod.refresh then
              display_mod.refresh()
            end
        end,
        desc = "Reload i18n translations on file change",
      })
    end
  end
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
  local before, after = pattern:match("^(.-){(" .. var .. ")}(.*)$")

  -- vim.notify("Scanning pattern: " ..
  --   pattern .. " for variable: " .. var .. "\nBefore: " .. tostring(before) .. "\nAfter: " .. tostring(after))
  if not before then
    -- 变量不在 pattern 中，递归下一个
    scan_vars(pattern, vars, idx + 1, cb)
    return
  end
  -- 获取变量所在目录
  local dir = before:match("^(.-)/?$") or "."

  -- 判断变量后是否直接跟着扩展名（如 .ts/.js/.json），如果是则扫描文件
  -- 支持 {module}.ts 这种情况
  local ext
  -- 优先用 pattern 匹配 {var}.ext 形式
  local ext_pattern = pattern:match("{" .. var .. "}%.([%w_]+)")
  if ext_pattern then
    ext = ext_pattern
  else
    -- 其次用 after 匹配 .ext 结尾
    ext = after:match("%.([%w_]+)$")
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

-- 加载单个文件配置
local function load_file_config(file_config, locale)
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
          M.translations[locale] = M.translations[locale] or {}
          M.meta[locale] = M.meta[locale] or {}
          M.file_prefixes[locale] = M.file_prefixes[locale] or {}
          local abs_store = vim.loop.fs_realpath(actual_file) or vim.fn.fnamemodify(actual_file, ":p")
          M.file_prefixes[locale][abs_store] = actual_prefix
          table.insert(M._translation_files, abs_store)
          for k, v in pairs(data) do
            local final_key = actual_prefix .. k
            M.translations[locale][final_key] = v
            local line = line_map and line_map[k] or 1
            local abs_path = vim.loop.fs_realpath(actual_file) or vim.fn.fnamemodify(actual_file, ":p")
            M.meta[locale][final_key] = { file = abs_path, line = line, col = (col_map and col_map[k]) or 1 }
          end
        end
      end
    end)
  else
    -- 直接加载文件
    if utils.file_exists(filepath) then
      local data, line_map, col_map = parse_file(filepath)
      if data then
        M.translations[locale] = M.translations[locale] or {}
        M.meta[locale] = M.meta[locale] or {}
        M.file_prefixes[locale] = M.file_prefixes[locale] or {}
        local abs_store = vim.loop.fs_realpath(filepath) or vim.fn.fnamemodify(filepath, ":p")
        M.file_prefixes[locale][abs_store] = prefix
        table.insert(M._translation_files, abs_store)
        for k, v in pairs(data) do
          local final_key = prefix .. k
          M.translations[locale][final_key] = v
          local line = line_map and line_map[k] or 1
          local abs_path = vim.loop.fs_realpath(filepath) or vim.fn.fnamemodify(filepath, ":p")
          M.meta[locale][final_key] = { file = abs_path, line = line, col = (col_map and col_map[k]) or 1 }
        end
      end
    end
  end
end

-- 加载所有翻译文件
M.load_translations = function()
  M.translations = {}
  M._translation_files = {}
  local options = config.options

  for _, locale in ipairs(options.locales) do
    local sources = options.sources or {}
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
      load_file_config(source, locale)
    end
  end

  -- 汇总所有 key (合并所有语言)
  local set = {}
  for _, translations in pairs(M.translations) do
    for k, _ in pairs(translations) do
      set[k] = true
    end
  end
  M.all_keys = {}
  for k, _ in pairs(set) do
    table.insert(M.all_keys, k)
  end
  table.sort(M.all_keys)

  -- 注册文件监控
  M._setup_file_watchers()
end

-- 获取特定语言的翻译
M.get_translation = function(key, locale)
  local locales = config.options.locales
  locale = locale or (locales and locales[1])
  if M.translations[locale] and M.translations[locale][key] then
    return M.translations[locale][key]
  end
  return nil
end

-- 获取所有语言的翻译
M.get_all_translations = function(key)
  local result = {}
  for locale, translations in pairs(M.translations) do
    if translations[key] then
      result[locale] = translations[key]
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
  end

  -- 更新 all_keys（保持简单，重新聚合）
  local set = {}
  for _, translations in pairs(M.translations) do
    for k, _ in pairs(translations) do
      set[k] = true
    end
  end
  M.all_keys = {}
  for k, _ in pairs(set) do
    table.insert(M.all_keys, k)
  end
  table.sort(M.all_keys)

  return true
end

return M
