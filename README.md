# 🌐 i18n.nvim

A lightweight Neovim plugin to parse, display, and manage project i18n translations directly in the editor.  
Designed for mixed stacks and monorepos. Supports JSON, YAML, Java .properties, and JS/TS translation modules (Tree-sitter).

<table>
  <tr>
    <th>Show Translation</th>
    <th>With <code>blink.cmp</code></th>
  </tr>
  <tr>
    <td>
      <img src="https://github.com/user-attachments/assets/cd6fc746-cfea-4021-8ee1-5449a23130b4" />
    </td>
    <td>
      <img src="https://github.com/user-attachments/assets/7f58a5f8-80e9-49af-a137-0fbf39cede55" />
    </td>
  </tr>
  <tr>
    <th>Diagnostic</th>
    <th>Help like <code>vim.lsp.buf.signature_help()</code></th>
  </tr>
  <tr>
    <td>
      <img src="https://github.com/user-attachments/assets/72365bcb-32bf-48c4-817e-b98f9f0609f0" />
    </td>
    <td>
      <img src="https://github.com/user-attachments/assets/6655b2b8-2b52-4ee7-8233-7024bff8b21d" />
    </td>
  </tr>
  <tr>
    <th>Jump like <code>vim.lsp.buf.definition()</code></th>
    <th>With <code>fzf-lua</code></th>
  </tr>
  <tr>
    <td>
      <img src="https://github.com/user-attachments/assets/05dc50b8-e219-4288-856b-ada0e452477b" />
    </td>
    <td>
      <img src="https://github.com/user-attachments/assets/2ebc7189-f892-4f23-a1d9-b46042bca2da" />
    </td>
  </tr>
  <tr>
    <th>Add Missing Key</th>
    <th>Show Other Translations</th>
  </tr>
  <tr>
    <td>
      <img src="https://github.com/user-attachments/assets/78e7e0ce-034f-4e7b-a73b-c0a0aa56c1c1" />
    </td>
    <td>
      <img src="https://github.com/user-attachments/assets/d2fbb08e-75c6-4190-b656-449aabc5fe13" />
    </td>
  </tr>
</table>

## ✨ Highlights

- Parse translation files (JSON, YAML, .properties, JS/TS via Tree-sitter).
- Flatten nested translation objects into dot-separated keys (e.g. `system.title`).
- Inline virtual text + popup preview of translations.
- Jump to definition, find usages, and add missing keys interactively.
- Auto-detect locale sources with project-level config override.
- Flexible pickers (fzf-lua / Telescope / vim_ui / Snacks) and completion sources (blink.cmp / nvim-cmp).

## ✅ Requirements

- Neovim 0.8+.
- Tree-sitter parsers for JS/TS/TSX/JSX/Vue if you parse those files.
- Optional: `rg` for faster usage scans (falls back to `git ls-files`).
- Optional integrations: `ibhagwan/fzf-lua`, `nvim-telescope/telescope.nvim`, `folke/snacks.nvim`, `blink.cmp`, `nvim-cmp`.

## 📦 Installation (lazy.nvim)

```lua
{
  'yelog/i18n.nvim',
  dependencies = {
    'nvim-treesitter/nvim-treesitter',
    -- optional pickers:
    -- 'ibhagwan/fzf-lua',
    -- 'nvim-telescope/telescope.nvim',
  },
  config = function()
    require('i18n').setup({
      locales = { 'en', 'zh' },
      sources = { 'src/locales/{locales}.json' },
    })
  end
}
```

> By default the plugin activates automatically when an i18n project is detected.  
> Set `activation = 'manual'` to opt into explicit `:I18nEnable`.

## 🚀 Quickstart

1. Configure `locales` + `sources` (or enable `auto_detect`).
2. Open a file and run `:I18nNextLocale` / `:I18nShowTranslations`.
3. Use the picker `I18n.i18n_keys()` or jump to definitions/usages.

## 🧭 Commands

| Command | Description |
| --- | --- |
| `:I18nEnable` | Manually activate (for `activation = 'manual'`). |
| `:I18nDisable` | Deactivate and clear overlays. |
| `:I18nStatus` | Show current status (activation, locales, loaded keys). |
| `:I18nDetectFramework` | Print detected framework info. |
| `:I18nReload` | Reload translations and rescan usages. |
| `:I18nNextLocale` | Cycle display locale. |
| `:I18nToggleOrigin` | Toggle showing the raw key while keeping translations active. |
| `:I18nToggleTranslation` | Toggle translation overlay on/off. |
| `:I18nToggleLocaleFileEol` | Toggle end-of-line translations in locale files. |
| `:I18nShowTranslations` | Popup with all locale translations for key under cursor. |
| `:I18nDefinitionNextLocale` | Jump to the same key in the next locale file. |
| `:I18nKeyUsages` | Jump to usages of the key under cursor. |
| `:I18nAddKey` | Interactive add-missing-key flow. |

All helpers are also available via `require('i18n')`, and a global `I18n` alias is created on setup.

## ⌨️ Keymaps (example)

```lua
keys = {
  { "<D-S-n>", function() I18n.i18n_keys() end,     desc = "Show i18n keys" },
  { "<D-S-B>", function() I18n.next_locale() end,   desc = "Next i18n locale" },
  { "<D-S-J>", function() I18n.toggle_origin() end, desc = "Toggle origin overlay" },
}
```

## 🔎 Key Picker (`i18n_keys`)

Default backend is `fzf-lua`. Switch with:

```lua
i18n_keys = { popup_type = 'telescope' | 'vim_ui' | 'snacks' | 'fzf-lua' }
```

Default actions (fzf-lua):
- `<CR>` copy key
- `<C-y>` copy current locale translation
- `<C-j>` jump (current locale first, fallback to default)
- `<C-l>` choose locale then jump
- `<C-x>` split, `<C-v>` vsplit, `<C-t>` tab

Override keys:

```lua
i18n_keys = {
  keys = {
    jump = { "<c-j>" },
    choose_locale_jump = { "<c-l>" },
  },
}
```

## 🆕 Add Missing i18n Key

Command: `:I18nAddKey`

Flow:
1. Place the cursor on an i18n call whose key does NOT exist (e.g. `t('system.new_feature.title')`).
2. Run `:I18nAddKey`.
3. Fill one input line per locale (first = default).
4. `<Tab>` / `<S-Tab>` moves between locales; `<Enter>` writes; `<Esc>` cancels.

Notes:
- Only JSON files are written (YAML is ignored with a warning).
- Keys are created as nested objects; missing files/directories are created.
- Target file is chosen via the longest matching `sources[].prefix`.

## 🧰 Navigation, Popup & Usage

**Navigation**
- `require('i18n').i18n_definition()` returns `true` on jump, `false` otherwise.
- `require('i18n').i18n_definition_next_locale()` jumps to the same key in the next locale.
- `navigation = { open_cmd = 'edit' | 'split' | 'vsplit' | 'tabedit' }`.

Example: prefer i18n, then LSP definition:
```lua
vim.keymap.set('n', 'gd', function()
  if require('i18n').i18n_definition() then return end
  if require('i18n').i18n_definition_next_locale() then return end
  vim.lsp.buf.definition()
end, { desc = 'i18n or LSP definition' })
```

**Popup**
- `:I18nShowTranslations` or `require('i18n').show_popup()` (returns boolean).

Example:
```lua
vim.keymap.set({ 'n', 'i' }, '<C-k>', function()
  if not require('i18n').show_popup() then
    vim.lsp.buf.signature_help()
  end
end, { desc = 'i18n popup or signature help' })
```

**Usage Scanner**
- Uses `rg --files` and falls back to `git ls-files --exclude-standard`.
- `:I18nKeyUsages` jumps to usages; multiple hits open your configured picker.
- Locale buffers can display usage badges (e.g. `← [2 usages]`).

Options:
```lua
usage = {
  popup_type = 'fzf-lua' | 'telescope' | 'vim_ui' | 'snacks',
  notify_no_key = true,
  max_file_size = 0,     -- 0 = no limit
  scan_on_startup = true,
}
```

Example: prefer usages, then LSP references:
```lua
vim.keymap.set('n', 'gu', function()
  if require('i18n').i18n_key_usages() then return end
  vim.lsp.buf.references()
end, { desc = 'i18n usages or LSP references' })
```

## ⚙️ Configuration

`require('i18n').setup(opts)` merges:
1. Defaults
2. User config
3. Project config file (if found)

A global `I18n` alias is exposed on setup.

### Common options (selected)

Core:
- `activation` (default: `'auto'`): `'auto'` detects i18n projects; `'lazy'` activates on supported filetypes; `'manual'` requires `:I18nEnable`; `'eager'` activates immediately.
- `locales` (default: `{}`): ordered locales; first is default.
- `sources` (default: `{ 'src/locales/{locales}.json' }`): string pattern or `{ pattern, prefix }`.
- `auto_detect` (default: `true`): runs when `sources` is empty or explicitly enabled.
- `func_pattern` (default: `{ 't', '$t' }`): function call matchers or raw Lua patterns.
- `func_type` (default: `{ 'vue', 'typescript', 'javascript', 'typescriptreact', 'javascriptreact', 'tsx', 'jsx', 'java' }`): filetypes/globs scanned for usages.
- `filetypes` / `ft`: restrict filetypes that get inline display (overrides defaults).

Namespace:
- `namespace_resolver` (default: `'auto'`): set `false` to disable.
- `namespace_separator` (default: `'.'`): set `':'` for i18next-style keys.

Display:
- `show_mode` (default: `'both'`): `both` | `translation` | `translation_conceal` | `origin`.
- `show_locale_file_eol_translation` (default: `true`): EOL translation in locale files.
- `show_locale_file_eol_usage` (default: `true`): usage badges in locale files.
- `display.refresh_debounce_ms` (default: `100`).

Diagnostics:
- `diagnostic`: enabled by default; `false` disables; a table is forwarded to `vim.diagnostic.set`.

Pickers:
- `i18n_keys.popup_type` (default: `'fzf-lua'`): `fzf-lua` | `telescope` | `vim_ui` | `snacks`.
- `usage.popup_type` (default: `'fzf-lua'`): picker used by `:I18nKeyUsages`.

Navigation:
- `navigation.open_cmd` (default: `'edit'`): `edit` | `split` | `vsplit` | `tabedit`.

Need a specific layout immediately? Call `I18n.set_show_mode('translation')` / `'translation_conceal'` / `'both'` / `'origin'` and use `I18n.get_show_mode()` to inspect the current value.

> The complete, authoritative list of default options (with their current values) lives in `lua/i18n/config.lua` inside the `M.defaults` table.

### `func_pattern` quick guide

- Plain strings are treated as function names (`{ 't', '$t' }`). Optional whitespace before the opening parenthesis is allowed.
- Tables unlock additional control:
  `{ call = 'i18n.t', quotes = { "'", '"' }, allow_whitespace = false }`.
- Whitespace between the opening parenthesis and the first quote is accepted by default; disable with `allow_arg_whitespace = false`.
- You can still drop down to raw Lua patterns via the `pattern` / `patterns` keys when you need something exotic (ensure the key stays in capture group 1).

### 🔍 Auto-detect Sources

The plugin can automatically scan your project structure to discover locale files, eliminating the need to manually configure `sources`.

**Basic usage** - just enable auto-detect:
```lua
require('i18n').setup({
  auto_detect = true,
  -- locales will also be auto-detected if not specified
})
```

**Or with custom settings:**
```lua
require('i18n').setup({
  auto_detect = {
    enabled = true,
    root_dirs = { 'src', 'app' },              -- directories to scan
    locale_dir_names = { 'locales', 'i18n' },  -- locale directory names
    extensions = { 'json', 'ts' },             -- supported file extensions
    max_depth = 6,                              -- max directory depth to scan
    notify = true,                               -- show auto-detect summary
  },
})
```

**Supported directory structures:**

```
Pattern A: Locale as filename
src/locales/en.json          → sources: ["src/locales/{locales}.json"]
src/locales/zh.json

Pattern B: Locale as directory with module files
src/locales/en/common.ts     → sources: [{ pattern: "src/locales/{locales}/{module}.ts", prefix: "{module}." }]
src/locales/en/system.ts
src/locales/zh/common.ts

Pattern C: Nested in views/business directories
src/views/gmail/locales/en/inbox.ts    → sources: [{ pattern: "src/views/{bu}/locales/{locales}/{module}.ts", prefix: "{bu}.{module}." }]
src/views/calendar/locales/en/events.ts
```

**Notes:**
- Auto-detect runs when `auto_detect = true` or when `sources` is empty/not configured.
- Auto-detect is skipped when a project config file defines `sources` (even if `auto_detect = true`).
- Detected locales are used only if `locales` is not explicitly configured.
- Notifications are shown only when `auto_detect.notify = true` (default: off).
- Access detected configuration via `require('i18n.config').options._detected_sources`.

### 🔧 Namespace Resolver (React i18next / Vue i18n)

For frameworks like **react-i18next** that use `useTranslation('namespace')` to scope translation keys, the plugin can automatically detect the namespace and prepend it to keys for lookup.

Example React component:
```jsx
const { t } = useTranslation('common');
const message = t('greeting');  // Plugin resolves to 'common.greeting' by default
```

Configuration options:
```lua
require('i18n').setup({
  -- Enable namespace resolution
  namespace_resolver = 'auto',  -- or 'react_i18next', 'vue_i18n', custom function, or table

  -- Separator between namespace and key
  namespace_separator = '.',    -- set ':' for i18next standard
})
```

Available resolver values:
- `false`: Disabled, no namespace resolution
- `'auto'`: Auto-detect framework based on filetype (tsx/jsx → react_i18next, vue → vue_i18n)
- `'react_i18next'`: Detect `useTranslation('namespace')` calls in React components
- `'vue_i18n'`: Detect `useI18n({ namespace: '...' })` in Vue components
- Custom function: `function(bufnr, key, line, col) return namespace_or_nil end`
- Table: Per-filetype configuration:
  ```lua
  namespace_resolver = {
    { filetypes = {'typescriptreact', 'javascriptreact'}, resolver = 'react_i18next' },
    { filetypes = {'vue'}, resolver = 'vue_i18n' },
  }
  ```

When namespace resolution is enabled:
- **Display**: Virtual text shows translations for the resolved key (e.g. `common.greeting`).
- **Navigation**: Jump-to-definition uses the resolved key to find the correct location.
- **Completion**: Suggestions are filtered to keys matching the current namespace and inserted without the namespace prefix.
- **Diagnostics**: Missing translation warnings show the full resolved key.

You can also register custom resolvers programmatically:
```lua
require('i18n.namespace').register_resolver('my_framework', function(bufnr, key, line, col)
  -- Custom logic to detect namespace
  return 'detected_namespace' -- or nil if not found
end)
```

### Diagnostics

If `diagnostic` is enabled (default), the plugin emits diagnostics for missing translations at the position of the i18n key. When a table is provided, it is forwarded verbatim to `vim.diagnostic.set(namespace, bufnr, diagnostics, opts)` allowing you to tune presentation (underline, virtual_text, signs, severity_sort, etc). Setting `diagnostic = false` both suppresses generation and clears previously shown diagnostics for the buffer.

Dynamic keys built via string concatenation or Lua `..` are ignored to avoid false positives (e.g. `t('user.' .. segment)` or `t('system.user.' + item)`).

## 🧩 Completion Integrations

### blink.cmp Integration

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

### nvim-cmp Integration

Features:
- Provides i18n keys as completion items (label & inserted text are the key itself).
- Context-aware: only triggers inside the first string argument of your configured i18n function calls and ignores matches inside comments.
- Documentation shows translations for every configured locale; missing ones are marked `(missing)`.
- Lightweight: reuses already parsed in-memory tables (no extra file IO during completion).

Basic setup (after installing `hrsh7th/nvim-cmp`):
```lua
local cmp = require('cmp')

cmp.register_source('i18n', require('i18n.integration.cmp_source').new())

cmp.setup({
  sources = cmp.config.sources({
    { name = 'i18n' },
  }, {
    -- other secondary sources...
  }),
})
```

## 🏗 Project-level Configuration (recommended)

You can place a project-specific config file at the project root. The plugin will auto-detect (in order) the first existing file:
- `.i18nrc.json`
- `i18n.config.json`
- `.i18nrc.lua`

If found, its values override anything you passed to `setup()`.

Example `.i18nrc.json`:
```json
{
  "locales": ["en_US", "zh_CN"],
  "sources": [
    "src/locales/{locales}.json",
    { "pattern": "src/locales/lang/{locales}/{module}.ts", "prefix": "{module}." }
  ]
}
```

Example `.i18nrc.lua`:
```lua
return {
  locales = { "en_US", "zh_CN" },
  sources = {
    "src/locales/{locales}.json",
    { pattern = "src/locales/lang/{locales}/{module}.ts", prefix = "{module}." },
  },
  func_pattern = {
    't',
    '$t',
    { call = 'i18n.t' },
  },
  func_type = { 'vue', 'typescript' },
  usage = { popup_type = 'vim_ui' },
  show_mode = 'translation_conceal',
}
```

Minimal Neovim config (global defaults) – can be empty or partial:
```lua
require('i18n').setup({
  locales = { 'en', 'zh' },  -- acts as a fallback if project file absent
  sources = { 'src/locales/{locales}.json' },
})
```

If later you add a project config file, reopen the project or call:
```lua
require('i18n').reload_project_config()
require('i18n').setup(require('i18n').options)
```

### Notes
- Unknown fields in project config are ignored.
- You can keep a small user-level setup and let each project define its own structure.
- If you frequently switch branches that add/remove locale files, trigger a manual reload.

## 🧠 How It Works

- JSON/YAML/.properties files are read and decoded (.properties uses simple `key=value` parsing; YAML uses a simplified parser covering common scenarios).
- JS/TS modules are parsed with Tree-sitter to find exported objects (supports `export default`, `module.exports`, direct object literals, and nested objects). Parsed keys and string values are normalized and flattened.
- Translations are merged into an internal table keyed by language and dot-separated keys.

## 📗 Examples

### Simple JSON i18n

One JSON file per locale:

```bash
projectA
├── src
│   ├── App.vue
│   ├── locales
│   │   ├── en.json
│   │   └── zh.json
│   └── main.ts
├── package.json
└── vite.config.ts
```

`.i18nrc.lua`:
```lua
return {
  locales = { 'en', 'zh' },
  sources = {
    'src/locales/{locales}.json'
  }
}
```

### Multi-module i18n

```bash
projectB
├── src
│   ├── App.vue
│   ├── locales
│   │   ├── en-US
│   │   │   ├── common.ts
│   │   │   ├── system.ts
│   │   │   └── ui.ts
│   │   └── zh-CN
│   │       ├── common.ts
│   │       ├── system.ts
│   │       └── ui.ts
│   └── main.ts
└── package.json
```

`.i18nrc.lua`:
```lua
return {
  locales = { 'en-US', 'zh-CN' },
  sources = {
    { pattern = 'src/locales/{locales}/{module}.ts', prefix = '{module}.' }
  }
}
```

### Multi-module + multi-business

```bash
projectC
├── src
│   ├── locales
│   │   ├── en-US
│   │   └── zh-CN
│   └── views
│       ├── gmail/locales/en-US/inbox.ts
│       └── calendar/locales/zh-CN/events.ts
└── package.json
```

`.i18nrc.lua`:
```lua
return {
  locales = { 'en-US', 'zh-CN' },
  sources = {
    { pattern = 'src/locales/{locales}/{module}.ts', prefix = '{module}.' },
    { pattern = 'src/views/{business}/locales/{locales}/{module}.ts', prefix = '{business}.{module}.' }
  }
}
```

## 🩺 Troubleshooting

- If JS/TS parsing fails, ensure Tree-sitter parsers are installed and up-to-date.
- If some values still contain quotes, ensure the source file uses plain string literals; complex template literals or expressions may need custom handling.

## 🤝 Contributing

Contributions, bug reports and PRs are welcome. Please:

1. Open an issue with reproducible steps.
2. Submit PRs with unit-tested or manually verified changes.
3. Keep coding style consistent with the repository.

## 📄 License

Apache-2.0 License. See [LICENSE](LICENSE) for details.
