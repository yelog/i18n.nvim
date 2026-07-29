# Spring YAML Basename Parsing Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Safely discover `spring.messages.basename` from YAML Spring configuration without a YAML parser dependency.

**Architecture:** Keep `spring_messages.lua` as the single discovery boundary. Separate indentation capture from mapping-node recognition so YAML property lines can be inspected safely while `spring.messages` is active. Preserve the existing default `messages` fallback when no valid setting is found.

**Tech Stack:** Lua, Neovim headless mode, native Vimscript file APIs.

---

### Task 1: Make YAML state handling safe

**Files:**
- Modify: `lua/i18n/spring_messages.lua:41-64`

**Step 1: Reproduce with a temporary Maven fixture**

Run a headless Neovim command that creates `src/main/resources/application.yaml`
with `spring.messages.basename: static/i18n/messages` and a matching
`messages.properties` bundle, invokes `require('i18n.spring_messages').discover`,

**Step 2: Implement the smallest state-machine correction**

Capture indentation independently for each non-empty YAML line. Update `spring`
and `messages` scope only for block mapping nodes. Match `basename` separately
only below the active `messages` indentation. Strip a trailing YAML comment
before splitting comma-separated basenames.

**Step 3: Run the fixture again**

Run the same headless command. Expected: no scheduled callback error and a

### Task 2: Verify compatibility paths

**Files:**
- Verify: `lua/i18n/spring_messages.lua`
- Verify: `README.md:341-361`
- Verify: `doc/i18n.nvim.txt:244-256`

**Step 1: Verify quoted multiple basenames**

Run a headless fixture using:

```yaml
spring:
  messages:
    basename: "i18n/messages, static/i18n/errors" # bundles
```

Expected: descriptors from both configured basenames, with locales retained.

**Step 2: Verify the default fallback**

Run a fixture without `spring.messages.basename` but containing
`messages_zh.properties`. Expected: discovery returns that bundle with locale
`zh`.

**Step 3: Check public documentation**

No option or user-visible behavior changes, so documentation text remains valid
and should not be changed.

### Task 3: Check plugin loadability

**Files:**
- Verify: `lua/i18n/init.lua`

**Step 1: Run the documented load-time check**

Run: `nvim --headless "+lua require('i18n').setup()" +q`

Expected: process exits with code 0.

**Step 2: Inspect the final diff**

Run: `git diff --check` and `git diff -- lua/i18n/spring_messages.lua docs/plans/`

Expected: no whitespace errors; only the YAML scanner and the design/plan
records changed.
