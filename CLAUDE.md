# RepoLens — Project Instructions

## What This Is

RepoLens is a standalone multi-lens code audit tool. It runs 335 expert analysis agents (209 code analysis + 18 tool gate + 21 runtime log + 14 product discovery + 43 deployment and Android audit + 13 open-source readiness + 17 content quality) against any git repository, live server, or Android APK and creates GitHub issues for real findings. Think of it as automated code review, agent-driven pentesting, tool-driven static/dynamic analysis, infrastructure auditing, and Android auditing with deep specialization.

That breakdown is a frozen inventory checked by `tests/test_claude_project_instructions.sh`. The live registry `config/domains.json` (counted 2026-09-25) holds 354 lenses across 37 domains. The default `audit` mode (and `feature`, `bugfix`, `bugreport`, `custom`, `branch-review`) runs the 248 audit-visible lenses of the 27 domains without a `mode` field; the rest are mode-specific (discover, deploy, opensource, content, greenfield, spec-change, and 16 polish lenses).

## Architecture

- **Entry point:** `repolens.sh` — CLI that orchestrates everything
- **Libraries:** `lib/` — Modular bash libraries (core, logging, streak detection, template engine, summary, parallel execution)
- **Config:** `config/domains.json` (lens registry), `config/label-colors.json` (GitHub label colors)
- **Prompts:** `prompts/_base/` (mode wrappers: audit/feature/bugfix/discover/deploy), `prompts/lenses/<domain>/<lens>.md` (335 expert prompts) in the frozen inventory above; 354 lens files on 2026-09-25
- **Logs:** `logs/<run-id>/` (runtime only, gitignored)

## Adding a New Lens

1. Create `prompts/lenses/<domain>/<lens-id>.md` with YAML frontmatter (id, domain, name, role) and `## Your Expert Focus` body
2. Add the lens ID to the appropriate domain in `config/domains.json`
3. No code changes needed

## Key Design Decisions

- **DONE x3 streak** — Each lens loops until the agent outputs DONE as first or last word, 3 consecutive times (discover and deploy modes use 1x streak — single-pass)
- **Mode isolation** — Discover and deploy modes have their own exclusive domains (`discovery` with 14 lenses, `deployment` with 26 lenses, and `android` with 17 lenses). The `"mode"` field in `domains.json` controls lens visibility: each mode only sees domains matching its mode, other modes exclude them
- **Deploy mode** — Runs on a live server. Agents use bash commands (systemctl, ss, df, journalctl, etc.) to investigate server state. Prompts enforce read-only operation. The `--project` path does not need to be a git repo in deploy mode
- **Agent-agnostic** — Supports claude, codex, spark/sparc, Cursor CLI, Cursor IDE/Composer handoff, opencode, and Antigravity via `--agent`
- **Prompt composition** — Base template provides universal rules, lens template provides expert focus. `lib/template.sh` concatenates and substitutes `{{VARIABLES}}`
- **Parallel execution** — File-based semaphore in `logs/<run-id>/.semaphore/`, signal handler for clean shutdown
- **Resume support** — `--resume <run-id>` skips already-completed lenses

## Conventions

- All shell scripts use `set -uo pipefail` (no `set -e` — callers handle errors)
- Functions are pure where possible — side effects documented in comments
- Config is JSON parsed with `jq`
- Logs are structured: `[LEVEL] [timestamp] message`

## Tests

- **No real models in tests.** Tests MUST NEVER invoke real AI models (claude, codex, opencode, etc.). No exceptions. Tests that call `repolens.sh --agent <model>` without `--dry-run` burn API credits, hang for minutes per invocation, leak orphan processes, and wedge AutoDev's quality gate. If a test needs to exercise repolens.sh behavior, use `--dry-run` or mock the agent call.
- Test suite runs via `bash tests/run-all.sh` or `make check`. Both share a recursion guard (`REPOLENS_MAKE_CHECK` env var) to prevent infinite nesting when tests validate the Makefile target.
- Each test file must complete in seconds, not minutes. If a new test takes more than 10 seconds, something is wrong. The full suite has 336 `tests/test_*.sh` files (2026-09-25) and takes minutes (256 suites took ~8 min in AutoDev's gate sandbox in August 2026).

## Do NOT

- Add LLM/AI logic into the scoring or assessment — this tool creates issues, it doesn't score code
- Hardcode repository-specific logic — this tool works on ANY git repo or server
- Modify the DONE detection protocol without understanding the streak mechanism
- Remove the `--dangerously-skip-permissions` flag from claude invocation — it's intentional for autonomous operation
- Write tests that call real AI models — use `--dry-run` or mocks instead (see Tests section above)
