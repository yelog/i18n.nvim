-- Telescope integration for searching & acting on i18n keys
-- Provides similar capabilities to the fzf-lua integration:
--  - Copy key / translation
--  - Jump to definition (current locale preferred, fallback default)
--  - Choose locale then jump
--  - Split / vsplit / tab jumps
--
-- NOTE:
--  - We reuse existing config.options.locales
--  - Key mappings are set locally inside the picker (do not override global Telescope defaults)
--  - Depends on nvim-telescope/telescope.nvim

local ok_telescope, telescope = pcall(require, 'telescope')
if not ok_telescope then
  vim.notify("[i18n] telescope.nvim not found (install nvim-telescope/telescope.nvim)", vim.log.levels.WARN)
  return {}
end

local pickers = require('telescope.pickers')
local finders = require('telescope.finders')
local previewers = require('telescope.previewers')
local conf = require('telescope.config').values
local actions = require('telescope.actions')
local action_state = require('telescope.actions.state')

local parser = require('i18n.parser')
local display = require('i18n.display')
local config = require('i18n.config')

local M = {}

---------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------
local function get_locales()
  return (config.options and config.options.locales) or {}
end

local function get_current_locale()
  local ok, cur = pcall(display.get_current_locale)
  if ok then return cur end
  local locales = get_locales()
  return locales[1]
end

local function get_cfg()
  local opts = config.options or {}
  if type(opts.i18n_keys) == 'table' then
    return opts.i18n_keys
  end
  if type(opts.fzf) == 'table' then
    return opts.fzf
  end
  return config.defaults.i18n_keys or {}
end

local function build_preview_lines(key)
  if not key then return { "No key" } end
  local locales = get_locales()
  local all = parser.get_all_translations(key) or {}
  local meta = parser.meta or {}
  local cur = get_current_locale()
  local def = locales[1]
  local cfg = get_cfg()
  local show_missing = cfg.show_missing ~= false
  local missing_placeholder = "<Missing translation>"

  local order_mode = (cfg.preview_order or "config")
  local ordered = {}
  if order_mode == "current_first" and cur then
    table.insert(ordered, cur)
    for _, l in ipairs(locales) do
      if l ~= cur then table.insert(ordered, l) end
    end
  elseif order_mode == "default_first" and def then
    table.insert(ordered, def)
    for _, l in ipairs(locales) do
      if l ~= def then table.insert(ordered, l) end
    end
  else
    ordered = locales
  end

  local lines = {}
  table.insert(lines, "Key: " .. key)
  table.insert(lines, string.rep("-", math.max(10, #key + 5)))
  for _, l in ipairs(ordered) do
    local val = all[l]
    local text = val
    if (val == nil or val == "") and show_missing then
      text = missing_placeholder
    end
    local mark = (l == cur) and " *" or ""
    local pos = ""
    if meta[l] and meta[l][key] then
      local m = meta[l][key]
      local rel = vim.fn.fnamemodify(m.file, ":.")
      pos = string.format(" (%s:%d)", rel, m.line or 1)
    end
    local chunks = vim.split(text or "", "\n", { plain = true })
    if #chunks == 0 then
      chunks = { "" }
    end
    for idx, chunk in ipairs(chunks) do
      chunk = chunk:gsub("\r", "")
      if idx == 1 then
        table.insert(lines, string.format("%s:%s %s%s", l, mark, chunk, pos))
      else
        table.insert(lines, string.format("   %s %s", mark ~= "" and " " or " ", chunk))
      end
    end
  end
  return lines
end

local function open_location(loc, key, open_cmd)
  if not loc or not loc.file then
    vim.notify("[i18n] No location for key: " .. key, vim.log.levels.WARN)
    return false
  end
  open_cmd = open_cmd or "edit"
  if vim.fn.filereadable(loc.file) ~= 1 then
    vim.notify("[i18n] File not readable: " .. loc.file, vim.log.levels.WARN)
    return false
  end
  if open_cmd ~= "edit" then
    vim.cmd(string.format("%s %s", open_cmd, vim.fn.fnameescape(loc.file)))
  else
    vim.cmd("edit " .. vim.fn.fnameescape(loc.file))
  end
  vim.api.nvim_win_set_cursor(0, { loc.line or 1, (loc.col or 1) - 1 })
  vim.api.nvim_echo({ { "[i18n] jumped: " .. key, "Comment" } }, false, {})
  return true
end

local function jump_key(key, locale, open_cmd)
  local loc = parser.get_key_location(key, locale)
  if not loc then return false end
  return open_location(loc, key, open_cmd)
end

local function choose_locale_and_jump(key)
  local locales = get_locales()
  if #locales == 0 then
    vim.notify("[i18n] No locales configured", vim.log.levels.WARN)
    return
  end
  local meta = parser.meta or {}
  pickers.new({}, {
    prompt_title = "I18n Locale",
    finder = finders.new_table {
      results = locales,
      entry_maker = function(l)
        local has = (meta[l] and meta[l][key]) and "✔" or "✖"
        local mark = (l == get_current_locale()) and "*" or " "
        return {
          value = l,
            display = string.format("%s [%s] %s", l, has, mark),
            ordinal = l
        }
      end
    },
    sorter = conf.generic_sorter({}),
    attach_mappings = function(prompt_bufnr, map)
      local function _select()
        local selection = action_state.get_selected_entry()
        if not selection then return end
        local locale = selection.value
        if not (meta[locale] and meta[locale][key]) then
          vim.notify("[i18n] No location for key in locale: " .. locale, vim.log.levels.WARN)
        else
          actions.close(prompt_bufnr)
          jump_key(key, locale, "edit")
        end
      end
      map({ "i", "n" }, "<CR>", function() _select() end)
      return true
    end
  }):find()
end

local function collect_keys(current_locale)
  local translations = parser.translations or {}
  local keys_map = {}
  for _, locale_tbl in pairs(translations) do
    for k, _ in pairs(locale_tbl) do
      keys_map[k] = true
    end
  end
  local list = {}
  for k in pairs(keys_map) do
    table.insert(list, k)
  end
  table.sort(list)

  -- 计算最长 key 的显示宽度（宽字符按 2 处理）
  local function display_width(str)
    if not str or str == "" then return 0 end
    local w = 0
    for ch in str:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
      if #ch > 1 then
        w = w + 2
      else
        local b = ch:byte()
        if b > 127 then
          w = w + 2
        else
          w = w + 1
        end
      end
    end
    return w
  end
  local function pad_right(str, width)
    local cur = display_width(str)
    if cur >= width then return str end
    return str .. string.rep(" ", width - cur)
  end

  local max_w = 0
  for _, k in ipairs(list) do
    local w = display_width(k)
    if w > max_w then max_w = w end
  end

  local entries = {}
  for _, key in ipairs(list) do
    local val = parser.get_translation(key, current_locale) or ""
    local disp_key = pad_right(key, max_w)
    table.insert(entries, {
      key = key,
      value = key,
      display = string.format("%s │ %s", disp_key, val),
      ordinal = key .. " " .. val,
    })
  end
  return entries
end

---------------------------------------------------------------------
-- Main picker
---------------------------------------------------------------------
function M.show_i18n_keys_with_telescope(opts)
  opts = opts or {}
  if not opts.suppress_deprecation then
    vim.deprecate(
      'require("i18n.integration.telescope").show_i18n_keys_with_telescope',
      'require("i18n").i18n_keys',
      '0.2.0'
    )
  end
  local current_locale = get_current_locale()
  local entries = collect_keys(current_locale)
  if #entries == 0 then
    vim.notify("[i18n] No i18n keys available", vim.log.levels.WARN)
    return
  end

  local previewer = previewers.new_buffer_previewer {
    title = "I18n Preview",
    define_preview = function(self, entry)
      if not entry or not entry.value then
        return
      end
      local lines = build_preview_lines(entry.value)
      vim.api.nvim_buf_set_option(self.state.bufnr, 'modifiable', true)
      vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
      vim.api.nvim_buf_set_option(self.state.bufnr, 'modifiable', false)
    end
  }

  local picker = pickers.new({}, {
    prompt_title = "I18n Keys",
    finder = finders.new_table {
      results = entries,
      entry_maker = function(item) return item end
    },
    sorter = conf.generic_sorter({}),
    previewer = previewer,
    attach_mappings = function(prompt_bufnr, map)
      local function get_key()
        local entry = action_state.get_selected_entry()
        return entry and entry.value or nil
      end

      local function act_copy_key()
        local k = get_key()
        if not k then return end
        vim.fn.setreg("+", k)
        vim.notify("[i18n] Copied key: " .. k, vim.log.levels.INFO)
      end

      local function act_copy_translation()
        local k = get_key()
        if not k then return end
        local cur = get_current_locale()
        local text = parser.get_translation(k, cur)
        if text then
          vim.fn.setreg("+", text)
          vim.notify(string.format("[i18n] Copied [%s] translation", cur), vim.log.levels.INFO)
        else
          vim.notify("[i18n] Missing translation in current locale", vim.log.levels.WARN)
        end
      end

      local function do_jump(open_variant, explicit_key)
        local k = explicit_key or get_key()
        if not k then return end
        local locales = get_locales()
        local cfg = (get_cfg().jump or {})
        local cur = get_current_locale()
        local prefer_cur = cfg.prefer_current_locale ~= false
        local tried = false
        if prefer_cur and cur then
          tried = true
            if jump_key(k, cur, open_variant or cfg.open_cmd_default or "edit") then
              return
            end
        end
        local def = locales[1]
        if def and (not tried or def ~= cur) then
          if jump_key(k, def, open_variant or cfg.open_cmd_default or "edit") then
            return
          end
        end
        vim.notify("[i18n] Cannot jump: no location found", vim.log.levels.WARN)
      end

      local function act_choose_locale()
        local k = get_key()
        if not k then return end
        actions.close(prompt_bufnr)
        choose_locale_and_jump(k)
      end

      local function wrap_close(fn)
        return function()
          fn()
          actions.close(prompt_bufnr)
        end
      end

      -- Default <CR> copy key
      map({ "i", "n" }, "<CR>", wrap_close(act_copy_key))
      map({ "i", "n" }, "<C-y>", wrap_close(act_copy_translation))
      map({ "i", "n" }, "<C-j>", function()
        local k = get_key()
        if not k then return end
        actions.close(prompt_bufnr)
        vim.schedule(function() do_jump("edit", k) end)
      end)
      map({ "i", "n" }, "<C-l>", act_choose_locale)
      map({ "i", "n" }, "<C-x>", function()
        local k = get_key()
        if not k then return end
        actions.close(prompt_bufnr)
        vim.schedule(function() do_jump("split", k) end)
      end)
      map({ "i", "n" }, "<C-v>", function()
        local k = get_key()
        if not k then return end
        actions.close(prompt_bufnr)
        vim.schedule(function() do_jump("vsplit", k) end)
      end)
      map({ "i", "n" }, "<C-t>", function()
        local k = get_key()
        if not k then return end
        actions.close(prompt_bufnr)
        vim.schedule(function() do_jump("tabedit", k) end)
      end)

      return true
    end
  })

  picker:find()
end

return M
