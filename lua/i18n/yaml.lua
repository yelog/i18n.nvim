local M = {}

local escapes = {
  ['0'] = '\0', a = '\a', b = '\b', t = '\t', n = '\n',
  v = '\v', f = '\f', r = '\r', e = '\27',
  [' '] = ' ', ['\t'] = '\t', ['"'] = '"', ['/'] = '/', ['\\'] = '\\',
  N = '\194\133', ['_'] = '\194\160', L = '\226\128\168', P = '\226\128\169',
}

local function decode_flow(text, quote)
  if quote then text = text:sub(2, -2) end
  local result = {}
  local whitespace = ''
  local index = 1
  local function append(value)
    if whitespace ~= '' then table.insert(result, whitespace) end
    table.insert(result, value)
    whitespace = ''
  end

  while index <= #text do
    local char = text:sub(index, index)
    local next_char = text:sub(index + 1, index + 1)
    local escaped_break = quote == '"' and char == '\\' and next_char == '\n'
    if char == '\n' or escaped_break then
      if escaped_break then append('') else whitespace = '' end
      index = index + (escaped_break and 2 or 1)
      local breaks = 1
      while index <= #text do
        local continuation = text:sub(index, index)
        if continuation == '\n' then
          breaks = breaks + 1
        elseif continuation ~= ' ' and continuation ~= '\t' then
          break
        end
        index = index + 1
      end
      table.insert(result, breaks > 1 and string.rep('\n', breaks - 1) or (escaped_break and '' or ' '))
    elseif char == ' ' or char == '\t' then
      whitespace = whitespace .. char
      index = index + 1
    elseif quote == '"' and char == '\\' then
      local digits = ({ x = 2, u = 4, U = 8 })[next_char]
      if digits then
        local hex = text:sub(index + 2, index + digits + 1)
        local codepoint = #hex == digits and hex:match('^%x+$') and tonumber(hex, 16) or nil
        if not codepoint or codepoint > 0x10FFFF or (codepoint >= 0xD800 and codepoint <= 0xDFFF) then
          return nil
        end
        append(codepoint == 0 and '\0' or vim.fn.nr2char(codepoint))
        index = index + digits + 2
      else
        if not escapes[next_char] then return nil end
        append(escapes[next_char])
        index = index + 2
      end
    elseif quote == "'" and char == "'" and next_char == "'" then
      append("'")
      index = index + 2
    else
      append(char)
      index = index + 1
    end
  end
  append('')
  return table.concat(result)
end

local function fold_block(lines)
  local result = {}
  for index, line in ipairs(lines) do
    table.insert(result, line)
    if index < #lines then
      local following = lines[index + 1]
      local separator = '\n'
      if line ~= '' and not line:match('^[ \t]') then
        if following ~= '' and not following:match('^[ \t]') then
          separator = ' '
        elseif following == '' then
          local next_index = index + 2
          while next_index <= #lines and lines[next_index] == '' do
            next_index = next_index + 1
          end
          if next_index <= #lines and not lines[next_index]:match('^[ \t]') then
            separator = ''
          end
        end
      end
      table.insert(result, separator)
    end
  end
  return table.concat(result)
end

local function decode_block(node, content, source_lines)
  local text = vim.treesitter.get_node_text(node, content)
  local end_row, end_col = node:end_()
  -- The grammar can omit trailing blank lines, including before a comment.
  local remainder = source_lines[end_row + 1]:sub(end_col + 1)
  if remainder:match('^ *$') then
    local trailing = { text, remainder }
    while source_lines[end_row + 2] ~= nil do
      table.insert(trailing, '\n')
      end_row = end_row + 1
      local line = source_lines[end_row + 1]
      if not line:match('^ *$') then break end
      table.insert(trailing, line)
    end
    text = table.concat(trailing)
  end
  local header, body = text:match('^([^\n]*)\n(.*)$')
  if not body then return '' end
  local indicators = header:match('^[|>]([1-9+-]*)') or ''
  local lines = vim.split(body, '\n', { plain = true })
  local row = node:start()
  local parent_indent = #(source_lines[row + 1]:match('^ *'))
  local explicit_indent = tonumber(indicators:match('[1-9]'))
  local indent = explicit_indent and parent_indent + explicit_indent or nil
  if not indent then
    indent = 0
    for _, line in ipairs(lines) do
      local width = #(line:match('^ *'))
      if line:find('[^ ]') then
        indent = width
        break
      end
      indent = math.max(indent, width)
    end
  end
  for index, line in ipairs(lines) do
    lines[index] = line:sub(indent + 1)
  end

  local value = header:sub(1, 1) == '>' and fold_block(lines) or table.concat(lines, '\n')
  if indicators:find('+', 1, true) then return value end
  local stripped = value:gsub('\n+$', '')
  if not indicators:find('-', 1, true) and stripped ~= '' and value:sub(-1) == '\n' then
    return stripped .. '\n'
  end
  return stripped
end

local function unwrap(node)
  while node and (node:type() == 'flow_node' or node:type() == 'block_node') do
    local value
    for child in node:iter_children() do
      local kind = child:type()
      if kind == 'tag' then return nil end
      if child:named() and kind ~= 'anchor' and kind ~= 'comment' then value = child end
    end
    node = value
  end
  return node
end

M.parse = function(content, root)
  if root:has_error() then return nil end
  local result, line_map, col_map = {}, {}, {}
  local source_lines = vim.split(content, '\n', { plain = true })
  local invalid_scalar = false

  local function scalar(node)
    if not node then return nil end
    local kind = node:type()
    if kind == 'block_scalar' then return decode_block(node, content, source_lines) end
    if kind ~= 'plain_scalar' and kind ~= 'single_quote_scalar' and kind ~= 'double_quote_scalar' then
      return nil
    end
    local text = vim.treesitter.get_node_text(node, content)
    local quote = kind == 'single_quote_scalar' and "'" or (kind == 'double_quote_scalar' and '"' or nil)
    local value = decode_flow(text, quote)
    if value == nil then invalid_scalar = true end
    return value
  end

  local function traverse(node, prefix)
    node = unwrap(node)
    if not node then return end
    local kind = node:type()
    if kind == 'stream' or kind == 'document' then
      for child in node:iter_children() do traverse(child, prefix) end
    elseif kind == 'block_mapping' or kind == 'flow_mapping' then
      for pair in node:iter_children() do
        if pair:type() == 'block_mapping_pair' or pair:type() == 'flow_pair' then
          local key_node = unwrap(pair:field('key')[1])
          local key = key_node and key_node:type() ~= 'block_scalar' and scalar(key_node) or nil
          local value_node = unwrap(pair:field('value')[1])
          local is_merge = key == '<<' and key_node:type() == 'plain_scalar'
          if key and not is_merge and value_node then
            local full_key = prefix .. key
            local value_kind = value_node:type()
            if value_kind == 'block_mapping' or value_kind == 'flow_mapping' then
              traverse(value_node, full_key .. '.')
            else
              local value = scalar(value_node)
              if value ~= nil then
                result[full_key] = value
                local row, col = key_node:start()
                line_map[full_key] = row + 1
                col_map[full_key] = col + 1
              end
            end
          end
        end
      end
    end
  end

  traverse(root, '')
  if invalid_scalar then return nil end
  return result, line_map, col_map
end

return M
