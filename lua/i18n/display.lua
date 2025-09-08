local M = {}
local config = require('i18n.config')
local parser = require('i18n.parser')

-- 命名空间
local ns = vim.api.nvim_create_namespace('i18n_display')
local diag_ns = vim.api.nvim_create_namespace('i18n_display_diag')
local keypos_ns = vim.api.nvim_create_namespace('i18n_keypos')

-- 最近一次弹窗窗口与缓冲区
M._popup_win = nil
M._popup_buf = nil

-- 当前显示语言索引（基于 config.locales）
M._current_locale_index = 1

-- 获取当前语言
M.get_current_locale = function()
  local locales = (config.options or {}).locales or {}
  if #locales == 0 then return nil end
  if not M._current_locale_index or M._current_locale_index > #locales then
    M._current_locale_index = 1
  end
  return locales[M._current_locale_index]
end

-- 切换到下一个语言
M.next_locale = function()
  local locales = (config.options or {}).locales or {}
  if #locales == 0 then
    vim.notify("[i18n] 未配置 locales", vim.log.levels.WARN)
    return
  end
  M._current_locale_index = (M._current_locale_index % #locales) + 1
  M.refresh()
end

-- 判断文件类型是否需要处理（动态适配插件使用者在插件管理器里设置的 ft）
local function is_supported_ft(bufnr)
  bufnr = bufnr or 0
  local ft = vim.bo[bufnr].filetype
  local opts = config.options or {}
  -- 允许用户通过 options.filetypes 或 options.ft 传入
  local fts = opts.filetypes or opts.ft
  if type(fts) == 'table' and #fts > 0 then
    for _, v in ipairs(fts) do
      if v == ft then return true end
    end
    return false
  end
  -- 默认支持的文件类型集合（未显式配置时）
  local default = {
    vue = true,
    javascript = true,
    typescript = true,
    typescriptreact = true,
    javascriptreact = true,
    tsx = true,
    jsx = true,
    java = true,
    json = true,
    jproperties = true,
    yaml = true,
  }
  return default[ft] == true
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
          -- 进一步精确出只包含引号内部 key 的起止位置，便于诊断高亮更精准
          local match_str = line:sub(start_pos, end_pos)
          local rel_s, rel_e = match_str:find(key, 1, true)
          local key_start_pos = start_pos
          local key_end_pos = end_pos
          if rel_s and rel_e then
            key_start_pos = start_pos + rel_s - 1
            key_end_pos = start_pos + rel_e - 1
          end
          table.insert(keys, {
            key = key,
            start_pos = start_pos,         -- 整个匹配开始
            end_pos = end_pos,             -- 整个匹配结束
            key_start_pos = key_start_pos, -- 仅 key（不含引号等）
            key_end_pos = key_end_pos,
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

-- 在翻译文件中行尾显示（默认语言）翻译
local function set_eol_virtual_text(bufnr, line_num, text)
  if not text or text == "" then return end
  vim.api.nvim_buf_set_extmark(bufnr, ns, line_num, 0, {
    virt_text = { { " ← " .. text, "Comment" } },
    virt_text_pos = "eol",
  })
end

-- 刷新缓冲区显示
M.refresh_buffer = function(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  -- 提前判定是否为翻译文件：即属于任一 locale 的已解析文件
  local buf_path = vim.api.nvim_buf_get_name(bufnr)
  local abs_path = vim.loop.fs_realpath(buf_path) or buf_path

  local file_locale = nil
  for _, loc in ipairs((config.options or {}).locales or {}) do
    local fp = parser.file_prefixes[loc]
    if fp then
      -- 先直接匹配绝对路径
      if fp[abs_path] then
        file_locale = loc
        break
      end
      -- 回退：尝试把已存路径 realpath 后比较（兼容旧数据未存绝对路径的情况）
      for stored_path, _ in pairs(fp) do
        local stored_abs = vim.loop.fs_realpath(stored_path) or vim.fn.fnamemodify(stored_path, ":p")
        if stored_abs == abs_path then
          file_locale = loc
          break
        end
      end
      if file_locale then break end
    end
  end

  -- 若不是支持的代码文件且也不是翻译文件，则直接返回
  if (not is_supported_ft(bufnr)) and (not file_locale) then
    return
  end

  -- 对代码文件立即清除虚拟文本；翻译文件延后到成功解析后再清除
  -- 这样在翻译文件内尚未完成输入（JSON 不合法 / 临时语法错误）时不至于出现错行或闪烁
  local cleared = false
  if not file_locale then
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
    cleared = true
  end
  -- 诊断配置处理
  local diag_opt = (config.options or {}).diagnostic
  local diag_enabled = diag_opt ~= false
  if vim.diagnostic then
    vim.diagnostic.reset(diag_ns, bufnr)
  end

  local patterns = config.options.func_pattern
  local default_locale = M.get_current_locale()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local diagnostics = {}

  -- 若是翻译文件：增量解析（未保存插入/删除行后行号立即同步），然后行尾展示当前显示语言翻译
  if file_locale then
    local changedtick = vim.api.nvim_buf_get_changedtick(bufnr)
    local last_tick = nil
    local ok_last = pcall(function()
      last_tick = vim.api.nvim_buf_get_var(bufnr, 'i18n_last_parsed_tick')
    end)
    if not ok_last then last_tick = nil end
    local parse_success = true
    if last_tick ~= changedtick then
      local ok_reload, parser_mod = pcall(require, 'i18n.parser')
      if ok_reload and parser_mod.reload_translation_buffer then
        local ok_ret, ret = pcall(parser_mod.reload_translation_buffer, abs_path, file_locale, bufnr)
        if ok_ret then
          parse_success = ret ~= false
        else
          parse_success = false
        end
      end
      pcall(vim.api.nvim_buf_set_var, bufnr, 'i18n_last_parsed_tick', changedtick)
    end

    -- 如果解析失败（例如 JSON 尚未完成输入），清空旧的行尾翻译以避免错位，然后返回
    if not parse_success then
      if not cleared then
        vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
        cleared = true
      end
      return
    end

    local meta_tbl = parser.meta[file_locale] or {}

    -- 先基于已存在的 key 位置 extmark（若有）更新行号，确保插入 / 删除行后不漂移
    for full_key, meta in pairs(meta_tbl) do
      if meta.file == abs_path then
        if meta.mark_id then
          local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, keypos_ns, meta.mark_id, {})
          if pos and pos[1] then
            meta.line = pos[1] + 1
            meta.col = (pos[2] or 0) + 1
          end
        else
          -- 为没有 mark 的条目建立位置跟踪 extmark
          local lnum = (meta.line or 1) - 1
          local col = (meta.col or 1) - 1
          local id = vim.api.nvim_buf_set_extmark(bufnr, keypos_ns, lnum, col, {})
          meta.mark_id = id
        end
      end
    end

    -- 成功解析后再清除旧的虚拟文本（仅清除展示 namespace，不动 keypos_ns）
    if not cleared then
      vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
      cleared = true
    end

    for full_key, meta in pairs(meta_tbl) do
      if meta.file == abs_path then
        local value = parser.get_translation(full_key, default_locale)
        if value then
          set_eol_virtual_text(bufnr, (meta.line or 1) - 1, value)
        end
      end
    end
    return
  end

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
    -- vim.notify("keys: " .. vim.inspect(keys), vim.log.levels.DEBUG)
    for _, key_info in ipairs(keys) do
      local translation = parser.get_translation(key_info.key, default_locale)

      if translation and config.options.show_translation then
        -- 如果当前行为光标所在行，则不显示虚拟文本
        if not cursor_line or line_num ~= cursor_line then
          set_virtual_text(bufnr, line_num - 1, key_info.end_pos, translation)
        end
      end

      if diag_enabled and not translation then
        table.insert(diagnostics, {
          lnum = line_num - 1,
          col = (key_info.key_start_pos or key_info.start_pos) - 1,
          end_col = key_info.key_end_pos or key_info.end_pos,
          severity = type(diag_opt) == "table" and diag_opt.severity or
              (vim.diagnostic and vim.diagnostic.severity.WARN) or 1,
          source = "i18n",
          message = string.format("缺少翻译: %s (%s)", key_info.key, default_locale or "default"),
        })
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
  if vim.diagnostic then
    if diag_enabled then
      if diagnostics and #diagnostics > 0 then
        if type(diag_opt) == "table" then
          vim.diagnostic.set(diag_ns, bufnr, diagnostics, diag_opt)
        else
          vim.diagnostic.set(diag_ns, bufnr, diagnostics)
        end
      else
        vim.diagnostic.reset(diag_ns, bufnr)
      end
    else
      -- 禁用诊断时保证清空
      vim.diagnostic.reset(diag_ns, bufnr)
    end
  end
end

-- 返回光标下的 i18n key（没有则返回 nil）
function M.get_key_under_cursor()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local line = vim.api.nvim_get_current_line()
  local patterns = config.options.func_pattern
  local keys = extract_i18n_keys(line, patterns)
  local cur_col1 = cursor[2] + 1 -- 转为 1-based 列
  for _, key_info in ipairs(keys) do
    -- 仅允许在 key 及其包裹引号范围内触发（排除函数名 t( 及右括号位置）
    local ks = key_info.key_start_pos or key_info.start_pos
    local ke = key_info.key_end_pos or key_info.end_pos
    local allowed_start = ks
    local allowed_end = ke
    -- 向外扩展一位若存在引号
    local prev_char = (ks > 1) and line:sub(ks - 1, ks - 1) or nil
    if prev_char == "'" or prev_char == '"' then
      allowed_start = ks - 1
    end
    local next_char = line:sub(ke + 1, ke + 1)
    if next_char == "'" or next_char == '"' then
      allowed_end = ke + 1
    end
    if cur_col1 >= allowed_start and cur_col1 <= allowed_end then
      return key_info.key
    end
  end
  return nil
end

-- 显示弹窗
-- 成功显示返回 true；未找到 key 或无翻译返回 false
M.show_popup = function()
  local current_key = M.get_key_under_cursor()

  if not current_key then
    vim.notify("No i18n key found at cursor position", vim.log.levels.WARN)
    return false
  end

  -- 获取所有翻译
  local translations = parser.get_all_translations(current_key)
  if vim.tbl_isempty(translations) then
    vim.notify("No translations found for: " .. current_key, vim.log.levels.WARN)
    return false
  end

  -- 构建显示内容（包含所有已配置语言，缺失翻译以占位符显示并标红）
  local lines = { "I18n: " .. current_key, "" }
  local missing_placeholder = "<Missing translation>"
  local missing_positions = {} -- { { line=number(0-based), col_start=number, col_end=number }, ... }

  local locale_list = (config.options or {}).locales or {}
  for _, locale in ipairs(locale_list) do
    local text = translations[locale]
    if text == nil then
      local line_str = string.format("%s: %s", locale, missing_placeholder)
      table.insert(lines, line_str)
      local line_idx0 = #lines - 1 -- 0-based
      local cs = line_str:find(missing_placeholder, 1, true) or 0
      if cs > 0 then
        cs = cs - 1 -- 0-based
        local ce = cs + #missing_placeholder
        table.insert(missing_positions, { line = line_idx0, col_start = cs, col_end = ce })
      end
    else
      table.insert(lines, string.format("%s: %s", locale, text))
    end
  end

  -- 创建浮动窗口（先关闭已有的）
  if M._popup_win and vim.api.nvim_win_is_valid(M._popup_win) then
    pcall(vim.api.nvim_win_close, M._popup_win, true)
  end
  if M._popup_buf and vim.api.nvim_buf_is_valid(M._popup_buf) then
    pcall(vim.api.nvim_buf_delete, M._popup_buf, { force = true })
  end

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
    border = 'rounded',
  }

  local win = vim.api.nvim_open_win(buf, false, opts)
  M._popup_win = win
  M._popup_buf = buf

  -- 设置高亮
  vim.api.nvim_buf_add_highlight(buf, -1, 'Title', 0, 0, -1)
  -- 缺失翻译占位符标红
  if missing_positions then
    for _, mp in ipairs(missing_positions) do
      pcall(vim.api.nvim_buf_add_highlight, buf, -1, 'Error', mp.line, mp.col_start, mp.col_end)
    end
  end

  -- 自动关闭已移除：弹窗将保持，直到光标移动/切换 buffer 的自动命令或手动 <Esc> 关闭

  -- ESC 关闭
  vim.keymap.set('n', '<Esc>', function()
    if M._popup_win and vim.api.nvim_win_is_valid(M._popup_win) then
      pcall(vim.api.nvim_win_close, M._popup_win, true)
    end
  end, { buffer = buf, nowait = true, silent = true })

  -- 光标移动 / buffer 切换自动关闭
  local group = vim.api.nvim_create_augroup('I18nPopupAutoClose', { clear = true })
  vim.api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI', 'BufEnter', 'BufLeave' }, {
    group = group,
    callback = function()
      if M._popup_win and vim.api.nvim_win_is_valid(M._popup_win) then
        pcall(vim.api.nvim_win_close, M._popup_win, true)
      end
      if M._popup_buf and vim.api.nvim_buf_is_valid(M._popup_buf) then
        pcall(vim.api.nvim_buf_delete, M._popup_buf, { force = true })
      end
    end
  })

  return true
end

-- 设置替换模式
M.setup_replace_mode = function()
  -- 自动命令组
  local group = vim.api.nvim_create_augroup('I18nDisplay', { clear = true })

  -- 文件打开时刷新
  vim.api.nvim_create_autocmd({ 'BufEnter', 'BufWritePost' }, {
    group = group,
    pattern = '*',
    callback = function(args)
      if not is_supported_ft(args.buf) then return end
      M.refresh_buffer(args.buf)
    end
  })

  -- 文本改变时刷新
  vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
    group = group,
    pattern = '*',
    callback = function(args)
      if not is_supported_ft(args.buf) then return end
      vim.defer_fn(function()
        M.refresh_buffer(args.buf)
      end, 100)
    end
  })

  -- 光标移动时刷新（用于隐藏/显示当前行虚拟文本）
  vim.api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI' }, {
    group = group,
    pattern = '*',
    callback = function(args)
      if not is_supported_ft(args.buf) then return end
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
if not vim.g._i18n_next_locale_command_defined then
  vim.api.nvim_create_user_command("I18nNextLocale", function()
    require('i18n.display').next_locale()
  end, { desc = "Cycle switch i18n display language" })
  vim.g._i18n_next_locale_command_defined = true
end

return M
