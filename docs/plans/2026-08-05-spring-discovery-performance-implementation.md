# Spring Discovery Performance Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace blocking recursive POM globbing with ignore-aware discovery and reuse duplicate Spring discovery within one activation cycle.

**Architecture:** `spring_messages.lua` remains the single Spring discovery boundary. It enumerates POMs through `rg`, Git, or a bounded Lua fallback, then memoizes the complete discovery result only until the current event-loop turn ends.

**Tech Stack:** Lua, Neovim Lua API, libuv filesystem APIs, ripgrep, Git, headless Neovim

---

### Task 1: Add ignore-aware POM enumeration

**Files:**
- Modify: `lua/i18n/spring_messages.lua:1-163`

**Step 1: Capture the current performance failure**

Run the existing plugin against `moss-web` with `usage.scan_on_startup = false`
and record `require('i18n').activate()` elapsed time.

Expected: approximately 4.1 seconds before the implementation.

**Step 2: Implement normalized result collection**

Add helpers that turn relative paths into absolute paths, reject paths under
`.git`, `node_modules`, and `target`, deduplicate paths, and return sorted output.

**Step 3: Implement the three discovery strategies**

Add `rg` discovery using `rg --files --hidden -g pom.xml` and explicit excluded
directory globs. Fall back to `git ls-files --cached --others
--exclude-standard`, then to recursive `vim.loop.fs_scandir`. Treat exit status
0 or 1 from `rg` as a completed query so an empty project does not trigger a
slower fallback.

**Step 4: Replace recursive Vim globbing**

Change `M.discover()` to iterate over `find_pom_files(vim.fn.getcwd())` instead
of `vim.fn.globpath(..., '**/pom.xml', ...)`.

**Step 5: Run a nested Maven fixture check**

Create a temporary ignored fixture containing a nested Spring POM and
`messages.properties`, invoke `spring_messages.discover()`, and assert one
descriptor with the nested module root.

Expected: the assertion passes with `rg` available.

### Task 2: Reuse duplicate discovery during activation

**Files:**
- Modify: `lua/i18n/spring_messages.lua`

**Step 1: Add an event-loop-scoped cache**

Key cached results by normalized working directory, `resource_root`, and
`require_spring`. Store descriptors and locales after discovery and schedule a
single cache clear with `vim.schedule()`.

**Step 2: Protect cached values from callers**

Return fresh array copies so parser or framework callers cannot mutate the
cached result shared by the other activation phase.

**Step 3: Verify invalidation**

Call discovery twice synchronously and assert equivalent results. Add a POM
after the scheduled clear, call discovery again, and assert the new module is
visible.

Expected: synchronous duplicate calls reuse enumeration; a later event-loop
turn observes filesystem changes.

### Task 3: Verify fallback behavior

**Files:**
- Verify: `lua/i18n/spring_messages.lua`

**Step 1: Verify Git fallback**

Run headless Neovim with a `PATH` that contains Git but not `rg` against a
temporary Git fixture containing a nested Spring module.

Expected: discovery returns the module and ignores an ignored POM.

**Step 2: Verify Lua fallback**

Run headless Neovim with neither `rg` nor Git visible against a non-Git fixture.
Include valid nested POMs plus decoy POMs under `node_modules` and `target`.

Expected: only valid modules are discovered.

**Step 3: Check malformed and unreadable paths**

Run discovery against an empty fixture and a directory containing an unreadable
subdirectory where supported.

Expected: discovery returns empty arrays without raising an error.

### Task 4: Document discovery behavior

**Files:**
- Modify: `README.md:341-365`
- Modify: `doc/i18n.nvim.txt:244-260`

**Step 1: Update user documentation**

Document that Maven discovery respects project ignore rules, excludes generated
dependency/build directories, and uses `rg`, Git, then Lua fallback.

**Step 2: Regenerate help tags**

Run: `nvim --headless -u NONE -c 'helptags doc' -c qa`

Expected: command exits successfully; `doc/tags` remains synchronized.

### Task 5: Run regression and performance verification

**Files:**
- Verify: `lua/i18n/spring_messages.lua`
- Verify: `README.md`
- Verify: `doc/i18n.nvim.txt`

**Step 1: Run the plugin load check**

Run: `nvim --headless --clean --cmd 'set runtimepath^=.' "+lua require('i18n').setup()" +q`

Expected: exit status 0 with no Lua errors.

**Step 2: Benchmark `moss-web` activation**

Repeat the baseline command with startup usage scanning disabled.

Expected: activation completes below 300 milliseconds on the same machine,
down from approximately 4.1 seconds.

**Step 3: Check the final diff**

Run: `git diff --check`

Expected: no whitespace errors.

Run: `git status --short`

Expected: only the intended Lua, documentation, and plan files are modified.
