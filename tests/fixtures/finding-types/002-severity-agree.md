---
title: "[MEDIUM] Missing rate limit on the password-reset endpoint"
severity: medium
type: security-vulnerability
domain: security
lens: auth
labels:
  - "audit:security/auth"
  - "severity:medium"
---

## Summary

The title's `[MEDIUM]` prefix agrees with the frontmatter `severity: medium`.
The detector must print `medium` and exit 0 (no mismatch). This fixture pins the
happy path where the title and frontmatter severities concur.

## Evidence

The password-reset endpoint accepts unlimited attempts, enabling enumeration and
brute force; both the title prefix and the frontmatter rate it medium.
