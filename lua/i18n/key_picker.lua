local parser = require('i18n.parser')
local display = require('i18n.display')
local config = require('i18n.config')

local devicons_ok, devicons = pcall(require, 'nvim-web-devicons')

local preview_ns = vim.api.nvim_create_namespace('I18nKeyPickerPreview')
local icon_ns = vim.api.nvim_create_namespace('I18nKeyPickerIcons')

local M = {}

local function get_locales()
  return (config.options and config.options.locales) or {}
end

local function get_current_locale()
  local ok, cur = pcall(display.get_current_locale)
  if ok then return cur end
  local locales = get_locales()
  return locales[1]
end

local function build_preview_lines(key)
  if not key then return { 'No key' } end
  local locales = get_locales()
  local all = parser.get_all_translations(key) or {}
  local meta = parser.meta or {}
  local current = get_current_locale()
  local default_locale = locales[1]
  local cfg = (config.options and config.options.i18n_keys) or {}
  local show_missing = cfg.show_missing ~= false
  local missing_placeholder = '<Missing translation>'

  local order_mode = cfg.preview_order or 'config'
  local ordered = {}
  if order_mode == 'current_first' and current then
    table.insert(ordered, current)
    for _, locale in ipairs(locales) do
      if locale ~= current then table.insert(ordered, locale) end
    end
  elseif order_mode == 'default_first' and default_locale then
    table.insert(ordered, default_locale)
    for _, locale in ipairs(locales) do
      if locale ~= default_locale then table.insert(ordered, locale) end
    end
  else
    ordered = locales
  end

  local lines = {}
  table.insert(lines, 'Key: ' .. key)
  table.insert(lines, string.rep('-', math.max(10, #key + 5)))
  for _, locale in ipairs(ordered) do
    local value = all[locale]
    local text = value
    if (value == nil or value == '') and show_missing then
      text = missing_placeholder
    end
    local mark = (locale == current) and ' *' or ''
    local position = ''
    if meta[locale] and meta[locale][key] then
      local m = meta[locale][key]
      local rel = m.file and vim.fn.fnamemodify(m.file, ':.') or ''
      position = string.format(' (%s:%d)', rel, m.line or 1)
    end
    local chunks = vim.split(text or '', '\n', { plain = true })
    if #chunks == 0 then
      chunks = { '' }
    end
    for idx, chunk in ipairs(chunks) do
      chunk = chunk:gsub('\r', '')
      if idx == 1 then
        table.insert(lines, string.format('%s:%s %s%s', locale, mark, chunk, position))
      else
        table.insert(lines, string.format('   %s %s', mark ~= '' and ' ' or ' ', chunk))
      end
    end
  end
  return lines
end

local function collect_entries()
  local translations = parser.translations or {}
  local key_map = {}
  for _, locale_tbl in pairs(translations) do
    for key, _ in pairs(locale_tbl) do
      key_map[key] = true
    end
  end
  local keys = {}
  for key in pairs(key_map) do
    table.insert(keys, key)
  end
  table.sort(keys)

  local entries = {}
  local current = get_current_locale()
  for _, key in ipairs(keys) do
    local translation = parser.get_translation(key, current) or ''
    local preview_lines = build_preview_lines(key)
    local icon = ''
    local icon_hl
    if devicons_ok then
      local icon_val, hl = devicons.get_icon(key, nil, { default = true })
      if icon_val and icon_val ~= '' then
        icon = icon_val .. ' '
        icon_hl = hl
      end
    end
    table.insert(entries, {
      key = key,
      translation = translation,
      preview_lines = preview_lines,
      icon = icon,
      icon_hl = icon_hl,
    })
  end
  return entries
end

local function copy_key(entry)
  if not entry or not entry.key then return end
  vim.fn.setreg('+', entry.key)
  vim.notify(string.format('[i18n] Copied key: %s', entry.key), vim.log.levels.INFO)
end

local function ensure_entry_display(entries)
  local max_width = 0
  for _, entry in ipairs(entries) do
    local icon = entry.icon or ''
    local prefix = icon ~= '' and (icon .. ' ') or ''
    local flattened = (entry.translation or ''):gsub('\n', ' ')
    local display = prefix .. entry.key
    if flattened ~= '' then
      display = string.format('%s → %s', display, flattened)
    end
    entry.display = display
    entry.display_width = vim.api.nvim_strwidth(display)
    if entry.display_width > max_width then
      max_width = entry.display_width
    end
  end
  return max_width
end

local function open_native_picker(entries)
  if vim.tbl_isempty(entries) then
    vim.notify('[i18n] No i18n keys available', vim.log.levels.WARN)
    return false
  end

  local current_locale = get_current_locale()
  local max_width = ensure_entry_display(entries)

  local max_height = math.max(6, math.floor(vim.o.lines * 0.6))
  local height = math.min(#entries, max_height)
  local list_width = math.max(40, math.min(max_width + 4, math.floor(vim.o.columns * 0.6)))
  local preview_width = math.max(40, math.floor(vim.o.columns * 0.3))
  if list_width + preview_width + 6 > vim.o.columns then
    preview_width = math.max(32, vim.o.columns - list_width - 6)
  end
  local total_width = list_width + preview_width + 2
  local row = math.max(1, math.floor((vim.o.lines - height) / 2))
  local col = math.max(0, math.floor((vim.o.columns - total_width) / 2))

  local list_buf = vim.api.nvim_create_buf(false, true)
  local preview_buf = vim.api.nvim_create_buf(false, true)
  local list_win = vim.api.nvim_open_win(list_buf, true, {
    relative = 'editor',
    style = 'minimal',
    border = 'rounded',
    row = row,
    col = col,
    width = list_width,
    height = height,
    title = ' I18n Keys ',
  })
  local preview_win = vim.api.nvim_open_win(preview_buf, false, {
    relative = 'editor',
    style = 'minimal',
    border = 'rounded',
    row = row,
    col = col + list_width + 2,
    width = preview_width,
    height = height,
    title = ' Preview ',
  })

  vim.bo[list_buf].buftype = 'nofile'
  vim.bo[list_buf].bufhidden = 'wipe'
  vim.bo[list_buf].swapfile = false
  vim.bo[list_buf].modifiable = true
  vim.wo[list_win].cursorline = true
  vim.wo[list_win].wrap = false

  vim.bo[preview_buf].buftype = 'nofile'
  vim.bo[preview_buf].bufhidden = 'wipe'
  vim.bo[preview_buf].swapfile = false
  vim.bo[preview_buf].modifiable = false
  vim.wo[preview_win].number = false
  vim.wo[preview_win].wrap = false

  local lines = {}
  for _, entry in ipairs(entries) do
    table.insert(lines, entry.display)
  end
  vim.api.nvim_buf_set_lines(list_buf, 0, -1, false, lines)
  vim.bo[list_buf].modifiable = false
  for idx, entry in ipairs(entries) do
    if entry.icon_hl and entry.icon and entry.icon ~= '' then
      local icon_len = vim.api.nvim_strwidth(entry.icon .. ' ')
      pcall(vim.api.nvim_buf_add_highlight, list_buf, icon_ns, entry.icon_hl, idx - 1, 0, icon_len)
    end
  end

  local current_index = 1

  local function cleanup()
    if list_win and vim.api.nvim_win_is_valid(list_win) then
      pcall(vim.api.nvim_win_close, list_win, true)
    end
    if preview_win and vim.api.nvim_win_is_valid(preview_win) then
      pcall(vim.api.nvim_win_close, preview_win, true)
    end
    if list_buf and vim.api.nvim_buf_is_valid(list_buf) then
      pcall(vim.api.nvim_buf_delete, list_buf, { force = true })
    end
    if preview_buf and vim.api.nvim_buf_is_valid(preview_buf) then
      pcall(vim.api.nvim_buf_delete, preview_buf, { force = true })
    end
  end

  local function update_preview(index)
    local entry = entries[index]
    if not entry then return end
    vim.api.nvim_buf_set_option(preview_buf, 'modifiable', true)
    vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, entry.preview_lines)
    vim.api.nvim_buf_clear_namespace(preview_buf, preview_ns, 0, -1)
    if current_locale then
      for idx, line in ipairs(entry.preview_lines) do
        if line:match('^' .. vim.pesc(current_locale) .. ':') then
          vim.api.nvim_buf_add_highlight(preview_buf, preview_ns, 'Visual', idx - 1, 0, -1)
          break
        end
      end
    end
    vim.api.nvim_buf_set_option(preview_buf, 'modifiable', false)
    pcall(vim.api.nvim_win_set_cursor, preview_win, { 1, 0 })
  end

  local function set_index(new_index)
    current_index = math.max(math.min(new_index, #entries), 1)
    vim.api.nvim_win_set_cursor(list_win, { current_index, 0 })
    update_preview(current_index)
  end

  local function confirm()
    local entry = entries[current_index]
    cleanup()
    if entry then
      vim.schedule(function()
        copy_key(entry)
      end)
    end
  end

  local function cancel()
    cleanup()
  end

  set_index(current_index)

  local mappings = {
    ['<CR>'] = confirm,
    ['<Esc>'] = cancel,
    ['q'] = cancel,
    ['<C-c>'] = cancel,
    ['j'] = function() set_index(current_index + 1) end,
    ['<Down>'] = function() set_index(current_index + 1) end,
    ['k'] = function() set_index(current_index - 1) end,
    ['<Up>'] = function() set_index(current_index - 1) end,
    ['gg'] = function() set_index(1) end,
    ['G'] = function() set_index(#entries) end,
    ['<C-d>'] = function() set_index(current_index + math.floor(height / 2)) end,
    ['<C-u>'] = function() set_index(current_index - math.floor(height / 2)) end,
  }
  for lhs, rhs in pairs(mappings) do
    vim.keymap.set('n', lhs, rhs, { buffer = list_buf, nowait = true, noremap = true, silent = true })
  end

  vim.api.nvim_create_autocmd('BufLeave', {
    buffer = list_buf,
    once = true,
    callback = cancel,
  })

  return true
end

local function open_snacks_picker(entries)
  local picker
  local ok_picker, module = pcall(require, 'snacks.picker')
  if ok_picker then
    picker = module
  else
    local ok_snacks, snacks = pcall(require, 'snacks')
    if ok_snacks then
      picker = snacks.picker
    end
  end
  if not picker then
    return false
  end

  ensure_entry_display(entries)

  local items = {}
  for _, entry in ipairs(entries) do
    table.insert(items, {
      text = entry.display,
      value = entry,
      preview = {
        text = table.concat(entry.preview_lines, '\n'),
        ft = 'markdown',
      },
    })
  end

  local select_fn = picker.select or picker.pick or picker.start
  if type(select_fn) ~= 'function' then
    return false
  end

  local cfg = {
    title = 'I18n Keys',
    items = items,
    preview = 'preview',
    confirm = function(p)
      local selection = p and p:selected({ fallback = true })
      local first = selection and selection[1]
      if first and first.value then
        copy_key(first.value)
      end
      if p and p.close then
        p:close()
      end
    end,
  }

  if picker.format and picker.format.ui_select then
    cfg.format = picker.format.ui_select(nil, #items)
  end

  local ok_call, err = pcall(select_fn, picker, cfg)
  if not ok_call then
    vim.notify('[i18n] snacks picker failed: ' .. tostring(err), vim.log.levels.WARN)
    return false
  end
  return true
end

M.show_with_native = function()
  local entries = collect_entries()
  return open_native_picker(entries)
end

M.show_with_snacks = function()
  local entries = collect_entries()
  if vim.tbl_isempty(entries) then
    vim.notify('[i18n] No i18n keys available', vim.log.levels.WARN)
    return false
  end
  local ok = open_snacks_picker(entries)
  if ok then
    return true
  end
  return open_native_picker(entries)
end

return M
