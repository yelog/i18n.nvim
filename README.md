# yelog/i18n.nvim

A lightweight Neovim plugin for displaying and managing project i18n (translation) files directly in the editor.  
Designed for front-end projects (JSON, YAML, JS/TS translation modules) and integrates with Tree-sitter to parse JS/TS translation objects.

## Key features

- Parse translation files in JSON, YAML and JS/TS (Tree-sitter based) formats.
- Flatten nested translation objects into dot-separated keys (e.g. `system.title`).
- Support static project configuration with language lists and flexible file patterns.
- Inline virtual text display and popup helpers to preview translations (via Neovim API).
- Recursive variable expansion in file patterns (e.g. `{module}`, `{langs}`).
- Fast, zero-dependency core (relies on Neovim builtin APIs and Tree-sitter).

## Requirements

- Neovim 0.8+ (Tree-sitter integration required)
- A Tree-sitter parser for JavaScript/TypeScript installed for files parsing

## Installation (lazy.nvim)

Example configuration using lazy.nvim:

```lua
require('lazy').setup({
  {
    'yelog/i18n.nvim',
    config = function()
      require('i18n').setup({
        options = {
          mode = 'static',
          static = {
            langs = { 'en_US', 'zh_CN' },
            -- files can be string or table { files = "...", prefix = "..." }
            files = {
              -- example patterns:
              -- 'src/locales/{langs}.json',
              -- 'src/views/{module}/locales/{langs}.ts',
            },
            -- function patterns used to detect i18n keys in code
            func_pattern = {
              "t%(['\"]([^'\"]+)['\"]",
              "%$t%(['\"]([^'\"]+)['\"]",
            },
          },
        },
      })
    end
  }
})
```

## Quickstart

1. Install the plugin with lazy.nvim (see above).
2. Configure `options.static.files` and `options.static.langs` to match your project layout.
3. Ensure Tree-sitter parsers for JavaScript / TypeScript are installed (e.g. via nvim-treesitter).
4. Open a source file and use the provided commands / keymaps to show translations and inline virtual text.

## Configuration

The plugin exposes `require('i18n').setup(opts)` where `opts` is merged with defaults. Common options:

- mode: "static" or other future modes
- static.langs: array of language codes, first is considered default
- static.files: array of file patterns or objects:
  - string pattern e.g. `src/locales/{langs}.json`
  - table: `{ files = "pattern", prefix = "optional.prefix." }`
- static.func_pattern: array of Lua patterns to locate i18n function usages in source files

Patterns support placeholders like `{langs}` and custom variables such as `{module}` which will be expanded by scanning the project tree.

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
