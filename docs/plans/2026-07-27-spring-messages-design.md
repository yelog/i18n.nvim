# Spring MessageSource Design

## Goal

Support Spring message bundles as a first-class message source. A source file
can only resolve bundles belonging to its nearest Maven module; absent keys do
not fall back to parent, sibling, or globally scanned modules.

## Configuration

`message_source.provider` selects the resource provider:

```lua
message_source = {
  provider = 'spring_messages',
  spring_messages = {
    resource_root = 'src/main/resources',
    fallback_to_default_bundle = true,
    fallback_to_system_locale = false,
  },
}
```

No module-scope option is exposed. `spring_messages` always uses strict Maven
module isolation. The existing `namespace_resolver` remains responsible only
for rewriting logical keys and is not used for resource discovery.

## Detection

Auto detection identifies a Spring module when its nearest `pom.xml` contains
Spring dependencies or a Spring Boot parent and the module has either a
`spring.messages.basename` setting or a matching message bundle. Each matching
Maven module is discovered independently.

## Resolution

The provider resolves the nearest `pom.xml` from the source buffer, then loads
only resources below that module's `src/main/resources`. It reads configured
basenames from application or bootstrap properties/YAML, defaulting to
`messages`. Locale lookup follows the deterministic chain `zh_CN -> zh ->
default bundle`; it does not consult the system locale unless explicitly
enabled.

The parser stores entries by module root, basename, locale, and key. Display,
definition jumps, popups, completion, usage scans, and key creation must query
the same module-scoped API. Missing keys return `nil` without global fallback.

## Implementation Plan

1. Add normalized `message_source` defaults and retain generic source loading
   when the provider is not Spring.
2. Add a Spring message provider that discovers Maven modules, reads basenames,
   and produces module-scoped resource descriptors.
3. Replace parser's flat module-candidate fallback with a strict scoped index
   for Spring entries and update public lookup APIs.
4. Pass buffer context through key listings, pickers, usages, and key creation.
5. Detect Spring modules in auto mode, document the feature, and verify it
   against the moss-cloud layout and manual headless loading.
