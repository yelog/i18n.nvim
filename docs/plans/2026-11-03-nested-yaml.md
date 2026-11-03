# Nested YAML Translation Parsing Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Resolve nested YAML translation keys with accurate definition positions while retaining the existing parser as a fallback when the YAML Tree-sitter parser is unavailable.

**Architecture:** Keep `parse_yaml` as the shared entry point for disk loads and unsaved buffers. Use Tree-sitter for mapping structure and coordinates, and an internal YAML module for scalar decoding. Preserve the three return values (`result`, `line_map`, `col_map`) and the existing flattened key format without adding dependencies or public options.

**Tech Stack:** Lua, Neovim Tree-sitter APIs, the optional `yaml` grammar, temporary headless fixtures, and the system Ruby YAML loader as a scalar verification reference.

---

### Task 1: Establish regression fixtures

**Files:** Temporary Lua/YAML fixtures outside the repository; no test framework.

1. Reproduce issue #8 through `parser.load_translations()` and assert that the
   nested key and its definition location are missing before the change.
2. Cover duplicate leaf names, quoted/Unicode keys, comments, blank lines,
   CRLF, flow mappings, strings, escapes, and literal/folded block scalars.
3. Exercise disk reload, unsaved buffer reload, source prefixes, missing grammar,
   parser creation errors, and malformed YAML during editing.

### Task 2: Implement YAML parsing

**Files:** Create `lua/i18n/yaml.lua`; modify `lua/i18n/parser.lua` and the
translation-buffer position tracking in `lua/i18n/display.lua`.

1. Protect `get_string_parser(content, 'yaml')` and `parse()` with `pcall`.
   On parser unavailability, retain the legacy flat parser. A syntax-error tree
   returns no result instead of being flattened by the fallback.
2. Traverse block/flow mappings recursively, concatenate parent keys with `.`,
   and index only scalar leaves. Record each key node's start position as
   one-based row and byte column.
3. Decode plain/single/double quoted strings, YAML escapes, flow line folding,
   and `|`/`>` block scalars with indentation and chomping indicators. Keep plain
   numeric/boolean/null spellings as strings for compatibility.
4. Skip sequences, aliases, merge entries, complex keys, and tagged values;
   do not pretend their source text is a resolved translation.
5. Keep both existing disk and buffer call sites routed through `parse_yaml`.
   Preserve actual line numbers and populate columns in the flat fallback.
6. Preserve the buffer's final-newline option when parsing YAML block scalars.
   Refresh existing YAML position marks from newly parsed coordinates, and
   cache a buffer's parsed tick only after successful parsing.

### Task 3: Document the support boundary

**Files:** Modify `README.md` and `doc/i18n.nvim.txt`; regenerate `doc/tags`.

1. Explain the optional `yaml` grammar, nested key example, supported scalar
   styles, exact locations, unsupported constructs, and flat fallback.
2. Clarify that there are no new commands, keymaps, or autocommands.

### Task 4: Verify and review

1. Run the temporary fixtures with and without the YAML grammar, including
   actual navigation, unsaved edits, syntax errors, and file reloads.
2. Compare scalar results against Ruby YAML for representative folding,
   escaping, indentation, and chomping examples.
3. Run a headless plugin setup in a fixture project and JSON/JS/TS smoke cases.
4. Run `nvim --headless -u NONE -i NONE '+helptags doc' +qa` and
   `git diff --check`, inspect the final diff, and report actual results.
5. Commit only after the user explicitly requests it and the review and
   verification pass. Pushing requires a separate user request.
