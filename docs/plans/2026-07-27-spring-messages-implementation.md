# Spring MessageSource Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Load Spring message bundles per Maven module and resolve keys strictly within the current module.

**Architecture:** A Spring provider discovers each Maven module's resource bundles and returns descriptors tagged with the module root. The parser retains generic source loading, but indexes Spring entries by module root and resolves all Spring lookups only within the current buffer's nearest module.

**Tech Stack:** Lua, Neovim API, Maven POM files, Spring Boot properties/YAML conventions.

---

### Task 1: Add Spring message configuration

**Files:**
- Modify: `lua/i18n/config.lua`
- Modify: `README.md`
- Modify: `doc/i18n.nvim.txt`

**Step 1:** Add a disabled-by-default `message_source` configuration with `provider = 'auto'|'generic'|'spring_messages'` and Spring resource options.

**Step 2:** Document that `spring_messages` always isolates the nearest Maven module and does not use `namespace_resolver`.

**Step 3:** Validate Neovim can load the default configuration.

### Task 2: Discover Spring bundles

**Files:**
- Create: `lua/i18n/spring_messages.lua`

**Step 1:** Implement module-root lookup by nearest `pom.xml` and detect Spring dependencies from that POM.

**Step 2:** Read supported application/bootstrap properties files for `spring.messages.basename`; default to `messages` when absent.

**Step 3:** Locate locale bundles beneath each module resource root and return their locale, basename, path, and module root.

**Step 4:** Run a headless Lua check against the moss-cloud fixture and verify four independent module roots are discovered.

### Task 3: Make parser resolution module-strict

**Files:**
- Modify: `lua/i18n/parser.lua`

**Step 1:** Load Spring descriptors instead of generic sources when the configured or detected provider is Spring.

**Step 2:** Build a module-keyed index and ensure Spring lookup APIs return `nil` when the current module lacks a key.

**Step 3:** Preserve existing generic-source behavior without a `message_source` provider.

**Step 4:** Run a headless check that the same key resolves in its own module and does not resolve from a sibling module.

### Task 4: Complete context-aware consumers

**Files:**
- Modify: `lua/i18n/display.lua`
- Modify: `lua/i18n/navigation.lua`
- Modify: `lua/i18n/key_picker.lua`
- Modify: `lua/i18n/integration/fzf.lua`
- Modify: `lua/i18n/integration/telescope.lua`
- Modify: `lua/i18n/integration/cmp.lua`
- Modify: `lua/i18n/integration/blink.lua`
- Modify: `lua/i18n/add_key.lua`
- Modify: `lua/i18n/usages.lua`

**Step 1:** Replace direct global-key access with parser APIs that receive the active buffer path.

**Step 2:** Ensure key creation selects only a translation file in the current module and reports absence instead of writing to another module.

**Step 3:** Ensure usage scans ignore keys outside the scanned file's module.

**Step 4:** Manually exercise display, definition lookup, picker, and add-key behavior in two modules with conflicting keys.

### Task 5: Verify and commit

**Files:**
- Modify: `README.md`
- Modify: `doc/i18n.nvim.txt`

**Step 1:** Run `nvim --headless "+lua require('i18n').setup()" +q`.

**Step 2:** Run `git diff --check` and inspect the staged diff.

**Step 3:** Commit the focused implementation and documentation with a Conventional Commit message.
