local M = {}
local config = require('i18n.config')
local utils = require('i18n.utils')

-- 存储所有翻译内容
M.translations = {}

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
  local result = {}
  -- 匹配 export default { ... } 或 module.exports = { ... }
  local obj_content = content:match("export%s+default%s*{(.-)}")
      or content:match("module%.exports%s*=%s*{(.-)}")
      or content:match("export%s*{(.-)}")

  if obj_content then
    -- 简单解析对象内容
    for key, value in obj_content:gmatch('["\']*([%w%.]+)["\']*%s*:%s*["\']([^"\']+)["\']') do
      result[key] = value
    end
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
local function deep_merge(t1, t2, prefix)
  prefix = prefix or ""
  for k, v in pairs(t2 or {}) do
    local full_key = prefix == "" and k or (prefix .. k)
    if type(v) == "table" then
      t1[full_key] = t1[full_key] or {}
      deep_merge(t1, v, full_key .. ".")
    else
      t1[full_key] = v
    end
  end
end

-- 加载单个文件配置
local function load_file_config(file_config, lang)
  local files_pattern = type(file_config) == "string" and file_config or file_config.files
  local prefix = type(file_config) == "table" and file_config.prefix or ""

  -- 替换 {langs} 占位符
  local filepath = files_pattern:gsub("{langs}", lang)

  -- 如果有 {module} 占位符，需要扫描目录
  if filepath:match("{module}") then
    local pattern = filepath:gsub("{module}", "([^/]+)")
    local dir = filepath:match("^(.-)/[^/]*{module}")

    if dir and utils.file_exists(dir) then
      local modules = utils.scan_dir(dir)
      for _, module in ipairs(modules) do
        local actual_file = filepath:gsub("{module}", module)
        local actual_prefix = prefix:gsub("{module}", module)

        if utils.file_exists(actual_file) then
          local data = parse_file(actual_file)
          if data then
            M.translations[lang] = M.translations[lang] or {}
            deep_merge(M.translations[lang], data, actual_prefix)
          end
        end
      end
    end
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
      load_file_config(file_config, lang)
    end
  end
end

-- 获取翻
M.get_translation = function(key, lang)
  lang = lang or config.options.static.default_lang[1]
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
