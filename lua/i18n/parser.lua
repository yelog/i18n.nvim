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

-- 解析 JS/TS 文件
local function parse_js(content)
  -- 递归解析对象字符串为扁平化 key-value
  local function parse_object(str, prefix, tbl)
    tbl = tbl or {}
    prefix = prefix or ""
    -- 匹配 key: value 或 key: { ... }
    for key, value in str:gmatch('([%w_]+)%s*:%s*([^\n,{}]+)') do
      -- 去除首尾空格和引号
      key = key:gsub("^['\"]", ""):gsub("['\"]$", "")
      value = value:gsub("^%s*", ""):gsub("%s*$", "")
      if value:match("^{") then
        -- 嵌套对象，递归
        local nested = value:match("^{(.*)}$")
        if nested then
          parse_object(nested, prefix .. key .. ".", tbl)
        end
      else
        value = value:gsub("^['\"]", ""):gsub("['\"]$", "")
        tbl[prefix .. key] = value
      end
    end
    -- 递归处理嵌套对象
    for obj_key, obj_body in str:gmatch('([%w_]+)%s*:%s*{(.-)}') do
      obj_key = obj_key:gsub("^['\"]", ""):gsub("['\"]$", "")
      parse_object(obj_body, prefix .. obj_key .. ".", tbl)
    end
    return tbl
  end

  -- 匹配 export default { ... } 或 module.exports = { ... }
  local obj_content = content:match("export%s+default%s*{(.*)}%s*;?%s*$")
      or content:match("module%.exports%s*=%s*{(.*)}%s*;?%s*$")
      or content:match("export%s*{(.*)}%s*;?%s*$")

  if obj_content then
    -- 递归解析所有 key
    local result = parse_object(obj_content)
    -- 去除末尾的点
    local clean_result = {}
    for k, v in pairs(result) do
      local clean_key = k:gsub("%.$", "")
      clean_result[clean_key] = v
    end
    return clean_result
  end
  return {}
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
local function deep_merge(t1, t2, prefix)
  prefix = prefix or ""
  for k, v in pairs(t2 or {}) do
    local full_key = prefix == "" and k or (prefix .. k)
    if type(v) == "table" then
      t1[full_key] = t1[full_key] or {}
      deep_merge(t1, v, full_key .. ".")
    else
      -- vim.notify("Merging key: " .. full_key .. " with value: " .. tostring(v))
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

return M
