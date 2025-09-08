local M = {}

M.defaults = {
  show_translation = true,
  show_origin = false,
  -- 是否在翻译源( locale )文件中的 key 行尾展示默认语言翻译（虚拟文本）
  show_locale_file_eol_translation = true,
  diagnostics = true,
  -- func_pattern:
  -- 使用 frontier(%f) 确保 t / $t 前面不是字母或数字或下划线，避免 split('/'), last(" 等误匹配
  -- %f[^%w_]t  表示 t 前不是 %w_（字母数字下划线）
  -- 示例可匹配: t("a.b"),  t('x'),  (t("x"),  $t("x")
  -- 不匹配: split("..."), data.last("..."), my_t("x")
  func_pattern = {
    -- 使用 frontier：%f[%w_]t 确保 t 前不是字母/数字/下划线/（保持 split('/ 之类不匹配）
    -- 示例匹配: t('a.b'),  title: t("x.y"), (t("x")), {{$t('k')}}
    -- 不匹配: split('x'), my_t('x'), last("x")
    "%f[%w_]t%(['\"]([^'\"]+)['\"]",
    -- $t 形式（前面任意非 $ 字符或行首）；%f[%$] 断言当前位置后是 $ 且前一字符不是 $
    "%f[%$]%$t%(['\"]([^'\"]+)['\"]",
  },
  locales = { "en", "zh" },
  sources = {
    "src/locales/{locales}.json",
  },
  navigation = {},
  fzf = {
    -- 动作按键映射（数组内多个字符串表示多个触发键）
    -- 使用 Vim 风格表示法 (<cr>, <c-j> 等)，内部会转换为 fzf 可识别键
    keys = {
      copy_key           = { "<cr>" },  -- 复制国际化 key
      copy_translation   = { "<c-y>" }, -- 复制当前显示语言翻译
      jump               = { "<c-j>" }, -- 跳转当前显示语言（失败回退默认语言）
      split_jump         = { "<c-x>" }, -- 水平分屏跳转
      vsplit_jump        = { "<c-v>" }, -- 垂直分屏跳转
      tab_jump           = { "<c-t>" }, -- 标签页跳转
      choose_locale_jump = { "<c-l>" }, -- 选择语言后跳转
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
