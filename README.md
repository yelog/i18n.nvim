# yelog/i18n.nvim

A lightweight Neovim plugin for displaying and managing project i18n (translation) files directly in the editor.  
Designed for front-end projects (JSON, YAML, JS/TS translation modules) and integrates with Tree-sitter to parse JS/TS translation objects.

> [!WARNING]
> This plugin is currently in an early stage of rapid validation and development. Configuration and API may change significantly at any time. Please use with caution and keep an eye on the changelog.

## Key features

- Parse translation files in JSON, YAML and JS/TS (Tree-sitter based) formats.
- Flatten nested translation objects into dot-separated keys (e.g. `system.title`).
- Support static project configuration with language lists and flexible file patterns.
- Inline virtual text display and popup helpers to preview translations (via Neovim API).
- Recursive variable expansion in file patterns (e.g. `{module}`, `{locales}`).
- Fast, zero-dependency core (relies on Neovim builtin APIs and Tree-sitter).

## Requirements

- Neovim 0.8+ (Tree-sitter integration required)
- A Tree-sitter parser for JavaScript/TypeScript installed for files parsing

## Installation (lazy.nvim)

Example configuration using lazy.nvim:

```lua
{
  'yelog/i18n.nvim',
  lazy = true,
  dependencies = {
    'ibhagwan/fzf-lua',
    'nvim-treesitter/nvim-treesitter'
  },
  config = function()
    require('i18n').setup({
      -- List of languages to parse, the first is considered the default language
      locales = { 'en', 'zh' },
      -- files can be string or table { files = "...", prefix = "..." }
      files = {
        'src/locales/{locales}.json',
        -- { files = "src/locales/lang/{locales}/{module}.ts",            prefix = "{module}." },
        -- { files = "src/views/{bu}/locales/lang/{locales}/{module}.ts", prefix = "{bu}.{module}." },
      },
      -- function patterns used to detect i18n keys in code
      func_pattern = {
        "t%(['\"]([^'\"]+)['\"]", -- t('key') or t("key")
        "%$t%(['\"]([^'\"]+)['\"]", -- $t('key') or $t("key")
      },
    })
  end
}
```

## Quickstart

1. Install the plugin with lazy.nvim (see above).
2. Configure `files` and `locales` to match your project layout.
3. Ensure Tree-sitter parsers for JavaScript / TypeScript are installed (e.g. via nvim-treesitter).
4. Open a source file and use the provided commands / keymaps to show translations and inline virtual text.

## Keymaps & Commands

Recommended keymaps (example using lazy-loaded setup):
```lua
-- Fuzzy find i18n keys (fzf integration)
vim.keymap.set("n", "<leader>fi", require("i18n.integration.fzf").show_i18n_keys_with_fzf, { desc = "Fuzzy find i18n key" })
vim.keymap.set("n", "<D-S-n>", require("i18n.integration.fzf").show_i18n_keys_with_fzf, { desc = "Fuzzy find i18n key" })
```


```lua
-- Cycle display language (rotates locales; updates inline virtual text)
vim.keymap.set("n", "<D-S-M-n>", "<cmd>I18nNextLocale<CR>", { desc = "Cycle i18n display language" })
-- Toggle whether inline shows the translated text or the raw i18n key
vim.keymap.set("n", "<leader>io", "<cmd>I18nToggleOrigin<CR>", { desc = "Toggle i18n origin display" })
```

Commands:
- :**I18nNextLocale**
  Cycles the active display language used for inline virtual text. It moves to the next entry in `locales` (wrapping back to the first). Inline overlays refresh automatically.
- :**I18nToggleOrigin**
  Toggles between showing the translated text (current language) and the raw/original i18n key in inline virtual text. When disabled you can easily copy / inspect the key names; toggling again restores the translation overlay.

## blink.cmp Integration

The plugin provides a blink.cmp source (`i18n.integration.blink_source`) that:
- Offers completion items where the label and inserted text are the i18n key.
- Shows the key itself in the detail field (so the preview panel title is stable / language-agnostic).
- Resolves full multi-language translations in the documentation panel (each language on its own line).
- Plays nicely with other sources (LSP, snippets, path, buffer, etc).

Example blink.cmp configuration:
```lua
require('blink.cmp').setup({
  sources = {
    default = { 'i18n', 'snippets', 'lsp', 'path', 'buffer' },
    -- cmdline = {}, -- optionally disable / customize cmdline sources
    providers = {
      lsp = { fallbacks = {} },
      i18n = {
        name = 'i18n',
        module = 'i18n.integration.blink_source',
        opts = {
          -- future options can be placed here
        },
      },
    },
  },
})
```

> [!WARNING]
> Since `blink.cmp` uses a dot (`.`) as a separator for queries, and our i18n keys are also separated by dots, it's recommended to avoid entering dots when searching for keys. For example, instead of typing `common.time.second`, you can type `commonseco` to fuzzy match the i18n key, then press `<c-y>` (or whatever shortcut you have set) to complete the selection.


## Configuration

The plugin exposes `require('i18n').setup(opts)` where `opts` is merged with defaults. Common options:

- locales: array of language codes, first is considered default
- files: array of file patterns or objects:
  - string pattern e.g. `src/locales/{locales}.json`
  - table: `{ files = "pattern", prefix = "optional.prefix." }`
- func_pattern: array of Lua patterns to locate i18n function usages in source files

Patterns support placeholders like `{locales}` and custom variables such as `{module}` which will be expanded by scanning the project tree.

## How it works (brief)

- JSON/YAML files are read and decoded (YAML support uses a simple line parser for common cases).
- JS/TS modules are parsed with Tree-sitter to find exported objects (supports `export default`, `module.exports`, direct object literals, and nested objects). Parsed keys and string values are normalized (quotes removed) and flattened.
- Translations are merged into an internal table keyed by language and dot-separated keys.

## Contributing

Contributions, bug reports and PRs are welcome. Please:

1. Open an issue with reproducible steps.
2. Submit PRs with unit-tested or manually verified changes.
3. Keep coding style consistent with the repository.

## Troubleshooting

- If JS/TS parsing fails, ensure Tree-sitter parsers are installed and up-to-date.
- If some values still contain quotes, ensure the source file uses plain string literals; complex template literals or expressions may need custom handling.

## License

MIT
