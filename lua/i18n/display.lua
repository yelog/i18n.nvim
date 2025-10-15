local M = {}
local config = require('i18n.config')
local parser = require('i18n.parser')
local usages = require('i18n.usages')
local utils = require('i18n.utils')

-- 命名空间
local ns = vim.api.nvim_create_namespace('i18n_display')
local diag_ns = vim.api.nvim_create_namespace('i18n_display_diag')
local keypos_ns = vim.api.nvim_create_namespace('i18n_keypos')

-- 最近一次弹窗窗口与缓冲区
M._popup_win = nil
M._popup_buf = nil

-- 当前显示语言索引（基于 config.locales）
M._current_locale_index = 1

-- 光标行缓存，避免重复刷新
M._cursor_state = {}

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
    vim.notify("[i18n] No locales configured", vim.log.levels.WARN)
    return
  end
  M._current_locale_index = (M._current_locale_index % #locales) + 1
  local new_locale = locales[M._current_locale_index]
  vim.notify(string.format("[i18n] display locale: %s", new_locale), vim.log.levels.INFO)
  M.refresh()
end

local function get_show_mode()
  local mode = (config.options or {}).show_mode
  if type(mode) ~= 'string' then
    return 'both'
  end
  mode = mode:lower()
  if mode ~= 'both' and mode ~= 'translation' and mode ~= 'translation_conceal' and mode ~= 'origin' then
    return 'both'
  end
  return mode
end

local function should_show_translation(mode, is_cursor_line)
  if mode == 'origin' then
    return false
  end
  if mode == 'translation_conceal' and is_cursor_line then
    return false
  end
  return true
end

local function should_hide_origin(mode, is_cursor_line)
  if mode == 'origin' or mode == 'both' then
    return false
  end
  -- translation / translation_conceal hide origin except on cursor line
  return not is_cursor_line
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

local function detect_buffer_locale(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local buf_path = vim.api.nvim_buf_get_name(bufnr)
  local abs_path = vim.loop.fs_realpath(buf_path) or buf_path

  local file_locale = nil
  for _, loc in ipairs((config.options or {}).locales or {}) do
    local fp = parser.file_prefixes[loc]
    if fp then
      if fp[abs_path] then
        file_locale = loc
        break
      end
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

  return file_locale, abs_path
end

local function is_dynamic_suffix(line, end_pos)
  if type(line) ~= 'string' or type(end_pos) ~= 'number' then
    return false
  end
  if end_pos >= #line then
    return false
  end
  local remainder = line:sub(end_pos + 1)
  if not remainder or remainder == '' then
    return false
  end
  local trimmed = remainder:match('^%s*(.*)$')
  if not trimmed or trimmed == '' then
    return false
  end
  local first_char = trimmed:sub(1, 1)
  local first_two = trimmed:sub(1, 2)
  if first_char == '+' or first_char == '[' then
    return true
  end
  if first_two == '..' then
    return true
  end
  return false
end

local function extract_i18n_keys(_, line_num, line, patterns, comment_checker)
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

          local skip = false
          if comment_checker and line_num then
            local row0 = line_num - 1
            local check_cols = {
              (key_start_pos or start_pos) - 1,
              (start_pos - 1),
              (key_end_pos or end_pos) - 1,
            }
            for _, col0 in ipairs(check_cols) do
              if col0 and col0 >= 0 and comment_checker(row0, col0) then
                skip = true
                break
              end
            end
          end

          if not skip then
            table.insert(keys, {
              key = key,
              start_pos = start_pos,         -- 整个匹配开始
              end_pos = end_pos,             -- 整个匹配结束
              key_start_pos = key_start_pos, -- 仅 key（不含引号等）
              key_end_pos = key_end_pos,
              dynamic = is_dynamic_suffix(line, end_pos),
            })
            for i = start_pos, end_pos do
              occupied[i] = true
            end
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
local function set_virtual_text(bufnr, line_num, col, text, origin_visible)
  if not text or text == "" then return end
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  local line = vim.api.nvim_buf_get_lines(bufnr, line_num, line_num + 1, false)[1]
  if not line then return end
  -- extmark col 为 0-based，且不能超过行长度
  local line_len = #line
  local col0 = math.max(0, math.min((col or 0) - 1, line_len))
  local char_at = line:sub(col0 + 1, col0 + 1)
  if char_at == "'" or char_at == '"' or char_at == '`' then
    col0 = math.min(line_len, col0 + 1)
  end
  local prefix = origin_visible and ": " or ""
  local ok = pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, line_num, col0, {
    virt_text = { { prefix .. text, "Comment" } },
    virt_text_pos = "inline",
  })
  if not ok then
    -- 若仍失败（例如 col0 == 行长度且 inline 不允许），尝试行尾方式兜底
    pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, line_num, 0, {
      virt_text = { { " " .. prefix .. text, "Comment" } },
      virt_text_pos = "eol",
    })
  end
end

-- 在翻译文件中行尾显示（默认语言）翻译
local function set_eol_virtual_text(bufnr, line_num, text)
  if not text or text == "" then return end
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  local line = vim.api.nvim_buf_get_lines(bufnr, line_num, line_num + 1, false)[1]
  if not line then return end
  local ok = pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, line_num, 0, {
    virt_text = { { " ← " .. text, "Comment" } },
    virt_text_pos = "eol",
  })
  if not ok then
    -- 兜底：忽略错误，防止抛出
    return
  end
end

local function refresh_lines_for_cursor(bufnr, line_nums, cursor_line)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  if not line_nums or #line_nums == 0 then return end

  local unique = {}
  local ordered = {}
  for _, line_num in ipairs(line_nums) do
    if type(line_num) == 'number' and line_num >= 1 and not unique[line_num] then
      unique[line_num] = true
      table.insert(ordered, line_num)
    end
  end
  if #ordered == 0 then return end

  local show_mode = get_show_mode()
  local default_locale = M.get_current_locale()
  local patterns = config.options.func_pattern
  local comment_checker = utils.make_comment_checker(bufnr)

  for _, line_num in ipairs(ordered) do
    local line = vim.api.nvim_buf_get_lines(bufnr, line_num - 1, line_num, false)[1]
    vim.api.nvim_buf_clear_namespace(bufnr, ns, line_num - 1, line_num)
    if not line then
      goto continue
    end
    local keys = extract_i18n_keys(bufnr, line_num, line, patterns, comment_checker)
    local is_cursor_line = cursor_line and line_num == cursor_line
    for _, key_info in ipairs(keys) do
      if not key_info.dynamic then
        local translation = parser.get_translation(key_info.key, default_locale)
        if translation then
          local show_translation_line = should_show_translation(show_mode, is_cursor_line)
          local hide_origin_line = should_hide_origin(show_mode, is_cursor_line)

          if show_translation_line then
            set_virtual_text(bufnr, line_num - 1, key_info.end_pos, translation, not hide_origin_line)
          end

          if hide_origin_line then
            local s, e, _, key = line:find("(['\"])([^'\"]+)['\"]", key_info.start_pos)
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
    ::continue::
  end
end

-- 刷新缓冲区显示
M.refresh_buffer = function(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  -- 提前判定是否为翻译文件：即属于任一 locale 的已解析文件
  local file_locale, abs_path = detect_buffer_locale(bufnr)

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
          -- 为没有 mark 的条目建立位置跟踪 extmark（加安全裁剪，避免 col 越界）
          local total_lines = vim.api.nvim_buf_line_count(bufnr)
          local lnum = (meta.line or 1)
          if lnum < 1 then lnum = 1 end
          if lnum > total_lines then lnum = total_lines end
          local line_text = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
          local line_len = #line_text
            -- meta.col 是 1-based
          local col = (meta.col or 1)
          if col < 1 then col = 1 end
          if col - 1 > line_len then
            -- 若超出行长，放在行尾（extmark col 允许等于行长表示 EOL 位置）
            col = line_len + 1
          end
          local id = vim.api.nvim_buf_set_extmark(bufnr, keypos_ns, lnum - 1, col - 1, {})
          meta.line = lnum
          meta.col = col
          meta.mark_id = id
        end
      end
    end

    -- 成功解析后再清除旧的虚拟文本（仅清除展示 namespace，不动 keypos_ns）
    if not cleared then
      vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
      cleared = true
    end

    local show_usage = config.options.show_locale_file_eol_usage ~= false
    local show_translation = config.options.show_locale_file_eol_translation ~= false
    for full_key, meta in pairs(meta_tbl) do
      if meta.file == abs_path then
        local segments = {}
        if show_usage then
          local usage_label = usages.get_usage_label(full_key)
          if usage_label then
            table.insert(segments, usage_label)
          end
        end
        if show_translation then
          local value = parser.get_translation(full_key, default_locale)
          if value and value ~= '' then
            table.insert(segments, value)
          end
        end
        if #segments > 0 then
          set_eol_virtual_text(bufnr, (meta.line or 1) - 1, table.concat(segments, ' · '))
        end
      end
    end
    return
  end

  local show_mode = get_show_mode()

  -- 获取当前窗口和光标行
  local current_win = vim.api.nvim_get_current_win()
  local cursor_line = nil
  if vim.api.nvim_win_get_buf(current_win) == bufnr then
    cursor_line = vim.api.nvim_win_get_cursor(current_win)[1]
  end

  -- 根据 show_mode 控制 conceallevel
  if show_mode == 'translation' or show_mode == 'translation_conceal' then
    vim.api.nvim_buf_set_option(bufnr, 'conceallevel', 2)
  else
    vim.api.nvim_buf_set_option(bufnr, 'conceallevel', 0)
  end

  local comment_checker = nil
  if not file_locale then
    comment_checker = utils.make_comment_checker(bufnr)
  end

  for line_num, line in ipairs(lines) do
    local keys = extract_i18n_keys(bufnr, line_num, line, patterns, comment_checker)
    -- vim.notify("keys: " .. vim.inspect(keys), vim.log.levels.DEBUG)
    local is_cursor_line = cursor_line and line_num == cursor_line
    for _, key_info in ipairs(keys) do
      if key_info.dynamic then
        goto continue_key
      end

      local translation = parser.get_translation(key_info.key, default_locale)

      local show_translation_line = false
      if translation and should_show_translation(show_mode, is_cursor_line) then
        show_translation_line = true
      end

      local hide_origin_line = false
      if translation and should_hide_origin(show_mode, is_cursor_line) then
        hide_origin_line = true
      end

      if translation and show_translation_line then
        set_virtual_text(bufnr, line_num - 1, key_info.end_pos, translation, not hide_origin_line)
      end

      if diag_enabled and not translation then
        table.insert(diagnostics, {
          lnum = line_num - 1,
          col = (key_info.key_start_pos or key_info.start_pos) - 1,
          end_col = key_info.key_end_pos or key_info.end_pos,
          severity = type(diag_opt) == "table" and diag_opt.severity or
              (vim.diagnostic and vim.diagnostic.severity.ERROR) or 1,
          source = "i18n",
          message = string.format("Missing translation: %s (%s)", key_info.key, default_locale or "default"),
        })
      end

      -- 只有找到译文并成功设置虚拟文本且模式要求隐藏原文时才 conceal
      if translation and hide_origin_line then
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
      ::continue_key::
    end
  end
  if cursor_line then
    M._cursor_state[bufnr] = cursor_line
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
  local bufnr = vim.api.nvim_get_current_buf()
  local patterns = config.options.func_pattern
  local comment_checker = utils.make_comment_checker(bufnr)
  local keys = extract_i18n_keys(bufnr, cursor[1], line, patterns, comment_checker)
  local cur_col1 = cursor[2] + 1 -- 转为 1-based 列
  for _, key_info in ipairs(keys) do
    if key_info.dynamic then
      goto continue_key
    end
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
    ::continue_key::
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
      if vim.api.nvim_get_current_buf() ~= args.buf then return end

      local show_mode = get_show_mode()
      if show_mode == 'origin' or show_mode == 'both' then
        local cursor = vim.api.nvim_win_get_cursor(0)
        M._cursor_state[args.buf] = cursor[1]
        return
      end

      local file_locale = detect_buffer_locale(args.buf)
      if file_locale then
        local cursor = vim.api.nvim_win_get_cursor(0)
        M._cursor_state[args.buf] = cursor[1]
        return
      end

      local cursor = vim.api.nvim_win_get_cursor(0)
      local current_line = cursor[1]
      local prev_line = M._cursor_state[args.buf]
      if prev_line == current_line then
        return
      end

      refresh_lines_for_cursor(args.buf, { prev_line, current_line }, current_line)
      M._cursor_state[args.buf] = current_line
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
