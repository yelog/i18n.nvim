-- Framework detection for i18n projects
-- Detects i18n frameworks from package.json dependencies and config files

local M = {}

-- Framework definitions with detection rules and default configurations
M.frameworks = {
  ['vue-i18n'] = {
    name = 'vue-i18n',
    display_name = 'Vue I18n',
    -- package.json dependency names
    packages = { 'vue-i18n', '@intlify/vue-i18n' },
    -- Config files that indicate this framework
    config_files = { 'vue.config.js', 'vue.config.ts', 'vite.config.ts', 'vite.config.js' },
    -- Root pattern files (for project detection)
    root_patterns = { 'vue.config.js', 'vue.config.ts', 'src/App.vue' },
    -- Default func_pattern for this framework
    func_pattern = { 't', '$t', 'tc', '$tc', 'd', '$d', 'n', '$n' },
    -- Default filetypes to scan
    func_type = { 'vue', 'typescript', 'javascript', 'tsx', 'jsx' },
    -- Namespace resolver
    namespace_resolver = 'vue_i18n',
  },

  ['react-i18next'] = {
    name = 'react-i18next',
    display_name = 'React i18next',
    packages = { 'react-i18next', 'i18next' },
    config_files = { 'i18next.config.js', 'i18next.config.ts', 'i18n.js', 'i18n.ts', 'i18n/index.ts', 'i18n/index.js' },
    root_patterns = { 'src/App.tsx', 'src/App.jsx', 'src/index.tsx', 'src/index.jsx' },
    func_pattern = { 't', 'i18n.t' },
    func_type = { 'typescriptreact', 'javascriptreact', 'typescript', 'javascript', 'tsx', 'jsx' },
    namespace_resolver = 'react_i18next',
  },

  ['next-intl'] = {
    name = 'next-intl',
    display_name = 'Next Intl',
    packages = { 'next-intl' },
    config_files = { 'next.config.js', 'next.config.mjs', 'next.config.ts' },
    root_patterns = { 'next.config.js', 'next.config.mjs', 'next.config.ts', 'app/layout.tsx', 'pages/_app.tsx' },
    func_pattern = { 't', 'useTranslations' },
    func_type = { 'typescriptreact', 'javascriptreact', 'typescript', 'javascript', 'tsx', 'jsx' },
    namespace_resolver = 'react_i18next',
  },

  ['nuxt-i18n'] = {
    name = 'nuxt-i18n',
    display_name = 'Nuxt I18n',
    packages = { '@nuxtjs/i18n', 'nuxt-i18n' },
    config_files = { 'nuxt.config.js', 'nuxt.config.ts' },
    root_patterns = { 'nuxt.config.js', 'nuxt.config.ts', 'app.vue' },
    func_pattern = { 't', '$t', 'tc', '$tc' },
    func_type = { 'vue', 'typescript', 'javascript' },
    namespace_resolver = 'vue_i18n',
  },

  ['react-intl'] = {
    name = 'react-intl',
    display_name = 'React Intl (FormatJS)',
    packages = { 'react-intl', '@formatjs/intl' },
    config_files = {},
    root_patterns = { 'src/App.tsx', 'src/App.jsx' },
    func_pattern = {
      { call = 'formatMessage', argument_pattern = "%(%%s*{%%s*id%%s*:%%s*['\"]([^'\"]+)['\"]" },
      { call = 'intl.formatMessage', argument_pattern = "%(%%s*{%%s*id%%s*:%%s*['\"]([^'\"]+)['\"]" },
      'FormattedMessage',
    },
    func_type = { 'typescriptreact', 'javascriptreact', 'typescript', 'javascript', 'tsx', 'jsx' },
    namespace_resolver = false,
  },

  ['i18next'] = {
    name = 'i18next',
    display_name = 'i18next (Generic)',
    packages = { 'i18next' },
    config_files = { 'i18next.config.js', 'i18next.config.ts' },
    root_patterns = {},
    func_pattern = { 't', 'i18n.t' },
    func_type = { 'typescript', 'javascript', 'typescriptreact', 'javascriptreact' },
    namespace_resolver = 'auto',
    -- Lower priority - only match if no other framework matches
    priority = -1,
  },

  -- Java Spring MessageSource
  ['spring-messages'] = {
    name = 'spring-messages',
    display_name = 'Spring MessageSource',
    packages = {},
    config_files = { 'pom.xml', 'build.gradle', 'build.gradle.kts' },
    root_patterns = { 'pom.xml', 'build.gradle', 'src/main/java' },
    -- Look for messages*.properties files
    source_patterns = { 'src/main/resources/messages*.properties', 'src/main/resources/i18n/*.properties' },
    func_pattern = {
      { call = 'getMessage', quotes = { '"', "'" } },
      { call = 'messageSource.getMessage', quotes = { '"', "'" } },
    },
    func_type = { 'java' },
    namespace_resolver = false,
  },
}

-- Cache for detection results
M._cache = {
  cwd = nil,
  result = nil,
  timestamp = 0,
}

-- Cache TTL in seconds
local CACHE_TTL = 60

-- Read and parse package.json
local function read_package_json(cwd)
  local path = cwd .. '/package.json'
  if vim.fn.filereadable(path) ~= 1 then
    return nil
  end

  local ok, content = pcall(vim.fn.readfile, path)
  if not ok or not content or #content == 0 then
    return nil
  end

  local json_str = table.concat(content, '\n')
  local ok_decode, data = pcall(vim.json.decode, json_str)
  if not ok_decode or type(data) ~= 'table' then
    return nil
  end

  return data
end

-- Check if any of the packages exist in dependencies
local function has_package(pkg_json, packages)
  if not pkg_json then return false end

  local deps = pkg_json.dependencies or {}
  local dev_deps = pkg_json.devDependencies or {}

  for _, pkg in ipairs(packages) do
    if deps[pkg] or dev_deps[pkg] then
      return true
    end
  end

  return false
end

-- Check if any config file exists
local function has_config_file(cwd, config_files)
  for _, file in ipairs(config_files or {}) do
    local path = cwd .. '/' .. file
    if vim.fn.filereadable(path) == 1 then
      return true, file
    end
  end
  return false, nil
end

-- Check if any root pattern file exists
local function has_root_pattern(cwd, root_patterns)
  for _, pattern in ipairs(root_patterns or {}) do
    local path = cwd .. '/' .. pattern
    if vim.fn.filereadable(path) == 1 or vim.fn.isdirectory(path) == 1 then
      return true
    end
  end
  return false
end

-- Detect framework from package.json and config files
function M.detect(opts)
  opts = opts or {}
  local cwd = opts.cwd or vim.fn.getcwd()

  -- Check cache
  local now = os.time()
  if M._cache.cwd == cwd and M._cache.result and (now - M._cache.timestamp) < CACHE_TTL then
    return M._cache.result
  end

  local result = {
    detected = false,
    framework = nil,
    frameworks = {},  -- All detected frameworks (may be multiple)
    is_i18n_project = false,
    config_file = nil,
    suggestions = {},
  }

  -- Read package.json
  local pkg_json = read_package_json(cwd)

  -- Check each framework
  local candidates = {}
  for name, fw in pairs(M.frameworks) do
    local score = fw.priority or 0
    local matched = false
    local match_reason = {}

    -- Check packages in package.json
    if has_package(pkg_json, fw.packages) then
      matched = true
      score = score + 10
      table.insert(match_reason, 'package.json')
    end

    -- Check config files
    local has_cfg, cfg_file = has_config_file(cwd, fw.config_files)
    if has_cfg then
      matched = true
      score = score + 5
      table.insert(match_reason, cfg_file)
      result.config_file = result.config_file or cfg_file
    end

    if matched then
      table.insert(candidates, {
        name = name,
        framework = fw,
        score = score,
        reasons = match_reason,
      })
    end
  end

  -- Sort by score (highest first)
  table.sort(candidates, function(a, b)
    return a.score > b.score
  end)

  -- Set results
  if #candidates > 0 then
    result.detected = true
    result.is_i18n_project = true
    result.framework = candidates[1].framework
    result.framework_name = candidates[1].name

    for _, c in ipairs(candidates) do
      table.insert(result.frameworks, {
        name = c.name,
        display_name = c.framework.display_name,
        reasons = c.reasons,
      })
    end

    -- Generate suggestions based on detected framework
    local fw = result.framework
    result.suggestions = {
      func_pattern = fw.func_pattern,
      func_type = fw.func_type,
      namespace_resolver = fw.namespace_resolver,
    }
  else
    -- No framework detected, but check if it might still be an i18n project
    -- by looking for common locale directories
    local auto_detect = require('i18n.auto_detect')
    local sources, locales = auto_detect.detect({ root_dirs = { '.' }, max_depth = 3 })
    if sources and #sources > 0 then
      result.is_i18n_project = true
      result.suggestions = {
        sources = sources,
        locales = locales,
      }
    end
  end

  -- Update cache
  M._cache = {
    cwd = cwd,
    result = result,
    timestamp = now,
  }

  return result
end

-- Check if current directory is an i18n project (lightweight check)
function M.is_i18n_project(opts)
  opts = opts or {}
  local cwd = opts.cwd or vim.fn.getcwd()

  -- Quick check: look for common i18n indicators
  local indicators = {
    -- Config files
    '.i18nrc.json',
    '.i18nrc.lua',
    'i18n.config.json',
    'i18next.config.js',
    'i18next.config.ts',
    -- Common locale directories
    'locales',
    'locale',
    'src/locales',
    'src/locale',
    'src/i18n',
    'i18n',
    'lang',
    'langs',
    'messages',
    'translations',
  }

  for _, indicator in ipairs(indicators) do
    local path = cwd .. '/' .. indicator
    if vim.fn.filereadable(path) == 1 or vim.fn.isdirectory(path) == 1 then
      return true
    end
  end

  -- Check package.json for i18n packages
  local pkg_json = read_package_json(cwd)
  if pkg_json then
    local i18n_packages = {
      'vue-i18n', '@intlify/vue-i18n',
      'react-i18next', 'i18next', 'next-intl',
      '@nuxtjs/i18n', 'nuxt-i18n',
      'react-intl', '@formatjs/intl',
    }
    if has_package(pkg_json, i18n_packages) then
      return true
    end
  end

  return false
end

-- Get root patterns for project detection (useful for LSP-style root detection)
function M.get_root_patterns()
  local patterns = {
    -- i18n config files (highest priority)
    '.i18nrc.json',
    '.i18nrc.lua',
    'i18n.config.json',
  }

  -- Add patterns from all frameworks
  for _, fw in pairs(M.frameworks) do
    for _, p in ipairs(fw.root_patterns or {}) do
      if not vim.tbl_contains(patterns, p) then
        table.insert(patterns, p)
      end
    end
  end

  -- Common project roots
  local common = { 'package.json', '.git', 'pom.xml', 'build.gradle' }
  for _, p in ipairs(common) do
    if not vim.tbl_contains(patterns, p) then
      table.insert(patterns, p)
    end
  end

  return patterns
end

-- Clear detection cache
function M.clear_cache()
  M._cache = {
    cwd = nil,
    result = nil,
    timestamp = 0,
  }
end

-- Debug function
function M.debug(opts)
  local result = M.detect(opts)

  print('=== i18n Framework Detection ===')
  print('CWD: ' .. (opts and opts.cwd or vim.fn.getcwd()))
  print('')

  if result.detected then
    print('Detected Framework: ' .. result.framework.display_name)
    print('')
    print('All Detected Frameworks:')
    for _, fw in ipairs(result.frameworks) do
      print('  - ' .. fw.display_name .. ' (matched: ' .. table.concat(fw.reasons, ', ') .. ')')
    end
    print('')
    print('Suggested Configuration:')
    if result.suggestions.func_pattern then
      print('  func_pattern: ' .. vim.inspect(result.suggestions.func_pattern))
    end
    if result.suggestions.func_type then
      print('  func_type: ' .. vim.inspect(result.suggestions.func_type))
    end
    if result.suggestions.namespace_resolver then
      print('  namespace_resolver: ' .. tostring(result.suggestions.namespace_resolver))
    end
  else
    print('No framework detected')
    print('')
    print('Is i18n project: ' .. tostring(result.is_i18n_project))
    if result.suggestions.sources then
      print('Detected sources: ' .. vim.inspect(result.suggestions.sources))
    end
    if result.suggestions.locales then
      print('Detected locales: ' .. table.concat(result.suggestions.locales, ', '))
    end
  end
end

return M
