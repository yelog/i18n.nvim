local parser = require('i18n.parser')
local utils = require('i18n.utils')
local config = require('i18n.config')

local M = {
  name = 'i18n',
}

function M:get_keyword_pattern()
  return "[%w%._-]*"
end

local function in_context(line, col)
  local before = line:sub(1, col)
  if before:match("t%(['\"]([%w%._-]*)$") or before:match("%$t%(['\"]([%w%._-]*)$") then
    return true
  end
  return false
end

local function current_part(line, col)
  local before = line:sub(1, col)
  local part = before:match("t%(['\"]([%w%._-]*)$")
  if not part then
    part = before:match("%$t%(['\"]([%w%._-]*)$")
  end
  return part
end

function M:should_complete(ctx)
  return in_context(ctx.line, ctx.col)
end

function M:get_completions(ctx)
  local part = current_part(ctx.line, ctx.col) or ""
  local keys = parser.get_all_keys()
  local opts = config.options.completion or {}
  local filtered = utils.fuzzy_filter(keys, part, opts.max_items or 15)
  local items = {}
  for _, key in ipairs(filtered) do
    table.insert(items, {
      label = key,
      insert_text = key,
      kind = 1, -- Text
    })
  end
  return {
    is_incomplete = true,
    items = items,
  }
end

return M
