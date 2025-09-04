local M = {}
local config = require('i18n.config')
local parser = require('i18n.parser')

-- 命名空间
local ns = vim.api.nvim_create_namespace('i18n_display')

-- 当前显示语言索引（基于 config.langs）
M._current_lang_index = 1

-- 获取当前语言
M.get_current_lang = function()
  local langs = (config.options or {}).langs or {}
  if #langs == 0 then return nil end
  if not M._current_lang_index or M._current_lang_index > #langs then
    M._current_lang_index = 1
  end
  return langs[M._current_lang_index]
end

-- 切换到下一个语言
M.next_lang = function()
  local langs = (config.options or {}).langs or {}
  if #langs == 0 then
    vim.notify("[i18n] 未配置 langs", vim.log.levels.WARN)
    return
  end
  M._current_lang_index = (M._current_lang_index % #langs) + 1
  M.refresh()
end

-- 提取国际化键
local function extract_i18n_keys(line, patterns)
  local keys = {}
  local occupied = {}
  for _, pattern in ipairs(patterns) do
    local pos = 1
    while pos <= #line do
      local start_pos, end_pos, key = line:find(pattern, pos)
      if start_pos then
        -- 检查该区间是否已被其他 pattern 匹配
        local overlap = false
        for i = start_pos, end_pos do
          if occupied[i] then
            overlap = true
            break
          end
        end
        if not overlap then
          table.insert(keys, {
            key = key,
            start_pos = start_pos,
            end_pos = end_pos
          })
          for i = start_pos, end_pos do
            occupied[i] = true
          end
        end
        pos = end_pos + 1
      else
        break
      end
    end
  end
  return keys
end

-- 设置虚拟文本
local function set_virtual_text(bufnr, line_num, col, text)
  local prefix = ""
  if config.options.show_origin ~= false then
    prefix = ": "
  end
  vim.api.nvim_buf_set_extmark(bufnr, ns, line_num, col, {
    virt_text = { { prefix .. text, "Comment" } },
    virt_text_pos = "inline",
  })
end

-- 刷新缓冲区显示
M.refresh_buffer = function(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  -- 清除旧的虚拟文本
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

  local patterns = config.options.func_pattern
  local default_lang = M.get_current_lang()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  -- 获取当前窗口和光标行
  local current_win = vim.api.nvim_get_current_win()
  local cursor_line = nil
  if vim.api.nvim_win_get_buf(current_win) == bufnr then
    cursor_line = vim.api.nvim_win_get_cursor(current_win)[1]
  end

  -- 根据 show_origin 控制 conceallevel
  if config.options.show_origin == false then
    vim.api.nvim_buf_set_option(bufnr, 'conceallevel', 2)
  else
    vim.api.nvim_buf_set_option(bufnr, 'conceallevel', 0)
  end

  for line_num, line in ipairs(lines) do
    local keys = extract_i18n_keys(line, patterns)
    for _, key_info in ipairs(keys) do
      local translation = nil
      if config.options.show_translation then
        translation = parser.get_translation(key_info.key, default_lang)
        if translation then
          -- 如果当前行为光标所在行，则不显示虚拟文本
          if not cursor_line or line_num ~= cursor_line then
            set_virtual_text(bufnr, line_num - 1, key_info.end_pos, translation)
          end
        end
      end

      -- 只有找到译文并成功设置 virt_text 后，show_origin = false 才 conceal
      if translation and config.options.show_origin == false then
        -- 只隐藏 key 及其引号，不隐藏函数名和括号
        -- 重新用正则查找本行内 key 的引号包裹范围
        -- 例如 $t('common.save') 只隐藏 'common.save'
        local s, e, quote, key = line:find("(['\"])([^'\"]+)['\"]", key_info.start_pos)
        if s and e and key == key_info.key then
          vim.api.nvim_buf_set_extmark(bufnr, ns, line_num - 1, s - 1, {
            end_col = e,
            conceal = "",
          })
        end
      end
    end
  end
end

-- 显示弹窗
M.show_popup = function()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local line = vim.api.nvim_get_current_line()
  local patterns = config.options.func_pattern

  -- 提取当前行的国际化键
  local keys = extract_i18n_keys(line, patterns)

  -- 找到光标所在的键
  local current_key = nil
  for _, key_info in ipairs(keys) do
    if cursor[2] >= key_info.start_pos - 1 and cursor[2] <= key_info.end_pos then
      current_key = key_info.key
      break
    end
  end

  if not current_key then
    vim.notify("No i18n key found at cursor position", vim.log.levels.WARN)
    return
  end

  -- 获取所有翻译
  local translations = parser.get_all_translations(current_key)
  if vim.tbl_isempty(translations) then
    vim.notify("No translations found for: " .. current_key, vim.log.levels.WARN)
    return
  end

  -- 构建显示内容
  local lines = { "Translations for: " .. current_key, "" }
  for lang, text in pairs(translations) do
    table.insert(lines, string.format("%s: %s", lang, text))
  end

  -- 创建浮动窗口
  local width = 0
  for _, line in ipairs(lines) do
    width = math.max(width, #line)
  end

  local height = #lines
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  local opts = {
    relative = 'cursor',
    width = width + 4,
    height = height,
    col = 0,
    row = 1,
    style = 'minimal',
    border = 'rounded'
  }

  local win = vim.api.nvim_open_win(buf, false, opts)

  -- 设置高亮
  vim.api.nvim_buf_add_highlight(buf, -1, 'Title', 0, 0, -1)

  -- 自动关闭
  vim.defer_fn(function()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end, 3000)

  -- ESC 关闭
  vim.api.nvim_buf_set_keymap(buf, 'n', '<Esc>', ':close<CR>', { noremap = true, silent = true })
end

-- 设置替换模式
M.setup_replace_mode = function()
  -- 自动命令组
  local group = vim.api.nvim_create_augroup('I18nDisplay', { clear = true })

  -- 文件打开时刷新
  vim.api.nvim_create_autocmd({ 'BufEnter', 'BufWritePost' }, {
    group = group,
    pattern = { '*.vue', '*.js', '*.jsx', '*.ts', '*.tsx' },
    callback = function(args)
      M.refresh_buffer(args.buf)
    end
  })

  -- 文本改变时刷新
  vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
    group = group,
    pattern = { '*.vue', '*.js', '*.jsx', '*.ts', '*.tsx' },
    callback = function(args)
      vim.defer_fn(function()
        M.refresh_buffer(args.buf)
      end, 100)
    end
  })

  -- 光标移动时刷新（用于隐藏/显示当前行虚拟文本）
  vim.api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI' }, {
    group = group,
    pattern = { '*.vue', '*.js', '*.jsx', '*.ts', '*.tsx' },
    callback = function(args)
      M.refresh_buffer(args.buf)
    end
  })
end

-- 设置弹窗模式
M.setup_popup_mode = function()
  -- 设置快捷键
  vim.keymap.set('n', '<leader>it', M.show_popup, { desc = 'Show i18n translations' })
end

-- 刷新所有缓冲区
M.refresh = function()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      M.refresh_buffer(bufnr)
    end
  end
end

-- 定义切换语言命令（只注册一次）
if not vim.g._i18n_next_lang_command_defined then
  vim.api.nvim_create_user_command("I18nNextLang", function()
    require('i18n.display').next_lang()
  end, { desc = "循环切换 i18n 显示语言" })
  vim.g._i18n_next_lang_command_defined = true
end

return M
