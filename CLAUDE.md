# RepoLens — Project Instructions

## What This Is

RepoLens is a standalone multi-lens code audit tool. It runs 109 expert analysis agents against any git repository and creates GitHub issues for real findings. Think of it as automated code review with deep specialization.

## Architecture

- **Entry point:** `repolens.sh` — CLI that orchestrates everything
- **Libraries:** `lib/` — Modular bash libraries (core, logging, streak detection, template engine, summary, parallel execution)
- **Config:** `config/domains.json` (lens registry), `config/label-colors.json` (GitHub label colors)
- **Prompts:** `prompts/_base/` (mode wrappers: audit/feature/bugfix), `prompts/lenses/<domain>/<lens>.md` (109 expert prompts)
- **Logs:** `logs/<run-id>/` (runtime only, gitignored)

## Adding a New Lens

1. Create `prompts/lenses/<domain>/<lens-id>.md` with YAML frontmatter (id, domain, name, role) and `## Your Expert Focus` body
2. Add the lens ID to the appropriate domain in `config/domains.json`
3. No code changes needed

## Key Design Decisions

- **DONE x3 streak** — Each lens loops until the agent outputs DONE as first or last word, 3 consecutive times
- **Agent-agnostic** — Supports claude, codex, spark/sparc, opencode via `--agent` flag
- **Prompt composition** — Base template provides universal rules, lens template provides expert focus. `lib/template.sh` concatenates and substitutes `{{VARIABLES}}`
- **Parallel execution** — File-based semaphore in `logs/<run-id>/.semaphore/`, signal handler for clean shutdown
- **Resume support** — `--resume <run-id>` skips already-completed lenses

## Conventions

- All shell scripts use `set -uo pipefail` (no `set -e` — callers handle errors)
- Functions are pure where possible — side effects documented in comments
- Config is JSON parsed with `jq`
- Logs are structured: `[LEVEL] [timestamp] message`

## Do NOT

- Add LLM/AI logic into the scoring or assessment — this tool creates issues, it doesn't score code
- Hardcode repository-specific logic — this tool works on ANY git repo
- Modify the DONE detection protocol without understanding the streak mechanism
- Remove the `--dangerously-skip-permissions` flag from claude invocation — it's intentional for autonomous operation
