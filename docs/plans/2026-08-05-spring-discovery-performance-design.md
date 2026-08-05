# Spring Discovery Performance Design

## Goal

Prevent Spring MessageSource auto-detection from blocking Neovim while opening
large non-Maven projects, without losing nested Maven module discovery.

## Scope

The change is limited to POM enumeration and duplicate discovery within one
activation cycle. Spring bundle parsing, module scoping, provider selection,
and the public configuration API remain unchanged.

## Approach

`spring_messages.lua` will own a `find_pom_files(root)` helper with three
ordered strategies:

1. Use `rg --files --hidden` with a `pom.xml` glob.
2. Fall back to `git ls-files` for tracked and untracked, non-ignored POMs.
3. Fall back to a Lua `uv.fs_scandir` traversal for non-Git projects.

Every strategy excludes `.git`, `node_modules`, and `target`. Results are
normalized to absolute paths, deduplicated, and sorted before bundle discovery.
An empty successful `rg` or Git result is authoritative; fallback occurs only
when the command is unavailable or cannot inspect the requested root.

`discover()` will memoize results by working directory, resource root, and
Spring requirement for the current event-loop turn. `vim.schedule()` clears the
memoized values after activation yields. This reuses the result between
framework detection and parser loading while allowing later reloads to observe
new modules.

## Error Handling

External command failures are not user-facing errors because the next strategy
can provide equivalent discovery. Unreadable directories in the Lua fallback
are skipped. A complete discovery failure returns no Spring descriptors, which
matches the current behavior when no POM is found.

## Verification

Headless Neovim checks will cover nested Spring modules and each available
fallback path. Existing plugin load behavior will be checked with
`require('i18n').setup()`. A benchmark in the `moss-web` project will compare
activation time against the measured approximately 4.1-second baseline, with a
target below 300 milliseconds on the same machine.
