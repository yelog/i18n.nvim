-- 集成 fzf-lua 查询 i18n key (改进版本)
local parser = require("i18n.parser")
local fzf = require("fzf-lua")

local M = {}

-- 计算字符串显示宽度（处理中文字符）
local function display_width(str)
  -- 添加 nil 检查，防止 gmatch 在 nil 值上调用
  if not str or str == "" then
    return 0
  end

  local width = 0
  for char in str:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    if char:byte() > 127 then
      width = width + 2 -- 中文字符宽度为2
    else
      width = width + 1 -- 英文字符宽度为1
    end
  end
  return width
end

-- 右填充字符串到指定宽度
local function pad_right(str, width)
  -- 添加 nil 检查
  str = str or ""

  local current_width = display_width(str)
  if current_width >= width then
    return str
  end
  return str .. string.rep(" ", width - current_width)
end

-- 截断过长文本并添加省略号
local function truncate_text(text, max_width)
  -- 添加 nil 检查
  if not text or text == "" then
    return ""
  end

  if display_width(text) <= max_width then
    return text
  end

  local truncated = ""
  local width = 0
  for char in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    local char_width = char:byte() > 127 and 2 or 1
    if width + char_width > max_width - 3 then -- 留3个字符给省略号
      truncated = truncated .. "..."
      break
    end
    truncated = truncated .. char
    width = width + char_width
  end
  return truncated
end

function M.show_i18n_keys_with_fzf()
  -- 增加对 parser.translations 的 nil 检查
  local translations = parser.translations or {}
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
  local langs = require("i18n.config").options.static.langs or {}

  -- 平分列宽：Key 列与语言列平均分配宽度，并在过宽时截断显示
  local col_count = 1 + #langs
  local total_columns = vim.o.columns or 120
  local separator_w = (col_count - 1) * 3           -- " │ " 分隔符总宽度
  local available = total_columns - separator_w - 2 -- 预留边距
  if available < col_count * 10 then
    available = col_count * 10
  end
  local each_width = math.floor(available / col_count)
  if each_width > 50 then
    each_width = 50
  end
  local col_widths = {}
  for i = 1, col_count do
    col_widths[i] = each_width
  end

  -- 构造多列
  local display_list = {}
  -- 行 -> 完整 key 的映射，保证复制时能得到未截断 key
  local display_to_key = {}

  -- 构造数据行（不包含表头）
  for _, key in ipairs(key_list) do
    local original_key = type(key) == "string" and key or tostring(key or "")
    local display_key = truncate_text(original_key, col_widths[1])
    local row = { pad_right(display_key, col_widths[1]) }

    for i, lang in ipairs(langs) do
      local value = ""
      local lang_data = translations[lang]
      if lang_data and type(lang_data) == 'table' and lang_data[key] ~= nil then
        value = lang_data[key]
      end
      value = type(value) == "string" and value or tostring(value or "")
      local truncated_value = truncate_text(value, col_widths[i + 1])
      table.insert(row, pad_right(truncated_value, col_widths[i + 1]))
    end
    local line = table.concat(row, " │ ")
    table.insert(display_list, line)
    display_to_key[line] = original_key
  end

  -- 构造固定的表头
  local header_row = { pad_right("Key", col_widths[1]) }
  for i, lang in ipairs(langs) do
    table.insert(header_row, pad_right(lang, col_widths[i + 1]))
  end
  local header = table.concat(header_row, " │ ")

  -- 构造分隔线
  local separator_parts = {}
  for i = 1, #col_widths do
    table.insert(separator_parts, string.rep("─", col_widths[i]))
  end
  local separator = table.concat(separator_parts, "─┼─")

  fzf.fzf_exec(display_list, {
    prompt = "I18n Key > ",
    header = header .. "\n" .. separator, -- 固定表头
    header_lines = 2,                     -- 固定表头行数
    actions = {
      ["default"] = function(selected)
        if selected and selected[1] then
          local line = selected[1]
          local key = display_to_key and display_to_key[line] or line:match("^([^│]+)"):gsub("%s+$", "")
          vim.notify("选中 key: " .. key)
          vim.fn.setreg('+', key)
        end
      end,
      ["ctrl-c"] = function(selected)
        if selected and selected[1] then
          local line = selected[1]
          local key = display_to_key and display_to_key[line] or line:match("^([^│]+)"):gsub("%s+$", "")
          vim.fn.setreg('+', key)
          vim.notify("已复制 key 到剪贴板: " .. key)
        end
      end,
    },
    fzf_opts = {
      ["--no-multi"] = "",
      ["--no-sort"] = "", -- 保持预排序（按 key 长度）在过滤后依旧有效
      ["--layout"] = "reverse",
      ["--info"] = "inline",
      ["--border"] = "rounded",
    }
  })
end

return M
