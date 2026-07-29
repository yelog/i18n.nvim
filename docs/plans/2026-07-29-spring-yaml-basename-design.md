# Spring YAML Basename Parsing Design

## Goal

Make Spring MessageSource discovery safely recognize
`spring.messages.basename` from common YAML configuration without adding a YAML
parser dependency or changing the public configuration API.

## Scope

The scanner continues to support `application.yml`, `application.yaml`,
`bootstrap.yml`, and `bootstrap.yaml`. It recognizes a `basename` value only
while it is nested below `spring.messages`. It supports plain and quoted values,
comma-separated basenames, and an optional trailing YAML comment.

## Approach

The current scanner conflates mapping-node detection with property-value
detection. A `basename: value` line therefore has no node-match indentation,
which can cause an attempt to take the length of `nil`.

The revised scanner keeps its structural state from indentation captured for
every non-empty line. It separately detects mapping nodes and `basename`
properties. A property is considered only when its indentation is deeper than
the active `messages` node. Returning to the `spring` indentation or less
clears the active state.

## Error Handling

Malformed or unsupported YAML does not raise an error. Discovery simply ignores
the unrecognized setting and retains the existing `messages` basename fallback.

## Verification

A headless Neovim regression script will create a temporary Maven Spring
fixture and assert discovery for a nested YAML basename, including a quoted,
commented multi-basename value. It will also assert the default basename
fallback when no setting is present.
