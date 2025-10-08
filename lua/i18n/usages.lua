local M = {}

local config = require('i18n.config')
local parser = require('i18n.parser')
local utils = require('i18n.utils')

local ft_glob_map = {
  vue = { '*.vue' },
  typescript = { '*.ts', '*.tsx' },
  typescriptreact = { '*.tsx' },
  javascript = { '*.js', '*.jsx', '*.mjs', '*.cjs' },
  javascriptreact = { '*.jsx', '*.tsx' },
  tsx = { '*.tsx' },
  ts = { '*.ts' },
  jsx = { '*.jsx' },
  js = { '*.js', '*.jsx', '*.mjs', '*.cjs' },
  lua = { '*.lua' },
  svelte = { '*.svelte' },
  python = { '*.py' },
}

local ft_to_ts = {
  typescriptreact = 'tsx',
  javascriptreact = 'javascript',
  tsx = 'tsx',
  jsx = 'jsx',
  vue = 'vue',
  svelte = 'svelte',
  ['javascript.jsx'] = 'jsx',
  ts = 'typescript',
  js = 'javascript',
  mjs = 'javascript',
  cjs = 'javascript',
  py = 'python',
  java = 'java',
  lua = 'lua',
}

M.usages = {}
M.file_index = {}
M._setup_done = false

local pending_refresh = false

local function schedule_display_refresh()
  if pending_refresh then return end
  pending_refresh = true
  vim.schedule(function()
    pending_refresh = false
    local ok, display = pcall(require, 'i18n.display')
    if ok and display and display.refresh then
      pcall(display.refresh)
    end
  end)
end

local function normalize_globs()
  local opts = config.options or {}
  local types = opts.func_type or opts.func_file_type or {}
  if type(types) ~= 'table' then return {} end
  local collected = {}
  local seen = {}
  for _, entry in ipairs(types) do
    if type(entry) == 'string' then
      local key = entry:lower()
      local globs = ft_glob_map[key]
      if not globs then
        if key:find('[%*%?%[]') then
          globs = { key }
        elseif key:sub(1, 2) == '*.' then
          globs = { key }
        elseif key:sub(1, 1) == '.' then
          globs = { '*' .. key }
        elseif key:sub(1, 2) == '**' then
          globs = { key }
        else
          globs = { '*.' .. key }
        end
      end
      for _, glob in ipairs(globs) do
        if not seen[glob] then
          seen[glob] = true
          table.insert(collected, glob)
        end
      end
    end
  end
  return collected
end

local function build_command(args)
  local escaped = {}
  for _, arg in ipairs(args) do
    table.insert(escaped, vim.fn.shellescape(arg))
  end
  return table.concat(escaped, ' ')
end

local function collect_files()
  local globs = normalize_globs()
  if #globs == 0 then return {} end

  local files = {}
  local seen = {}
  local cwd = vim.loop.cwd()

  if vim.fn.executable('rg') == 1 then
    local cmd_args = { 'rg', '--files' }
    for _, glob in ipairs(globs) do
      table.insert(cmd_args, '-g')
      table.insert(cmd_args, glob)
    end
    local output = vim.fn.systemlist(build_command(cmd_args))
    if vim.v.shell_error == 0 and type(output) == 'table' then
      for _, path in ipairs(output) do
        if type(path) == 'string' and path ~= '' then
          local abs = path
          if not abs:match('^%a:[\\/]') and not abs:match('^/') then
            abs = cwd .. '/' .. abs
          end
          abs = vim.loop.fs_realpath(abs) or abs
          if not seen[abs] then
            seen[abs] = true
            table.insert(files, abs)
          end
        end
      end
    end
  end

  if #files == 0 then
    local git_args = { 'git', 'ls-files', '--cached', '--others', '--exclude-standard' }
    local git_output = vim.fn.systemlist(build_command(git_args))
    if vim.v.shell_error == 0 and type(git_output) == 'table' then
      local regexes = {}
      for _, glob in ipairs(globs) do
        table.insert(regexes, vim.fn.glob2regpat(glob))
      end
      for _, rel in ipairs(git_output) do
        if type(rel) == 'string' and rel ~= '' then
          for _, reg in ipairs(regexes) do
            if vim.fn.match(rel, reg) ~= -1 then
              local abs = cwd .. '/' .. rel
              abs = vim.loop.fs_realpath(abs) or abs
              if not seen[abs] then
                seen[abs] = true
                table.insert(files, abs)
              end
              break
            end
          end
        end
      end
    end
  end

  return files
end

local function extract_keys(line, patterns)
  local matches = {}
  local occupied = {}
  if type(patterns) ~= 'table' then return matches end
  for _, pattern in ipairs(patterns) do
    if type(pattern) == 'string' then
      local pos = 1
      while pos <= #line do
        local s, e, key = line:find(pattern, pos)
        if not s then break end
        local overlap = false
        for idx = s, e do
          if occupied[idx] then
            overlap = true
            break
          end
        end
        if not overlap and key and key ~= '' then
          local key_start = line:find(key, s, true) or s
          table.insert(matches, {
            key = key,
            match_start = s,
            match_end = e,
            key_start = key_start,
          })
          for idx = s, e do
            occupied[idx] = true
          end
        end
        pos = e + 1
      end
    end
  end
  return matches
end

local function collect_file_usages(file)
  if vim.fn.filereadable(file) ~= 1 then
    return {}, {}
  end
  local ok, lines = pcall(vim.fn.readfile, file)
  if not ok or type(lines) ~= 'table' then
    return {}, {}
  end

  local entries = {}
  local key_set = {}
  local patterns = config.options and config.options.func_pattern or {}

  local comment_checker = nil
  local bufnr = vim.fn.bufnr(file)
  if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
    comment_checker = utils.make_comment_checker(bufnr)
  end

  if not comment_checker and utils.make_comment_checker_from_content then
    local ft = nil
    local ok_ft, matched_ft = pcall(vim.filetype.match, { filename = file })
    if ok_ft then
      ft = matched_ft
    end
    if not ft or ft == '' then
      local ext = vim.fn.fnamemodify(file, ':e')
      if ext and ext ~= '' then
        ft = ext
      end
    end
    if ft and ft_to_ts[ft] then
      ft = ft_to_ts[ft]
    end
    local lang = ft
    if lang and lang ~= '' then
      local content = table.concat(lines, '\n')
      comment_checker = utils.make_comment_checker_from_content(content, lang)
    end
  end

  for idx, raw in ipairs(lines) do
    if type(raw) == 'string' then
      local line = raw:gsub('\r$', '')
      local found = extract_keys(line, patterns)
      for _, match in ipairs(found) do
        local skip = false
        if comment_checker then
          local row0 = idx - 1
          local positions = {
            (match.key_start or match.match_start or 1) - 1,
            (match.match_start or 1) - 1,
            (match.match_end or 1) - 1,
          }
          for _, col0 in ipairs(positions) do
            if col0 and col0 >= 0 and comment_checker(row0, col0) then
              skip = true
              break
            end
          end
        end
        if not skip then
          local preview = line
          preview = preview:gsub('^%s+', ''):gsub('%s+$', '')
          if #preview > 120 then
            preview = preview:sub(1, 117) .. '...'
          end
          table.insert(entries, {
            key = match.key,
            file = file,
            line = idx,
            col = match.key_start or match.match_start,
            preview = preview,
          })
          key_set[match.key] = true
        end
      end
    end
  end

  return entries, key_set
end

local function sort_usages(list)
  table.sort(list, function(a, b)
    if a.file ~= b.file then
      return a.file < b.file
    end
    if (a.line or 0) ~= (b.line or 0) then
      return (a.line or 0) < (b.line or 0)
    end
    return (a.col or 0) < (b.col or 0)
  end)
end

local function format_usage_entry(item)
  if not item then return '' end
  local rel = item.file and vim.fn.fnamemodify(item.file, ':.') or '<unknown>'
  local preview = item.preview or ''
  return string.format('%s:%d:%d %s', rel, item.line or 1, item.col or 1, preview)
end

local function select_with_vim_ui(entries, key, callback)
  vim.ui.select(entries, {
    prompt = string.format('Usages of %s', key),
    format_item = format_usage_entry,
  }, callback)
  return true
end

local function select_with_telescope(entries, key, callback)
  local ok, pickers = pcall(require, 'telescope.pickers')
  if not ok then return false end
  local finders = require('telescope.finders')
  local conf = require('telescope.config').values
  local actions = require('telescope.actions')
  local action_state = require('telescope.actions.state')

  pickers.new({}, {
    prompt_title = string.format('Usages of %s', key),
    finder = finders.new_table {
      results = entries,
      entry_maker = function(item)
        return {
          value = item,
          display = format_usage_entry(item),
          ordinal = string.format('%s %s %s', item.key or key, item.file or '', item.preview or ''),
        }
      end,
    },
    sorter = conf.generic_sorter({}),
    attach_mappings = function(prompt_bufnr, map)
      local function select_current()
        local selection = action_state.get_selected_entry()
        if not selection then return end
        actions.close(prompt_bufnr)
        vim.schedule(function()
          callback(selection.value)
        end)
      end
      map('i', '<CR>', select_current)
      map('n', '<CR>', select_current)
      return true
    end,
  }):find()
  return true
end

local function select_with_fzflua(entries, key, callback)
  local ok_fzf, fzf = pcall(require, 'fzf-lua')
  if not ok_fzf then return false end

  local ok_config, fzf_config = pcall(require, 'fzf-lua.config')
  local ok_make_entry, make_entry = pcall(require, 'fzf-lua.make_entry')
  local ok_path, fzf_path = pcall(require, 'fzf-lua.path')
  if not (ok_config and ok_make_entry and ok_path) then
    return false
  end

  local function canonical_path(pathname)
    if not pathname or pathname == '' then
      return nil
    end
    return vim.loop.fs_realpath(pathname) or vim.fn.fnamemodify(pathname, ':p')
  end

  local line_lookup = {}
  local location_lookup = {}

  local opts = fzf_config.normalize_opts({
    prompt = string.format('Usages > %s > ', key),
    fzf_opts = {
      ['--no-multi'] = '',
      ['--info'] = 'inline',
    },
  }, 'lsp')
  if not opts then return false end
  opts.fzf_opts['--multi'] = nil
  opts.cwd = opts.cwd or (vim.loop and vim.loop.cwd() or vim.fn.getcwd())

  local lines = {}
  for _, item in ipairs(entries) do
    local file = item.file or ''
    if file ~= '' then
      local entry_line = make_entry.lcol({
        filename = file,
        lnum = item.line or 1,
        col = item.col or 1,
        text = item.preview or '',
      }, opts)
      if entry_line then
        local formatted = make_entry.file(entry_line, opts)
        if formatted then
          table.insert(lines, formatted)
          line_lookup[formatted] = line_lookup[formatted] or {}
          table.insert(line_lookup[formatted], item)
          local abs = canonical_path(file)
          if abs then
            local loc_key = string.format('%s:%d:%d', abs, item.line or 1, item.col or 1)
            location_lookup[loc_key] = location_lookup[loc_key] or {}
            table.insert(location_lookup[loc_key], item)
          end
        end
      end
    end
  end

  if vim.tbl_isempty(lines) then
    return false
  end

  opts.actions = {
    ['default'] = function(selected, o)
      if not selected or not selected[1] then return end
      local entry_line = selected[1]
      local parsed = fzf_path.entry_to_file(entry_line, o)
      local result
      local candidates = line_lookup[entry_line]
      if candidates then
        if #candidates == 1 then
          result = candidates[1]
        elseif parsed and parsed.path and parsed.path ~= '' then
          local abs = canonical_path(parsed.path)
          local lnum = parsed.line and parsed.line > 0 and parsed.line or 1
          local col = parsed.col and parsed.col > 0 and parsed.col or 1
          for _, candidate in ipairs(candidates) do
            local candidate_path = canonical_path(candidate.file)
            if candidate_path == abs
                and (candidate.line or 1) == lnum
                and (candidate.col or 1) == col then
              result = candidate
              break
            end
          end
        end
      end
      if not result and parsed and parsed.path and parsed.path ~= '' then
        local abs = canonical_path(parsed.path)
        local lnum = parsed.line and parsed.line > 0 and parsed.line or 1
        local col = parsed.col and parsed.col > 0 and parsed.col or 1
        if abs then
          local bucket = location_lookup[string.format('%s:%d:%d', abs, lnum, col)]
          if bucket and #bucket > 0 then
            result = bucket[1]
          end
        end
      end
      if not result and candidates and #candidates > 0 then
        result = candidates[1]
      end
      if result then
        callback(result)
      end
    end,
  }

  fzf.fzf_exec(lines, opts)
  return true
end

local function select_with_snacks(entries, key, callback)
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
  if not picker then return false end

  local select_fn = picker.select or picker.pick or picker.start
  if type(select_fn) ~= 'function' then return false end

  local items = {}
  for _, entry in ipairs(entries) do
    table.insert(items, {
      text = format_usage_entry(entry),
      value = entry,
    })
  end

  local ok_call, err = pcall(select_fn, picker, {
    title = string.format('Usages of %s', key),
    items = items,
    action = function(item)
      local value = item and (item.value or item)
      if value then callback(value) end
    end,
  })
  if not ok_call then
    vim.notify('[i18n] snacks picker failed: ' .. tostring(err), vim.log.levels.WARN)
    return false
  end
  return true
end

local popup_handlers = {
  vim_ui = select_with_vim_ui,
  telescope = select_with_telescope,
  ['fzf-lua'] = select_with_fzflua,
  snacks = select_with_snacks,
}

local function pick_usage(entries, key, callback)
  local popup_cfg = (config.options and config.options.popup) or {}
  local preferred = popup_cfg.type or 'vim_ui'
  local order = { preferred }
  if preferred ~= 'vim_ui' then
    table.insert(order, 'vim_ui')
  end
  for _, typ in ipairs(order) do
    local handler = popup_handlers[typ]
    if handler then
      local ok = handler(entries, key, callback)
      if ok then return end
    end
  end
  -- fallback
  select_with_vim_ui(entries, key, callback)
end

local function remove_file_entries(file)
  local tracked = M.file_index[file]
  if not tracked then return end
  for key in pairs(tracked) do
    local list = M.usages[key]
    if list then
      local filtered = {}
      for _, entry in ipairs(list) do
        if entry.file ~= file then
          table.insert(filtered, entry)
        end
      end
      if #filtered == 0 then
        M.usages[key] = nil
      else
        M.usages[key] = filtered
      end
    end
  end
  M.file_index[file] = nil
end

local function record_entries(file, entries, key_set)
  if #entries == 0 then
    return
  end
  for _, entry in ipairs(entries) do
    M.usages[entry.key] = M.usages[entry.key] or {}
    table.insert(M.usages[entry.key], entry)
  end
  for key, _ in pairs(key_set) do
    sort_usages(M.usages[key])
  end
  M.file_index[file] = key_set
end

local function open_location(entry, key)
  if not entry or not entry.file then return false end
  if vim.fn.filereadable(entry.file) ~= 1 then
    vim.notify(string.format('[i18n] Usage file not found: %s', entry.file), vim.log.levels.WARN)
    return false
  end
  local open_cmd = (config.options.navigation and config.options.navigation.open_cmd) or 'edit'
  if open_cmd ~= 'edit' then
    vim.cmd(string.format('%s %s', open_cmd, vim.fn.fnameescape(entry.file)))
  else
    vim.cmd('edit ' .. vim.fn.fnameescape(entry.file))
  end
  local line = entry.line or 1
  local col = math.max((entry.col or 1) - 1, 0)
  vim.api.nvim_win_set_cursor(0, { line, col })
  vim.api.nvim_echo({ { string.format('[i18n] usage: %s', key), 'Comment' } }, false, {})
  return true
end

local function detect_key_at_cursor()
  local buf_path = vim.api.nvim_buf_get_name(0)
  if buf_path == '' then return nil end
  local abs_path = vim.loop.fs_realpath(buf_path) or buf_path
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  local locales = (config.options and config.options.locales) or {}
  if #locales == 0 then return nil end

  local meta_per_locale = parser.meta or {}

  for _, locale in ipairs(locales) do
    local meta_tbl = meta_per_locale[locale]
    if meta_tbl then
      for key, meta in pairs(meta_tbl) do
        if meta.file == abs_path and meta.line == cursor_line then
          return key
        end
      end
    end
  end

  local candidate
  local best_diff
  for _, locale in ipairs(locales) do
    local meta_tbl = meta_per_locale[locale]
    if meta_tbl then
      for key, meta in pairs(meta_tbl) do
        if meta.file == abs_path and meta.line and meta.line <= cursor_line then
          local diff = cursor_line - meta.line
          if not best_diff or diff < best_diff then
            best_diff = diff
            candidate = key
          end
        end
      end
    end
  end

  return candidate
end

function M.scan_file(path)
  if not path or path == '' then return end
  local abs = vim.loop.fs_realpath(path) or path
  remove_file_entries(abs)
  local entries, key_set = collect_file_usages(abs)
  if next(key_set) then
    record_entries(abs, entries, key_set)
  else
    M.file_index[abs] = nil
  end
end

function M.scan_project_usages()
  M.usages = {}
  M.file_index = {}
  local files = collect_files()
  for _, file in ipairs(files) do
    local entries, key_set = collect_file_usages(file)
    if next(key_set) then
      record_entries(file, entries, key_set)
    end
  end
  schedule_display_refresh()
  return files
end

function M.refresh()
  local files = M.scan_project_usages()
  return files
end

function M.get_usages_for_key(key)
  if not key then return {} end
  return M.usages[key] or {}
end

function M.get_usage_count(key)
  local list = M.get_usages_for_key(key)
  return #list
end

function M.get_usage_label(key)
  if not key then return nil end
  local count = M.get_usage_count(key)
  if count == 0 then
    return 'no usages'
  elseif count == 1 then
    return '1 usage'
  else
    return string.format('%d usages', count)
  end
end

function M.jump_to_usage(key)
  if not key or key == '' then
    vim.notify('[i18n] No i18n key detected under cursor', vim.log.levels.WARN)
    return false
  end
  local entries = M.get_usages_for_key(key)
  if #entries == 0 then
    vim.notify(string.format('[i18n] No usages found for %s', key), vim.log.levels.INFO)
    return false
  end
  if #entries == 1 then
    return open_location(entries[1], key)
  end

  pick_usage(entries, key, function(choice)
    if choice then
      open_location(choice, key)
    end
  end)
  return true
end

function M.jump_under_cursor()
  local key = detect_key_at_cursor()
  if not key then
    vim.notify('[i18n] No i18n key detected under cursor', vim.log.levels.WARN)
    return false
  end
  return M.jump_to_usage(key)
end

function M.remove_file(path)
  if not path or path == '' then return end
  local abs = vim.loop.fs_realpath(path) or path
  remove_file_entries(abs)
  schedule_display_refresh()
end

function M.setup()
  if M._setup_done then return end
  M._setup_done = true
  local group = vim.api.nvim_create_augroup('I18nUsageScanner', { clear = true })
  local patterns = normalize_globs()
  if #patterns > 0 then
    vim.api.nvim_create_autocmd('BufWritePost', {
      group = group,
      pattern = patterns,
      callback = function(args)
        if args and args.file and args.file ~= '' then
          M.scan_file(args.file)
          schedule_display_refresh()
        end
      end,
      desc = 'Rescan i18n key usages after saving source file',
    })

    vim.api.nvim_create_autocmd('BufDelete', {
      group = group,
      pattern = patterns,
      callback = function(args)
        if args and args.file and args.file ~= '' then
          M.remove_file(args.file)
        end
      end,
      desc = 'Remove cached i18n usages when buffer is deleted',
    })
  end

  vim.schedule(function()
    M.scan_project_usages()
  end)
end

return M
