local M = {}

local function realpath(path)
  return vim.loop.fs_realpath(path) or path
end

local function read_file(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  return ok and table.concat(lines, '\n') or nil
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
    local indent, name = line:match('^(%s*)([%w%-_]+):%s*$')
    if name == 'spring' then
      spring_indent, messages_indent = #indent, nil
    elseif name == 'messages' and spring_indent and #indent > spring_indent then
      messages_indent = #indent
    elseif messages_indent and #indent > messages_indent then
      local value = line:match('^%s*basename:%s*[\'"]?(.-)[\'"]?%s*$')
      if value then
        local result = {}
        for basename in value:gmatch('[^,]+') do
          basename = basename:match('^%s*(.-)%s*$')
          if basename ~= '' then table.insert(result, basename) end
        end
        return result
      end
    elseif indent and #indent <= (spring_indent or 0) then
      spring_indent, messages_indent = nil, nil
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
  local descriptors, locale_set = {}, {}
  for _, pom in ipairs(vim.fn.globpath(vim.fn.getcwd(), '**/pom.xml', false, true)) do
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
  return descriptors, locales
end

return M
