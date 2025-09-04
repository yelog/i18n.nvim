local async = require "blink.cmp.lib.async"

local config
local i18n_items

---Include the trigger character when accepting a completion.
---@param context blink.cmp.Context
local function transform(items, context)
  return vim.tbl_map(function(entry)
    return vim.tbl_deep_extend("force", entry, {
      kind = require("blink.cmp.types").CompletionItemKind.Text,
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
      return { "t('", 't("' } -- 包含可能的触发字符
    end,
  })
  self.get_trigger_characters = as_func(config.trigger)
  if not i18n_items then
    -- 增加对 parser.translations 的 nil 检查
    local translations = require("i18n.parser").translations or {}
    local keys_map = {}
    for _, lang_tbl in pairs(translations) do
      for k, _ in pairs(lang_tbl) do
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
    -- local langs = require("i18n.config").options.static.langs or {}

    i18n_items = {}
    for _, k in ipairs(key_list) do
      table.insert(i18n_items, {
        label = k,
        insertText = k,
        textEdit = { newText = k },
      })
    end
  end
  return self
end

-- 更重要的是实现 should_show_completion_items 方法
function M:should_show_completion_items(ctx)
  local line = ctx.line
  local col = ctx.cursor[2]

  -- 获取当前行到光标位置的文本
  local before_cursor = string.sub(line, 1, col)

  -- 检查是否在 $t('') 或 $t("") 的引号内
  local pattern1 = "%$t%s*%(%s*['\"]([^'\"]*)"                         -- 匹配 $t('xxx 或 $t("xxx
  local pattern2 = "%$t%s*%(%s*['\"][^'\"]*['\"]%s*,%s*['\"]([^'\"]*)" -- 匹配带参数的情况

  -- 检查是否匹配第一个参数的引号内
  local match1 = string.match(before_cursor, pattern1)
  if match1 then
    return true
  end

  -- 检查是否匹配第二个参数的引号内（如果有的话）
  local match2 = string.match(before_cursor, pattern2)
  if match2 then
    return true
  end

  return false
end

---@param context blink.cmp.Context
function M:get_completions(context, callback)
  local task = async.task.empty():map(function()
    local cursor_before_line = context.line:sub(1, context.cursor[2])
    -- if
    --     not keyword_pattern(cursor_before_line, self:get_trigger_characters())
    -- then
    --   callback()
    -- else
    callback {
      is_incomplete_forward = true,
      is_incomplete_backward = true,
      items = transform(i18n_items, context),
      context = context,
    }
    -- end
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
  return callback(resolved)
end

return M
