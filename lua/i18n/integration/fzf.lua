-- 集成 fzf-lua 查询 i18n key (修复版本)
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
  -- 先按长度，再在长度相同条件下按字母序
  table.sort(key_list, function(a, b)
    if #a == #b then
      return a < b
    end
    return #a < #b
  end)

  -- 获取所有语言
  local locales = require("i18n.config").options.locales or {}

  -- 计算等宽的列宽
  local col_count = 1 + #locales
  local total_columns = vim.o.columns or 120
  local separator_width = (col_count - 1) * 3 -- " │ " 分隔符总宽度
  local padding = 4                           -- 左右边距
  local available_width = total_columns - separator_width - padding

  -- 所有列等宽分配
  local col_width = math.floor(available_width / col_count)

  -- 设置最小和最大列宽限制
  local min_col_width = 15 -- 最小列宽，确保能显示基本内容
  local max_col_width = 40 -- 最大列宽，避免单列过宽

  -- 应用限制
  col_width = math.max(col_width, min_col_width)
  col_width = math.min(col_width, max_col_width)

  -- 创建列宽数组（所有列等宽）
  local col_widths = {}
  for i = 1, col_count do
    col_widths[i] = col_width
  end

  -- 构造显示列表
  local display_list = {}
  -- 行索引 -> 完整 key 的映射，保证复制时能得到未截断 key
  local index_to_key = {}

  -- 构造数据行
  for index, key in ipairs(key_list) do
    local original_key = type(key) == "string" and key or tostring(key or "")

    -- 保存索引到 key 的映射
    index_to_key[index] = original_key

    -- 构建显示行
    local display_key = truncate_text(original_key, col_widths[1])
    local row = { pad_right(display_key, col_widths[1]) }

    for i, locale in ipairs(locales) do
      local value = ""
      local locale_data = translations[locale]
      if locale_data and type(locale_data) == 'table' and locale_data[key] ~= nil then
        value = locale_data[key]
      end
      value = type(value) == "string" and value or tostring(value or "")

      local truncated_value = truncate_text(value, col_widths[i + 1])
      table.insert(row, pad_right(truncated_value, col_widths[i + 1]))
    end

    local display_line = table.concat(row, " │ ")
    table.insert(display_list, display_line)
  end

  -- 构造固定的表头（高亮当前默认语言）
  local display_ok, display_mod = pcall(require, "i18n.display")
  local current_locale = nil
  if display_ok and type(display_mod.get_current_locale) == "function" then
    current_locale = display_mod.get_current_locale()
  end
  if not current_locale then
    current_locale = locales[1]
  end

  local HL_START = "\27[7m" -- 反转视频 standout，高亮当前默认语言
  local HL_END = "\27[0m"

  local header_row = { pad_right("Key", col_widths[1]) }
  for i, locale in ipairs(locales) do
    local cell = pad_right(locale, col_widths[i + 1])
    if locale == current_locale then
      cell = HL_START .. cell .. HL_END
    end
    table.insert(header_row, cell)
  end
  local header = table.concat(header_row, " │ ")

  -- 构造分隔线
  local separator_parts = {}
  for i = 1, #col_widths do
    table.insert(separator_parts, string.rep("─", col_widths[i]))
  end
  local separator = table.concat(separator_parts, "─┼─")

  -- 使用 fzf_exec 直接传递显示列表
  fzf.fzf_exec(display_list, {
    prompt = "I18n Key > ",
    header = header .. "\n" .. separator,
    header_lines = 2,
    actions = {
      ["default"] = function(selected)
        if selected and selected[1] then
          -- 通过行内容找到对应的索引
          local selected_line = selected[1]
          for index, display_line in ipairs(display_list) do
            if display_line == selected_line then
              local key = index_to_key[index]
              if key then
                -- vim.notify("选中 key: " .. key)
                vim.fn.setreg('+', key)
              end
              break
            end
          end
        end
      end,
      ["ctrl-c"] = function(selected)
        if selected and selected[1] then
          -- 通过行内容找到对应的索引
          local selected_line = selected[1]
          for index, display_line in ipairs(display_list) do
            if display_line == selected_line then
              local key = index_to_key[index]
              if key then
                vim.fn.setreg('+', key)
                -- vim.notify("已复制 key 到剪贴板: " .. key)
              end
              break
            end
          end
        end
      end,
    },
    fzf_opts = {
      ["--no-multi"] = "",
      ["--no-sort"] = "", -- 保持预排序
      ["--layout"] = "reverse",
      ["--info"] = "inline",
      ["--border"] = "rounded",
      ["--ansi"] = "",     -- 启用 ANSI 颜色代码支持
      ["--tabstop"] = "1", -- 设置 tab 宽度为 1，避免对齐问题
    },
    winopts = {
      width = 0.9,  -- 窗口宽度占屏幕 90%
      height = 0.8, -- 窗口高度占屏幕 80%
      row = 0.5,    -- 垂直居中
      col = 0.5,    -- 水平居中
    },
  })
end

-- 可选：添加一个配置函数，允许用户自定义列宽策略
function M.setup(opts)
  opts = opts or {}
  if opts.column_width_strategy then
    -- 可以在这里添加其他列宽策略的支持
    -- 例如: "equal", "adaptive", "custom"
  end
end

return M
