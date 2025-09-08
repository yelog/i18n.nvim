local M = {}

M.defaults = {
  show_translation = true,
  show_origin = false,
  diagnostics = true,
  func_pattern = {
    "t%(['\"]([^'\"]+)['\"]",
    "%$t%(['\"]([^'\"]+)['\"]",
  },
  locales = { "en", "zh" },
  sources = {
    "src/locales/{locales}.json",
  },
  navigation = {},
  fzf = {
    -- 动作按键映射（数组内多个字符串表示多个触发键）
    keys = {
      copy_key        = { "enter", "ctrl-y" },
      jump_current    = { "ctrl-j" },
      jump_default    = { "ctrl-d" },
      choose_locale   = { "ctrl-l" },
      split_jump      = { "ctrl-s" },
      vsplit_jump     = { "ctrl-v" },
      tab_jump        = { "ctrl-t" },
      copy_translation = { "ctrl-c" },
    },
    jump = {
      prefer_current_locale = true,
      open_cmd_default = "edit", -- edit|split|vsplit|tabedit
    },
    show_missing = true,
    missing_style = "Error",
    preview_order = "config", -- config|current_first|default_first
  }
}

-- 记录项目级配置
M.project_config = nil
M.options = {}

-- 尝试从当前工作目录加载项目级配置
local function load_project_config()
  local config_files = { '.i18nrc.json', 'i18n.config.json', '.i18nrc.lua' }
  local cwd = vim.fn.getcwd()
  for _, filename in ipairs(config_files) do
    local full = cwd .. '/' .. filename
    if vim.fn.filereadable(full) == 1 then
      if filename:match('%.json$') then
        local ok_read, content = pcall(vim.fn.readfile, full)
        if ok_read and content and #content > 0 then
          local joined = table.concat(content, '\n')
          local ok_decode, decoded = pcall(vim.json.decode, joined)
          if ok_decode and type(decoded) == "table" then
            return decoded, full
          else
            vim.notify("[i18n] 解析 JSON 失败: " .. full, vim.log.levels.WARN)
          end
        else
          vim.notify("[i18n] 读取配置文件失败: " .. full, vim.log.levels.WARN)
        end
      elseif filename:match('%.lua$') then
        local ok_dofile, lua_tbl = pcall(dofile, full)
        if ok_dofile and type(lua_tbl) == "table" then
          return lua_tbl, full
        else
          vim.notify("[i18n] 运行 Lua 配置失败: " .. full, vim.log.levels.WARN)
        end
      end
    end
  end
  return nil, nil
end

-- 允许外部强制重新加载项目配置
function M.reload_project_config()
  local project_cfg = load_project_config()
  if project_cfg then
    M.project_config = project_cfg
  end
  return M.project_config
end

-- opts 预期形式（已移除 default 层级，用户直接传配置）：
-- require('i18n').setup({
--   locales = {...},
--   sources = {...},
-- })
M.setup = function(opts)
  opts = opts or {}
  local user_config = opts

  local project_cfg = M.reload_project_config()

  M.options = vim.tbl_deep_extend('force', M.defaults, user_config, project_cfg or {})

  return M.options
end

return M
