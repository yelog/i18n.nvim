-- Auto-detect i18n sources from project directory structure
-- Scans for common locale directory patterns and generates sources config automatically

local M = {}

-- Default known locale codes
M.default_known_locales = {
  -- Simple codes
  'en', 'zh', 'fr', 'de', 'ja', 'ko', 'es', 'pt', 'ru', 'it', 'nl', 'pl', 'tr', 'ar', 'th', 'vi',
  -- Regional codes with hyphen
  'en-US', 'en-GB', 'en-AU', 'zh-CN', 'zh-TW', 'zh-HK', 'zh-Hans', 'zh-Hant',
  'pt-BR', 'pt-PT', 'es-ES', 'es-MX', 'fr-FR', 'fr-CA', 'de-DE', 'de-AT',
  -- Regional codes with underscore
  'en_US', 'en_GB', 'en_AU', 'zh_CN', 'zh_TW', 'zh_HK',
  'pt_BR', 'pt_PT', 'es_ES', 'es_MX', 'fr_FR', 'fr_CA', 'de_DE', 'de_AT',
}

-- Default locale directory names to search for
M.default_locale_dir_names = {
  'locales', 'locale', 'i18n', 'lang', 'langs', 'languages', 'translations', 'messages',
}

-- Default supported file extensions
M.default_extensions = {
  'json', 'ts', 'js', 'yaml', 'yml', 'properties',
}

-- Check if a name matches a known locale code
local function is_known_locale(name, known_locales)
  if not name then return false end
  local lower_name = name:lower()
  for _, loc in ipairs(known_locales) do
    if lower_name == loc:lower() then
      return true
    end
  end
  return false
end

-- Check if filename (without extension) matches a locale
local function extract_locale_from_filename(filename, known_locales)
  -- Remove extension
  local name = filename:match('^(.+)%.[^.]+$') or filename

  -- Direct match: en.json, zh.json
  if is_known_locale(name, known_locales) then
    return name
  end

  -- Suffix match: messages_en.json, common.en.json
  for _, loc in ipairs(known_locales) do
    local pattern1 = '[_.]' .. loc:lower() .. '$'
    local pattern2 = '^' .. loc:lower() .. '[_.]'
    if name:lower():match(pattern1) or name:lower():match(pattern2) then
      return loc
    end
  end

  return nil
end

-- Scan a directory and return entries
local function scan_directory(dir_path)
  local entries = {}
  local handle = vim.loop.fs_scandir(dir_path)
  if not handle then return entries end

  while true do
    local name, type = vim.loop.fs_scandir_next(handle)
    if not name then break end
    table.insert(entries, {
      name = name,
      type = type,
      path = dir_path .. '/' .. name,
    })
  end

  return entries
end

-- Check if path exists and is a directory
local function is_directory(path)
  local stat = vim.loop.fs_stat(path)
  return stat and stat.type == 'directory'
end

-- Check if path exists and is a file
local function is_file(path)
  local stat = vim.loop.fs_stat(path)
  return stat and stat.type == 'file'
end

-- Get file extension
local function get_extension(filename)
  return filename:match('%.([^.]+)$')
end

-- Check if extension is supported
local function is_supported_extension(filename, extensions)
  local ext = get_extension(filename)
  if not ext then return false end
  ext = ext:lower()
  for _, e in ipairs(extensions) do
    if ext == e:lower() then
      return true
    end
  end
  return false
end

-- Find all directories matching locale dir names recursively
local function find_locale_directories(root_dir, locale_dir_names, max_depth, current_depth)
  current_depth = current_depth or 0
  max_depth = max_depth or 5

  if current_depth > max_depth then return {} end
  if not is_directory(root_dir) then return {} end

  local results = {}
  local entries = scan_directory(root_dir)

  for _, entry in ipairs(entries) do
    if entry.type == 'directory' then
      -- Skip common non-source directories
      local skip_dirs = { 'node_modules', '.git', 'dist', 'build', '.next', '.nuxt', 'coverage', '__pycache__', '.cache' }
      local should_skip = false
      for _, skip in ipairs(skip_dirs) do
        if entry.name == skip then
          should_skip = true
          break
        end
      end

      if not should_skip then
        -- Check if this directory name matches a locale dir name
        local lower_name = entry.name:lower()
        for _, locale_dir_name in ipairs(locale_dir_names) do
          if lower_name == locale_dir_name:lower() then
            table.insert(results, {
              path = entry.path,
              name = entry.name,
              parent = root_dir,
            })
            break
          end
        end

        -- Recurse into subdirectories
        local sub_results = find_locale_directories(entry.path, locale_dir_names, max_depth, current_depth + 1)
        for _, r in ipairs(sub_results) do
          table.insert(results, r)
        end
      end
    end
  end

  return results
end

-- Analyze the structure of a locale directory
-- Returns: { type = "locale_as_dir"|"locale_as_file", detected_locales = {...}, has_modules = bool, sample_structure = {...} }
local function analyze_locale_directory(dir_path, known_locales, extensions)
  local entries = scan_directory(dir_path)
  if #entries == 0 then return nil end

  local locale_dirs = {}
  local locale_files = {}
  local other_dirs = {}
  local other_files = {}

  for _, entry in ipairs(entries) do
    if entry.type == 'directory' then
      if is_known_locale(entry.name, known_locales) then
        table.insert(locale_dirs, entry)
      else
        -- Check if it might be a "lang" subdirectory
        local lower_name = entry.name:lower()
        if lower_name == 'lang' or lower_name == 'langs' or lower_name == 'languages' then
          -- Recurse into this directory
          local sub_analysis = analyze_locale_directory(entry.path, known_locales, extensions)
          if sub_analysis then
            sub_analysis.has_lang_subdir = true
            sub_analysis.lang_subdir_name = entry.name
            return sub_analysis
          end
        end
        table.insert(other_dirs, entry)
      end
    elseif entry.type == 'file' then
      if is_supported_extension(entry.name, extensions) then
        local locale = extract_locale_from_filename(entry.name, known_locales)
        if locale then
          table.insert(locale_files, { entry = entry, locale = locale })
        else
          table.insert(other_files, entry)
        end
      end
    end
  end

  -- Determine structure type
  if #locale_dirs > 0 then
    -- Type: locale as directory (e.g., locales/en/, locales/zh/)
    local detected_locales = {}
    local has_modules = false
    local module_extension = nil

    for _, ld in ipairs(locale_dirs) do
      table.insert(detected_locales, ld.name)
      -- Check if locale dir contains module files
      local locale_entries = scan_directory(ld.path)
      for _, le in ipairs(locale_entries) do
        if le.type == 'file' and is_supported_extension(le.name, extensions) then
          has_modules = true
          module_extension = get_extension(le.name)
          break
        end
      end
    end

    return {
      type = 'locale_as_dir',
      detected_locales = detected_locales,
      has_modules = has_modules,
      module_extension = module_extension,
      sample_locale_dir = locale_dirs[1] and locale_dirs[1].path or nil,
    }
  elseif #locale_files > 0 then
    -- Type: locale as file (e.g., locales/en.json, locales/zh.json)
    local detected_locales = {}
    local file_extension = nil

    for _, lf in ipairs(locale_files) do
      table.insert(detected_locales, lf.locale)
      file_extension = file_extension or get_extension(lf.entry.name)
    end

    return {
      type = 'locale_as_file',
      detected_locales = detected_locales,
      file_extension = file_extension,
    }
  end

  return nil
end

-- Generate source pattern and prefix from analyzed structure
local function generate_source_config(locale_dir_info, analysis, cwd)
  local dir_path = locale_dir_info.path
  local parent_path = locale_dir_info.parent

  -- Make path relative to cwd
  local relative_path = dir_path
  if cwd and dir_path:sub(1, #cwd) == cwd then
    relative_path = dir_path:sub(#cwd + 2)  -- +2 to skip the trailing /
  end
  -- Remove leading './' if present
  relative_path = relative_path:gsub('^%./', '')

  -- Analyze parent path to extract variables (like {bu} for business unit)
  local parent_relative = parent_path
  if cwd and parent_path:sub(1, #cwd) == cwd then
    parent_relative = parent_path:sub(#cwd + 2)
  end
  -- Remove leading './' if present
  parent_relative = parent_relative:gsub('^%./', '')

  -- Check if parent path contains variable segments
  -- e.g., src/views/gmail/locales -> {bu} = gmail
  local path_variables = {}
  local pattern_path = relative_path
  local prefix_parts = {}

  -- Find variable segments by looking for non-standard directory names
  -- between known anchors (src, views, locales, etc.)
  local known_anchors = { 'src', 'source', 'app', 'lib', 'views', 'pages', 'components', 'modules', 'features', 'packages' }
  local segments = {}
  for seg in parent_relative:gmatch('[^/]+') do
    -- Skip '.' and empty segments
    if seg ~= '.' and seg ~= '' then
      table.insert(segments, seg)
    end
  end

  -- Identify variable segments
  -- Only segments AFTER the first anchor should be considered as variables
  -- This prevents top-level directories (like 'playground', 'examples') from being treated as variables
  local variable_names = { 'bu', 'business', 'module', 'feature', 'component', 'domain', 'area' }
  local var_index = 1
  local new_segments = {}
  local found_first_anchor = false

  for i, seg in ipairs(segments) do
    local is_anchor = false
    local lower_seg = seg:lower()
    for _, anchor in ipairs(known_anchors) do
      if lower_seg == anchor then
        is_anchor = true
        break
      end
    end
    for _, locale_name in ipairs(M.default_locale_dir_names) do
      if lower_seg == locale_name:lower() then
        is_anchor = true
        break
      end
    end

    if is_anchor then
      found_first_anchor = true
      table.insert(new_segments, seg)
    elseif not found_first_anchor then
      -- Before first anchor: keep segment as-is (not a variable)
      table.insert(new_segments, seg)
    else
      -- After first anchor: this is likely a variable segment
      local var_name = variable_names[var_index] or ('var' .. var_index)
      var_index = var_index + 1
      table.insert(new_segments, '{' .. var_name .. '}')
      table.insert(path_variables, { name = var_name, value = seg, index = i })
      table.insert(prefix_parts, '{' .. var_name .. '}')
    end
  end

  -- Reconstruct pattern path
  if #new_segments > 0 then
    pattern_path = table.concat(new_segments, '/') .. '/' .. locale_dir_info.name
  end

  local source_config = {}

  if analysis.has_lang_subdir then
    pattern_path = pattern_path .. '/' .. analysis.lang_subdir_name
  end

  if analysis.type == 'locale_as_dir' then
    pattern_path = pattern_path .. '/{locales}'

    if analysis.has_modules then
      pattern_path = pattern_path .. '/{module}.' .. (analysis.module_extension or 'json')
      table.insert(prefix_parts, '{module}')
    else
      -- Single file per locale directory? Check for index file
      pattern_path = pattern_path .. '.' .. (analysis.module_extension or 'json')
    end
  elseif analysis.type == 'locale_as_file' then
    pattern_path = pattern_path .. '/{locales}.' .. (analysis.file_extension or 'json')
  end

  source_config.pattern = pattern_path

  -- Generate prefix if there are variables
  if #prefix_parts > 0 then
    source_config.prefix = table.concat(prefix_parts, '.') .. '.'
  end

  return source_config, analysis.detected_locales
end

-- Deduplicate and merge locale lists
local function merge_locales(locale_lists)
  local seen = {}
  local result = {}

  for _, list in ipairs(locale_lists) do
    for _, loc in ipairs(list) do
      if not seen[loc] then
        seen[loc] = true
        table.insert(result, loc)
      end
    end
  end

  -- Sort: prefer simple codes first, then regional
  table.sort(result, function(a, b)
    local a_simple = not a:find('[-_]')
    local b_simple = not b:find('[-_]')
    if a_simple ~= b_simple then
      return a_simple
    end
    return a < b
  end)

  return result
end

-- Deduplicate sources by pattern
local function deduplicate_sources(sources)
  local seen = {}
  local result = {}

  for _, src in ipairs(sources) do
    local key = type(src) == 'string' and src or src.pattern
    if key and not seen[key] then
      seen[key] = true
      table.insert(result, src)
    end
  end

  return result
end

-- Main function: auto-detect sources from project structure
-- @param opts table - options including known_locales, locale_dir_names, extensions, root_dirs
-- @return sources table, locales table
function M.detect(opts)
  opts = opts or {}

  local cwd = vim.fn.getcwd()
  local root_dirs = opts.root_dirs or { '.' }
  local locale_dir_names = opts.locale_dir_names or M.default_locale_dir_names
  local known_locales = opts.known_locales or M.default_known_locales
  local extensions = opts.extensions or M.default_extensions
  local max_depth = opts.max_depth or 6

  local all_sources = {}
  local all_locales = {}

  -- Search each root directory
  for _, root in ipairs(root_dirs) do
    local root_path = root
    if not root:match('^/') then
      root_path = cwd .. '/' .. root
    end

    if is_directory(root_path) then
      -- Find all locale directories
      local locale_dirs = find_locale_directories(root_path, locale_dir_names, max_depth)

      for _, locale_dir_info in ipairs(locale_dirs) do
        -- Analyze each locale directory
        local analysis = analyze_locale_directory(locale_dir_info.path, known_locales, extensions)

        if analysis and analysis.detected_locales and #analysis.detected_locales > 0 then
          -- Generate source config
          local source_config, detected = generate_source_config(locale_dir_info, analysis, cwd)

          if source_config and source_config.pattern then
            table.insert(all_sources, source_config.prefix and source_config or source_config.pattern)
            table.insert(all_locales, detected)
          end
        end
      end
    end
  end

  -- Deduplicate and merge results
  local sources = deduplicate_sources(all_sources)
  local locales = merge_locales(all_locales)

  return sources, locales
end

-- Check if auto-detect should run (no sources configured or explicitly enabled)
function M.should_auto_detect(config_opts)
  if not config_opts then return false end

  -- Project config sources take precedence
  if config_opts._project_config_sources then
    return false
  end

  -- Explicitly enabled (either true or { enabled = true })
  if config_opts.auto_detect == true then
    return true
  end
  if type(config_opts.auto_detect) == 'table' and config_opts.auto_detect.enabled then
    return true
  end

  -- Explicitly disabled
  if config_opts.auto_detect == false then
    return false
  end

  -- Auto-enable if no sources configured
  if not config_opts.sources or (type(config_opts.sources) == 'table' and #config_opts.sources == 0) then
    return true
  end

  return false
end

-- Debug function to show what would be detected
-- Call with: :lua require('i18n.auto_detect').debug()
-- Or with custom opts: :lua require('i18n.auto_detect').debug({ root_dirs = {'src'} })
function M.debug(custom_opts)
  local cwd = vim.fn.getcwd()
  print('=== i18n Auto-detect Debug ===')
  print('CWD: ' .. cwd)

  -- Try to get config from i18n if available
  local config_opts = {}
  local ok_config, config = pcall(require, 'i18n.config')
  if ok_config and config.options and config.options.auto_detect then
    local ad = config.options.auto_detect
    if type(ad) == 'table' then
      config_opts = ad
    end
  end

  local opts = {
    root_dirs = (custom_opts and custom_opts.root_dirs) or config_opts.root_dirs or { '.' },
    locale_dir_names = (custom_opts and custom_opts.locale_dir_names) or config_opts.locale_dir_names or M.default_locale_dir_names,
    known_locales = (custom_opts and custom_opts.known_locales) or config_opts.known_locales or M.default_known_locales,
    extensions = (custom_opts and custom_opts.extensions) or config_opts.extensions or M.default_extensions,
    max_depth = (custom_opts and custom_opts.max_depth) or config_opts.max_depth or 6,
  }

  print('\nUsing options:')
  print('  root_dirs: ' .. vim.inspect(opts.root_dirs))
  print('  locale_dir_names: ' .. vim.inspect(opts.locale_dir_names))
  print('  extensions: ' .. vim.inspect(opts.extensions))
  print('  max_depth: ' .. opts.max_depth)

  print('\nSearching for locale directories...')

  for _, root in ipairs(opts.root_dirs) do
    local root_path = root
    if not root:match('^/') then
      root_path = cwd .. '/' .. root
    end

    print('\nChecking root: ' .. root_path .. ' (exists: ' .. tostring(is_directory(root_path)) .. ')')

    if is_directory(root_path) then
      local locale_dirs = find_locale_directories(root_path, opts.locale_dir_names, opts.max_depth)
      print('  Found ' .. #locale_dirs .. ' locale director(ies)')

      for _, locale_dir_info in ipairs(locale_dirs) do
        print('\n  Locale dir: ' .. locale_dir_info.path)
        print('    name: ' .. locale_dir_info.name)
        print('    parent: ' .. locale_dir_info.parent)

        -- List contents of this directory
        local contents = scan_directory(locale_dir_info.path)
        print('    contents: ' .. #contents .. ' items')
        for _, item in ipairs(contents) do
          print('      - ' .. item.name .. ' (' .. item.type .. ')')
        end

        local analysis = analyze_locale_directory(locale_dir_info.path, opts.known_locales, opts.extensions)
        if analysis then
          print('    Analysis result:')
          print('      type: ' .. (analysis.type or 'unknown'))
          print('      detected_locales: ' .. vim.inspect(analysis.detected_locales or {}))
          print('      has_modules: ' .. tostring(analysis.has_modules))
          print('      has_lang_subdir: ' .. tostring(analysis.has_lang_subdir))
          if analysis.lang_subdir_name then
            print('      lang_subdir_name: ' .. analysis.lang_subdir_name)
          end
          if analysis.module_extension then
            print('      module_extension: ' .. analysis.module_extension)
          end

          local source_config, detected = generate_source_config(locale_dir_info, analysis, cwd)
          print('    Generated config:')
          print('      pattern: ' .. (source_config.pattern or 'nil'))
          print('      prefix: ' .. (source_config.prefix or '(none)'))
        else
          print('    Analysis: FAILED (no valid structure found)')

          -- Additional debug: check what's inside
          local entries = scan_directory(locale_dir_info.path)
          print('    Directory contents for debug:')
          for _, e in ipairs(entries) do
            if e.type == 'directory' then
              local is_locale = is_known_locale(e.name, opts.known_locales)
              local is_lang = e.name:lower() == 'lang' or e.name:lower() == 'langs' or e.name:lower() == 'languages'
              print('      [DIR] ' .. e.name .. ' (is_locale: ' .. tostring(is_locale) .. ', is_lang_subdir: ' .. tostring(is_lang) .. ')')
            else
              print('      [FILE] ' .. e.name)
            end
          end
        end
      end
    end
  end

  print('\n=== Running full detection ===')
  local sources, locales = M.detect(opts)
  print('Detected ' .. #sources .. ' source(s):')
  for i, src in ipairs(sources) do
    if type(src) == 'string' then
      print('  ' .. i .. '. ' .. src)
    else
      print('  ' .. i .. '. pattern: ' .. (src.pattern or 'nil') .. ', prefix: ' .. (src.prefix or '(none)'))
    end
  end
  print('Detected ' .. #locales .. ' locale(s): ' .. table.concat(locales, ', '))
end

-- Get auto-detect options from config
function M.get_options(config_opts)
  local auto_detect = config_opts and config_opts.auto_detect
  if type(auto_detect) ~= 'table' then
    auto_detect = {}
  end

  return {
    root_dirs = auto_detect.root_dirs,
    locale_dir_names = auto_detect.locale_dir_names,
    known_locales = auto_detect.known_locales,
    extensions = auto_detect.extensions,
    max_depth = auto_detect.max_depth,
  }
end

return M
