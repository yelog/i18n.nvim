local M = {}

local config = require('i18n.config')
local parser = require('i18n.parser')
local utils = require('i18n.utils')

-- 简单获取光标下的 i18n key（基于 func_pattern）
local function get_key_under_cursor()
  local bufnr = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local line = vim.api.nvim_get_current_line()
  local col = cursor[2] + 1
  local comment_checker = utils.make_comment_checker(bufnr)
  for _, pat in ipairs(config.options.func_pattern or {}) do
    local init = 1
    while true do
      local s, e, cap = line:find(pat, init)
      if not s then break end
      local skip = false
      if comment_checker then
        local row0 = cursor[1] - 1
        local match = line:sub(s, e)
        local rel_key_s, rel_key_e = nil, nil
        if cap and cap ~= '' then
          rel_key_s, rel_key_e = match:find(cap, 1, true)
        end
        local key_start = rel_key_s and (s + rel_key_s - 1) or s
        local key_end = rel_key_e and (s + rel_key_e - 1) or e
        local check_cols = {
          key_start - 1,
          key_end - 1,
          s - 1,
        }
        for _, col0 in ipairs(check_cols) do
          if col0 and col0 >= 0 and comment_checker(row0, col0) then
            skip = true
            break
          end
        end
      end
      if not skip and col >= s and col <= e then
        return cap
      end
      init = e + 1
    end
  end
  return nil
end

-- 判断 key 是否已存在（任一 locale）
local function key_exists(key)
  for locale, translations in pairs(parser.translations or {}) do
    if translations[key] ~= nil then
      return true, locale
    end
  end
  return false, nil
end

-- 找到每个 locale 对应的文件（最长前缀匹配）
local function resolve_files_for_key(key)
  local mapping = {}
  for _, locale in ipairs(config.options.locales or {}) do
    local prefixes = parser.file_prefixes[locale] or {}
    local best_len = -1
    local best_file = nil
    local best_prefix = ""
    for file, prefix in pairs(prefixes) do
      if prefix == "" or key:sub(1, #prefix) == prefix then
        local plen = #prefix
        if plen > best_len then
          best_len = plen
          best_file = file
          best_prefix = prefix
        end
      end
    end
    if best_file then
      mapping[locale] = { file = best_file, prefix = best_prefix }
    end
  end
  return mapping
end

-- 读取 JSON -> table（空或失败返回 {}）
local function read_json_table(path)
  local content = utils.read_file(path)
  if not content or content == "" then return {} end
  local ok, decoded = pcall(vim.json.decode, content)
  if ok and type(decoded) == "table" then return decoded end
  return {}
end

-- 嵌套写入 path a.b.c
local function assign_nested(tbl, keypath, value)
  local parts = {}
  for seg in keypath:gmatch("[^%.]+") do
    table.insert(parts, seg)
  end
  local node = tbl
  for i = 1, #parts do
    local k = parts[i]
    if i == #parts then
      node[k] = value
    else
      if type(node[k]) ~= "table" then
        node[k] = {}
      end
      node = node[k]
    end
  end
end

-- 简单 pretty JSON（避免依赖外部库）
local function encode_pretty(tbl, indent, depth)
  indent = indent or "  "
  depth = depth or 0
  if type(tbl) ~= "table" then
    return vim.json.encode(tbl)
  end
  local is_array = (#tbl > 0)
  local pieces = {}
  if is_array then
    table.insert(pieces, "[")
    for i, v in ipairs(tbl) do
      local comma = (i < #tbl) and "," or ""
      if type(v) == "table" then
        table.insert(pieces, string.rep(indent, depth + 1) .. encode_pretty(v, indent, depth + 1) .. comma)
      else
        table.insert(pieces, string.rep(indent, depth + 1) .. vim.json.encode(v) .. comma)
      end
    end
    table.insert(pieces, string.rep(indent, depth) .. "]")
  else
    table.insert(pieces, "{")
    local keys = {}
    for k, _ in pairs(tbl) do table.insert(keys, k) end
    table.sort(keys)
    for i, k in ipairs(keys) do
      local v = tbl[k]
      local comma = (i < #keys) and "," or ""
      if type(v) == "table" then
        table.insert(pieces,
          string.format("%s%q: %s%s", string.rep(indent, depth + 1), k,
            encode_pretty(v, indent, depth + 1), comma))
      else
        table.insert(pieces,
          string.format("%s%q: %s%s", string.rep(indent, depth + 1), k, vim.json.encode(v), comma))
      end
    end
    table.insert(pieces, string.rep(indent, depth) .. "}")
  end
  return table.concat(pieces, "\n")
end

local function ensure_dir(path)
  local dir = vim.fn.fnamemodify(path, ":h")
  if dir ~= "" and vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, "p")
  end
end

-- 尝试在原 JSON 文本中“就地”追加一个嵌套 key，而不整体重排。
-- 仅当所有中间层级对象已存在时执行；否则返回 false 交由旧逻辑（重排写回）。
-- 返回: appended:boolean, new_content_or_nil
local function append_json_key(file, relative_key, value)
  if not utils.file_exists(file) then
    return false
  end
  local content = utils.read_file(file) or ""
  if content == "" then
    return false
  end
  -- 找到第一个 '{'
  local root_open = content:find("{")
  if not root_open then
    return false
  end

  -- 匹配根对象闭合
  local function find_matching_brace(start_pos)
    local depth = 0
    for i = start_pos, #content do
      local ch = content:sub(i, i)
      if ch == "{" then
        depth = depth + 1
      elseif ch == "}" then
        depth = depth - 1
        if depth == 0 then
          return i
        end
      end
    end
    return nil
  end
  local root_close = find_matching_brace(root_open)
  if not root_close then
    return false
  end

  local parts = {}
  for seg in relative_key:gmatch("[^%.]+") do
    table.insert(parts, seg)
  end
  if #parts == 0 then
    return false
  end

  -- 遍历中间层级，定位到目标父对象（最后一个层级的上一级）
  local target_start = root_open
  local target_end = root_close
  for i = 1, #parts - 1 do
    local seg = parts[i]
    local region = content:sub(target_start, target_end)
    -- 在当前对象区域内查找 "seg": { （允许前后空白）
    -- 使用最左匹配（假设 key 唯一）
    local rel_idx = region:find('"' .. vim.pesc(seg) .. '"%s*:%s*{')
    if not rel_idx then
      -- 若任一父层级不存在，放弃“就地追加”
      return false
    end
    -- 找到该子对象 '{' 的绝对位置
    local abs_brace = target_start + rel_idx - 1
    local brace_pos = content:find("{", abs_brace)
    if not brace_pos then
      return false
    end
    local sub_close = find_matching_brace(brace_pos)
    if not sub_close then
      return false
    end
    target_start = brace_pos
    target_end = sub_close
  end

  -- 现在 target_start/target_end 包含父对象（或根对象，如果只有一层）
  local last_key = parts[#parts]

  -- 判断该 key 是否已存在
  local parent_region = content:sub(target_start, target_end)
  if parent_region:find('"' .. vim.pesc(last_key) .. '"%s*:') then
    -- 已存在，无需追加
    return true, content
  end

  local before_parent_close = content:sub(1, target_end - 1)
  local after_parent_close = content:sub(target_end)

  -- 计算父对象缩进
  -- 父对象起始 '{' 所在行
  local line_start = before_parent_close:match("()\n[^\n]*$") or 1
  local line_text = before_parent_close:sub(line_start)
  local parent_indent = line_text:match("^(%s*)") or ""

  -- 取内部内容
  local inner = content:sub(target_start + 1, target_end - 1)
  local object_empty = inner:match("^%s*$") ~= nil

  -- 推测子属性缩进：找第一条属性
  local indent_unit = "  "
  local first_prop_indent = inner:match("\n(%s*)[\"']%w")
  if first_prop_indent and #first_prop_indent > #parent_indent then
    indent_unit = first_prop_indent:sub(#parent_indent + 1)
  end

  -- 是否需要给现有最后一个属性补逗号
  local needs_comma = false
  if not object_empty then
    local trimmed_inner = inner:gsub("%s+$", "")
    local last_char = trimmed_inner:sub(-1)
    if last_char ~= "," then
      needs_comma = true
    end
  end

  local encoded_value = vim.json.encode(value)

  -- 构造插入片段：避免重复增加额外的 } ，同时消除多余空行
  -- 先去掉父对象关闭前可能存在的多余空白/换行
  local trimmed_before = before_parent_close:gsub("%s*$", "")
  before_parent_close = trimmed_before

  local insertion_prefix = ""
  if not object_empty and needs_comma then
    insertion_prefix = ","
  end

  local insertion = insertion_prefix ..
      "\n" .. parent_indent .. indent_unit ..
      string.format('"%s": %s', last_key, encoded_value)

  -- 直接复用原有的 '}' （after_parent_close 以 '}' 开头），不再手动添加新 '}'
  local new_content = before_parent_close .. insertion .. "\n" .. parent_indent .. after_parent_close

  local ok = pcall(function()
    local f = assert(io.open(file, "w"))
    f:write(new_content)
    f:close()
  end)
  if not ok then
    return false
  end
  return true, new_content
end

-- 追加 JS/TS 属性：
-- 优先尝试根据相对 key 的层级定位已存在的嵌套对象并在对象内部添加末级键；
-- 若任一中间层级对象不存在，则退化为在根导出对象上以扁平 "a.b.c": "Value" 形式追加。
local function append_js_ts_property(file, relative_key, value)
  local content = utils.read_file(file) or ""
  local encoded_value = vim.json.encode(value)

  -- 渲染属性名：若为合法标识符则不加引号；否则使用单引号
  local function render_prop_key(k)
    if k:match("^[A-Za-z_$][A-Za-z0-9_$]*$") then
      return k
    end
    return "'" .. k .. "'"
  end

  -- 新文件：保持最简单结构（不去构造嵌套对象）
  if content == "" then
    local lines = {
      "export default {",
      string.format('  %q: %s', relative_key, encoded_value),
      "}",
      ""
    }
    local ok = pcall(function()
      local f = assert(io.open(file, "w"))
      f:write(table.concat(lines, "\n"))
      f:close()
    end)
    return ok
  end

  -- 如果完整扁平 key 已存在则直接成功
  if content:find('["\']' .. vim.pesc(relative_key) .. '["\']%s*:') then
    return true
  end

  -- 定位导出对象起始 {
  local brace_start_idx
  do
    local idx = content:find("export%s+default%s+{")
    if idx then
      brace_start_idx = content:find("{", idx)
    end
    if not brace_start_idx then
      local idx2 = content:find("module%.exports%s*=%s*{")
      if idx2 then
        brace_start_idx = content:find("{", idx2)
      end
    end
  end

  if not brace_start_idx then
    -- 未找到根对象，退化为在文件末尾新建
    local appended = "\nexport default {\n  " ..
        string.format('%q: %s', relative_key, encoded_value) .. "\n}\n"
    local ok = pcall(function()
      local f = assert(io.open(file, "a"))
      f:write(appended)
      f:close()
    end)
    return ok
  end

  -- 计算根对象闭合位置
  local function find_matching_brace(start_pos)
    local depth = 0
    for i = start_pos, #content do
      local ch = content:sub(i, i)
      if ch == "{" then
        depth = depth + 1
      elseif ch == "}" then
        depth = depth - 1
        if depth == 0 then
          return i
        end
      end
    end
    return nil
  end
  local root_end = find_matching_brace(brace_start_idx)
  if not root_end then
    vim.notify("[i18n] Failed to detect end of export object in: " .. file, vim.log.levels.WARN)
    return false
  end

  -- 尝试嵌套插入
  local parts = {}
  for seg in relative_key:gmatch("[^%.]+") do table.insert(parts, seg) end

  local can_nested = (#parts > 1)
  local target_object_start = brace_start_idx
  local target_object_end = root_end

  if can_nested then
    -- 在根对象内部搜索每一级中间对象
    -- 范围限定在当前对象 (target_object_start, target_object_end)
    for i = 1, #parts - 1 do
      local segment = parts[i]
      local pattern = '["\']?' .. vim.pesc(segment) .. '["\']?%s*:%s*{'
      local search_region = content:sub(target_object_start, target_object_end)
      local rel_start, rel_brace = search_region:find(pattern)
      if not rel_brace then
        can_nested = false
        break
      end
      -- 绝对位置
      local abs_brace = target_object_start + rel_brace - 1
      -- 找该对象的结束 brace
      local seg_end = find_matching_brace(abs_brace)
      if not seg_end then
        can_nested = false
        break
      end
      -- 下一轮在该子对象内继续
      target_object_start = abs_brace
      target_object_end = seg_end
    end
  end

  if can_nested then
    local last_key = parts[#parts]
    -- 检查该对象内是否已存在末级 key
    local object_region = content:sub(target_object_start, target_object_end)
    if object_region:find('["\']' .. vim.pesc(last_key) .. '["\']%s*:') then
      return true
    end

    -- 计算插入点（在 target_object_end 之前）
    local before = content:sub(1, target_object_end - 1)
    local after = content:sub(target_object_end)

    -- 判断对象是否为空（忽略空白和注释的简单判断：寻找除 { 空白 以外的字符）
    local inner = content:sub(target_object_start + 1, target_object_end - 1)
    local inner_trim = inner:gsub("%s+", "")
    local object_empty = (inner_trim == "")

    -- 获取缩进：取闭合大括号所在行的前导空白作为对象缩进
    local line_start = before:match("()\n[^\n]*$") or 1
    local prev_line = before:sub(line_start)
    local object_indent = prev_line:match("^(%s*)") or ""
    local indent_unit = "  "
    -- 尝试找第一条属性的缩进
    local first_prop_indent = inner:match("\n(%s*)[\"'%w_]+%s*:")
    if first_prop_indent and #first_prop_indent > 0 then
      indent_unit = first_prop_indent
      -- 如果 first_prop_indent 比 object_indent 长，则 indent_unit = first_prop_indent - object_indent
      if first_prop_indent:find("^" .. object_indent) then
        local rest = first_prop_indent:sub(#object_indent + 1)
        if #rest > 0 then
          indent_unit = rest
        end
      end
    end

    local needs_comma = false
    if not object_empty then
      -- 找最后一个非空白字符（不含换行）在 before 对象末尾
      local inner_before = inner:match("(.+)%s*$") or ""
      local last_char = inner_before:match("([,%{%}])%s*$")
      if last_char ~= "," then
        needs_comma = true
      end
    end

    local key_rendered = render_prop_key(last_key)
    local prop_line =
      (needs_comma and "," or "") ..
      "\n" .. object_indent .. indent_unit ..
      string.format('%s: %s', key_rendered, encoded_value)

    local new_content = before .. prop_line .. "\n" .. object_indent .. after
    local ok = pcall(function()
      local f = assert(io.open(file, "w"))
      f:write(new_content)
      f:close()
    end)
    return ok
  end

  -- 退化：根级扁平追加（与原实现一致）
  local insert_pos -- 根对象闭合前位置
  insert_pos = root_end
  local before_root = content:sub(1, insert_pos - 1)
  local after_root = content:sub(insert_pos)
  local line_before_block = before_root:match("([^\n]*)$")
  local needs_comma = false
  if line_before_block then
    local trimmed = line_before_block:gsub("%s+$", "")
    if trimmed ~= "" and not trimmed:match(",$") and not trimmed:match("{%s*$") then
      needs_comma = true
    end
  end
  local indent = "  "
  local first_prop = before_root:match("{%s*\n(%s+)[\"'%w_]")
  if first_prop then
    indent = first_prop
  end
  local key_rendered_root = render_prop_key(relative_key)
  local prop_line = (needs_comma and "," or "") .. "\n" ..
      indent .. string.format('%s: %s', key_rendered_root, encoded_value)
  local new_content = before_root .. prop_line .. after_root
  local ok = pcall(function()
    local f = assert(io.open(file, "w"))
    f:write(new_content)
    f:close()
  end)
  return ok
end

local function write_key_to_files(key, values, filemap)
  for locale, data in pairs(filemap) do
    local file = data.file
    if file and values[locale] and values[locale] ~= "" then
      local ext = file:match("%.([%w_]+)$") or ""
      if ext == "json" then
        ensure_dir(file)
        local rel = key:gsub("^" .. vim.pesc(data.prefix), "")
        -- 优先尝试原地追加（不重排），失败再回退到旧的重排写入
        local appended, newc = append_json_key(file, rel, values[locale])
        if appended and newc then
          -- 同步缓冲区
          local bufnr = vim.fn.bufnr(file)
          if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
            local lines = vim.split(newc, '\n', true)
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
          end
        elseif appended and not newc then
          -- 已存在 key，忽略
        else
          -- 回退：解析+重排（仅在无法原地插入时才发生）
            local tbl = read_json_table(file)
            assign_nested(tbl, rel, values[locale])
            local encoded = encode_pretty(tbl)
            local ok_write = pcall(function()
              local f = assert(io.open(file, "w"))
              f:write(encoded)
              f:close()
            end)
            if not ok_write then
              vim.notify("[i18n] Failed writing file: " .. file, vim.log.levels.ERROR)
            else
              local bufnr = vim.fn.bufnr(file)
              if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
                local lines = vim.split(encoded, '\n', true)
                vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
              end
            end
        end
      elseif ext == "yml" or ext == "yaml" then
        vim.notify("[i18n] YAML write not yet supported (skipped): " .. file, vim.log.levels.WARN)
      elseif ext == "js" or ext == "ts" then
        ensure_dir(file)
        local rel = key:gsub("^" .. vim.pesc(data.prefix), "")
        local ok_js = append_js_ts_property(file, rel, values[locale])
        if not ok_js then
          vim.notify("[i18n] Failed updating JS/TS file: " .. file, vim.log.levels.ERROR)
        else
          vim.notify("[i18n] Updated JS/TS: " .. file, vim.log.levels.DEBUG)
          -- 同步已加载缓冲区内容，避免 parser 行列与缓冲区长度不一致导致 extmark col 越界
          local bufnr = vim.fn.bufnr(file)
          if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
            local newc = utils.read_file(file)
            if newc then
              local lines = vim.split(newc, '\n', true)
              vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
            end
          end
        end
      else
        vim.notify("[i18n] Unsupported target file type for automatic insertion: " .. file, vim.log.levels.WARN)
      end
    end
  end
end

-- 弹窗编辑
function M.add_key_interactive()
  local locales = config.options.locales or {}
  if #locales == 0 then
    vim.notify("[i18n] No locales configured", vim.log.levels.WARN)
    return
  end

  local key = get_key_under_cursor()
  if not key or key == "" then
    vim.notify("[i18n] No i18n key under cursor", vim.log.levels.WARN)
    return
  end

  local exists = key_exists(key)
  if exists then
    vim.notify("[i18n] Key already exists: " .. key, vim.log.levels.INFO)
    return
  end

  local filemap = resolve_files_for_key(key)
  if vim.tbl_isempty(filemap) then
    vim.notify("[i18n] Cannot resolve target translation files for key (check prefixes): " .. key,
      vim.log.levels.ERROR)
    return
  end

  -- 创建浮动窗口
  local width = math.max(60, #key + 20)
  local height = #locales + 8
  local buf = vim.api.nvim_create_buf(false, true)
  local ui = vim.api.nvim_list_uis()[1]
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((ui.height - height) / 2),
    col = math.floor((ui.width - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " Add i18n Key ",
    title_pos = "center",
  })

  local lines = {}
  table.insert(lines, "Add key: " .. key)
  table.insert(lines, string.rep("-", width - 2))
  for _, locale in ipairs(locales) do
    table.insert(lines, locale .. ": ")
  end
  table.insert(lines, "")
  table.insert(lines, "Files:")
  for _, locale in ipairs(locales) do
    local fm = filemap[locale]
    if fm then
      table.insert(lines, string.format("  %s -> %s", locale, fm.file))
    else
      table.insert(lines, string.format("  %s -> (unresolved)", locale))
    end
  end
  table.insert(lines, "")
  table.insert(lines, "[Tab] Next  [S-Tab] Prev  [Enter] Save  [Esc] Cancel")

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(buf, "modifiable", true)
  vim.bo[buf].filetype = "i18n_add_key"

  -- 记录可输入的行号
  local first_input_line = 3
  local locale_line_index = {}
  for idx, locale in ipairs(locales) do
    locale_line_index[locale] = first_input_line + idx - 1
  end
  local last_input_line = first_input_line + #locales - 1

  local touched = {}
  local default_locale = locales[1]

  -- 将光标移到默认语言输入位置末尾
  vim.api.nvim_win_set_cursor(win, { locale_line_index[default_locale], (#default_locale + 3) })

  local function extract_value(line)
    local _, _, val = line:find("^[^:]+:%s*(.*)$")
    return val or ""
  end

  local function set_line(locale, value)
    local lnum = locale_line_index[locale]
    local prefix = locale .. ": "
    vim.api.nvim_buf_set_lines(buf, lnum - 1, lnum, false, { prefix .. value })
  end

  local function get_line(locale)
    local lnum = locale_line_index[locale]
    return vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1] or ""
  end

  local function get_all_values()
    local out = {}
    for _, loc in ipairs(locales) do
      out[loc] = extract_value(get_line(loc))
    end
    return out
  end

  local function move_input(delta)
    local pos = vim.api.nvim_win_get_cursor(win)
    local line = pos[1]
    local new_line = line + delta
    if new_line < first_input_line then new_line = last_input_line end
    if new_line > last_input_line then new_line = first_input_line end
    local cur_line_text = vim.api.nvim_buf_get_lines(buf, new_line - 1, new_line, false)[1] or ""
    vim.api.nvim_win_set_cursor(win, { new_line, #cur_line_text })
  end

  -- Keymaps
  local function map(lhs, rhs)
    vim.keymap.set({ "i", "n" }, lhs, rhs, { buffer = buf, nowait = true, silent = true })
  end

  map("<Tab>", function()
    move_input(1)
  end)
  map("<S-Tab>", function()
    move_input(-1)
  end)

  local function cancel()
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end

  vim.keymap.set({ "n" }, "<Esc>", cancel, { buffer = buf, nowait = true, silent = true })
  map("<C-c>", cancel)

  local function save_and_close()
    local values = get_all_values()
    -- 若所有值为空则取消
    local any_non_empty = false
    for _, v in pairs(values) do
      if v ~= "" then any_non_empty = true break end
    end
    if not any_non_empty then
      vim.notify("[i18n] All translations empty; cancelled", vim.log.levels.WARN)
      cancel()
      return
    end
    write_key_to_files(key, values, filemap)
    parser.load_translations()
    local ok_d, display_mod = pcall(require, 'i18n.display')
    if ok_d and display_mod.refresh then
      display_mod.refresh()
    end
    vim.notify("[i18n] Added key: " .. key, vim.log.levels.INFO)
    cancel()
  end

  map("<CR>", function()
    -- 仅当光标在输入区域才保存；否则忽略
    local cur = vim.api.nvim_win_get_cursor(win)[1]
    if cur >= first_input_line and cur <= last_input_line then
      save_and_close()
    end
  end)

  -- 自动同步默认语言输入到未 touch 的其它 locale
  vim.api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, {
    buffer = buf,
    callback = function()
      local pos = vim.api.nvim_win_get_cursor(win)
      local cur_line = pos[1]
      for loc, lno in pairs(locale_line_index) do
        if lno == cur_line then
          touched[loc] = true
        end
      end
      if cur_line == locale_line_index[default_locale] then
        local default_val = extract_value(get_line(default_locale))
        for _, loc in ipairs(locales) do
          if loc ~= default_locale and not touched[loc] then
            set_line(loc, default_val)
          end
        end
      end
    end,
  })
end

return M
