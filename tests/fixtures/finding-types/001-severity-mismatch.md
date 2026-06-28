---
title: "[LOW] SQL query interpolates request input without parameterization"
severity: high
type: security-vulnerability
domain: security
lens: injection
labels:
  - "audit:security/injection"
  - "severity:high"
---

## Summary

The title's `[LOW]` prefix disagrees with the frontmatter `severity: high`.
Frontmatter is the single source of truth (issue #331), so the detector must
keep `high` as the authoritative severity and signal the disagreement via its
exit code. This fixture pins that mismatch path.

## Evidence

A request-derived string is concatenated straight into a SQL statement, so the
real-world severity is high regardless of the under-stated title prefix.
