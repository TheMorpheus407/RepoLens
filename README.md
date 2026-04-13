# RepoLens

[![License: Apache-2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

**Multi-lens code audit tool.** Runs 280 specialist lenses across 27 domains against any git repository or live server and creates GitHub issues for real findings. Think automated code review, agent-driven pentesting, tool-driven static/dynamic analysis, and infrastructure auditing — all with deep specialization.

## Getting Started

### Prerequisites

| Tool | Required | Purpose | Install |
|------|----------|---------|---------|
| `git` | Yes | Repo validation, cloning | OS package manager (`apt install git`, `brew install git`, `nix-env -i git`) |
| `jq` | Yes | JSON config parsing | OS package manager (`apt install jq`, `brew install jq`, `nix-env -i jq`) |
| `gh` | Yes (authenticated) | Create issues, labels, query repos | [cli.github.com](https://cli.github.com) — run `gh auth login` after install |
| Agent CLI | Yes (at least one) | Run analysis agents | See below |
| `docker` + `docker compose` | Only for `--hosted` | DAST scanning environment | OS package manager |

### Supported Agent CLIs

| `--agent` value | CLI required | Notes |
|-----------------|-------------|-------|
| `claude` | `claude` | Primary, recommended |
| `codex` | `codex` | OpenAI Codex CLI |
| `spark` / `sparc` | `codex` | Uses Codex CLI with spark model |
| `opencode` | `opencode` | Open-source agent CLI |
| `opencode/<model>` | `opencode` | Specify a custom model |

### Quickstart

```bash
# 1. Clone RepoLens
git clone https://github.com/TheMorpheus407/RepoLens.git
cd RepoLens

# 2. Make the entry point executable
chmod +x repolens.sh

# 3. Authenticate GitHub CLI (if not already done)
gh auth login

# 4. Run your first audit — single lens, fast feedback
./repolens.sh --project ~/my-app --agent claude --focus injection

# 5. Audit an entire domain
./repolens.sh --project ~/my-app --agent claude --domain security

# 6. Full parallel audit (all 280 lenses)
./repolens.sh --project ~/my-app --agent claude --parallel --max-parallel 8
```

## Modes

RepoLens supports 8 modes. Each mode controls which domains/lenses are visible and how the agent iterates.

| Mode | DONE Streak | Domains | Description |
|------|-------------|---------|-------------|
| `audit` | 3× | 23 code/toolgate domains (210 lenses) | **Default.** Standard code audit — finds issues in existing code |
| `feature` | 3× | 23 code/toolgate domains (210 lenses) | Feature gap discovery — identifies missing capabilities |
| `bugfix` | 3× | 23 code/toolgate domains (210 lenses) | Bug hunting — finds real bugs and defects |
| `discover` | 1× | `discovery` domain (14 lenses) | Product discovery — brainstorming for product strategy |
| `deploy` | 1× | `deployment` domain (26 lenses) | Server audit — inspects a live server for operational issues |
| `custom` | 1× | 23 code/toolgate domains (210 lenses) | Change impact analysis — identifies what needs adapting after a change |
| `opensource` | 1× | `open-source-readiness` domain (13 lenses) | Open-source readiness — checks if a repo can go public safely |
| `content` | 1× | `content-quality` domain (17 lenses) | Content audit & creation — audits or creates content from `--source` material |

### Mode Examples

```bash
# Audit (default) — comprehensive code review
./repolens.sh --project ~/my-app --agent claude --parallel

# Feature — discover missing capabilities
./repolens.sh --project ~/my-app --agent codex --mode feature --domain testing

# Bugfix — hunt for real bugs
./repolens.sh --project ~/my-app --agent spark --mode bugfix --focus race-conditions

# Discover — product strategy brainstorming
./repolens.sh --project ~/my-app --agent claude --mode discover

# Deploy — audit a live server (read-only)
./repolens.sh --project /srv/myapp --agent claude --mode deploy --parallel --max-issues 5

# Custom — change impact analysis
./repolens.sh --project ~/my-app --agent claude --change "Switching from REST to GraphQL"

# Opensource — pre-publication readiness check
./repolens.sh --project ~/my-app --agent claude --mode opensource

# Content — audit or create educational content
./repolens.sh --project ~/my-app --agent claude --mode content --source ~/docs/math-book.pdf

# CI — skip confirmation prompt for automation
./repolens.sh --project ~/my-app --agent claude --parallel --yes
```

## CLI Reference

```
Usage: repolens.sh --project <path|url> --agent <agent> [OPTIONS]
```

### Required Flags

| Flag | Description |
|------|-------------|
| `--project <path\|url>` | Local path or remote Git URL (cloned read-only if URL) |
| `--agent <agent>` | `claude \| codex \| spark \| sparc \| opencode \| opencode/<model>` |

### Optional Flags

| Flag | Description |
|------|-------------|
| `--mode <mode>` | `audit` (default) \| `feature` \| `bugfix` \| `discover` \| `deploy` \| `custom` \| `opensource` \| `content` |
| `--change <statement>` | Change impact statement (implies `--mode custom`) |
| `--source <file>` | Source material (PDF, text, markdown) for content creation or reference |
| `--focus <lens-id>` | Run a single lens (e.g., `injection`, `dead-code`) |
| `--domain <domain-id>` | Run all lenses in one domain (e.g., `security`) |
| `--parallel` | Run lenses in parallel (one agent process per lens) |
| `--max-parallel <n>` | Max concurrent agents in parallel mode (default: 8) |
| `--resume <run-id>` | Resume a previous interrupted run |
| `--spec <file>` | Spec/PRD/roadmap to guide analysis (any text file, max 100 KB) |
| `--max-issues <n>` | Stop after creating *n* total issues |
| `--hosted` | Spin up Docker Compose for DAST scanning (used with `toolgate` domain) |
| `--yes, -y` | Skip confirmation prompt (for CI/automation) |
| `-h, --help` | Show help |

## Domains & Lenses (280 total across 27 domains)

### Code Analysis Domains (used by `audit`, `feature`, `bugfix`, `custom`)

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
| **Frontend** | 5 | Component architecture, accessibility, responsive design, routing, frontend security |
| **Visual Design** | 5 | Color system, typography scale, spacing system, visual hierarchy, icon consistency |
| **Design System** | 4 | Design tokens, component library usage, CSS architecture, UI copy consistency |
| **Interaction Design** | 8 | Loading states, error states, form UX, animations, interactive feedback, touch targets, scroll behavior, keyboard navigation |
| **Information Architecture** | 6 | Empty states, navigation patterns, content hierarchy, search UX, help context, dashboard patterns |
| **Adaptive UX** | 5 | Adaptive content, theme adaptation, viewport sizing, RTL layout, print stylesheet |
| **UX Anti-Patterns** | 6 | Dark patterns, cognitive overload, destructive actions, flow dead-ends, permission anti-patterns, notification interrupts |
| **Observability** | 5 | Logging, structured logging, metrics, audit trail, health monitoring |
| **DevOps** | 6 | CI, Docker, env config, deployment safety, infra reproducibility, dependency management |
| **Compliance** | 56 | GDPR/DSGVO, NIS2, HIPAA, PCI-DSS, AI Act, DORA, AML/KYC, sovereignty, privacy-by-design, data retention, consent flows, and 45 more |
| **Maintainability** | 6 | Tech debt, upgrade paths, config patterns, error traceability, modularity, dependency health |
| **Internationalization** | 2 | String internationalization, locale-aware formatting |
| **Documentation** | 4 | Code docs, architecture docs, operational docs, onboarding |
| **Concurrency** | 4 | Race conditions, async patterns, resource contention, transaction concurrency |
| **Tool Gate** | 18 | Lint, typecheck, SAST, dependency CVEs, quality gates, test suite, DAST (web, injection, scanner, headers, API), session-based tools (ZAP, sqlmap, Nuclei, Lighthouse, k6, ZAP API, Schemathesis) |

### Mode-Specific Domains

| Domain | Mode | Lenses | Focus |
|--------|------|--------|-------|
| **Product Discovery** | `discover` | 14 lenses | Product gaps, integration opportunities, UX improvements, monetization, developer experience, automation, data insights, scale readiness, community, competitive edge, accessibility, content/education, AI augmentation, workflow orchestration |
| **Deployment** | `deploy` | 26 lenses | Service health, TLS, DNS, NTP, network security, load balancing, reverse proxy, disk/memory/CPU, containers, database, queues, secrets, SSH, hardening, logs, monitoring, backups, disaster recovery, config drift, dependencies, updates, cron jobs |
| **Open Source Readiness** | `opensource` | 13 lenses | Secret leaks, license compliance, dependency licensing, internal exposure, git history secrets, community readiness, documentation gaps, monetization exposure, PII, build reproducibility, security posture, code attribution, trademarks |
| **Content Quality** | `content` | 17 lenses | Content inventory, metadata, staleness, accessibility, linking, duplication, completeness, consistency, code examples, PII, multimedia, versioning, audience targeting, localization, topic extraction, planning, exercise design |

## How It Works

1. Validates target repo (or server for `deploy` mode), agent CLI, and `gh` auth
2. Resolves lens list (all, `--domain`, or `--focus`)
3. Shows confirmation prompt (target repo, mode, lens count) — requires `y` to proceed, or use `--yes` to skip
4. Ensures GitHub labels exist (`audit:<domain>/<lens>`)
5. For each lens:
   - Composes prompt from base template + lens expert focus
   - Runs agent in target repo directory
   - Agent reads code, finds issues, creates GitHub issues via `gh`
   - Loops until DONE detected (3× streak for audit/feature/bugfix, 1× for other modes)
6. Generates `logs/<run-id>/summary.json`

For a deeper look at the methodology — how lenses are composed, how agents iterate, and how streak detection works — see [METHODOLOGY.md](METHODOLOGY.md).

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

## Testing

Run the full test suite:

```bash
make check
```

This discovers and runs all `tests/test_*.sh` scripts, reports per-suite results, and exits non-zero if any suite fails.

## Legal

### License

This project is licensed under the **Apache License 2.0**. See [LICENSE](LICENSE) for the full text and [NOTICE](NOTICE) for required attribution.

### No Warranty

This software is provided **"as is"**, without warranty of any kind, express or implied. See the Apache-2.0 license for details.

### Deploy Mode — Authorization Required

`deploy` mode runs read-only inspection commands on a live server (e.g., `systemctl`, `journalctl`, `ss`, `df`). **You must have explicit authorization to audit the target server before running deploy mode.** Unauthorized server scanning may violate laws and policies. RepoLens enforces read-only operation through prompt instructions, but responsibility for authorization lies with the user.

### About `--dangerously-skip-permissions`

RepoLens passes `--dangerously-skip-permissions` to the Claude agent CLI. This flag is required for autonomous operation — agents need to create GitHub issues via `gh` and read project files without interactive permission prompts. Safety is enforced through detailed prompt instructions (not the CLI permissions system), which restrict agents to read-only analysis and `gh issue create` commands.

## Support

If you find RepoLens useful, consider supporting its development:

- Star this repo on GitHub
- [Sponsor on GitHub](https://github.com/sponsors/TheMorpheus407)
- [Support on Patreon](https://patreon.com/themorpheus407)
- Share it with your team

