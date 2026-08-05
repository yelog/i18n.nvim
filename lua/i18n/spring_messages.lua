local M = {}

local excluded_dirs = {
  ['.git'] = true,
  node_modules = true,
  target = true,
}

local discovery_cache = {}
local cache_clear_scheduled = false

local function realpath(path)
  return vim.loop.fs_realpath(path) or path
end

local function read_file(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  return ok and table.concat(lines, '\n') or nil
end

local function is_absolute(path)
  return path:match('^/') ~= nil or path:match('^%a:[/\\]') ~= nil
end

local function is_excluded(path)
  for part in path:gsub('\\', '/'):gmatch('[^/]+') do
    if excluded_dirs[part] then return true end
  end
  return false
end

local function normalize_pom_files(root, paths)
  local files, seen = {}, {}
  root = realpath(root)
  for _, path in ipairs(paths or {}) do
    if type(path) == 'string' and path ~= '' then
      local abs = is_absolute(path) and path or (root .. '/' .. path)
      abs = realpath(abs)
      local relative = abs:sub(1, #root + 1) == root .. '/' and abs:sub(#root + 2) or path
      if not is_excluded(relative) and not seen[abs] then
        seen[abs] = true
        table.insert(files, abs)
      end
    end
  end
  table.sort(files)
  return files
end

local function find_poms_with_rg(root)
  if vim.fn.executable('rg') ~= 1 then return nil end
  local output = vim.fn.systemlist({
    'rg', '--files', '--hidden',
    '-g', 'pom.xml',
    '-g', '!.git',
    '-g', '!node_modules',
    '-g', '!target',
    root,
  })
  if vim.v.shell_error > 1 then return nil end
  return normalize_pom_files(root, output)
end

local function find_poms_with_git(root)
  if vim.fn.executable('git') ~= 1 then return nil end
  local output = vim.fn.systemlist({
    'git', '-C', root, 'ls-files', '--cached', '--others', '--exclude-standard',
    '--', 'pom.xml', '**/pom.xml',
  })
  if vim.v.shell_error ~= 0 then return nil end
  return normalize_pom_files(root, output)
end

local function find_poms_with_lua(root)
  local files = {}
  local function scan(dir)
    local handle = vim.loop.fs_scandir(dir)
    if not handle then return end
    while true do
      local name, entry_type = vim.loop.fs_scandir_next(handle)
      if not name then break end
      local path = dir .. '/' .. name
      if entry_type == 'directory' and not excluded_dirs[name] then
        scan(path)
      elseif entry_type == 'file' and name == 'pom.xml' then
        table.insert(files, path)
      end
    end
  end
  scan(root)
  return normalize_pom_files(root, files)
end

local function find_pom_files(root)
  return find_poms_with_rg(root) or find_poms_with_git(root) or find_poms_with_lua(root)
end

local function copy_list(items)
  local result = {}
  for _, item in ipairs(items or {}) do
    if type(item) == 'table' then
      local copy = {}
      for key, value in pairs(item) do copy[key] = value end
      table.insert(result, copy)
    else
      table.insert(result, item)
    end
  end
  return result
end

local function cache_result(key, descriptors, locales)
  discovery_cache[key] = {
    descriptors = copy_list(descriptors),
    locales = copy_list(locales),
  }
  if cache_clear_scheduled then return end
  cache_clear_scheduled = true
  vim.schedule(function()
    discovery_cache = {}
    cache_clear_scheduled = false
  end)
end

local function is_spring_project(root)
  local current = root
  local cwd = realpath(vim.fn.getcwd())
  while current and current ~= '' do
    local pom = current .. '/pom.xml'
    local content = read_file(pom)
    if content and (content:find('org%.springframework') or content:find('spring%-boot')) then
      return true
    end
    if current == cwd or current == '/' then break end
    local parent = vim.fn.fnamemodify(current, ':h')
    if parent == current then break end
    current = parent
  end
  return false
end

local function property_basenames(content)
  local value = content:match('\nspring%.messages%.basename%s*[:=]%s*([^\r\n]+)')
    or content:match('^spring%.messages%.basename%s*[:=]%s*([^\r\n]+)')
  if not value then return nil end
  local result = {}
  for basename in value:gmatch('[^,]+') do
    basename = basename:match('^%s*(.-)%s*$')
    if basename ~= '' then table.insert(result, basename) end
  end
  return result
end

local function yaml_basenames(content)
  local spring_indent, messages_indent
  for line in content:gmatch('[^\r\n]+') do
    local indent = line:match('^(%s*)')
    local name = line:match('^%s*([%w%-_]+):%s*$')
    if name == 'spring' then
      spring_indent, messages_indent = #indent, nil
    elseif spring_indent and #indent <= spring_indent then
      spring_indent, messages_indent = nil, nil
    elseif name == 'messages' and spring_indent and #indent > spring_indent then
      messages_indent = #indent
    elseif messages_indent and #indent <= messages_indent then
      messages_indent = nil
    elseif messages_indent then
      local value = line:match('^%s*basename:%s*(.-)%s*$')
      if value then
        value = value:match('^%s*(.-)%s*$')
        if value:sub(1, 1) == "'" then
          value = value:match("^'(.*)'%s+#.*$") or value:match("^'(.*)'$") or value
        elseif value:sub(1, 1) == '"' then
          value = value:match('^"(.*)"%s+#.*$') or value:match('^"(.*)"$') or value
        else
          value = value:match('^(.-)%s+#.*$') or value
        end
        local result = {}
        for basename in value:gmatch('[^,]+') do
          basename = basename:match('^%s*(.-)%s*$')
          if basename ~= '' then table.insert(result, basename) end
        end
        return result
      end
    end
  end
  return nil
end

local function configured_basenames(resource_root)
  local names = { 'application.properties', 'bootstrap.properties', 'application.yml', 'application.yaml', 'bootstrap.yml', 'bootstrap.yaml' }
  for _, name in ipairs(names) do
    local content = read_file(resource_root .. '/' .. name)
    if content then
      local basenames = name:match('%.properties$') and property_basenames(content) or yaml_basenames(content)
      if basenames and #basenames > 0 then return basenames end
    end
  end
  return { 'messages' }
end

local function bundle_descriptors(module_root, basenames, resource_root)
  local descriptors, locales = {}, {}
  for priority, basename in ipairs(basenames) do
    local pattern = resource_root .. '/' .. basename .. '*.properties'
    for _, path in ipairs(vim.fn.glob(pattern, false, true)) do
      local stem = path:sub(1, -12)
      local base = resource_root .. '/' .. basename
      local suffix = stem:sub(#base + 1)
      if stem == base or suffix:match('^_[%w_%-]+$') then
        local locale = suffix == '' and '__default' or suffix:sub(2)
        table.insert(descriptors, { path = realpath(path), locale = locale, module_root = module_root, priority = priority })
        if locale ~= '__default' then locales[locale] = true end
      end
    end
  end
  return descriptors, locales
end

local function inferred_bundle_descriptors(module_root, resource_root)
  local by_basename = {}
  for _, path in ipairs(vim.fn.glob(resource_root .. '/**/messages*.properties', false, true)) do
    local filename = vim.fn.fnamemodify(path, ':t:r')
    local base_name, locale = filename:match('^(.-)_([a-z][a-z][a-z]*[_-][A-Za-z][A-Za-z0-9]*)$')
    if not base_name then
      base_name, locale = filename:match('^(.-)_([a-z][a-z][a-z]*)$')
    end
    local basename = vim.fn.fnamemodify(path, ':h') .. '/' .. (base_name or filename)
    local suffix = locale and ('_' .. locale) or ''
    if suffix == '' or suffix:match('^_[%w_%-]+$') then
      by_basename[basename] = by_basename[basename] or {}
      table.insert(by_basename[basename], path)
    end
  end
  local descriptors, locales, priority = {}, {}, 0
  for basename, paths in pairs(by_basename) do
    priority = priority + 1
    for _, path in ipairs(paths) do
      local filename = vim.fn.fnamemodify(path, ':t:r')
      local base_name = vim.fn.fnamemodify(basename, ':t')
      local suffix = filename:sub(#base_name + 1)
      local locale = suffix == '' and '__default' or suffix:sub(2)
      table.insert(descriptors, { path = realpath(path), locale = locale, module_root = module_root, priority = priority })
      if locale ~= '__default' then locales[locale] = true end
    end
  end
  return descriptors, locales
end

function M.discover(options, require_spring)
  local spring_opts = ((options.message_source or {}).spring_messages) or {}
  local resource_dir = spring_opts.resource_root or 'src/main/resources'
  local root = realpath(vim.fn.getcwd())
  local cache_key = table.concat({ root, resource_dir, tostring(require_spring == true) }, '\n')
  local cached = discovery_cache[cache_key]
  if cached then
    return copy_list(cached.descriptors), copy_list(cached.locales)
  end
  local descriptors, locale_set = {}, {}
  for _, pom in ipairs(find_pom_files(root)) do
    local module_root = realpath(vim.fn.fnamemodify(pom, ':h'))
    if not module_root:find('/target/', 1, true) and (not require_spring or is_spring_project(module_root)) then
      local resource_root = module_root .. '/' .. resource_dir
      if vim.fn.isdirectory(resource_root) == 1 then
        local found, locales = bundle_descriptors(module_root, configured_basenames(resource_root), resource_root)
        if #found == 0 then
          found, locales = inferred_bundle_descriptors(module_root, resource_root)
        end
        vim.list_extend(descriptors, found)
        for locale in pairs(locales) do locale_set[locale] = true end
      end
    end
  end
  table.sort(descriptors, function(a, b)
    if a.module_root == b.module_root then return a.priority < b.priority end
    return a.module_root < b.module_root
  end)
  local locales = {}
  for locale in pairs(locale_set) do table.insert(locales, locale) end
  table.sort(locales)
  cache_result(cache_key, descriptors, locales)
  return copy_list(descriptors), copy_list(locales)
end

return M
