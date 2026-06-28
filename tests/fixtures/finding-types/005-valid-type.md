---
title: "[MEDIUM] N+1 query renders the dashboard in O(rows) round-trips"
severity: medium
type: performance-risk
domain: code-quality
lens: hotpath
labels:
  - "audit:code-quality/hotpath"
  - "severity:medium"
---

## Summary

The explicit `type: performance-risk` is a canonical finding-type. It must win
over the `code-quality` domain default (which would otherwise resolve to
`maintainability`). This fixture pins the explicit-type-wins-over-domain path:
`finding_resolve_type` returns `performance-risk`, not `maintainability`.

## Evidence

The dashboard issues one query per row instead of a single batched query, so
render time grows linearly with the dataset. The explicit `type:` overrides the
domain's default classification.
