---
title: "[MEDIUM] Critical billing path has no regression test"
severity: medium
domain: testing
lens: coverage
labels:
  - "audit:testing/coverage"
  - "severity:medium"
---

## Summary

This finding deliberately omits the `type:` frontmatter key. `finding_resolve_type`
must fall back to `domain_default_finding_type(testing)`, which resolves to
`test-gap`. This fixture pins the missing-type → domain-default path.

## Evidence

The checkout-to-invoice flow has zero automated coverage, so a regression would
ship unnoticed. With no explicit `type:`, the resolver relies on the `testing`
domain default.
