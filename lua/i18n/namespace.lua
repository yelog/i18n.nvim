local M = {}

-- Cache: { [bufnr] = { tick = N, scopes = { [start_line] = { namespace = string, end_line = N } } } }
M._cache = {}

-- Resolver registry
M._resolvers = {}

-- Helper: get Tree-sitter node text
local function get_node_text(node, bufnr)
  if not node then return nil end
  local ts = vim.treesitter
  if ts.get_node_text then
    return ts.get_node_text(node, bufnr)
  elseif vim.treesitter.query and vim.treesitter.query.get_node_text then
    return vim.treesitter.query.get_node_text(node, bufnr)
  end
  -- Fallback for older Neovim versions
  local start_row, start_col, end_row, end_col = node:range()
  local lines = vim.api.nvim_buf_get_lines(bufnr, start_row, end_row + 1, false)
  if #lines == 0 then return nil end
  if #lines == 1 then
    return lines[1]:sub(start_col + 1, end_col)
  end
  lines[1] = lines[1]:sub(start_col + 1)
  lines[#lines] = lines[#lines]:sub(1, end_col)
  return table.concat(lines, '\n')
end

-- Helper: strip quotes from string
local function strip_quotes(str)
  if not str or #str < 2 then return str end
  local first = str:sub(1, 1)
  local last = str:sub(-1)
  if (first == '"' or first == "'" or first == '`') and first == last then
    return str:sub(2, -2)
  end
  return str
end

-- Helper: find enclosing function scope for a position
local function find_enclosing_scope(root, row, col)
  if not root then return nil end

  local node = root:named_descendant_for_range(row, col, row, col)
  if not node then return nil end

  -- Walk up to find function/arrow function/method scope
  local scope_types = {
    function_declaration = true,
    function_expression = true,
    arrow_function = true,
    method_definition = true,
    -- React component patterns
    variable_declarator = true,
    lexical_declaration = true,
  }

  while node do
    local ntype = node:type()
    if scope_types[ntype] then
      return node
    end
    node = node:parent()
  end

  return root
end

-- Helper: find useTranslation calls in a scope
local function find_use_translation_in_scope(scope_node, bufnr)
  if not scope_node then return nil end

  local namespaces = {}

  -- Iterate through all descendants looking for useTranslation calls
  local function traverse(node)
    if not node then return end

    local ntype = node:type()

    -- Look for call_expression with useTranslation
    if ntype == 'call_expression' then
      local func_node = node:field('function')[1]
      if func_node then
        local func_text = get_node_text(func_node, bufnr)
        if func_text == 'useTranslation' then
          -- Get arguments
          local args_node = node:field('arguments')[1]
          if args_node then
            -- First argument is the namespace (string or array)
            for child in args_node:iter_children() do
              local child_type = child:type()
              if child_type == 'string' then
                local ns = strip_quotes(get_node_text(child, bufnr))
                if ns and ns ~= '' then
                  table.insert(namespaces, ns)
                end
                break
              elseif child_type == 'array' then
                -- Handle array of namespaces: useTranslation(['ns1', 'ns2'])
                -- Use the first namespace
                for array_child in child:iter_children() do
                  if array_child:type() == 'string' then
                    local ns = strip_quotes(get_node_text(array_child, bufnr))
                    if ns and ns ~= '' then
                      table.insert(namespaces, ns)
                    end
                    break
                  end
                end
                break
              end
            end
          end
        end
      end
    end

    -- Recurse into children
    for child in node:iter_children() do
      traverse(child)
    end
  end

  traverse(scope_node)

  return namespaces[1] -- Return first found namespace
end

-- Helper: find useI18n calls in Vue setup (for vue-i18n)
local function find_use_i18n_in_scope(scope_node, bufnr)
  if not scope_node then return nil end

  local function traverse(node)
    if not node then return nil end

    local ntype = node:type()

    -- Look for call_expression with useI18n
    if ntype == 'call_expression' then
      local func_node = node:field('function')[1]
      if func_node then
        local func_text = get_node_text(func_node, bufnr)
        if func_text == 'useI18n' then
          -- Get arguments (options object)
          local args_node = node:field('arguments')[1]
          if args_node then
            for child in args_node:iter_children() do
              if child:type() == 'object' then
                -- Look for messages or locale property that might indicate namespace
                -- Vue i18n typically doesn't use namespaces the same way
                -- But we can look for a custom namespace property
                for prop in child:iter_children() do
                  if prop:type() == 'pair' then
                    local key_node = prop:field('key')[1]
                    local value_node = prop:field('value')[1]
                    if key_node and value_node then
                      local key_text = get_node_text(key_node, bufnr)
                      if key_text == 'namespace' or key_text == 'ns' then
                        local ns = strip_quotes(get_node_text(value_node, bufnr))
                        if ns and ns ~= '' then
                          return ns
                        end
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end
    end

    -- Recurse into children
    for child in node:iter_children() do
      local result = traverse(child)
      if result then return result end
    end

    return nil
  end

  return traverse(scope_node)
end

-- React i18next resolver
M._resolvers.react_i18next = function(bufnr, key, line, col)
  if not vim.treesitter or not vim.treesitter.get_parser then
    return nil
  end

  local ok_parser, ts_parser = pcall(vim.treesitter.get_parser, bufnr)
  if not ok_parser or not ts_parser then
    return nil
  end

  local ok_tree, trees = pcall(ts_parser.parse, ts_parser)
  if not ok_tree or not trees or not trees[1] then
    return nil
  end

  local root = trees[1]:root()
  if not root then return nil end

  -- Find enclosing scope
  local scope = find_enclosing_scope(root, line - 1, col - 1)
  if not scope then return nil end

  -- Find useTranslation in that scope
  local namespace = find_use_translation_in_scope(scope, bufnr)

  return namespace
end

-- Vue i18n resolver
M._resolvers.vue_i18n = function(bufnr, key, line, col)
  if not vim.treesitter or not vim.treesitter.get_parser then
    return nil
  end

  local ok_parser, ts_parser = pcall(vim.treesitter.get_parser, bufnr)
  if not ok_parser or not ts_parser then
    return nil
  end

  local ok_tree, trees = pcall(ts_parser.parse, ts_parser)
  if not ok_tree or not trees or not trees[1] then
    return nil
  end

  local root = trees[1]:root()
  if not root then return nil end

  -- Find enclosing scope
  local scope = find_enclosing_scope(root, line - 1, col - 1)
  if not scope then return nil end

  -- Find useI18n in that scope
  local namespace = find_use_i18n_in_scope(scope, bufnr)

  return namespace
end

-- Auto resolver that detects framework based on filetype
M._resolvers.auto = function(bufnr, key, line, col)
  local ft = vim.bo[bufnr].filetype

  -- React filetypes
  if ft == 'typescriptreact' or ft == 'javascriptreact' or ft == 'tsx' or ft == 'jsx' then
    return M._resolvers.react_i18next(bufnr, key, line, col)
  end

  -- Vue filetype
  if ft == 'vue' then
    return M._resolvers.vue_i18n(bufnr, key, line, col)
  end

  -- JavaScript/TypeScript - try react_i18next as it's most common
  if ft == 'javascript' or ft == 'typescript' then
    return M._resolvers.react_i18next(bufnr, key, line, col)
  end

  return nil
end

-- Get resolver function from config
local function get_resolver(resolver_config, bufnr)
  if not resolver_config then
    return nil
  end

  -- String: built-in resolver name
  if type(resolver_config) == 'string' then
    return M._resolvers[resolver_config]
  end

  -- Function: custom resolver
  if type(resolver_config) == 'function' then
    return resolver_config
  end

  -- Table: per-filetype configuration
  if type(resolver_config) == 'table' then
    local ft = vim.bo[bufnr].filetype
    for _, entry in ipairs(resolver_config) do
      if entry.filetypes then
        for _, eft in ipairs(entry.filetypes) do
          if eft == ft then
            -- Entry matches current filetype
            if type(entry.resolver) == 'string' then
              return M._resolvers[entry.resolver]
            elseif type(entry.resolver) == 'function' then
              return entry.resolver
            end
          end
        end
      end
    end
  end

  return nil
end

-- Check cache validity
local function is_cache_valid(bufnr)
  local cache_entry = M._cache[bufnr]
  if not cache_entry then return false end

  local current_tick = vim.api.nvim_buf_get_changedtick(bufnr)
  return cache_entry.tick == current_tick
end

-- Get cached namespace for a position
local function get_cached_namespace(bufnr, line)
  local cache_entry = M._cache[bufnr]
  if not cache_entry or not cache_entry.scopes then return nil, false end

  -- Find the scope that contains this line
  for start_line, scope_data in pairs(cache_entry.scopes) do
    if line >= start_line and line <= scope_data.end_line then
      return scope_data.namespace, true
    end
  end

  return nil, false
end

-- Store namespace in cache
local function cache_namespace(bufnr, start_line, end_line, namespace)
  local current_tick = vim.api.nvim_buf_get_changedtick(bufnr)

  if not M._cache[bufnr] or M._cache[bufnr].tick ~= current_tick then
    M._cache[bufnr] = {
      tick = current_tick,
      scopes = {}
    }
  end

  M._cache[bufnr].scopes[start_line] = {
    namespace = namespace,
    end_line = end_line
  }
end

-- Main entry point: resolve namespace for a key
-- @param bufnr number - buffer number
-- @param key string - raw extracted key
-- @param line number - 1-based line number
-- @param col number - 1-based column
-- @return string - resolved key (with namespace prefix if found)
function M.resolve(bufnr, key, line, col)
  local config = require('i18n.config')
  local resolver_config = (config.options or {}).namespace_resolver

  -- Disabled by default
  if not resolver_config then
    return key
  end

  -- Check cache first
  if is_cache_valid(bufnr) then
    local cached_ns, found = get_cached_namespace(bufnr, line)
    if found then
      if cached_ns then
        local separator = (config.options or {}).namespace_separator or ':'
        return cached_ns .. separator .. key
      end
      return key
    end
  end

  -- Get appropriate resolver
  local resolver = get_resolver(resolver_config, bufnr)
  if not resolver then
    return key
  end

  -- Call resolver to get namespace
  local ok, namespace = pcall(resolver, bufnr, key, line, col)
  if not ok then
    -- Resolver failed, fallback to raw key
    return key
  end

  -- Cache the result (estimate scope as current line +/- 100 for simplicity)
  -- A more accurate implementation would track actual scope boundaries
  local scope_start = math.max(1, line - 100)
  local scope_end = line + 100
  cache_namespace(bufnr, scope_start, scope_end, namespace)

  if namespace then
    local separator = (config.options or {}).namespace_separator or ':'
    return namespace .. separator .. key
  end

  return key
end

-- Resolve namespace only (without appending to key)
-- @param bufnr number - buffer number
-- @param line number - 1-based line number
-- @param col number - 1-based column
-- @return string|nil - namespace or nil
function M.resolve_namespace_only(bufnr, line, col)
  local config = require('i18n.config')
  local resolver_config = (config.options or {}).namespace_resolver

  if not resolver_config then
    return nil
  end

  -- Check cache first
  if is_cache_valid(bufnr) then
    local cached_ns, found = get_cached_namespace(bufnr, line)
    if found then
      return cached_ns
    end
  end

  local resolver = get_resolver(resolver_config, bufnr)
  if not resolver then
    return nil
  end

  local ok, namespace = pcall(resolver, bufnr, '', line, col)
  if not ok then
    return nil
  end

  return namespace
end

-- Clear cache for a buffer
function M.clear_cache(bufnr)
  if bufnr then
    M._cache[bufnr] = nil
  else
    M._cache = {}
  end
end

-- Register a custom resolver
-- @param name string - resolver name
-- @param resolver function - resolver function(bufnr, key, line, col) -> namespace|nil
function M.register_resolver(name, resolver)
  if type(name) == 'string' and type(resolver) == 'function' then
    M._resolvers[name] = resolver
  end
end

return M
