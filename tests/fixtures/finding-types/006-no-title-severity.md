---
title: "Connection pool is never closed on shutdown"
severity: low
type: reliability-bug
domain: error-handling
lens: lifecycle
labels:
  - "audit:error-handling/lifecycle"
  - "severity:low"
---

## Summary

The title carries no leading `[SEVERITY]` prefix, so `severity_from_title`
returns empty and the detector reports no mismatch: it prints the frontmatter
`severity: low` and exits 0. This fixture pins the no-title-prefix path, where
the title cannot disagree with the frontmatter.

## Evidence

The pooled connections are not released during graceful shutdown, slowly leaking
sockets across restarts. The plain title intentionally omits any bracketed
severity word.
