# Lens-Based Auditing: The RepoLens Methodology

> **Version:** v0.1 — This document is a preliminary draft/stub. Sections will be expanded in future revisions.

---

## Abstract

RepoLens implements **Lens-Based Auditing (LBA)**, a methodology for automated code analysis that decomposes the audit problem into 297 narrow-focus specialist agents ("lenses") across 30 domains. Rather than asking a single generalist agent to review an entire codebase for every possible concern, LBA assigns each concern to a dedicated expert lens — one that examines the code through a single, specific perspective.

The tool currently supports 8 modes of operation (audit, feature, bugfix, discover, deploy, opensource, content, custom), multiple agent backends, parallel execution, and automated GitHub issue creation. This document describes the methodology behind the tool: what Lensing is, why it works, and how its components fit together.

---

## Core Concept: Lensing and Lens-Based Auditing (LBA)

**Lensing** is the act of examining a codebase through a single, narrow expert perspective. Each "lens" is a prompt template consisting of YAML frontmatter (defining its `id`, `domain`, `name`, and `role`) and an expert focus body that details exactly what patterns to look for, how to investigate them, and what constitutes a real finding.

At execution time, a template engine merges a mode-specific base template with the individual lens body and substitutes runtime variables (repository name, lens label, project path). The result is a fully composed prompt that gives the agent:

1. Universal behavioral rules (issue format, deduplication, termination protocol)
2. Deep domain-specific expertise (the lens body)
3. Runtime context (project path, repository owner, labels)

**Lens-Based Auditing (LBA)** is the methodology built on Lensing: run many lenses independently against the same codebase, each creating GitHub issues for real findings. Its key properties are:

- **Single responsibility** — each lens examines one aspect only
- **Deep specialization** — lens prompts encode detailed expert knowledge
- **Independent iteration** — each lens runs its own loop until it declares itself done
- **Deterministic termination** — the DONE×3 streak protocol prevents premature or runaway exits
- **Parallel execution** — lenses run concurrently via a file-based semaphore, with no shared state
- **Agent-agnostic** — any LLM agent CLI (claude, codex, spark, opencode) can execute lenses

The current lens inventory spans 30 domains with 297 total lenses, broken down as: 209 code analysis + 18 tool gate + 14 product discovery + 26 deployment/server audit + 13 open-source readiness + 17 content quality.

---

## Why LBA Differs from Monolithic LLM Code Review

Traditional monolithic LLM code review asks a single prompt to cover all concerns — security, performance, architecture, testing, accessibility, and more — simultaneously. This approach suffers from **attention dilution**: each concern receives shallow treatment because the model's context window and focus are spread thin across every domain at once.

LBA takes the opposite approach. By assigning one prompt per concern (297 total), each lens can devote its full context window and specialization depth to a single domain. The advantages of this decomposition include:

| Dimension | Monolithic Review | Lens-Based Auditing |
|-----------|-------------------|---------------------|
| **Expertise depth** | Shallow across everything | Deep within each lens |
| **Context window** | Consumed by instructions for all domains | Fully devoted to one domain |
| **Parallelism** | Sequential, single-threaded | Concurrent agents |
| **Scalability** | Add more to the prompt (diminishing returns) | Add a new `.md` file (linear scaling) |
| **Coverage** | Hard to verify — reviewer fatigue | Measurable — each domain has defined lenses |

The fundamental insight is that LBA trades breadth-per-call for depth-per-call, achieving total coverage through the aggregate of many narrow specialists rather than one broad generalist.

---

## The DONE×3 Streak Protocol

The DONE streak protocol is LBA's deterministic termination mechanism. It ensures that each lens runs long enough to be thorough, but stops when genuinely finished.

**How it works:**

1. Each lens runs in an iteration loop.
2. After each iteration, the agent's output is inspected: if the first or last word (normalized to uppercase) equals "DONE", the iteration counts toward the streak.
3. A `done_streak` counter tracks consecutive DONE detections. If the agent outputs DONE, the counter increments; if it does not, the counter resets to zero.
4. When `done_streak` reaches the required threshold, the lens loop exits and the lens is marked complete.

**Streak thresholds by mode:**

| Modes | Streak Required | Rationale |
|-------|----------------|-----------|
| audit, feature, bugfix | 3 | Multi-pass exhaustive search — the agent must confirm "nothing left to find" 3 consecutive times |
| discover, deploy, custom, opensource, content | 1 | Single-pass modes — one comprehensive sweep is sufficient |

**Why 3 consecutive DONEs?** A single DONE can be premature — the agent may have missed areas it has not yet explored. Requiring 3 consecutive DONEs forces the agent through at least 3 iterations where it genuinely finds nothing new, providing high confidence of completeness. If the agent discovers something on iteration N+1, the streak resets to 0 and the cycle continues.

A safety cap of 20 iterations per lens prevents runaway loops regardless of DONE detection.

---

## Parallel Agent Execution Model

LBA lenses are designed to run independently, which enables parallel execution. RepoLens implements concurrency through a file-based semaphore system.

**How it works:**

- A semaphore directory holds token files — one per running lens.
- Before a lens starts, it acquires a semaphore slot by checking how many token files exist. If the count is below the concurrency limit (default: 8 simultaneous agents), the lens creates its token and proceeds. Otherwise, it waits.
- When a lens completes (or crashes), its token file is removed, freeing the slot for another lens.
- Signal handlers ensure clean shutdown: on interrupt, all child processes are tracked and terminated.

Each lens subprocess operates independently — there is no shared state between lenses. Results are collected atomically, and completed lenses are tracked in a `.completed` file that enables resume support across interrupted runs.

The system falls back to sequential execution automatically when global constraints require it (e.g., issue budget enforcement or hosted scanning modes where concurrent operation would cause conflicts).

---

## Mode Isolation

RepoLens supports 8 modes of operation. Mode isolation ensures that each mode sees only the domains and lenses relevant to its purpose, preventing cross-contamination between fundamentally different audit strategies.

Mode isolation is implemented through three mechanisms:

1. **Domain filtering** — A `"mode"` field in the domain registry controls which domains are visible to each mode
2. **Base prompt selection** — Each mode has a dedicated base template that shapes agent behavior
3. **Behavioral parameters** — DONE streak threshold, label prefix, issue severity schema, and confirmation gates vary per mode

**The 8 modes:**

| Mode | Purpose | Visible Lenses |
|------|---------|---------------|
| **audit** | Find real issues in existing code | 227 (code + toolgate domains) |
| **feature** | Identify missing capabilities | 227 |
| **bugfix** | Find bugs backed by evidence | 227 |
| **custom** | Change impact analysis | 227 |
| **discover** | Brainstorm product ideas | 14 (discovery domain only) |
| **deploy** | Read-only live server inspection | 26 (deployment domain only) |
| **opensource** | Public release risk assessment | 13 (open-source readiness only) |
| **content** | Content quality and creation | 17 (content quality only) |

Each mode uses its own severity schema (e.g., audit uses CRITICAL/HIGH/MEDIUM/LOW, discover uses SMALL/MEDIUM/LARGE/XL, custom uses BREAKING/REQUIRED/RECOMMENDED/OPTIONAL) and its own GitHub label format.

Deploy mode is unique in that it does not require a git repository — it operates on live servers using system commands (systemctl, ss, df, journalctl) in a strictly read-only fashion, with explicit legal authorization gates.

---

## Future Work

The following directions are natural extensions of Lens-Based Auditing:

- **Scoring and prioritization** — Aggregate lens findings into a composite quality score
- **Custom lens SDK** — Formalize the lens file format for third-party lens creation
- **Cross-lens correlation** — Detect when findings from different lenses relate to the same root cause
- **Historical tracking** — Compare findings across runs to track improvement over time
- **Confidence calibration** — Measure false positive rates per lens and adjust thresholds
- **Multi-agent collaboration** — Allow lenses within a domain to share context
- **Language-specific lens packs** — Pre-built lens sets optimized for specific ecosystems (Rust, Python, TypeScript, etc.)

These expansions will be explored in future versions of this document and in the RepoLens roadmap.

---

## Citation

Created by Cedric Moessner.
Bootstrap Academy.

> If you reference this methodology in academic or professional work, please cite:
>
> Moessner, C. (2026). *Lens-Based Auditing: A Methodology for Multi-Agent Code Analysis.* RepoLens Project, Bootstrap Academy.
