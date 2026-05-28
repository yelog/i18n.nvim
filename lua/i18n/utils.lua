local M = {}

local c_like_line_comments = {
  javascript = true,
  typescript = true,
  tsx = true,
  jsx = true,
  vue = true,
  svelte = true,
  java = true,
  css = true,
}

local c_like_block_comments = {
  javascript = true,
  typescript = true,
  tsx = true,
  jsx = true,
  vue = true,
  svelte = true,
  java = true,
  css = true,
}

local hash_line_comments = {
  python = true,
}

local html_block_comments = {
  html = true,
  vue = true,
  svelte = true,
}

local lua_comments = {
  lua = true,
}

local function normalize_language(language)
  if type(language) ~= 'string' then return nil end
  language = language:lower()
  if language == 'typescriptreact' then return 'tsx' end
  if language == 'javascriptreact' then return 'jsx' end
  if language == 'javascript.jsx' then return 'jsx' end
  if language == 'ts' then return 'typescript' end
  if language == 'js' or language == 'mjs' or language == 'cjs' then return 'javascript' end
  if language == 'py' then return 'python' end
  return language
end

local function has_comment_syntax(language)
  language = normalize_language(language)
  return c_like_line_comments[language]
    or c_like_block_comments[language]
    or hash_line_comments[language]
    or html_block_comments[language]
    or lua_comments[language]
end

local function add_comment_range(ranges, row, start_col, end_col)
  ranges[row] = ranges[row] or {}
  table.insert(ranges[row], { start_col, end_col })
end

local function close_block_comment(line, start_pos, close_marker)
  local close_start, close_end = line:find(close_marker, start_pos, true)
  if close_start then
    return close_end, close_end
  end
  return nil, #line
end

local function scan_line_for_comments(line, language, ranges, row, state)
  local i = 1
  local len = #line
  local string_quote = nil
  local escaped = false

  if state.block_comment then
    local close_pos, end_col = close_block_comment(line, 1, state.block_comment)
    add_comment_range(ranges, row, 0, end_col)
    if close_pos then
      state.block_comment = nil
      i = close_pos + 1
    else
      return
    end
  end

  while i <= len do
    local char = line:sub(i, i)
    local two = line:sub(i, i + 1)
    local four = line:sub(i, i + 3)

    if string_quote then
      if escaped then
        escaped = false
      elseif char == '\\' then
        escaped = true
      elseif char == string_quote then
        string_quote = nil
      end
      i = i + 1
    elseif char == "'" or char == '"' or char == '`' then
      string_quote = char
      i = i + 1
    elseif html_block_comments[language] and four == '<!--' then
      local close_pos, end_col = close_block_comment(line, i + 4, '-->')
      add_comment_range(ranges, row, i - 1, end_col)
      if close_pos then
        i = close_pos + 1
      else
        state.block_comment = '-->'
        return
      end
    elseif lua_comments[language] and line:sub(i, i + 3) == '--[[' then
      local close_pos, end_col = close_block_comment(line, i + 4, ']]')
      add_comment_range(ranges, row, i - 1, end_col)
      if close_pos then
        i = close_pos + 1
      else
        state.block_comment = ']]'
        return
      end
    elseif lua_comments[language] and two == '--' then
      add_comment_range(ranges, row, i - 1, len)
      return
    elseif c_like_block_comments[language] and two == '/*' then
      local close_pos, end_col = close_block_comment(line, i + 2, '*/')
      add_comment_range(ranges, row, i - 1, end_col)
      if close_pos then
        i = close_pos + 1
      else
        state.block_comment = '*/'
        return
      end
    elseif c_like_line_comments[language] and two == '//' then
      add_comment_range(ranges, row, i - 1, len)
      return
    elseif hash_line_comments[language] and char == '#' then
      add_comment_range(ranges, row, i - 1, len)
      return
    else
      i = i + 1
    end
  end
end

local function make_fallback_comment_checker(lines, language)
  language = normalize_language(language)
  if type(lines) ~= 'table' or not language or not has_comment_syntax(language) then
    return nil
  end

  local ranges = {}
  local state = {}
  for row, line in ipairs(lines) do
    scan_line_for_comments(type(line) == 'string' and line or '', language, ranges, row - 1, state)
  end

  return function(row, col)
    if row == nil or col == nil then return false end
    if row < 0 or col < 0 then return false end

    local row_ranges = ranges[row]
    if not row_ranges then return false end
    for _, range in ipairs(row_ranges) do
      if col >= range[1] and col <= range[2] then
        return true
      end
    end
    return false
  end
end

local function combine_comment_checkers(primary, fallback)
  if primary and fallback then
    return function(row, col)
      return primary(row, col) or fallback(row, col)
    end
  end
  return primary or fallback
end

-- 读取文件内容
M.read_file = function(filepath)
  local file = io.open(filepath, "r")
  if not file then
    return nil
  end
  local content = file:read("*a")
  file:close()
  return content
end

-- 检查文件是否存在
M.file_exists = function(filepath)
  if type(vim) == 'table' and vim.loop and vim.loop.fs_stat then
    local stat = vim.loop.fs_stat(filepath)
    if stat then return true end
  end
  local file = io.open(filepath, "r")
  if file then
    file:close()
    return true
  end
  return false
end

-- 扫描目录获取子目录或者指定后缀的文件
-- scan_sub(dir, ext): ext为空则查目录，否则查指定后缀文件
M.scan_sub = function(dir, ext)
  local result = {}
  local handle = vim.loop.fs_scandir(dir)
  if handle then
    while true do
      local name, type = vim.loop.fs_scandir_next(handle)
      if not name then break end
      if not ext then
        if type == "directory" then
          table.insert(result, name)
        end
      else
        if type == "file" and name:sub(- #ext) == ext then
          table.insert(result, name)
        end
      end
    end
  end
  return result
end

-- 简单模糊过滤 (子串优先，其次子序列)
M.fuzzy_filter = function(candidates, input, max_items)
  max_items = max_items or 15
  if not input or input == "" then
    local slice = {}
    for i, k in ipairs(candidates) do
      if i > max_items then break end
      table.insert(slice, k)
    end
    return slice
  end
  local lower_input = input:lower()
  local scored = {}
  for _, key in ipairs(candidates) do
    local lk = key:lower()
    local s, e = lk:find(lower_input, 1, true)
    if s then
      -- 直接子串匹配分数：长度奖励 + 越靠前越好
      local score = (e - s + 1) * 5 - s * 0.01
      table.insert(scored, { key = key, score = score })
    else
      -- 子序列匹配
      local idx = 1
      local matched = 0
      for c in lower_input:gmatch('.') do
        local found = lk:find(c, idx, true)
        if not found then
          matched = 0
          break
        end
        matched = matched + 1
        idx = found + 1
      end
      if matched > 0 then
        local score = matched * 1 - idx * 0.001
        table.insert(scored, { key = key, score = score })
      end
    end
  end
  table.sort(scored, function(a, b) return a.score > b.score end)
  local out = {}
  for i, item in ipairs(scored) do
    if i > max_items then break end
    table.insert(out, item.key)
  end
  return out
end

-- 返回一个函数用于判断给定缓冲区坐标是否处于注释节点内。
-- 优先使用 tree-sitter，同时用轻量词法扫描补足嵌入语言注释。
M.make_comment_checker = function(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local ts_checker = nil

  if vim and vim.treesitter and vim.treesitter.get_parser then
    local ok_parser, parser = pcall(vim.treesitter.get_parser, bufnr)
    if ok_parser and parser then
      ts_checker = function(row, col)
        if row == nil or col == nil then return false end
        if row < 0 or col < 0 then return false end

        local ok_tree, trees = pcall(parser.parse, parser)
        if not ok_tree or not trees or not trees[1] then
          return false
        end

        local root = trees[1]:root()
        if not root then return false end

        local node = root:named_descendant_for_range(row, col, row, col)
        if not node then
          node = root:descendant_for_range(row, col, row, col)
        end

        while node do
          local ntype = node:type()
          if ntype and ntype:lower():find('comment') then
            return true
          end
          node = node:parent()
        end

        return false
      end
    end
  end

  if not vim or not vim.api or not vim.api.nvim_buf_get_lines then
    return nil
  end

  local ok_lines, lines = pcall(vim.api.nvim_buf_get_lines, bufnr, 0, -1, false)
  if not ok_lines then return nil end
  local ok_ft, ft = pcall(vim.api.nvim_get_option_value, 'filetype', { buf = bufnr })
  if not ok_ft or not ft or ft == '' then
    ft = vim.bo[bufnr] and vim.bo[bufnr].filetype or nil
  end
  return combine_comment_checkers(ts_checker, make_fallback_comment_checker(lines, ft))
end

-- 基于原始行内容构建注释检测函数，适用于未加载缓冲区的文件内容。
M.make_comment_checker_from_lines = function(lines, language)
  return make_fallback_comment_checker(lines, language)
end

-- 基于原始文本内容构建注释检测函数，适用于未加载缓冲区的文件内容。
M.make_comment_checker_from_content = function(content, language)
  if not content or content == "" then return nil end
  if not language or language == "" then return nil end
  language = normalize_language(language)
  local ts_checker = nil

  if vim and vim.treesitter and vim.treesitter.get_string_parser then
    local ok_parser, parser = pcall(vim.treesitter.get_string_parser, content, language)
    if ok_parser and parser then
      local ok_tree, trees = pcall(parser.parse, parser)
      if ok_tree and trees and trees[1] then
        local root = trees[1]:root()
        if root then
          ts_checker = function(row, col)
            if row == nil or col == nil then return false end
            if row < 0 or col < 0 then return false end

            local node = root:named_descendant_for_range(row, col, row, col)
            if not node then
              node = root:descendant_for_range(row, col, row, col)
            end

            while node do
              local ntype = node:type()
              if ntype and ntype:lower():find('comment') then
                return true
              end
              node = node:parent()
            end

            return false
          end
        end
      end
    end
  end

  return combine_comment_checkers(ts_checker, make_fallback_comment_checker(vim.split(content, '\n', true), language))
end

return M
