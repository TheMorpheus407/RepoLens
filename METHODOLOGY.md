# Lens-Based Auditing: The RepoLens Methodology

> **Version:** v0.1 — This document is a preliminary draft/stub. Sections will be expanded in future revisions.

---

## Abstract

RepoLens implements **Lens-Based Auditing (LBA)**, a methodology for automated code analysis that decomposes the audit problem into 336 narrow-focus specialist agents ("lenses") across 33 domains. Rather than asking a single generalist agent to review an entire codebase for every possible concern, LBA assigns each concern to a dedicated expert lens — one that examines the code through a single, specific perspective.

The tool currently supports 11 modes of operation (audit, feature, bugfix, bugreport, discover, deploy, opensource, content, greenfield, custom, polish), multiple agent backends, parallel execution, automated issue creation, and ranked polishing shortlists. This document describes the methodology behind the tool: what Lensing is, why it works, and how its components fit together.

---

## Core Concept: Lensing and Lens-Based Auditing (LBA)

**Lensing** is the act of examining a codebase through a single, narrow expert perspective. Each "lens" is a prompt template consisting of YAML frontmatter (defining its `id`, `domain`, `name`, and `role`) and an expert focus body that details exactly what patterns to look for, how to investigate them, and what constitutes a real finding.

At execution time, a template engine merges a mode-specific base template with the individual lens body and substitutes runtime variables (repository name, lens label, project path). The result is a fully composed prompt that gives the agent:

1. Universal behavioral rules (issue format, deduplication, termination protocol)
2. Deep domain-specific expertise (the lens body)
3. Runtime context (project path, repository owner, labels)

**Lens-Based Auditing (LBA)** is the methodology built on Lensing: run many lenses independently against the same codebase, each producing mode-specific output such as issues, local files, ranked artifacts, or polishing shortlists. Its key properties are:

- **Single responsibility** — each lens examines one aspect only
- **Deep specialization** — lens prompts encode detailed expert knowledge
- **Independent iteration** — each lens runs its own loop until it declares itself done
- **Deterministic termination** — the DONE×3 streak protocol prevents premature or runaway exits
- **Parallel execution** — lenses run concurrently via a file-based semaphore, with no shared state
- **Agent-agnostic** — any LLM agent CLI (claude, codex, spark, opencode) can execute lenses

The current lens inventory spans 33 domains with 336 total lenses, broken down as: 230 code analysis/audit-visible lenses (209 code analysis plus 21 runtime log analysis) + 18 tool gate + 14 product discovery + 43 deployment and Android audit + 13 open-source readiness + 17 content quality + 1 greenfield planning. Polish mode adds 16 suggestion lenses across the `fluency`, `effort-signal`, and `hedonic` domains.

---

## Why LBA Differs from Monolithic LLM Code Review

Traditional monolithic LLM code review asks a single prompt to cover all concerns — security, performance, architecture, testing, accessibility, and more — simultaneously. This approach suffers from **attention dilution**: each concern receives shallow treatment because the model's context window and focus are spread thin across every domain at once.

LBA takes the opposite approach. By assigning one prompt per concern (336 total), each lens can devote its full context window and specialization depth to a single domain. The advantages of this decomposition include:

| Dimension | Monolithic Review | Lens-Based Auditing |
|-----------|-------------------|---------------------|
| **Expertise depth** | Shallow across everything | Deep within each lens |
| **Context window** | Consumed by instructions for all domains | Fully devoted to one domain |
| **Parallelism** | Sequential, single-threaded | Concurrent agents |
| **Scalability** | Add more to the prompt (diminishing returns) | Add a new `.md` file (linear scaling) |
| **Coverage** | Hard to verify — reviewer fatigue | Measurable — each domain has defined lenses |

The fundamental insight is that LBA trades breadth-per-call for depth-per-call, achieving total coverage through the aggregate of many narrow specialists rather than one broad generalist.

---

## The DONE×N Streak Protocol (within-lens iteration)

The DONE streak protocol is LBA's deterministic termination mechanism for a **single lens**. It ensures that each lens runs long enough to be thorough, but stops when that lens is genuinely finished. The depth threshold `N` is controlled by `--depth N` (per-mode defaults below).

This mechanism operates strictly *within* one lens. In particular:

- **Per-lens** — scoped to a single lens invocation chain. Other lenses run their own independent DONE streaks.
- **Single-context but with fresh agent invocations** — each iteration is a fresh agent process, not a continuation of the previous one. There is no in-process conversational memory between iterations.
- **Backed by external memory via the GitHub issue list** — the lens reads the existing repository issues at the start of each iteration to avoid duplicating prior findings. The issue tracker, not the agent's context, is the persistent state.
- **Complementary to — not equivalent to — `--rounds N`.** DONE×N controls how deeply *one* lens digs. `--rounds N` controls how many times the *entire selected lens set* is dispatched, with cross-pollination via a meta-orchestrator between rounds. See the "Multi-Round Investigation with Meta-Orchestrator" section below and the `--rounds N` vs `--depth N` cross-reference for details.

**How it works:**

1. Each lens runs in an iteration loop.
2. After each iteration, the agent's output is inspected: if the first or last word (normalized to uppercase) equals "DONE", the iteration counts toward the streak.
3. A `done_streak` counter tracks consecutive DONE detections. If the agent outputs DONE, the counter increments; if it does not, the counter resets to zero.
4. When `done_streak` reaches the required threshold `N`, the lens loop exits and the lens is marked complete.

**Streak thresholds by mode:**

RepoLens resolves these thresholds from a single per-mode default table; the values below are the CLI defaults and may be overridden with `--depth N` (valid range: 1..19).

| Modes | Streak Required (N) | Rationale |
|-------|---------------------|-----------|
| audit, feature, bugfix | 3 | Multi-pass exhaustive search — the agent must confirm "nothing left to find" 3 consecutive times |
| discover, deploy, custom, opensource, content, greenfield, polish | 1 | Single-pass modes — one comprehensive sweep is sufficient |

Runs started with `--max-issues` use an effective 1× streak so the issue budget is enforced promptly.

**Why N=3 consecutive DONEs (in audit/feature/bugfix)?** A single DONE can be premature — the agent may have missed areas it has not yet explored. Requiring 3 consecutive DONEs forces the agent through at least 3 iterations where it genuinely finds nothing new, providing high confidence of completeness. If the agent discovers something on iteration k+1, the streak resets to 0 and the cycle continues.

A safety cap of 20 iterations per lens prevents fast runaway loops regardless of DONE detection and regardless of `--depth`. A separate per-lens wall-clock budget, `REPOLENS_LENS_MAX_WALL` (default 3600 seconds), prevents slow or timing-out iterations from occupying a sequential run or parallel worker slot for `MAX_ITERATIONS_PER_LENS × resolved agent timeout`; lenses stopped by that budget are recorded with summary status `max-wall`.

RepoLens also stops a lens early when the agent repeatedly makes no observable progress. By default, three consecutive degraded iterations stop that lens with summary status `agent-no-progress`. Degraded iterations are non-zero agent exits or near-empty outputs without `DONE`, issue URLs, or newly created local findings. The failed lens remains resumable, and a run with five such lens failures records the run-level stop reason as `agent-degraded` so operators can distinguish a systemic agent/backend problem from one difficult lens.

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

RepoLens supports 11 modes of operation. Mode isolation ensures that each mode sees only the domains and lenses relevant to its purpose, preventing cross-contamination between fundamentally different audit strategies.

Mode isolation is implemented through three mechanisms:

1. **Domain filtering** — A `"mode"` field in the domain registry controls which domains are visible to each mode
2. **Base prompt selection** — Each mode has a dedicated base template that shapes agent behavior
3. **Behavioral parameters** — DONE streak threshold, label prefix, issue severity schema, and confirmation gates vary per mode

**The 11 modes:**

The `--depth default` and `--rounds default` columns reflect the CLI defaults as of this revision. `--depth` controls within-lens iteration; `--rounds` controls across-lens cross-pollination via the meta-orchestrator (see next section). Modes marked "1 (locked)" cap `--rounds` at 1 by design — single-pass operation is intrinsic to those modes.

| Mode | Purpose | Visible Lenses | `--depth` default | `--rounds` default |
|------|---------|---------------|-------------------|--------------------|
| **audit** | Find real issues in existing code | 248 (code + toolgate + logs domains) | 3 | 1 (locked) |
| **feature** | Identify missing capabilities | 248 | 3 | 1 (locked) |
| **bugfix** | Find bugs backed by evidence | 248 | 3 | 1 (locked) |
| **bugreport** | Symptom-driven investigation: triage + rounds-driven lens dispatch + verifier + synthesizer. Requires `--bug-report <file\|text>` | 248 | 1 | 3 |
| **custom** | Change impact analysis | 248 | 1 | 1 (locked) |
| **discover** | Brainstorm product ideas | 14 (discovery domain only) | 1 | 1 (locked) |
| **deploy** | Read-only live-server inspection in local or remote SSH sub-modes, plus Android APK/source inspection | `deployment` domain (26 server lenses) or `android` domain (17 Android lenses, including `apk-dependencies`, `native-libraries`, `manifest-audit`, `network-security-config`, `exported-components`, `intent-filters`, `intent-fuzzing`, `drozer-attack-surface`, `logcat-leaks`, `ssl-pinning-mitm`, `frida-runtime`, `detection-bypass`, `keystore-extraction`, and `gradle-static-analysis`) | 1 | 1 (locked) |
| **opensource** | Public release risk assessment | 13 (open-source readiness only) | 1 | 1 (locked) |
| **content** | Content quality and creation | 17 (content quality only) | 1 | 1 (locked) |
| **greenfield** | Spec-to-backlog planning for a new or skeletal project. Requires `--spec <file>`, checks the current open issue or local draft backlog, and creates non-duplicate implementation-sized `[P0]`-`[P3]` issues without inspecting repository code | 1 (greenfield planning only) | 1 | 1 (locked) |
| **polish** | Ranked polishing shortlists for small, additive craft refinements with voice-fit evidence | 16 (`fluency`, `effort-signal`, and `hedonic` polish domains; `fluency` is visual-UI only) | 1 | 1 (locked) |

Each mode uses its own output schema (e.g., audit uses CRITICAL/HIGH/MEDIUM/LOW, discover uses SMALL/MEDIUM/LARGE/XL, custom uses BREAKING/REQUIRED/RECOMMENDED/OPTIONAL, and greenfield uses P0/P1/P2/P3) and its own label format when labels apply.

Greenfield mode is intentionally spec-led rather than code-led. Its single planner lens treats the provided `--spec` file as product-owner intent. Before each planner iteration, RepoLens supplies the current backlog: all currently open forge issues in normal mode, or existing local draft markdown files in `--local` mode. The planner skips covered spec slices, creates only the next missing implementation-sized backlog item, and emits `DONE` when no non-duplicate work remains. The target project still provides the repository and issue tracker context, but greenfield planning does not derive work from current implementation details.

Polish mode is intentionally suggestion-led rather than defect-led. It first builds a project voice profile, then runs the fluency, effort-signal, and hedonic polish lenses once. Lenses emit structured tags such as `voice_fit`, `voice_fit_justification`, `location_expectedness`, and `polish_family`; RepoLens combines those tags deterministically into `logs/<run-id>/polish/ranked-suggestions.json`. The final rank orders agent-surfaced polish suggestions. It does not score the repository, and the agents do not compute the rank themselves. After ranking, RepoLens emits one polishing shortlist per lens with usable suggestions, defaulting to the top 3 ranked items and including a one-line voice-fit justification for every listed item. Forge runs create those shortlists as `[POLISH]` issues; `--local` runs write grouped markdown drafts under `logs/<run-id>/polish/filed/`.

Deploy mode is unique in that it does not require a git repository. It can inspect a live server, a direct Android APK, a discovered APK, or a shallow Android source tree. Live-server deploy uses system commands (systemctl, ss, df, journalctl) in a strictly read-only fashion, with explicit legal authorization gates.

### Deploy Target Resolution

Deploy target resolution is intentionally ordered so `auto` remains conservative for server operators:

1. RepoLens starts with `server` as the default target kind.
2. If `--mode deploy` receives a direct `*.apk` path, `auto` and explicit `android` select the Android target and normalize the project path to the APK parent directory.
3. Explicit `--deploy-target server` short-circuits Android detection and always keeps the `deployment` domain.
4. For `auto` or explicit `android`, RepoLens searches for an APK under the target path, preferring normal Android build output locations before scanning for the newest `*.apk`.
5. If no APK is found, RepoLens checks only shallow Android source markers: `gradlew`, `build.gradle`, `build.gradle.kts`, `app/build.gradle`, and `app/build.gradle.kts`.
6. Only explicit `--deploy-target android` exits with the no-source/no-APK Android message when neither an APK nor a shallow marker exists. In `auto`, that same plain path preserves live-server deploy behavior.
7. The resolved target kind selects either the `deployment` domain for servers or the `android` domain for Android targets.
8. RepoLens exports the resolved metadata, including `$REPOLENS_ANDROID_APK_PATH` when an APK is known, for prompt composition and agent execution.

Remote deploy is a server-only qualifier on top of this target resolution. `--remote <ssh-target>` accepts `host`, `host:port`, `user@host`, or `user@host:port`, defaults the port to `22`, and is rejected outside deploy mode, with `--hosted`, or when target resolution selects Android. `--remote-key <path>` must point to an existing regular file. Remote server metadata appears during `--dry-run`, in the deploy authorization prompt, and again in the normal run confirmation prompt. If `--remote-label` is set, prompts show the label plus a separate `Raw target: ...` line. Remote confirmations also show the SSH wrapper form agents will use before the operator authorizes the run.

The classification phase is pure filesystem probing; it must not execute target-controlled build tooling. Android source build fallback is deferred until after the dry-run exit point, deploy authorization, and the normal run confirmation. It also requires `--build-android-apk`, an Android target with no resolved APK, and shallow build markers. When those gates pass, RepoLens runs `./gradlew assembleDebug` rather than a release build because debug builds are the standard local inspection artifact and do not require release signing keys, Play signing, publishing credentials, or release-only packaging paths. `--dry-run` never runs Gradle or agents.

---

## Multi-Round Investigation with Meta-Orchestrator

Some root causes are **cross-lens AND cross-domain**: a configuration-loading bug that leaks secrets, a race condition that only manifests as a latency anomaly observed by a different lens, a build-system quirk that breaks tests in a way only the testing lens can describe. A single lens running DONE×N cannot reach these findings *by design* — its context is narrow and its expertise is single-purpose. Multi-round investigation lets early-round findings inform later-round lens prompts via a **meta-orchestrator** that synthesizes intermediate state between rounds.

**Pipeline:**

```
triage → round 1 (all selected lenses) → meta-orchestrator → round 2 (informed lenses) → … → verifier → synthesizer → filing batch
```

- **triage** (optional, default ON for `bugreport`) — a round-0 prefix phase that narrows the lens selection or seeds shared context.
- **round 1..N** — the selected lens set runs in parallel. Each lens still uses its own DONE×N streak internally. Round outputs are written to `logs/<run-id>/rounds/round-N/lens-outputs/*.md` plus a `digest.md` and `hypotheses.md`.
- **meta-orchestrator** — runs *between* rounds. It reads the round-N digest, identifies cross-lens patterns, and proposes the round-N+1 dispatch (which lenses to re-run, with what prior context attached as untrusted reference material). Mode-specific orchestrator templates exist for `discover` and `content`; other modes use the default template.
- **verifier** (optional, default ON for `bugreport`, OFF elsewhere; opt out with `--no-verifier`) — independently re-checks proposed findings before they become issues.
- **synthesizer** — consolidates the cross-round manifest, deduplicates findings, and makes cross-link decisions.
- **filing batch** — one parallel filer per manifest cluster (per-cluster `.lock`) creates the GitHub issues.

**When to use `--rounds > 1`:**

- `bugreport` investigations where the symptom and the root cause are likely to live in different domains.
- `bugreport` cases where a single-pass investigation yields findings that look like consequences of a deeper, undiscovered cause.

**When NOT to use `--rounds > 1`:**

- Every non-`bugreport` mode is locked to `--rounds 1`.
- `deploy` runs against a live server, read-only by design, and remains single-pass.
- `opensource`, `content`, `discover`, and `polish` are single-pass readiness, content, product-strategy, and polishing modes.
- `greenfield` creates one next implementation issue per invocation and remains locked to `--rounds 1`.

A cross-mode safety ceiling (`REPOLENS_MAX_ROUNDS`, default 5) aborts excessive `--rounds` values irrespective of mode. The `--i-know-this-is-expensive` flag bypasses the soft abort gate at `rounds >= 4` but does NOT bypass this hard ceiling.

**Cost shape:**

```
cost ≈ rounds × breadth × depth × per-lens-cost
     + (rounds − 1) × meta-orchestrator-cost
     + verifier
     + synthesizer
     + filing-batch
```

The meta-orchestrator runs *between* rounds, so `N` rounds need `N − 1` orchestrator passes. The dry-run cost estimator (`--dry-run`) scales its estimate by `depth × rounds` and warns when `--rounds >= 4` is invoked without `--i-know-this-is-expensive`.

### `--rounds N` vs `--depth N`

The two flags are independent dimensions of search effort and should not be confused:

- **`--depth N`** — within-lens iteration intensity. Sets the DONE-streak threshold a single lens must reach before terminating. Higher depth makes one lens dig harder against its own narrow domain.
- **`--rounds N`** — across-lens cross-pollination. Re-dispatches the entire selected lens set `N` times, with the meta-orchestrator carrying findings from round `k` into round `k+1`. Higher rounds let early findings in one domain inform later prompts in another.

Worked examples:

- `--depth 5`: a single security lens iterates 5 deep passes against the auth module before declaring DONE. The lens's domain does not change; only its persistence does.
- `--rounds 3`: round 1 surfaces a config-loading bug, the meta-orchestrator notices that the affected code path touches secrets handling, and round 2 re-runs secrets-related lenses with that context. Round 3 can then re-examine downstream effects with both prior digests as reference.

The flags can be combined. Effective cost is multiplicative (see the cost shape formula above).

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
