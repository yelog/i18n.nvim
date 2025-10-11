# 🌐 i18n.nvim

A lightweight Neovim plugin for displaying and managing project i18n (translation) files directly in the editor.  
Designed to work across most project types (front-end, backend, mixed monorepos), supporting JSON, YAML, Java .properties, and JS/TS translation modules (Tree-sitter parses JS/TS translation objects).

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

## ✨ Key Features

- 📄 Parse translation files (JSON, YAML, .properties, JS/TS via Tree-sitter).
- 🧩 Flatten nested translation objects into dot-separated keys (e.g. `system.title`).
- 🗂 Flexible project configuration (locales & file patterns).
- 👁 Inline virtual text & popup helpers to preview translations.
- 🔁 Recursive placeholder expansion in file patterns (e.g. `{module}`, `{locales}`).
- ⚡ Fast, zero-dependency core (Neovim built-ins + Tree-sitter).

## 📦 Requirements

- Neovim 0.8+ (Tree-sitter integration required)
- A Tree-sitter parser for JavaScript/TypeScript installed for files parsing

## 🛠 Installation (lazy.nvim)

Example configuration using lazy.nvim:

```lua
{
  'yelog/i18n.nvim',
  dependencies = {
    'ibhagwan/fzf-lua',
    'nvim-treesitter/nvim-treesitter'
  },
  config = function()
    require('i18n').setup({
      -- Locales to parse; first is the default locale
      -- Use I18nNextLocale command to switch the default locale in real time
      locales = { 'en', 'zh' },
      -- sources can be string or table { pattern = "...", prefix = "..." }
      sources = {
        'src/locales/{locales}.json',
        -- { pattern = "src/locales/lang/{locales}/{module}.ts",            prefix = "{module}." },
        -- { pattern = "src/views/{bu}/locales/lang/{locales}/{module}.ts", prefix = "{bu}.{module}." },
      }
    })
  end
}
```

## 🚀 Quickstart

1. Install the plugin with lazy.nvim (see above).
2. Configure `sources` and `locales` to match your project layout.
3. Ensure Tree-sitter parsers for JavaScript / TypeScript are installed (e.g. via nvim-treesitter).
4. Open a source file and use the provided commands / keymaps to show translations and inline virtual text.

## 🎛 Keymaps & Commands

Recommended keymaps (lazy.nvim `keys` example, using the global `I18n` helper):
```lua
keys = {
  { "<D-S-n>", function() I18n.i18n_keys() end,      desc = "Show i18n keys" },
  { "<D-S-B>", function() I18n.next_locale() end,    desc = "Switch to next locale" },
  { "<D-S-J>", function() I18n.toggle_origin() end,  desc = "Toggle origin overlay" },
}
-- When using the default fzf-lua backend the key picker supports:
--   <CR> : copy key
--   <C-y>: copy current locale translation
--   <C-j>: jump (current locale first, fallback default)
--   <C-l>: choose locale then jump (secondary picker)
--   <C-x>: horizontal split jump
--   <C-v>: vertical split jump
--   <C-t>: tab jump
-- Override these in setup(): i18n_keys.keys = { jump = { "<c-j>" }, choose_locale_jump = { "<c-l>" } }
-- Other popup types: set `i18n_keys = { popup_type = 'telescope' | 'vim_ui' | 'snacks' | 'fzf-lua' }`.
-- `vim_ui` renders a native floating picker; `snacks` delegates to folke/snacks.nvim when available (falling back to the native picker otherwise).
```

Commands:
- 🔄 :**I18nNextLocale**
  Cycles the active display language used for inline virtual text. It moves to the next entry in `locales` (wrapping back to the first). Inline overlays refresh automatically.
- 👁 :**I18nToggleOrigin** / `I18n.toggle_origin()`
  Switches between `show_mode = "both"` and a translation-only mode (restoring the last non-origin preference, defaulting to `"translation_conceal"`). Use this when you want to hide or reveal raw keys while leaving translations visible.
- 💡 :**I18nToggleTranslation** / `I18n.toggle_translation()`
  Toggles the inline translation overlay entirely by jumping between `show_mode = "origin"` and your previous non-origin mode. Handy for quickly disabling overlays while editing.
- 📝 :**I18nToggleLocaleFileEol** / `I18n.toggle_locale_file_eol()`
  Toggles showing end-of-line translations in locale source files (per i18n key line). When enabled, each key line in a locale translation file shows the current display locale’s translation as EOL virtual text; disabling hides these overlays (useful for focused editing or cleaner diffs).

Need a specific layout immediately? Call `I18n.set_show_mode('translation')` / `'translation_conceal'` / `'both'` / `'origin'` and use `I18n.get_show_mode()` to inspect the current value.

### 🆕 Interactive: Add Missing i18n Key

You can interactively add a missing i18n key (across all configured locales) with a floating window editor.

Command:
:I18nAddKey

Usage:
1. Place the cursor on an i18n function call whose key does NOT yet exist (e.g. t("system.new_feature.title")).
2. Run :I18nAddKey
3. A popup appears with one input line per configured locale (first = default).
4. Type the default locale translation; untouched other locale lines auto-fill with the same text.
5. Use <Tab> / <S-Tab> to move between locale input lines.
6. Press <Enter> to write the values into their respective locale files (creating missing nested objects automatically for JSON).
7. Press <Esc> or <C-c> to cancel without changes.

Details:
- Target files are chosen by matching the longest registered file prefix (from your config.sources prefix) against the key.
- Currently JSON files are updated (YAML is ignored for writing if encountered, with a notification).
- Files are created if missing, and keys are inserted in nested form (a.b.c builds { "a": { "b": { "c": "..." }}}).
- After saving, translations are reloaded and inline displays refresh automatically.

Example workflow:
t("feature.welcome.message") -- key does not exist yet
:I18nAddKey
Enter default text: "Welcome!"
Auto-filled other locales.
Edit zh locale line to: "欢迎！"
<Enter> to confirm.
Now the key exists in all locale files.

## 🔌 blink.cmp Integration

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

## 🧩 nvim-cmp Integration

Features:
- Provides i18n keys as completion items (label & inserted text are the key itself)
- Context aware: only triggers inside the first string argument of your configured i18n function calls (derived from `config.options.func_pattern`) and ignores matches inside comments
- Documentation shows translations for every configured locale; missing ones are marked `(missing)`
- Lightweight: reuses already parsed in‑memory tables (no extra file IO during completion)

Basic setup (after installing `hrsh7th/nvim-cmp`):
```lua
local cmp = require('cmp')

-- Register the i18n source (do this once, e.g. in your cmp config file)
cmp.register_source('i18n', require('i18n.integration.cmp_source').new())

cmp.setup({
  sources = cmp.config.sources({
    { name = 'i18n' },
    -- other primary sources...
  }, {
    -- secondary sources...
  }),
})
```

Lazy.nvim snippet:
```lua
{
  'yelog/i18n.nvim',
  dependencies = {
    'hrsh7th/nvim-cmp',
  },
  config = function()
    require('i18n').setup({
      locales = { 'en', 'zh' },
      sources = { 'src/locales/{locales}.json' },
    })
  end
}
```

Tips:
- To make the source always active (not recommended), you could broaden
  `func_pattern` (e.g. add more function names or custom matchers), but keeping
  precise entries reduces noise.
- Pair with fuzzy filtering of `nvim-cmp` for quick partial matches even across dotted segments.

## 🔭 Telescope Integration

A Telescope picker is also provided for users who prefer Telescope over fzf-lua.  
It offers similar actions: copy key, copy current locale translation, jump to definition (current or default locale), choose locale then jump, and split/vsplit/tab open variants.

Setup (lazy.nvim example):
```lua
{
  'yelog/i18n.nvim',
  dependencies = {
    'nvim-telescope/telescope.nvim',
  },
  config = function()
    require('i18n').setup({
      locales = { 'en', 'zh' },
      sources = { 'src/locales/{locales}.json' },
    })
  end
}
```

To switch the picker backend, set `i18n_keys = { popup_type = 'telescope' | 'vim_ui' | 'snacks' | 'fzf-lua' }` in your setup (or project config).  
`vim_ui` renders a native floating picker with preview; `snacks` delegates to `Snacks.picker` when installed and falls back to the native picker otherwise.  
The same keymap above will now open the chosen UI; Telescope users can press `?` inside the picker to view the standard help overlay.  
The legacy helpers `show_i18n_keys_with_fzf()` / `show_i18n_keys_with_telescope()` are still available but deprecated in favor of `i18n_keys()`.

## ⚙️ Configuration

The plugin exposes `require('i18n').setup(opts)` where `opts` is merged with defaults.

Merge precedence (highest last):
1. Built-in defaults (internal)
2. Options passed to `require('i18n').setup({...})`
3. Project-level config file in the current working directory (if present)

So a project config will override anything you set in your Neovim config for that particular project.

> [!NOTE]
> The complete, authoritative list of default options (with their current values) lives in `lua/i18n/config.lua` inside the `M.defaults` table. Consult that file to discover every available key, verify current defaults, or track new options introduced in updates.

Requiring the module creates a global `I18n` alias, so mappings can call helpers
directly (e.g. `function() I18n.i18n_keys() end`) without requiring the module
inside each callback.

Common options (all optional when a project file is present):
- locales: array of language codes, first is considered default
- sources: array of file patterns or objects:
  * string pattern e.g. `src/locales/{locales}.json`
  * table: `{ pattern = "pattern", prefix = "optional.prefix." }`
- func_pattern: names/specs describing translation call sites. Plain strings
  become safe matchers (e.g. `{ 't', '$t' }`); tables allow advanced control;
  raw Lua patterns are still accepted for legacy setups.
- func_type: filetype or glob list scanned for usage counts (defaults to
  `{ 'vue', 'typescript', 'javascript', 'typescriptreact', 'javascriptreact', 'tsx', 'jsx', 'java' }`)
- usage.popup_type: picker shown when a key has multiple usages (`vim_ui` | `telescope` | `fzf-lua` | `snacks`, default `vim_ui`)
- i18n_keys.popup_type: picker backend for browsing keys (`fzf-lua` | `telescope` | `vim_ui` | `snacks`, default `fzf-lua`)
- show_mode: controls inline rendering (`both` | `translation` | `translation_conceal` | `origin`; defaults to `both` when unset/unknown). `both` appends the translation after the raw key on every line. `translation` hides the key except on the cursor line (where both are shown). `translation_conceal` hides the key and suppresses the translation on the cursor line so you can edit the raw key comfortably. `origin` disables the overlay entirely.
- show_locale_file_eol_usage: toggle usage badges in locale buffers (default `true`)
- filetypes / ft: restrict which filetypes are processed
- diagnostic: controls missing translation diagnostics (see below):
  * `false`: disable diagnostics entirely (existing ones are cleared)
  * `true`: enable diagnostics with default behavior (ERROR severity for missing translations)
  * `{ ... }` (table): enable diagnostics and pass the table as the 4th argument to `vim.diagnostic.set` (e.g. `{ underline = false, virtual_text = false }`)

### `func_pattern` quick guide

- Plain strings are treated as function names (`{ 't', '$t' }`). Optional
  whitespace before the opening parenthesis is allowed.
- Tables unlock additional control:
  `{ call = 'i18n.t', quotes = { "'", '"' }, allow_whitespace = false }`.
- Whitespace between the opening parenthesis and the first quote is accepted by
  default; disable with `allow_arg_whitespace = false`.
- You can still drop down to raw Lua patterns via the `pattern` / `patterns`
  keys when you need something exotic (ensure the key stays in capture group 1).

Diagnostics
If `diagnostic` is enabled (true or a table), the plugin emits diagnostics for missing translations at the position of the i18n key. When a table is provided, it is forwarded verbatim to `vim.diagnostic.set(namespace, bufnr, diagnostics, opts)` allowing you to tune presentation (underline, virtual_text, signs, severity_sort, etc). Setting `diagnostic = false` both suppresses generation and clears previously shown diagnostics for the buffer.
Dynamic keys built via string concatenation or Lua `..` are ignored to avoid false positives (e.g. `t('user.' .. segment)` or `t('system.user.' + item)`).

Patterns support placeholders like `{locales}` and custom variables such as `{module}` which will be expanded by scanning the project tree.

Navigation
Jump from an i18n key usage to its definition (default locale file + line) using an explicit helper function:
Helper: require('i18n').i18n_definition() -> boolean
Unified API: all public helpers are available via require('i18n') (e.g. i18n_definition, show_popup, reload_project_config, next_locale).
Returns true if it jumped, false if no i18n key / location found (so you can fallback to LSP).

Example keymap that prefers i18n, then falls back to LSP definition:
```lua
vim.keymap.set('n', 'gd', function()
  -- Jump from an i18n key usage to its definition
  if require('i18n').i18n_definition() then
    return
  end
  -- Jump from current i18n definition to the next locale's definition, following the order in locales
  if require('i18n').i18n_definition_next_locale() then
    return
  end
  -- Fall back to LSP definition
  vim.lsp.buf.definition()
end, { desc = 'i18n or LSP definition' })
```

Separate key (only i18n):
```lua
vim.keymap.set('n', 'gK', function()
  require('i18n').i18n_definition()
end, { desc = 'Jump to i18n definition' })
```

Configuration option:
navigation = {
  open_cmd = "edit", -- or 'vsplit' | 'split' | 'tabedit'
}

Line numbers are best-effort for JSON/YAML/.properties (heuristic matching); JS/TS uses Tree-sitter for higher accuracy.

Usage Scanner
Track how often each i18n key appears in your source tree. The plugin scans
files matching `func_type` (defaults to `{ 'vue', 'typescript', 'javascript',
  'typescriptreact', 'javascriptreact', 'tsx', 'jsx', 'java' }`) using
`rg --files` and falls back to `git ls-files --exclude-standard`, so
`.gitignore`d paths are skipped automatically.
Initial project scans now run asynchronously after `VimEnter`, keeping startup
responsive while usage counts backfill in the background.

- Locale buffers append `← [No usages]` / `← [2 usages]` style badges before the translation so coverage and text remain visually distinct.
- `:I18nKeyUsages` or `require('i18n').i18n_key_usages()` inspects the key under the cursor: one usage jumps immediately; multiple usages open your configured picker.
- Saved buffers matching `func_type` are rescanned automatically; trigger a background rescan with `require('i18n').refresh_usages()` if you tweak configuration on the fly (pass `{ sync = true }` to block until completion).
- Set `usage = { popup_type = 'telescope' | 'fzf-lua' | 'snacks' | 'vim_ui' }` to reuse your preferred picker when resolving multiple usages.
- Adjust highlight links via `:hi I18nUsageLabel`, `:hi I18nUsageTranslation`, and `:hi I18nUsageSeparator` if you prefer different colors.

Example keymap that tries the i18n usage jump first, then falls back to LSP references (mirrors the `gd` example above):
```lua
vim.keymap.set('n', 'gu', function()
  if require('i18n').i18n_key_usages() then
    return
  end
  vim.lsp.buf.references()
end, { desc = 'i18n usages or LSP references' })
```

Extend `func_type` with additional globs if your project mixes in other languages (e.g. `{ 'vue', '*.svelte', 'javascriptreact' }`).

Popup helper (returns boolean)
You can show a transient popup of all translations for the key under cursor:
Helper: require('i18n').show_popup() -> boolean
Returns true if a popup was shown, false if no key / translations found.

Example combined mapping (try popup first, else fallback to signature help):
```lua
vim.keymap.set({ "n", "i" }, "<C-k>", function()
  if not require('i18n').show_popup() then
    vim.lsp.buf.signature_help()
  end
end, { desc = "i18n popup or signature help" })
```


### 🏗 Project-level Configuration (recommended)

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

If later you add a project config file, just reopen the project (or call:
```lua
require('i18n').reload_project_config()
require('i18n').setup(require('i18n').options)
```
) to apply overrides.

### Notes
- Unknown fields in project config are ignored.
- You can keep a very small user-level setup and let each project define its own structure.
- If you frequently switch branches that add/remove locale files, you may want to trigger a manual reload (e.g. a custom command that re-runs `setup()`).

## 🧠 How It Works

- JSON/YAML/.properties files are read and decoded (.properties uses simple key=value parsing; YAML uses a simplified parser covering only common scenarios).
- JS/TS modules are parsed with Tree-sitter to find exported objects (supports `export default`, `module.exports`, direct object literals, and nested objects). Parsed keys and string values are normalized (quotes removed) and flattened.
- Translations are merged into an internal table keyed by language and dot-separated keys.

## 📗 Use Case

> [!NOTE]
> If you work on multiple projects, keep the config in the project root to avoid editing your global Neovim config when switching.
> All examples below use a project-level config; see [Project-level Configuration (recommended)](#-project-level-configuration-recommended).

### Simple JSON i18n

One JSON file per locale

```bash
projectA
├── src
│   ├── App.vue
│   ├── locales
│   │   ├── en.json
│   │   └── zh.json
│   └── main.ts
├── package.json
├── tsconfig.json
└── vite.config.ts
```
Create a `.i18nrc.lua` file at the project root:
```lua
return {
  locales = { "en", "zh" },
  sources= { 
    "src/locales/{locales}.json"
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
├── package.json
├── tsconfig.json
└── vite.config.ts
```
Create a `.i18nrc.lua` file at the project root:
```lua
return {
    locales = { "en-US", "zh-CN" },
    sources = {
        { pattern = "src/locales/{locales}/{module}.ts", prefix = "{module}." }
    }
}
```

### Multi-module multi-business i18n
```bash
projectC
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
│   ├── views
│   │   ├── gmail
│   │   │   └── locales
│   │   │       ├── en-US
│   │   │       │   ├── inbox.ts
│   │   │       │   ├── compose.ts
│   │   │       │   └── settings.ts
│   │   │       └── zh-CN
│   │   │           ├── inbox.ts
│   │   │           ├── compose.ts
│   │   │           └── settings.ts
│   │   ├── calendar
│   │   │   └── locales
│   │   │       ├── en-US
│   │   │       │   ├── events.ts
│   │   │       │   ├── reminders.ts
│   │   │       │   └── settings.ts
│   │   │       └── zh-CN
│   │   │           ├── events.ts
│   │   │           ├── reminders.ts
│   │   │           └── settings.ts
│   │   └── search
│   │       └── locales
│   │           ├── en-US
│   │           │   ├── query.ts
│   │           │   ├── results.ts
│   │           │   └── filters.ts
│   │           └── zh-CN
│   │               ├── query.ts
│   │               ├── results.ts
│   │               └── filters.ts
│   └── main.ts
├── package.json
├── tsconfig.json
└── vite.config.ts
```
With the distributed i18n files below, create a `.i18nrc.lua` at the project root:
```lua
return {
    locales = { "en-US", "zh-CN" },
    sources = {
      { pattern = "src/locales/{locales}/{module}.ts", prefix = "{module}." },
      { pattern = "src/views/{business}/locales/{locales}/{module}.ts", prefix = "{business}.{module}." }
    }
}
```

## 🤝 Contributing

Contributions, bug reports and PRs are welcome. Please:

1. Open an issue with reproducible steps.
2. Submit PRs with unit-tested or manually verified changes.
3. Keep coding style consistent with the repository.

## 🩺 Troubleshooting

- If JS/TS parsing fails, ensure Tree-sitter parsers are installed and up-to-date.
- If some values still contain quotes, ensure the source file uses plain string literals; complex template literals or expressions may need custom handling.

## 📄 License

Apache-2.0 License. See [LICENSE](LICENSE) for details.
