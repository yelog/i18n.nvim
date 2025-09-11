-- nvim-cmp source for i18n keys
-- Reuses parsed translation data (parser.translations) to offer keys.
-- Context-aware: only triggers when cursor is in first string arg of an i18n call
-- as defined by config.options.func_pattern.
--
-- Exposed via: require('i18n.integration.cmp_source').new()

local parser_ok, parser = pcall(require, "i18n.parser")
local config_ok, config = pcall(require, "i18n.config")

local source = {}
source.__index = source

-- Collect all keys from in-memory translations
local function collect_keys()
  if not parser_ok or not parser or not parser.translations then
    return {}
  end
  local map = {}
  for _, locale_tbl in pairs(parser.translations) do
    for k, _ in pairs(locale_tbl) do
      map[k] = true
    end
  end
  local list = {}
  for k in pairs(map) do
    table.insert(list, k)
  end
  table.sort(list)
  return list
end

-- Determine if cursor is currently in a context where completion should trigger
local function in_i18n_context(line, byte_col)
  if not config_ok then return false end
  local opts = config.options or config.defaults or {}
  local pats = opts.func_pattern
  -- byte_col 可能是 0 / 1 基，双策略
  local before_a = line:sub(1, byte_col)
  local before_b = line:sub(1, byte_col + 1)

  local function match_patterns(before)
    if type(pats) ~= "table" then return false end
    for _, pat in ipairs(pats) do
      if type(pat) == "string" then
        local pos = pat:find("%(", 1, true)
        if pos then
          local prefix = pat:sub(1, pos - 1)
          local raw_prefix = prefix
            :gsub("%%(%W)", "%1")
            :gsub("%%%%", "%%")
            :gsub("%%f%[[^%]]+%]", "")
          local esc = vim.pesc(raw_prefix)
          local dyn = esc .. "%s*%(%s*['\"][^'\"]*$"
          if before:match(dyn) then
            return true
          end
        end
      end
    end
    return false
  end

  if match_patterns(before_a) or match_patterns(before_b) then
    return true
  end

  -- 兜底：常规形式
  local generic_forms = {
    "t%s*%(%s*['\"][^'\"]*$",
    "%$t%s*%(%s*['\"][^'\"]*$",
    "[%.:]t%s*%(%s*['\"][^'\"]*$",
    "[%.:]%$t%s*%(%s*['\"][^'\"]*$",
  }
  for _, f in ipairs(generic_forms) do
    if before_a:match(f) or before_b:match(f) then
      return true
    end
  end

  -- 更强力回溯：向后找最近的未闭合引号，并判断其前 40 个字符里是否存在 t( / $t(
  local scan = before_b
  local qpos = scan:reverse():find("['\"]")
  if qpos then
    local abs_q = #scan - qpos + 1
    local prefix_zone_start = math.max(1, abs_q - 40)
    local zone = scan:sub(prefix_zone_start, abs_q)
    if zone:match("t%s*%(%s*['\"]$") or zone:match("%$t%s*%(%s*['\"]$") then
      return true
    end
  end

  return false
end

-- Factory
function source.new()
  return setmetatable({
    _cache = nil,
    _cache_len = 0,
  }, source)
end

-- Always available (context filtering is done in complete)
function source:is_available()
  return parser_ok == true
end

-- Allow word chars, dot, dash, underscore (cmp uses this to find boundaries)
function source:get_keyword_pattern()
  return "[%w%._%-]*"
end

-- Optional trigger characters (improve responsiveness after typing a dot)
function source:get_trigger_characters()
  -- 增加引号触发，使得输入 t(' 立即弹出补全，而无需再输入首字符
  return { ".", "_", "'", '"' }
end

-- Perform completion
function source:complete(params, callback)
  if not parser_ok then
    return callback({})
  end

  local line = params.context.cursor_line or params.context.line or ""
  local col = params.context.cursor.col or params.context.cursor[2] or 0

  -- 进入字符串第一字符时（quote 后光标立即触发）可能没有匹配到模式，放宽一次检测：
  local relaxed_ok = in_i18n_context(line, col)
  if not relaxed_ok then
    -- 如果上一字符是引号，且前面 80 字符存在 t( / $t( 结构，则放行
    local prev_char = line:sub(col, col)
    if prev_char == "'" or prev_char == '"' then
      local zone_start = math.max(1, col - 80)
      local zone = line:sub(zone_start, col)
      if zone:match("t%s*%(") or zone:match("%$t%s*%(") then
        relaxed_ok = true
      end
    end
  end
  if not relaxed_ok then
    return callback({})
  end

  -- 惰性加载：若用户尚未调用 setup，则使用 defaults 补上 locales 防止 load_translations 崩溃
  if (not parser.translations) or vim.tbl_isempty(parser.translations) then
    if config_ok then
      if (not config.options) or (not config.options.locales) then
        config.options = vim.tbl_deep_extend("force", {}, config.defaults or {}, config.options or {})
      end
      pcall(function()
        if parser.load_translations then
          parser.load_translations()
        end
      end)
    end
  end

  -- 构建 / 刷新 key 缓存
  local keys = {}
  if parser.get_all_keys then
    local ok_keys, res = pcall(parser.get_all_keys)
    if ok_keys and type(res) == "table" then
      keys = res
    end
  end
  if #keys == 0 then
    keys = collect_keys()
  end

  if (not self._cache) or (#keys ~= self._cache_len) then
    self._cache = keys
    self._cache_len = #keys
  end

  local items = {}
  for _, k in ipairs(self._cache) do
    items[#items + 1] = {
      label = k,
      insertText = k,
      filterText = k,
      sortText = k,
      data = { key = k },
      kind = 1,
    }
  end

  callback(items)
end

-- Provide documentation with all locale translations
function source:resolve(completion_item, callback)
  if not parser_ok or not config_ok then
    return callback(completion_item)
  end
  local key = (completion_item.data and completion_item.data.key) or completion_item.label
  local locales = (config.options and config.options.locales) or {}
  local trans = {}
  if parser.get_all_translations then
    trans = parser.get_all_translations(key) or {}
  else
    for _, loc in ipairs(locales) do
      local lt = parser.translations[loc]
      if lt and lt[key] ~= nil then
        trans[loc] = lt[key]
      end
    end
  end

  local lines = {}
  for _, loc in ipairs(locales) do
    local v = trans[loc]
    if type(v) == "table" then
      local okj, json = pcall(vim.json.encode, v)
      v = okj and json or vim.inspect(v)
    end
    if v == nil then
      v = "(missing)"
    end
    lines[#lines + 1] = string.format("%s: %s", loc, v)
  end

  if #lines > 0 then
    completion_item.documentation = {
      kind = "markdown",
      value = "```text\n" .. table.concat(lines, "\n") .. "\n```",
    }
  end
  callback(completion_item)
end

-- No special execute behavior
function source:execute(completion_item, callback)
  callback(completion_item)
end

return {
  new = source.new
}
