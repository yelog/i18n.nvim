local async = require "blink.cmp.lib.async"

local config
local i18n_items

---Include the trigger character when accepting a completion.
---@param context blink.cmp.Context
local function transform(items, context)
  return vim.tbl_map(function(entry)
    return vim.tbl_deep_extend("force", entry, {
      kind = require("blink.cmp.types").CompletionItemKind.Keyword,
      textEdit = {
        range = {
          start = {
            line = context.cursor[1] - 1,
            character = context.bounds.start_col - 1,
          },
          ["end"] = {
            line = context.cursor[1] - 1,
            character = context.cursor[2],
          },
        },
      },
    })
  end, items)
end

---@param value string|string[]|fun():string[]
---@return fun():string[]
local function as_func(value)
  local ret

  if type(value) == "string" then
    return function()
      return { value }
    end
  elseif type(value) == "table" then
    return function()
      return value
    end
  elseif type(value) == "function" then
    return value --[[@as fun(self: blink.cmp.Source)]]
  end

  return function()
    return {}
  end
end

local function keyword_pattern(line, trigger_characters)
  -- Pattern is taken from `cmp-emoji` for similar trigger behavior.
  for _, c in ipairs(trigger_characters) do
    local pattern = [=[\%([[:space:]"'`]\|^\)\zs]=]
        .. c
        .. [=[[[:alnum:]_\-\+]*]=]
        .. c
        .. [=[\?]=]
        .. "$"
    if vim.regex(pattern):match_str(line) then
      return true
    end
  end
  return false
end

---@type blink.cmp.Source
local M = {}

function M.new(opts)
  local self = setmetatable({}, { __index = M })
  config = vim.tbl_deep_extend("keep", opts or {}, {
    insert = true,
    trigger = function()
      -- 使用单字符触发，引号输入后再由 should_show_completion_items 精确判断上下文
      return { "'", '"' }
    end,
  })
  self.get_trigger_characters = as_func(config.trigger)
  if not i18n_items then
    -- 增加对 parser.translations 的 nil 检查 (使用 pcall 避免 require 失败导致循环加载错误)
    local translations = {}
    local ok_parser, parser_mod = pcall(require, "i18n.parser")
    if ok_parser and type(parser_mod) == "table" then
      translations = parser_mod.translations or {}
    end
    local keys_map = {}
    for _, locale_tbl in pairs(translations) do
      for k, _ in pairs(locale_tbl) do
        keys_map[k] = true
      end
    end

    local key_list = {}
    for k, _ in pairs(keys_map) do
      table.insert(key_list, k)
    end

    -- 排序 key 列表
    table.sort(key_list, function(a, b)
      return #a < #b
    end)

    -- 获取所有语言
    local locales = require("i18n.config").options.locales or {}

    i18n_items = {}
    for _, k in ipairs(key_list) do
      local default_val = nil
      if #locales > 0 and translations[locales[1]] then
        default_val = translations[locales[1]][k]
      end
      if type(default_val) == "table" then
        local ok, json = pcall(vim.json.encode, default_val)
        if ok then
          default_val = json
        else
          default_val = vim.inspect(default_val)
        end
      end
      i18n_items[#i18n_items + 1] = {
        label = k,
        insertText = k,
        textEdit = { newText = k },
        -- detail 作为右侧预览面板标题，改为展示 key 本身
        detail = k,
        -- documentation 在 resolve 时再构建，避免初始构建过慢
      }
    end
  end
  return self
end

-- 更重要的是实现 should_show_completion_items 方法
function M:should_show_completion_items(ctx)
  local before = ctx.line:sub(1, ctx.cursor[2])

  -- 基于 config.func_pattern 动态判断是否位于首个参数未闭合的引号中
  local ok_cfg, plugin_cfg = pcall(require, "i18n.config")
  if not ok_cfg or not plugin_cfg.options then
    return false
  end
  local func_patterns = plugin_cfg.options.func_pattern
  if type(func_patterns) ~= "table" or vim.tbl_isempty(func_patterns) then
    return false
  end

  for _, pat in ipairs(func_patterns) do
    if type(pat) == "string" then
      -- 将末尾的参数捕获部分转换为“未闭合引号”检测，确保在首个参数内触发
      local detection, replaced = pat:gsub("(['\"])%b()%1$", "%1[^%1]*$")
      if replaced > 0 then
        local ok, matched = pcall(string.match, before, detection)
        if ok and matched then
          return true
        end
      end
    end
  end

  return false
end

---@param context blink.cmp.Context
function M:get_completions(context, callback)
  if not self:should_show_completion_items(context) then
    return callback()
  end

  local before = context.line:sub(1, context.cursor[2])
  local prefix = before:match("['\"]([^'\"]*)$")

  local items = i18n_items
  if prefix and prefix ~= "" then
    local filtered = {}
    for _, it in ipairs(i18n_items) do
      if it.label:find(prefix, 1, true) then
        table.insert(filtered, it)
      end
    end
    items = filtered
  end

  local task = async.task.empty():map(function()
    callback {
      is_incomplete_forward = false,
      is_incomplete_backward = false,
      items = transform(items, context),
      context = context,
    }
  end)
  return function()
    task:cancel()
  end
end

---`newText` is used for `ghost_text`, thus it is set to the emoji name in `emojis`.
---Change `newText` to the actual emoji when accepting a completion.
function M:resolve(item, callback)
  local resolved = vim.deepcopy(item)
  if config.insert then
    resolved.textEdit.newText = resolved.insertText
  end

  -- 构建多语言文档预览
  local ok_parser, parser = pcall(require, "i18n.parser")
  local ok_config, cfg = pcall(require, "i18n.config")
  if ok_parser and ok_config and cfg.options and cfg.options then
    local locales = cfg.options.locales or {}
    local trans_tbl = {}
    if parser.get_all_translations then
      trans_tbl = parser.get_all_translations(resolved.label) or {}
    elseif parser.translations then
      for _, locale in ipairs(locales) do
        local locale_tbl = parser.translations[locale] or {}
        if locale_tbl[resolved.label] then
          trans_tbl[locale] = locale_tbl[resolved.label]
        end
      end
    end
    local lines = {}
    for _, locale in ipairs(locales) do
      local v = trans_tbl[locale]
      if type(v) == "table" then
        local okj, json = pcall(vim.json.encode, v)
        if okj then
          v = json
        else
          v = vim.inspect(v)
        end
      end
      if v == nil then
        v = "(missing)"
      end
      lines[#lines + 1] = string.format("%s: %s", locale, v)
    end
    if #lines > 0 then
      resolved.documentation = table.concat(lines, "\n")
      if not resolved.detail and locales[1] then
        resolved.detail = trans_tbl[locales[1]] and tostring(trans_tbl[locales[1]]) or nil
      end
    end
  end

  return callback(resolved)
end

return M
