local M = {}
local config = require('i18n.config')
local utils = require('i18n.utils')

-- 解析 JSON 文件
local function parse_json(content)
  local ok, result = pcall(vim.json.decode, content)
  if ok then
    return result
  end
  return nil
end

-- 解析 YAML 文件
local function parse_yaml(content)
  -- 简单的 YAML 解析，实际使用可能需要更复杂的解析器
  local result = {}
  for line in content:gmatch("[^\r\n]+") do
    local key, value = line:match("^%s*([%w%.]+):%s*(.+)%s*$")
    if key and value then
      -- 移除引号
      value = value:gsub("^['\"]", ""):gsub("['\"]$", "")
      result[key] = value
    end
  end
  return result
end

-- 解析 JS/TS 文件（使用 treesitter 支持递归任意深度）
local function parse_js(content)
  local ts = vim.treesitter
  local parser = nil
  local lang = nil

  -- 自动判断语言类型
  if content:match("export%s+default") or content:match("module%.exports") then
    lang = "javascript"
  else
    lang = "typescript"
  end

  -- treesitter 解析
  local ok, tree = pcall(function()
    parser = ts.get_string_parser(content, lang)
    return parser:parse()[1]
  end)
  if not ok or not tree then
    return {}
  end

  local root = tree:root()
  local result = {}

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
          local kfirst = key:sub(1,1)
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
            local vfirst = value:sub(1,1)
            local vlast = value:sub(-1)
            if (vfirst == '"' or vfirst == "'" or vfirst == "`") and vlast == vfirst then
              value = value:sub(2, -2)
            end
          end

          result[prefix .. key] = value
        end
      end
    end
  end

  local obj_node = find_export_object(root)
  if obj_node then
    traverse_object(obj_node, "")
  end

  return result
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

-- 提取所有自定义变量（不包括 langs）
local function extract_vars(str)
  local vars = {}
  for var in str:gmatch("{([%w_]+)}") do
    if var ~= "langs" then
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
local function load_file_config(file_config, lang)
  local files_pattern = type(file_config) == "string" and file_config or file_config.files
  local prefix = type(file_config) == "table" and file_config.prefix or ""

  -- 替换 {langs} 占位符
  local filepath = files_pattern:gsub("{langs}", lang)
  local vars = extract_vars(filepath)
  if #vars > 0 then
    -- 存在自定义变量，递归扫描
    scan_vars(filepath, vars, 1, function(actual_file)
      -- prefix 也需要替换变量
      local actual_prefix = fill_prefix(actual_file, filepath, prefix)
      -- vim.notify("actual_file: " .. actual_file .. "\nfilepath: " .. filepath .. "\nactual_prefix: " .. actual_prefix)
      if utils.file_exists(actual_file) then
        local data = parse_file(actual_file)
        if data then
          M.translations[lang] = M.translations[lang] or {}
          deep_merge(M.translations[lang], data, actual_prefix)
        end
      end
    end)
  else
    -- 直接加载文件
    if utils.file_exists(filepath) then
      local data = parse_file(filepath)
      if data then
        M.translations[lang] = M.translations[lang] or {}
        deep_merge(M.translations[lang], data, prefix)
      end
    end
  end
end

-- 加载所有翻译文件
M.load_translations = function()
  M.translations = {}
  local static_config = config.options.static

  for _, lang in ipairs(static_config.langs) do
    for _, file_config in ipairs(static_config.files) do
      -- 判断 {module} 后面是文件后缀还是 /
      local files_pattern = type(file_config) == "string" and file_config or file_config.files
      local filepath = files_pattern:gsub("{langs}", lang)
      local ext = nil
      if filepath:match("{module}") then
        ext = filepath:match("{module}%.([%w_]+)")
        if ext then ext = "." .. ext end
      end
      load_file_config(file_config, lang)
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
end

-- 获取特定语言的翻译
M.get_translation = function(key, lang)
  local langs = config.options.static.langs
  lang = lang or (langs and langs[1])
  if M.translations[lang] and M.translations[lang][key] then
    return M.translations[lang][key]
  end
  return nil
end

-- 获取所有语言的翻译
M.get_all_translations = function(key)
  local result = {}
  for lang, translations in pairs(M.translations) do
    if translations[key] then
      result[lang] = translations[key]
    end
  end
  return result
end

M.get_all_keys = function()
  if not M.all_keys then return {} end
  return M.all_keys
end

return M
