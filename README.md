# RepoLens

[![License: Apache-2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)
[![Version: v0.1.0](https://img.shields.io/badge/version-v0.1.0-brightgreen.svg)](CHANGELOG.md)
[![CI](https://github.com/TheMorpheus407/RepoLens/actions/workflows/ci.yml/badge.svg)](https://github.com/TheMorpheus407/RepoLens/actions/workflows/ci.yml)
[![GitHub Stars](https://img.shields.io/github/stars/TheMorpheus407/RepoLens?style=social)](https://github.com/TheMorpheus407/RepoLens)

**Multi-lens code audit tool.** Runs 280 specialist lenses across 27 domains against any git repository or live server and creates GitHub issues for real findings. Think automated code review, agent-driven pentesting, tool-driven static/dynamic analysis, and infrastructure auditing — all with deep specialization.

> [!IMPORTANT]
> **RepoLens runs AI agents with shell access against your repository, and a full audit can cost hundreds of dollars in API charges.** It is NOT a sandboxed security tool, comes with NO warranty, and you use it entirely at your own risk. **Read [Warnings & Limits](#warnings--limits) before your first run** — especially the cost and security sections.

## Getting Started

### Prerequisites

| Tool | Required | Purpose | Install |
|------|----------|---------|---------|
| `bash` | Yes (4.0+) | Shell runtime — associative arrays, `read -ra`, other 4.x features are used throughout | Linux distributions ship 4.0+ already. macOS ships 3.2 by default (GPLv3 avoidance) — upgrade via `brew install bash`. RepoLens aborts at startup on older bash with an upgrade hint. |
| `git` | Yes | Repo validation, cloning | OS package manager (`apt install git`, `brew install git`, `nix-env -i git`) |
| `jq` | Yes | JSON config parsing | OS package manager (`apt install jq`, `brew install jq`, `nix-env -i jq`) |
| `gh` | Yes (unless `--local`) | Create issues, labels, query repos | [cli.github.com](https://cli.github.com) — run `gh auth login` after install |
| Agent CLI | Yes (at least one) | Run analysis agents | See [Supported Agent CLIs](#supported-agent-clis) below for install + auth per CLI |
| `docker` + `docker compose` | Only for `--hosted` | DAST scanning environment | OS package manager |

### Supported Agent CLIs

| `--agent` value | CLI required | Notes |
|-----------------|-------------|-------|
| `claude` | `claude` | Anthropic Claude Code |
| `codex` | `codex` | OpenAI Codex CLI |
| `spark` / `sparc` | `codex` | Codex CLI with spark model |
| `opencode` | `opencode` | Open-source agent CLI (75+ providers) |
| `opencode/<model>` | `opencode` | opencode with a specific provider/model |

You need **at least one** agent CLI installed and authenticated before running RepoLens. Install commands and auth flows differ per CLI — see below.

> [!TIP]
> **Recommendation:** Use `claude` for complex audits — it produces the highest-quality findings, but is also the most expensive option. For a cheaper alternative, run `opencode` with a MiniMax model — costs are a fraction of Claude, with the trade-off of more false positives. Calibrate on a single lens or domain (`--focus` / `--domain`) before committing to a full parallel run.

#### Claude Code (`claude`)

**Install** — Linux, macOS, WSL:

```bash
curl -fsSL https://claude.ai/install.sh | bash
```

Other platforms: `brew install --cask claude-code` (macOS), `winget install Anthropic.ClaudeCode` (Windows), or see the [official setup guide](https://code.claude.com/docs/en/setup) for PowerShell and legacy npm options.

**Authenticate:** run `claude` and follow the browser prompt. Requires a Claude **Pro, Max, Team, Enterprise, or Console** account — the free Claude.ai plan does not include Claude Code. Alternatives: export `ANTHROPIC_API_KEY`, or route through Amazon Bedrock / Google Vertex AI / Microsoft Foundry.

#### OpenAI Codex (`codex`)

**Install:**

```bash
npm install -g @openai/codex
```

Alternatives: `brew install --cask codex` (macOS), or prebuilt binaries from [github.com/openai/codex/releases](https://github.com/openai/codex/releases).

**Authenticate** — pick one:

- `codex login` — browser flow using a ChatGPT Plus / Pro / Business / Edu / Enterprise subscription (recommended; unlocks fast mode)
- `printenv OPENAI_API_KEY | codex login --with-api-key` — pay-as-you-go API billing
- Or export `OPENAI_API_KEY` in your shell

The `spark` / `sparc` agent values reuse the same `codex` binary — installing once covers all three.

#### opencode (`opencode`)

**Install:**

```bash
curl -fsSL https://opencode.ai/install | bash
```

Alternatives: `npm install -g opencode-ai` (npm package is `opencode-ai`, binary is `opencode`), `brew install anomalyco/tap/opencode`, `paru -S opencode-bin` (Arch), or see [opencode.ai/docs](https://opencode.ai/docs/) for Windows / Docker options.

**Authenticate:**

```bash
opencode auth login
```

Pick a provider from the interactive list — opencode supports 75+ providers (Anthropic, OpenAI, Bedrock, Vertex, Azure, Groq, DeepSeek, xAI, OpenRouter, Together AI, MiniMax, local Ollama, …). Credentials are stored in `~/.local/share/opencode/auth.json`.

### Quickstart

```bash
# 1. Clone RepoLens
git clone https://github.com/TheMorpheus407/RepoLens.git
cd RepoLens

# 2. Make the entry point executable
chmod +x repolens.sh

# 3. Authenticate GitHub CLI (if not already done; not needed for --local)
gh auth login

# 4. Run your first audit — single lens, fast feedback
./repolens.sh --project ~/my-app --agent claude --focus injection

# 5. Audit an entire domain
./repolens.sh --project ~/my-app --agent claude --domain security

# 6. Full parallel audit (all 280 lenses)
./repolens.sh --project ~/my-app --agent claude --parallel --max-parallel 8
```

## Warnings & Limits

RepoLens is a power tool. Before you point it at anything you care about — or anything that costs money — read this section.

### Cost — RepoLens can be very expensive

> [!CAUTION]
> A full audit runs **280 lenses across 27 domains**. Each lens loops until the agent emits `DONE` three times in a row (`audit` / `feature` / `bugfix` modes). That adds up to **hundreds — often thousands — of agent invocations per run**, and cost scales with your model choice (Claude Opus is dramatically more expensive than smaller models or Codex). Real-world runs can easily reach hundreds of dollars on a single repo.

**Before launching a full audit:**

- Use `--max-cost <dollars>` to set a budget — RepoLens warns if the minimum estimate exceeds it. The estimate is a **lower bound**; real runs typically cost 2–5× more due to tool-call churn and DONE-streak iteration.
- Use `--dry-run` to preview which lenses would execute without spending anything.
- Use `--max-issues <n>` to cap output (also forces sequential execution).
- Scope with `--focus <lens-id>` or `--domain <domain-id>` instead of auditing everything at once.
- Calibrate cost on a single domain with a cheap agent (`codex`, `opencode`) before committing to a full parallel audit with a premium model.

You are responsible for every dollar of API spend. Know your per-token pricing.

### Rate Limits & Automated Traffic

> [!NOTE]
> RepoLens generates a lot of automated traffic. A 280-lens run can create dozens to hundreds of GitHub issues, plus repo reads via `gh`, plus parallel AI provider calls.

- **GitHub API.** Authenticated `gh` calls count against your per-user REST and GraphQL quotas. Large runs can trip secondary (abuse) rate limits. Use `--max-issues <n>` to cap output, or `--local` to skip the GitHub API entirely.
- **AI provider rate limits.** Every iteration consumes Anthropic / OpenAI tokens. Free and low-tier accounts will hit their RPM (requests-per-minute) and TPM (tokens-per-minute) ceilings immediately under `--parallel`. Verify your account is on a tier sized for concurrent agent traffic before scaling.
- **Terms of Service & abuse risk.** Do **not** point RepoLens at repositories you do not own or have explicit permission to audit. Automated bulk issue creation against third-party repos can be treated as spam by GitHub and may get your account flagged or suspended.

Start small with `--focus <lens-id>` or one `--domain`, then scale up with `--parallel --max-parallel 2` before raising concurrency. The default is `--max-parallel 8`.

### Security & Safe Use

> [!WARNING]
> **RepoLens is NOT a sandboxed or hardened security tool.** It is an operator-trust tool designed for scanning repositories you own on a machine you control.

Under the hood, RepoLens spawns AI agents (claude, codex, etc.) with shell access — claude specifically runs with `--dangerously-skip-permissions` for autonomous operation. That means:

- **Prompt injection is trivial.** A README, code comment, commit message, or docstring in the scanned repo can instruct the agent to do arbitrary things.
- **`--spec` files from untrusted sources are dangerous.** Spec content is embedded in the agent prompt. While RepoLens sanitizes known tag-breakout vectors (e.g., `</spec>` injection), a malicious spec file can still influence agent behavior through indirect prompt injection. Only use `--spec` with files you wrote or trust completely.
- **Scripts in the scanned repo can execute.** A hostile `docker-compose.yml`, `Makefile`, `package.json` postinstall hook, or shell script could be invoked by the agent while investigating.
- **Deploy mode runs live shell commands** against whatever host you point it at — see also [Legal → Deploy Mode](#deploy-mode--authorization-required) for the authorization requirements.

**Recommended setup:**

- Run RepoLens inside a **dedicated, isolated VM or container** — never on a workstation that holds SSH keys, cloud credentials, browser sessions, or anything you can't afford to lose.
- **Only scan repositories you own or fully trust.** Do not point RepoLens at random GitHub clones, dependency sources, or third-party code.
- Treat every run as if the target repo were actively hostile.

For vulnerability disclosure, see [SECURITY.md](SECURITY.md).

### Disclaimer — No Warranty, Use at Your Own Risk

> [!WARNING]
> **RepoLens is provided "AS IS", without warranty of any kind**, express or implied — including but not limited to warranties of merchantability, fitness for a particular purpose, and non-infringement. **You use it entirely at your own risk.**

That risk includes, without limitation:

- **Incorrect findings** — false positives, hallucinated issues, or misleading recommendations from AI agents.
- **Missed issues** — real bugs, vulnerabilities, or misconfigurations RepoLens fails to detect.
- **Financial cost** — API/token usage from agent CLIs (claude, codex, etc.) can accrue significant charges.
- **Infrastructure impact** — in `deploy` mode and similar, agents execute shell commands on real systems; despite read-only prompting, unintended side effects are possible.
- **GitHub side effects** — automated issue, label, and PR creation in your repositories.

For the full legal text, see [LICENSE](LICENSE) (Apache License, Version 2.0, Sections 7 and 8).

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

# Local — write findings as markdown files instead of GitHub issues
./repolens.sh --project ~/my-app --agent claude --local

# Local with custom output directory
./repolens.sh --project ~/my-app --agent claude --local --output ~/reports/myapp-audit

# Local with domain filter and parallel execution
./repolens.sh --project ~/my-app --agent claude --local --domain security --parallel

# Dry run — preview which lenses would run without executing anything
./repolens.sh --project ~/my-app --agent claude --mode deploy --dry-run
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
| `--local` | Write findings as local markdown files instead of creating GitHub issues. No `gh` required |
| `--output <path>` | Output directory for local markdown files (requires `--local`, default: `logs/<run-id>/issues/`) |
| `--hosted` | Spin up Docker Compose for DAST scanning (used with `toolgate` domain) |
| `--max-cost <amount>` | Warn if the **minimum cost estimate** exceeds this dollar amount (e.g., `--max-cost 10`). The estimate is a lower bound — real runs typically cost 2–5× more due to tool-call churn and iteration non-convergence. Budget accordingly. |
| `--dry-run` | Validate config and show which lenses would run, then exit (no agents executed) |
| `--yes, -y` | Skip confirmation prompt (for CI/automation) |
| `--version` | Show version and sponsor information, then exit |
| `--about` | Show tool description and sponsor information, then exit |
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

1. Validates target repo (or server for `deploy` mode), agent CLI, and `gh` auth (skipped with `--local`)
2. Resolves lens list (all, `--domain`, or `--focus`)
3. If `--dry-run`: prints mode, agent, project path, and the full lens list, then exits — no agents run and no prompts are shown
4. For `--agent claude`: prompts for acknowledgment that `--dangerously-skip-permissions` only skips interactive permission prompts, not safety filters. `--yes` bypasses this prompt
5. For `deploy` mode: prompts for explicit authorization confirmation (`I confirm I am authorized to audit this server [y/N]`). Displays legal references (§202a StGB, CFAA, EU Directive 2013/40/EU). `--yes` bypasses this prompt
6. Shows confirmation prompt (target repo, mode, lens count, estimated cost) — requires `y` to proceed, or use `--yes` to skip. If `--max-cost` is set and the estimate exceeds it, a warning is displayed
7. Ensures GitHub labels exist (skipped with `--local`)
8. For each lens:
   - Composes prompt from base template + lens expert focus
   - Runs agent in target repo directory
   - Agent reads code, finds issues, and creates GitHub issues via `gh` (or writes markdown files in `--local` mode)
   - Loops until DONE detected (3× streak for audit/feature/bugfix, 1× for other modes)
9. Generates `logs/<run-id>/summary.json`

For a deeper look at the methodology — how lenses are composed, how agents iterate, and how streak detection works — see [METHODOLOGY.md](METHODOLOGY.md).

## Adding a Lens

See [CONTRIBUTING.md](CONTRIBUTING.md) for the full contribution workflow (fork, branch, PR process).

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

- **GitHub Issues** — Created directly in the target repo with severity-prefixed titles and domain labels (default)
- **Local Markdown** — With `--local`, findings are written as individual markdown files to `<output-dir>/<domain>/<lens-id>/NNN-slug.md` with YAML frontmatter (title, severity, domain, lens, labels). Default output directory: `logs/<run-id>/issues/`
- **Logs** — `logs/<run-id>/<domain>/<lens>/iteration-N-TIMESTAMP.txt`
- **Summary** — `logs/<run-id>/summary.json`

## Development

### Running Tests

Run the full test suite:

```bash
make check
```

Or invoke the pure-bash runner directly (useful in environments without `make`):

```bash
bash tests/run-all.sh
```

Either entry point discovers and runs all `tests/test_*.sh` scripts, reports per-suite results, and exits non-zero if any suite fails. Individual suites can also be run standalone, e.g. `bash tests/test_streak_ansi.sh`.

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for a detailed history of changes.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for how to report bugs, suggest features, submit code, and add new lenses.

Please note that this project is released with a [Code of Conduct](CODE_OF_CONDUCT.md). By participating, you agree to abide by its terms.

## Authors

See [AUTHORS.md](AUTHORS.md) for credits and contributors.

## Security

To report a vulnerability, see [SECURITY.md](SECURITY.md). Do not open a public issue for security vulnerabilities.

## Governance

For information about project leadership, decision-making, and contribution acceptance criteria, see [GOVERNANCE.md](GOVERNANCE.md).

## Legal

### License

This project is licensed under the **Apache License 2.0**. See [LICENSE](LICENSE) for the full text and [NOTICE](NOTICE) for required attribution. The warranty disclaimer is summarized in [Warnings & Limits → Disclaimer](#disclaimer--no-warranty-use-at-your-own-risk).

### Deploy Mode — Authorization Required

`deploy` mode runs read-only inspection commands on a live server (e.g., `systemctl`, `journalctl`, `ss`, `df`). **You must have explicit authorization to audit the target server before running deploy mode.**

**Legal risk:** Running RepoLens deploy mode against infrastructure you do not own or are not explicitly authorized to audit may constitute a criminal offense, including but not limited to:

- **Germany:** [§202a StGB](https://www.gesetze-im-internet.de/stgb/__202a.html) — Ausspähen von Daten (data espionage)
- **EU:** Directive 2013/40/EU — Attacks against information systems
- **United States:** Computer Fraud and Abuse Act (CFAA), 18 U.S.C. §1030
- **United Kingdom:** Computer Misuse Act 1990

RepoLens enforces read-only operation through prompt instructions, but **responsibility for authorization lies entirely with the user**. The CLI will prompt for explicit authorization confirmation before executing deploy mode. Using `--yes` to skip this prompt implies acceptance of this responsibility.

### About `--dangerously-skip-permissions`

RepoLens passes `--dangerously-skip-permissions` to the Claude agent CLI. This flag is required for autonomous operation — agents need to create GitHub issues via `gh` and read project files without interactive permission prompts. Despite its name, the flag does **not** disable safety filters, content guardrails, or ethical guidelines. Safety is enforced through detailed prompt instructions (not the CLI permissions system), which restrict agents to read-only analysis and `gh issue create` commands.

When using `--agent claude`, RepoLens displays an explanation of the flag and asks for acknowledgment before running any agents. Use `--yes` to skip this prompt in CI/automation.

## Troubleshooting

Most first-run failures fall into one of these patterns. Errors are quoted verbatim from the script.

| Error / Symptom | Cause | Fix |
|-----------------|-------|-----|
| `ERROR: RepoLens requires bash 4.0 or newer.` | bash < 4 (macOS ships 3.2 by default) | `brew install bash`, then re-run with the Homebrew `bash` first on `PATH` |
| `Missing required command: jq` | jq not installed | `apt install jq` / `brew install jq` / `nix-env -i jq` |
| `Missing required command: gh` | GitHub CLI not installed | Install from [cli.github.com](https://cli.github.com), or pass `--local` to skip GitHub entirely |
| `gh is not authenticated. Run 'gh auth login'.` | `gh` not authenticated, or token expired | `gh auth login` (or `gh auth refresh` if your token is stale) |
| `Missing required command: claude` (or `codex` / `opencode`) | Agent CLI not installed | See [Supported Agent CLIs](#supported-agent-clis) for install + auth |
| Agent prompts for login on every iteration | Agent CLI not authenticated | Authenticate the CLI directly — see [Supported Agent CLIs](#supported-agent-clis) |
| `Invalid agent: …` | Typo in `--agent` value | Must be one of `claude`, `codex`, `spark`, `sparc`, `opencode`, `opencode/<model>` |
| `Not a git repository: …` | `--project` path is not a git repo | Use `git init`, pass a real repo path, or use `--mode deploy` (which doesn't require git) |
| `--hosted requires Docker to be installed` | Docker missing or daemon stopped | Install Docker, then `sudo systemctl start docker` (or open Docker Desktop) |
| `--hosted requires a docker-compose.yml or compose.yml in the project` | No compose file at project root | Add a compose file, or drop `--hosted` and audit statically |
| `Lens '…' not found in domains.json` | Typo in `--focus` lens id, or wrong mode | List available lenses: `jq -r '.domains[].lenses[]' config/domains.json` |
| `Domain '…' not found in domains.json` | Typo in `--domain` id, or mode mismatch | `discover` / `deploy` / `opensource` / `content` modes only see their own domain — see the [Modes](#modes) table |
| `Mode 'custom' requires --change "your change statement"` | `--mode custom` without a change statement | Pass `--change "your statement"` |
| `Hit safety cap (N iterations). Stopping lens.` | Agent never emitted `DONE` 3× in a row | Inspect `logs/<run-id>/<domain>/<lens>.log` — usually a model output-format issue, rate limit, or context overflow. Retry with a smaller `--max-parallel` or a different `--agent`. |
| `Running non-interactively without --yes flag.` | CI / non-TTY without confirmation | Pass `--yes` (read [Security & Safe Use](#security--safe-use) first) |

**Still stuck?** Check `logs/<run-id>/` — every lens writes its full agent transcript there, including the prompt sent and the raw output received. The run id is printed at startup. To list past runs: `ls -1 logs/`.

## Support

RepoLens is free, open source, and maintained on a best-effort basis. **We do not offer free user support.** Please do not open GitHub issues asking for help with installation, environment setup, or general usage — the [Troubleshooting](#troubleshooting) section above covers the predictable failures, and `logs/<run-id>/` covers the rest.

**Bug reports** (with reproduction steps) and **well-scoped feature requests** are welcome via [GitHub Issues](https://github.com/TheMorpheus407/RepoLens/issues).

**Commercial / paid support** for companies — installation help, custom lens development, integration consulting, prioritized fixes — is available. Email [hallo@bootstrap.academy](mailto:hallo@bootstrap.academy).

Supported by [Patreon patrons](https://patreon.com/themorpheus407) — thank you.

