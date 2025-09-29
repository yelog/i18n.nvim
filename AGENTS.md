# Repository Guidelines

## Project Structure & Module Organization
- Core plugin logic lives under `lua/i18n/`. `init.lua` wires setup and commands; `parser.lua`, `display.lua`, `navigation.lua`, and `add_key.lua` handle translation loading, inline rendering, motions, and key creation. Integrations for picker/completion live in `lua/i18n/integration/` (fzf, telescope, cmp, blink).
- Vim help content resides in `doc/i18n.nvim.txt` with tag file in `doc/tags`. Update both when user-facing behaviour changes.
- No dedicated test harness is shipped; sample configs are documented in `README.md` and should be mirrored in issues/fixtures when adding features.

## Build, Test, and Development Commands
- Use `nvim --headless "+lua require('i18n').setup()" +q` against a fixture project to catch load-time errors.
- Run `nvim --clean -u lua/i18n/dev.lua` (create ad hoc dev profiles in gitignored files) to iterate with predictable settings.
- When editing help docs, regenerate tags via `:helptags doc` inside Neovim before pushing.

## Coding Style & Naming Conventions
- Lua code uses two-space indentation, snake_case locals, and prefers single-quoted strings unless interpolation demands double quotes.
- Keep modules pure; expose user-facing helpers via `lua/i18n/init.lua` instead of requiring submodules directly.
- Inline comments should explain non-obvious Neovim APIs or performance considerations; avoid translating existing Chinese comments unless changing semantics.

## Testing Guidelines
- Add targeted fixtures under `tests/` (gitignored) or re-use example locale trees from the README when reproducing bugs.
- Document manual verification steps in the PR, naming Vim commands used (e.g., `:I18nReload`, `:I18nAddKey`, picker bindings).
- Aim to cover new parsers with unit-esque helper functions (`parser.lua`) and verify multiline locales to avoid regressions.

## Commit & Pull Request Guidelines
- Follow Conventional Commits as seen in history (`feat:`, `fix:`, `docs:`). Reference files or modules in the subject when helpful.
- Each PR should include: short summary, testing notes, screenshots or asciinema when UI output changes, and linked issues or TODOs.
- Keep PRs focused; separate parser refactors, UI tweaks, and integration changes so reviewers can validate with minimal context.

## Documentation Expectations
- Reflect behaviour changes in both `README.md` and `doc/i18n.nvim.txt`; keep command tables and option names synchronized.
- If adding commands, mention default keymaps and autocommand impact so downstream plugin managers can update recipes.
