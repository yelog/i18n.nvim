# i18n.nvim

`i18n.nvim` 是一个为 Neovim 设计的国际化（i18n）辅助插件，适用于前端开发者，尤其是 Vue/React/TypeScript/JavaScript 项目。它可以在编辑器中高亮、预览和快速替换 i18n key，提升多语言开发效率。

## 特性

- 支持多种主流 i18n 文件格式（JSON、YAML、JS/TS 导出对象等）
- 自动识别和高亮 buffer 中的 i18n key
- 光标悬停时弹窗预览所有语言的翻译
- 支持一键替换、批量刷新
- 可自定义 key 匹配模式、语言文件路径等
- 适配 Vue、React、JS、TS、TSX、JSX 等文件类型

## 安装

使用 [lazy.nvim](https://github.com/folke/lazy.nvim)：

```lua
{
  "yelog/i18n.nvim",
  config = function()
    require("i18n").setup({
      -- 你的自定义配置
    })
  end,
}
```

## 快速开始

```lua
require("i18n").setup({
  mode = "static",
  static = {
    langs = { "zh-CN", "en-US" },
    default_lang = { "zh-CN" },
    files = {
      "./src/locales/{langs}.json",
    },
    func_pattern = { "t%((.-)%)" }, -- 匹配 t('key') 形式
  },
})
```

## 常用命令与快捷键

- `<leader>it`：弹窗预览当前行下所有语言的翻译
- 保存/切换 buffer 时自动刷新高亮
- 支持自定义 key 匹配规则

## 配置项说明

详见 [lua/i18n/config.lua](lua/i18n/config.lua) 文件，支持自定义语言、默认语言、i18n 文件路径、key 匹配模式等。

## 贡献

欢迎 issue 和 PR！

## License

MIT
