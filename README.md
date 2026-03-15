# RepoLens

**Multi-lens code audit tool.** Runs 109 expert analysis agents against any git repository and creates GitHub issues for real findings.

## Quick Start

```bash
# Audit a repo with a single lens
./repolens.sh --project ~/my-app --agent claude --focus injection

# Audit an entire domain
./repolens.sh --project ~/my-app --agent claude --domain security

# Full audit (all 109 lenses) in parallel
./repolens.sh --project ~/my-app --agent claude --parallel --max-parallel 8

# Feature discovery mode
./repolens.sh --project ~/my-app --agent codex --mode feature --domain testing

# Bug hunting mode
./repolens.sh --project ~/my-app --agent spark --mode bugfix --focus race-conditions
```

## Requirements

- `git` — target must be a git repository
- `gh` — GitHub CLI, authenticated (`gh auth login`)
- `jq` — JSON processing
- One of: `claude`, `codex`, or `opencode` CLI

## Usage

```
Usage: repolens.sh --project <path> --agent <agent> [OPTIONS]

Required:
  --project <path>        Path to git repository to audit
  --agent <agent>         claude | codex | spark | sparc | opencode | opencode/<model>

Options:
  --mode <mode>           audit (default) | feature | bugfix
  --focus <lens-id>       Run a single lens (e.g., "injection", "dead-code")
  --domain <domain-id>    Run all lenses in one domain (e.g., "security")
  --parallel              Run lenses in parallel
  --max-parallel <n>      Max concurrent agents (default: 8)
  --resume <run-id>       Resume a previous interrupted run
  -h, --help              Show help
```

## Modes

| Mode | Purpose | Issue Style |
|------|---------|-------------|
| `audit` | Find issues in existing code | Summary, Impact, Evidence, Fix, References |
| `feature` | Discover missing capabilities | Summary, Motivation, Current State, Proposal, Acceptance Criteria |
| `bugfix` | Hunt for real bugs | Summary, Expected/Actual, Root Cause, Reproduction, Fix, Impact |

## Domains & Lenses (109 total)

| Domain | Lenses | Focus |
|--------|--------|-------|
| **Security** | 11 | Injection, XSS/CSRF, auth, secrets, CVEs, headers, crypto, input validation, data exposure, rate limiting |
| **Code Quality** | 14 | Naming, complexity, dead code, duplication, magic values, smells, linting, formatting, comments, types, immutability, readability, consistency |
| **Architecture** | 9 | SoC, module boundaries, circular deps, coupling, SRP, dependency direction, API contracts, state, extensibility |
| **Testing** | 9 | Unit/integration/e2e gaps, quality, anti-patterns, edge cases, error paths, maintainability, determinism |
| **Error Handling** | 6 | Unhandled errors, swallowing, messages, boundaries, graceful degradation, timeout/retry |
| **Performance** | 9 | Queries, memory, blocking I/O, frontend perf, caching, algorithms, pagination, connections, startup |
| **API Design** | 6 | REST conventions, validation, response consistency, versioning, idempotency, documentation |
| **Database** | 6 | Schema, migrations, indexes, transactions, integrity, query safety |
| **Frontend** | 9 | Components, a11y, responsive, loading/error/empty states, forms, routing, frontend security |
| **Observability** | 5 | Logging, structured logging, metrics, audit trail, health monitoring |
| **DevOps** | 6 | CI, Docker, env config, deployment safety, infra reproducibility, dependency management |
| **Compliance** | 6 | GDPR/DSGVO, NIS2, sovereignty, privacy-by-design, data retention, consent flows |
| **Maintainability** | 6 | Tech debt, upgrade paths, config patterns, error traceability, modularity, dependency health |
| **i18n** | 2 | String internationalization, locale-aware formatting |
| **Documentation** | 4 | Code docs, architecture docs, operational docs, onboarding |
| **Concurrency** | 4 | Race conditions, async patterns, resource contention, transaction concurrency |

## How It Works

1. Validates target repo, agent CLI, and `gh` auth
2. Resolves lens list (all, `--domain`, or `--focus`)
3. Ensures GitHub labels exist (`audit:<domain>/<lens>`)
4. For each lens:
   - Composes prompt from base template + lens expert focus
   - Runs agent in target repo directory
   - Agent reads code, finds issues, creates GitHub issues via `gh`
   - Loops until DONE detected 3 consecutive times
5. Generates `logs/<run-id>/summary.json`

## Adding a Lens

1. Create `prompts/lenses/<domain>/<your-lens>.md`:

```yaml
---
id: your-lens
domain: your-domain
name: Your Lens Name
role: Your Expert Role Title
---

## Your Expert Focus

Detailed instructions for what this lens should analyze...
```

2. Add `"your-lens"` to the domain's `lenses` array in `config/domains.json`

That's it. No code changes needed.

## Resume

If a run is interrupted (Ctrl+C, crash), resume it:

```bash
./repolens.sh --project ~/my-app --agent claude --resume 20260315T120000Z-a1b2c3d4
```

Completed lenses are skipped. The run ID is printed at startup and found in `logs/`.

## Output

- **GitHub Issues** — Created directly in the target repo with severity-prefixed titles and domain labels
- **Logs** — `logs/<run-id>/<domain>/<lens>/iteration-N-TIMESTAMP.txt`
- **Summary** — `logs/<run-id>/summary.json`

## License

MIT
