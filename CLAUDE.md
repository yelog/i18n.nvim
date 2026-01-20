# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

i18n.nvim is a Neovim plugin for displaying and managing i18n (translation) files directly in the editor. It parses translation files (JSON, YAML, .properties, JS/TS via Tree-sitter), flattens nested keys, and provides inline virtual text overlays, diagnostics, navigation, and completion integration.

## Core Architecture

### Module Organization

All plugin logic lives in `lua/i18n/`:

- **`init.lua`**: Entry point that wires setup, user commands, and public API. Exposes global `I18n` table for direct access in keymaps. All user-facing functions route through here.
- **`config.lua`**: Configuration management with three-tier merge (defaults → user config → project config). Handles `.i18nrc.json` / `.i18nrc.lua` / `i18n.config.json` auto-detection. Normalizes `func_pattern` from user-friendly specs into Lua patterns.
- **`parser.lua`**: Parses translation files and maintains in-memory translation tables. Supports JSON, YAML, .properties, and JS/TS (via Tree-sitter). Flattens nested keys (e.g., `system.title`). Tracks file metadata (line/col) for navigation. Sets up file watchers to reload on changes.
- **`display.lua`**: Renders inline virtual text overlays and diagnostics. Manages show modes (`both`, `translation`, `translation_conceal`, `origin`). Handles locale switching and EOL translation display in locale files. Creates diagnostics for missing translations.
- **`navigation.lua`**: Jump-to-definition for i18n keys. Returns boolean to enable fallback to LSP. Supports jumping between locale files (`i18n_definition_next_locale`).
- **`usages.lua`**: Scans project files for i18n key usage counts. Uses `rg --files` or `git ls-files`. Runs async after `VimEnter`. Tracks usage per key and displays badges in locale files.
- **`add_key.lua`**: Interactive floating window for adding missing i18n keys across all locales. Auto-fills empty inputs, handles nested key creation in JSON.
- **`utils.lua`**: Shared utilities (file detection, quote stripping, key extraction from cursor position).
- **`key_picker.lua`**: Native (`vim.ui.select`) and Snacks.nvim picker implementations for browsing i18n keys.

### Integration Modules (`lua/i18n/integration/`)

- **`fzf.lua`**: fzf-lua picker with actions (copy key, copy translation, jump, split/vsplit/tab open, choose locale).
- **`telescope.lua`**: Telescope picker with similar actions.
- **`cmp_source.lua`**: nvim-cmp completion source. Context-aware (triggers inside i18n function calls), shows all locale translations in docs.
- **`blink_source.lua`**: blink.cmp completion source with multi-locale documentation.

### Key Data Flow

1. **Setup**: `init.lua:setup()` → `config.setup()` → `parser.load_translations()` → `display.setup_replace_mode()` → `usages.setup()`
2. **Translation Loading**: `parser.load_translations()` expands file patterns, parses each file, flattens keys, stores in `parser.translations[locale][key]` and `parser.meta[locale][key]`
3. **Display Refresh**: `display.refresh()` → iterates open buffers → clears old extmarks → scans for i18n keys (using `func_pattern`) → creates virtual text and diagnostics based on show mode
4. **Navigation**: Cursor on i18n key → `navigation.i18n_definition()` → extract key → lookup in `parser.meta` → jump to file:line
5. **Usage Tracking**: `usages.setup()` → async scan all project files → parse i18n calls → count per key → store in `usages.counts[key]` → display EOL badges in locale files

### Configuration System

**Merge precedence** (highest wins):
1. Built-in defaults (`config.defaults`)
2. User config passed to `setup({})`
3. Project config (`.i18nrc.json`, `i18n.config.json`, or `.i18nrc.lua` in CWD)

**Critical config keys**:
- `locales`: Array of language codes (first is default)
- `sources`: File patterns with `{locales}` / `{module}` placeholders, or tables with `pattern` and `prefix`
- `func_pattern`: Describes i18n function calls. Supports plain strings (`'t'`, `'$t'`), tables with `call`, `quotes`, `boundary`, or raw Lua patterns
- `show_mode`: `'both'` | `'translation'` | `'translation_conceal'` | `'origin'`
- `diagnostics`: `true` | `false` | `{ underline = ..., virtual_text = ... }` (passed to `vim.diagnostic.set`)
- `func_type`: Filetypes to scan for usage (defaults: vue, typescript, javascript, tsx, jsx, java, etc.)

### Pattern Expansion

File patterns like `src/locales/{locales}/{module}.ts` are expanded by:
1. `{locales}` replaced with each locale from config
2. Custom placeholders (`{module}`, `{business}`) discovered via filesystem globbing
3. Results cached per locale and prefix applied to flattened keys

### Show Modes

- `both`: Always show original key + translation inline
- `translation`: Hide key except on cursor line (shows key + translation on cursor line)
- `translation_conceal`: Hide key and suppress translation on cursor line (for editing raw keys)
- `origin`: Disable translation overlay entirely (show only original key)

Toggle commands: `:I18nToggleOrigin`, `:I18nToggleTranslation`

### Virtual Text Rendering

`display.lua` creates extmarks with `virt_text` and `virt_lines`:
- In source files: appends translation after i18n key call
- In locale files (when `show_locale_file_eol_translation` enabled): shows current locale's translation + usage count at EOL
- Conceal mechanism: uses extmark `conceal` to hide original key in `translation` / `translation_conceal` modes

### Diagnostics

When `diagnostics` is enabled (true or table), missing translations emit diagnostics at key positions. Dynamic keys (containing `..` or `+` for concatenation) are ignored to avoid false positives.

### Usage Scanner

- Async scan triggered after `VimEnter` via `usages.setup()`
- Uses `rg --files` or `git ls-files --exclude-standard`
- Filters by `func_type` extensions
- Parses each file for i18n function calls matching `func_pattern`
- Stores counts in `usages.counts[key]`
- Re-scans individual buffers on `BufWritePost` matching `func_type`

## Development Commands

### Manual Testing
```bash
# Load-time check (from a project with translation files)
nvim --headless "+lua require('i18n').setup()" +q

# Manual dev profile (create gitignored dev config if needed)
nvim --clean -u lua/i18n/dev.lua
```

### Help Documentation
```vim
" Regenerate help tags after editing doc/i18n.nvim.txt
:helptags doc
```

## Coding Style (from AGENTS.md)

- Two-space indentation
- `snake_case` for locals and functions
- Single-quoted strings (double for interpolation / embedded quotes)
- Module pattern: `local M = {}` at top, `return M` at end
- Public API: `M.function_name = function()`
- Private helpers: `local function helper_name()`
- Internal state: underscore prefix (`M._translation_files`)
- Place `require()` at top of module
- Use `pcall(require, ...)` for optional dependencies
- Use `vim.notify` with `[i18n]` prefix for user messages
- Return booleans from navigation helpers to enable LSP fallbacks
- Use `vim.tbl_deep_extend('force', ...)` for config merges
- Create namespaces at module scope with `vim.api.nvim_create_namespace()`
- Create augroups with `{ clear = true }` before registering autocmds
- Validate buffers/windows before use (`vim.api.nvim_buf_is_valid()`)

## Common Patterns

### Adding a New User Command
1. Define handler in appropriate module (e.g., `display.lua`, `navigation.lua`)
2. Export via `M.function_name` and proxy in `init.lua` if needed
3. Register command in `init.lua:setup()` using `vim.api.nvim_create_user_command`
4. Update `README.md` and `doc/i18n.nvim.txt`

### Extending `func_pattern`
- Plain strings are auto-converted to safe patterns with boundary and whitespace handling
- Tables allow custom `call`, `quotes`, `boundary`, `allow_whitespace`, `capture_pattern`
- Raw Lua patterns supported via `pattern` / `patterns` keys (ensure key is capture group 1)
- Normalization happens in `config.setup()` via `normalize_func_patterns()`

### Adding a Picker Integration
1. Create `lua/i18n/integration/<picker>.lua`
2. Implement `show_i18n_keys_with_<picker>()` that accepts options and returns boolean
3. Handle actions: copy key, copy translation, jump (with split/vsplit/tab variants), choose locale
4. Update `resolve_i18n_key_picker()` in `init.lua` to support new `popup_type`
5. Document in README.md

### Parser Extension (New File Format)
1. Add parsing function in `parser.lua` (e.g., `parse_toml()`)
2. Return flat table of `{ key = value }` and optional line/col maps
3. Update `load_file()` to detect file extension and route to parser
4. Add filetype to default `filetypes` in `display.lua` and `func_type` in `config.lua`

## File Watching

`parser._setup_file_watchers()` creates autocmds for all translation files:
- `BufWritePost`, `BufDelete`, `FileChangedShellPost`
- Callback: `parser.load_translations()` + `display.refresh()`
- Runs after each `load_translations()` call

## Testing

No automated test harness. Manual verification:
1. Create fixture project with sample translation files
2. Load plugin and trigger commands (`:I18nReload`, `:I18nAddKey`, etc.)
3. Verify virtual text, diagnostics, navigation, completion
4. Document steps in PRs

## Documentation Sync

When changing behavior:
- Update both `README.md` and `doc/i18n.nvim.txt`
- Keep command names and option descriptions synchronized
- Regenerate tags via `:helptags doc` before committing

## Common Gotchas

- **Lua patterns vs. raw strings**: Plain strings in `func_pattern` are auto-escaped; use `pattern` key for raw patterns
- **Line number accuracy**: JSON/YAML/properties use heuristic matching; JS/TS uses Tree-sitter for precision
- **Async operations**: Usage scanning is async; diagnostic refresh may lag until scan completes
- **Conceal conflicts**: Show modes that hide keys may conflict with user-configured conceallevel
- **Empty translations**: Missing keys show diagnostics; empty string values are valid translations
- **Placeholder expansion**: Custom placeholders in file patterns are discovered via glob; nonexistent paths are skipped silently
