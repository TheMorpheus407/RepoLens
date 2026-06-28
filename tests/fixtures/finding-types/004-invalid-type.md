---
title: "[HIGH] Auth token logged in plaintext"
severity: high
type: bogus
domain: security
lens: secrets
labels:
  - "audit:security/secrets"
  - "severity:high"
---

## Summary

The `type: bogus` value is not a canonical finding-type and is not a recognized
alias, so `finding_type_normalize` returns empty. `finding_resolve_type` must
then fall back to `domain_default_finding_type(security)`, which resolves to
`security-vulnerability`. The `security` domain is chosen on purpose because its
default differs from the `maintainability` catch-all, so a passing assertion
proves the fallback path actually ran rather than coincidentally matching the
default.

## Evidence

A bearer token is written to the application log at info level, exposing it to
anyone with log access.
