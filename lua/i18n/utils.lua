local M = {}

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
-- 若当前环境缺少 tree-sitter 或解析失败，则返回 nil。
M.make_comment_checker = function(bufnr)
  if not vim or not vim.treesitter or not vim.treesitter.get_parser then
    return nil
  end

  bufnr = bufnr or vim.api.nvim_get_current_buf()

  local ok_parser, parser = pcall(vim.treesitter.get_parser, bufnr)
  if not ok_parser or not parser then
    return nil
  end

  return function(row, col)
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

-- 基于原始文本内容构建注释检测函数，适用于未加载缓冲区的文件内容。
M.make_comment_checker_from_content = function(content, language)
  if not content or content == "" then return nil end
  if not language or language == "" then return nil end
  if not vim or not vim.treesitter or not vim.treesitter.get_string_parser then
    return nil
  end

  local ok_parser, parser = pcall(vim.treesitter.get_string_parser, content, language)
  if not ok_parser or not parser then
    return nil
  end

  local ok_tree, trees = pcall(parser.parse, parser)
  if not ok_tree or not trees or not trees[1] then
    return nil
  end

  local root = trees[1]:root()
  if not root then return nil end

  return function(row, col)
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

return M
