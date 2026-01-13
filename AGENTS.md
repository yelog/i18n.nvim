# Repository Guidelines

## Scope & Purpose
- This file guides agentic coding in this repo.
- Prefer minimal, focused changes that match existing patterns.
- Do not add new tooling (linters/tests) unless explicitly requested.

## Project Structure & Module Organization
- Core plugin logic lives under `lua/i18n/`.
- `init.lua` wires setup and user-facing API/commands.
- `parser.lua`, `display.lua`, `navigation.lua`, `add_key.lua`, `usages.lua` handle parsing, rendering, navigation, key creation, and usage scans.
- Integrations live in `lua/i18n/integration/` (fzf, telescope, cmp, blink).
- Vim help content lives in `doc/i18n.nvim.txt`; tag file in `doc/tags`.
- Keep modules pure; expose user-facing helpers via `lua/i18n/init.lua` instead of requiring submodules directly.

## Build, Test, and Development Commands
- No automated build/lint/test tooling is configured.
- No single-test invocation exists because there is no test harness.
- Manual load-time check (run from a fixture project):
  - `nvim --headless "+lua require('i18n').setup()" +q`
- Manual dev profile (create gitignored dev config):
  - `nvim --clean -u lua/i18n/dev.lua`
- Help tags regeneration (inside Neovim):
  - `:helptags doc`

## Documentation Expectations
- Update both `README.md` and `doc/i18n.nvim.txt` when behavior changes.
- Keep command tables and option names synchronized between docs.
- If adding commands, mention default keymaps and autocommand impact.
- When editing help docs, regenerate tags via `:helptags doc` before pushing.

## Coding Style & Naming Conventions
- Lua uses two-space indentation.
- Use snake_case for locals and function names.
- Prefer single-quoted strings unless interpolation or embedded single quotes require double quotes.
- Module pattern: `local M = {}` at top; `return M` at end.
- Public API: `M.function_name = function()`.
- Private helpers: `local function helper_name()`.
- Internal state uses underscore prefix: `M._translation_files`.
- Avoid one-letter variable names unless matching existing surrounding style.

## Imports / Requires
- Place `require()` calls at top of module.
- Optional dependencies use `pcall(require, ...)` and fall back gracefully.
- Prefer local module requires (e.g., `i18n.config`, `i18n.utils`) over deep user imports.

## Error Handling & Notifications
- Guard optional modules and Neovim API calls with `pcall`.
- Use `vim.notify` with `[i18n]` prefix for user-facing messages.
- Prefer `vim.log.levels.WARN/INFO/ERROR` for severity.
- Return booleans from navigation helpers to allow LSP fallbacks.
- Validate inputs early with `type(...)` and `nil` checks.

## Tables & Iteration
- Use `vim.tbl_isempty()` to check empty tables.
- Use `pairs()` for maps, `ipairs()` for arrays.
- Use `vim.tbl_deep_extend('force', ...)` for config merges.

## Neovim API Patterns
- Create namespaces at module scope with `vim.api.nvim_create_namespace()`.
- Create augroups with `{ clear = true }` before registering autocmds.
- Use `vim.schedule()` or `vim.defer_fn()` for UI-safe or deferred updates.
- Validate buffers/windows with `vim.api.nvim_buf_is_valid()` / `vim.api.nvim_win_is_valid()` before use.

## Comments
- Inline comments should explain non-obvious Neovim APIs or performance considerations.
- Preserve existing Chinese comments; do not translate unless changing semantics.

## Testing & Verification Guidance
- No dedicated test harness is shipped; use manual verification.
- Re-use sample configs from `README.md` when reproducing bugs.
- Add targeted fixtures under `tests/` (gitignored) if needed.
- Document manual verification steps in PRs, naming Vim commands used (e.g., `:I18nReload`, `:I18nAddKey`).

## Commit & Pull Request Guidelines
- Follow Conventional Commits (`feat:`, `fix:`, `docs:`, etc.).
- Reference files or modules in subject when helpful.
- Keep PRs focused; separate parser refactors, UI tweaks, and integration changes.
- Include summary, testing notes, and screenshots/asciinema for UI changes.
- Link related issues or TODOs.

## Repo Rules Discovery
- No `.cursor/rules/`, `.cursorrules`, or `.github/copilot-instructions.md` found.
- If such files are added later, their rules override this document for scoped paths.
