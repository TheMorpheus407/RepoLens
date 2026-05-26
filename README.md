# RepoLens

[![License: Apache-2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)
[![Version: v0.2.0](https://img.shields.io/badge/version-v0.2.0-brightgreen.svg)](CHANGELOG.md)
[![CI](https://github.com/TheMorpheus407/RepoLens/actions/workflows/ci.yml/badge.svg)](https://github.com/TheMorpheus407/RepoLens/actions/workflows/ci.yml)
[![GitHub Stars](https://img.shields.io/github/stars/TheMorpheus407/RepoLens?style=social)](https://github.com/TheMorpheus407/RepoLens)

**Multi-lens code audit tool.** Runs 335 specialist lenses across 32 domains against any git repository, live server, or Android APK and creates remote issues for real findings. Think automated code review, agent-driven pentesting, tool-driven static/dynamic analysis, infrastructure auditing, and Android auditing — all with deep specialization.

> [!IMPORTANT]
> **RepoLens runs AI agents with shell access against your repository, and a full audit can cost hundreds of dollars in API charges.** It is NOT a sandboxed security tool, comes with NO warranty, and you use it entirely at your own risk. **Read [Warnings & Limits](#warnings--limits) before your first run** — especially the cost and security sections.

## Getting Started

### Prerequisites

| Tool                        | Required               | Purpose                                                                                | Install                                                                                                                                                                               |
| --------------------------- | ---------------------- | -------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `bash`                      | Yes (4.0+)             | Shell runtime — associative arrays, `read -ra`, other 4.x features are used throughout | Linux distributions ship 4.0+ already. macOS ships 3.2 by default (GPLv3 avoidance) — upgrade via `brew install bash`. RepoLens aborts at startup on older bash with an upgrade hint. |
| `git`                       | Yes                    | Repo validation, cloning                                                               | OS package manager (`apt install git`, `brew install git`, `nix-env -i git`)                                                                                                          |
| `jq`                        | Yes                    | JSON config parsing                                                                    | OS package manager (`apt install jq`, `brew install jq`, `nix-env -i jq`)                                                                                                             |
| `timeout` (coreutils)       | Yes                    | Per-invocation agent timeout watchdog with SIGKILL escalation grace (see `REPOLENS_AGENT_TIMEOUT*` and `REPOLENS_AGENT_KILL_GRACE` below) | Ships in GNU coreutils. Pre-installed on Linux/NixOS. On macOS: `brew install coreutils`.                                                                                             |
| `gh`, `tea`, or `fj`        | Yes (unless `--local`) | Remote forge operations for labels and issue queries                                   | See [Supported forges](#supported-forges) for detection, install links, and auth commands                                                                                             |
| Agent CLI                   | Yes (at least one)     | Run analysis agents                                                                    | See [Supported Agent CLIs](#supported-agent-clis) below for install + auth per CLI                                                                                                    |
| `docker` + `docker compose` | Only for `--hosted`    | DAST scanning environment                                                              | OS package manager                                                                                                                                                                    |

### Supported forges

Supported forges are GitHub (`gh`), Gitea (`tea`), and Codeberg/Forgejo (`fj`). RepoLens reads `git remote get-url origin` from the target project and uses the origin host to choose the forge backend. Pass `--forge <gh|tea|fj>` to override auto-detection. Use `--local` to write markdown findings without any remote forge CLI.

| Forge              | Provider | CLI           | Auto-detection               | Install / auth                                                                                                                   |
| ------------------ | -------- | ------------- | ---------------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| GitHub             | `gh`     | GitHub CLI    | `github.com` origins         | Install from [cli.github.com](https://cli.github.com), then run `gh auth login`                                                  |
| Gitea              | `tea`    | Gitea Tea CLI | Hostnames containing `gitea` | Install from [gitea.com/gitea/tea](https://gitea.com/gitea/tea), then run `tea login add`                                        |
| Codeberg / Forgejo | `fj`     | Forgejo CLI   | `codeberg.org` origins       | Install from [forgejo-contrib/forgejo-cli](https://codeberg.org/forgejo-contrib/forgejo-cli), then run `fj -H <host> auth login` |

Self-hosted instances whose hostnames do not match the auto-detect heuristics require `--forge <gh|tea|fj>`. Self-hosted Forgejo targets also need an HTTPS or SSH `origin` remote so RepoLens can pass a secure `fj -H <host>` binding; insecure HTTP origins are not used for authenticated `fj` commands.

### Supported Agent CLIs

| `--agent` value    | CLI required | Notes                                   |
| ------------------ | ------------ | --------------------------------------- |
| `claude`           | `claude`     | Anthropic Claude Code                   |
| `codex`            | `codex`      | OpenAI Codex CLI                        |
| `spark` / `sparc`  | `codex`      | Codex CLI with spark model              |
| `opencode`         | `opencode`   | Open-source agent CLI (75+ providers)   |
| `opencode/<model>` | `opencode`   | opencode with a specific provider/model |

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

# 3. Authenticate your forge CLI (if not already done; not needed for --local)
gh auth login                  # GitHub
tea login add                  # Gitea
fj -H codeberg.org auth login  # Codeberg; use your Forgejo host for self-hosted instances

# 4. Run your first audit — single lens, fast feedback
./repolens.sh --project ~/my-app --agent claude --focus injection

# 5. Audit an entire domain
./repolens.sh --project ~/my-app --agent claude --domain security

# 6. Full parallel audit (248 audit-visible lenses)
./repolens.sh --project ~/my-app --agent claude --parallel --max-parallel 8
```

## Warnings & Limits

RepoLens is a power tool. Before you point it at anything you care about — or anything that costs money — read this section.

### Cost — RepoLens can be very expensive

> [!CAUTION]
> A default full audit runs **248 audit-visible lenses across 27 code/toolgate/logs domains**. RepoLens has 335 lenses across 32 domains in total, but `discover`, `deploy`, `opensource`, and `content` lenses are mode-specific and do not run in the default audit mode. Each audit lens loops until the agent emits `DONE` three times in a row. That adds up to **hundreds — often thousands — of agent invocations per run**, and cost scales with your model choice (Claude Opus is dramatically more expensive than smaller models or Codex). Real-world runs can easily reach hundreds of dollars on a single repo.

**Before launching a full audit:**

- Use `--max-cost <dollars>` to set a budget — RepoLens warns if the minimum estimate exceeds it. The estimate is a **lower bound**; real runs typically cost 2–5× more due to tool-call churn and DONE-streak iteration.
- Use `--dry-run` to preview which lenses would execute without spending anything.
- Use `--max-issues <n>` to cap output (also forces sequential execution).
- Scope with `--focus <lens-id>` or `--domain <domain-id>` instead of auditing everything at once.
- Calibrate cost on a single domain with a cheap agent (`codex`, `opencode`) before committing to a full parallel audit with a premium model.

You are responsible for every dollar of API spend. Know your per-token pricing.

**Cost scales with `depth × rounds`.** Both flags multiply the per-lens iteration cost: raising `--depth` (within-lens iterations) and `--rounds` (cross-lens orchestration) compounds. A `--depth 5 --rounds 3` run is roughly **5× the per-lens iteration cost and 3× the lens-pass count** compared to defaults. Preview the resolved estimate with `--dry-run` before launching.

**`--rounds >= 4` requires explicit cost acknowledgement.** RepoLens refuses to launch unless you pass `--i-know-this-is-expensive` (or the equivalent `--max-cost <dollars>` + `--yes` combination). The hard-ceiling environment variable `REPOLENS_MAX_ROUNDS` (default `5`) caps `--rounds` and cannot be bypassed by `--i-know-this-is-expensive` — to exceed it, set `REPOLENS_MAX_ROUNDS` explicitly before launching.

### Rate Limits & Automated Traffic

> [!NOTE]
> RepoLens generates a lot of automated traffic. A default 248-lens audit run can create dozens to hundreds of remote issues, plus repo reads via `gh`, `tea`, or `fj`, plus parallel AI provider calls.

- **GitHub API / Gitea API / Forgejo API.** Authenticated `gh` calls count against GitHub API quotas; authenticated `tea` and `fj` calls count against your Gitea or Forgejo account/API quotas. Large runs can trip rate limits. Use `--max-issues <n>` to cap output, or `--local` to skip remote forge calls entirely.
- **Concurrent same-repo runs.** Starting multiple runs against the same repository is supported. Remote label setup is coordinated per repository; repeated runs with the same desired label set can reuse a fresh bootstrap result, while other runs create only missing labels when the forge supports label listing. Per-lens issue checks still run independently, so lower `--max-parallel` when running several modes at once against the same forge account.
- **AI provider rate limits.** Every iteration consumes Anthropic / OpenAI tokens. Free and low-tier accounts will hit their RPM (requests-per-minute) and TPM (tokens-per-minute) ceilings immediately under `--parallel`. Verify your account is on a tier sized for concurrent agent traffic before scaling.
- **Automatic agent retry.** If an agent exits non-zero with a recognized rate-limit message and a parseable resume time within `REPOLENS_RATE_LIMIT_MAX_SLEEP`, RepoLens sleeps until that time plus 60 seconds and retries the same lens once. Unparseable waits, waits beyond the cap, or a second rate-limit after retry abort the run so you can resume or adjust concurrency manually.
- **Terms of Service & abuse risk.** Do **not** point RepoLens at repositories you do not own or have explicit permission to audit. Automated bulk issue creation against third-party repos can be treated as spam by your forge provider and may get your account flagged or suspended.

Start small with `--focus <lens-id>` or one `--domain`, then scale up with `--parallel --max-parallel 2` before raising concurrency. The default is `--max-parallel 8`.

### Security & Safe Use

> [!WARNING]
> **RepoLens is NOT a sandboxed or hardened security tool.** It is an operator-trust tool designed for scanning repositories you own on a machine you control.

Under the hood, RepoLens spawns AI agents (claude, codex, etc.) with shell access — claude specifically runs with `--dangerously-skip-permissions` for autonomous operation. That means:

- **Prompt injection is trivial.** A README, code comment, commit message, or docstring in the scanned repo can instruct the agent to do arbitrary things.
- **`--spec` files from untrusted sources are dangerous.** Spec content is embedded in the agent prompt. While RepoLens sanitizes known tag-breakout vectors (e.g., `</spec>` injection), a malicious spec file can still influence agent behavior through indirect prompt injection. Only use `--spec` with files you wrote or trust completely.
- **Scripts in the scanned repo can execute.** A hostile `docker-compose.yml`, `Makefile`, `package.json` postinstall hook, or shell script could be invoked by the agent while investigating.
- **Deploy mode runs live shell commands** against whatever host you point it at — see also [Legal → Deploy Mode](#deploy-mode--authorization-required) for the authorization requirements.

Remote deploy mode runs read-only commands on a server you authorize, but the agent has shell access via the SSH multiplexer. Treat it with the same caution as deploy mode locally — only point it at hosts you own or are explicitly authorized to audit. The legal references in `Deploy Mode — Authorization Required` apply identically to remote targets.

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
- **Remote forge side effects** — automated issue, label, and PR creation in your repositories.

For the full legal text, see [LICENSE](LICENSE) (Apache License, Version 2.0, Sections 7 and 8).

## Modes

RepoLens supports 9 modes. Each mode controls which domains/lenses are visible and how the agent iterates.

| Mode         | DONE Streak | Domains                                    | Description                                                                   |
| ------------ | ----------- | ------------------------------------------ | ----------------------------------------------------------------------------- |
| `audit`      | 3×          | 27 code/toolgate/logs domains (248 lenses) | **Default.** Standard code audit — finds issues in existing code              |
| `feature`    | 3×          | 27 code/toolgate/logs domains (248 lenses) | Feature gap discovery — identifies missing capabilities                       |
| `bugfix`     | 3×          | 27 code/toolgate/logs domains (248 lenses) | Bug hunting — finds real bugs and defects                                     |
| `bugreport`  | 1×          | 27 code/toolgate/logs domains (248 lenses) | Symptom-driven investigation — triage + rounds-driven lens dispatch + verifier + synthesizer. Requires `--bug-report <file\|text>` |
| `discover`   | 1×          | `discovery` domain (14 lenses)             | Product discovery — brainstorming for product strategy                        |
| `deploy`     | 1×          | `deployment` domain (26 lenses) or `android` domain (17 lenses) | Server or Android audit — inspects a live server, APK target, or shallow Gradle Android source tree |
| `custom`     | 1×          | 27 code/toolgate/logs domains (248 lenses) | Change impact analysis — identifies what needs adapting after a change        |
| `opensource` | 1×          | `open-source-readiness` domain (13 lenses) | Open-source readiness — checks if a repo can go public safely                 |
| `content`    | 1×          | `content-quality` domain (17 lenses)       | Content audit & creation — audits or creates content from `--source` material |

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

# Deploy — force live-server lenses even if Android files are present
./repolens.sh --project /srv/myapp --agent claude --mode deploy --deploy-target server

# Remote deploy — audit a server from your workstation
./repolens.sh --project ~/myapp --agent claude --mode deploy \
    --remote ubuntu@198.51.100.10 \
    --remote-key ~/.ssh/server_deploy \
    --remote-label "Production app server" \
    --max-issues 1

# Deploy — audit a remote server target over SSH
./repolens.sh --project /srv/myapp --agent claude --mode deploy --remote ubuntu@host.example.com:2222 --remote-key ~/.ssh/id_ed25519

# Deploy — audit an Android APK target
./repolens.sh --project ~/my-app/app/build/outputs/apk/debug/app-debug.apk --agent claude --mode deploy

# Deploy — audit an Android source tree when no APK is built yet
./repolens.sh --project ~/my-android-app --agent claude --mode deploy --deploy-target android

# Custom — change impact analysis
./repolens.sh --project ~/my-app --agent claude --change "Switching from REST to GraphQL"

# Opensource — pre-publication readiness check
./repolens.sh --project ~/my-app --agent claude --mode opensource

# Content — audit or create educational content
./repolens.sh --project ~/my-app --agent claude --mode content --source ~/docs/math-book.pdf

# Logs — point runtime log analysis lenses at a log corpus
./repolens.sh --project ~/AutoDev --agent claude --logs ~/CybersecurityAssessment/logs/auto-develop/ --domain logs --parallel

# CI — skip confirmation prompt for automation
./repolens.sh --project ~/my-app --agent claude --parallel --yes

# Local — write findings as markdown files instead of remote issues
./repolens.sh --project ~/my-app --agent claude --local

# Local with custom output directory
./repolens.sh --project ~/my-app --agent claude --local --output ~/reports/myapp-audit

# Local with domain filter and parallel execution
./repolens.sh --project ~/my-app --agent claude --local --domain security --parallel

# Dry run — preview which lenses would run without executing anything
./repolens.sh --project ~/my-app --agent claude --mode deploy --dry-run
```

## Remote deploy mode

Remote deploy mode lets you run deploy-mode server lenses from your workstation while inspecting a server over SSH. Use it only for server targets; it is rejected with `--hosted` and Android deploy targets.

Remote SSH runs with `BatchMode=yes`, so the connection must not require an interactive password prompt. Load the key before starting RepoLens, for example with `ssh-add ~/.ssh/server_deploy`, or pass an unlocked key with `--remote-key <path>`. RepoLens writes the remote preflight output for each run under `logs/<run-id>/.remote/preflight.log`.

Remote deploy uses OpenSSH ControlMaster so the run performs one TCP connection and authentication, then multiplexes agent SSH commands over the control socket. The master connection persists for 600 seconds after the last command, which reduces repeated authentication and connection setup during long deploy runs.

For the first run against a remote host, start with `--max-issues 1` and avoid `--parallel`; if you do enable parallel execution, keep it to `--parallel --max-parallel 1` until the transcript confirms commands are wrapped correctly and the target handles the SSH load. `--max-issues 1` keeps the first pass short, and `--max-parallel 1` prevents several lenses from competing for the same remote target while you validate the setup.

Forge actions still happen on the operator workstation. `gh`, `tea`, or `fj` issue creation, label setup, and issue lookups run locally against the configured forge account; only deploy-target investigation commands are wrapped over SSH.

## Advanced controls

These flags scale RepoLens beyond the simple [Quickstart](#quickstart) invocations. They compound cost — read [Warnings & Limits → Cost](#cost--repolens-can-be-very-expensive) before raising either.

- **`--depth N`** — within-lens iteration depth. The DONE-streak length the agent must reach (the agent outputs `DONE` as the first or last word `N` times consecutively) before the lens is considered complete. Defaults to `3` for `audit`, `feature`, and `bugfix`; defaults to `1` for every other mode (including `bugreport`). Supersedes the legacy `DONE_STREAK_REQUIRED` env var (honored as a fallback when `--depth` is unset, deprecated). Must be between `1` and `19`.
- **`--rounds N`** — multi-round investigation orchestrated by a meta-orchestrator that re-prioritizes lenses across rounds based on prior-round findings. Defaults to `1` for every pre-existing mode (single round, identical to pre-rounds runs); `bugreport` defaults to `3`. Per-mode caps: `audit`, `feature`, `bugfix`, `custom`, and `bugreport` accept `1`–`10`; `deploy`, `opensource`, `content`, and `discover` are locked to `1`.

### Example invocations

```bash
# Deep audit — full parallel audit with raised within-lens depth
./repolens.sh --project ~/my-app --agent claude --parallel --depth 5

# Focused single-lens deep-dive — high depth on one lens
./repolens.sh --project ~/my-app --agent claude --focus injection --depth 8

# Full bugreport pipeline — symptom-driven multi-round investigation
./repolens.sh --project ~/my-app --agent claude --mode bugreport --bug-report ~/bug.txt
```

### Cost discipline

Any run with `--depth > 3` or `--rounds >= 2` should be guarded explicitly. Use these together:

- `--max-cost <dollars>` — RepoLens warns if the lower-bound estimate exceeds the budget. Real runs typically cost 2–5× the lower bound.
- `--i-know-this-is-expensive` — required for `--rounds >= 4`. Acknowledges the multiplicative cost of multi-round runs.
- `--dry-run` — preview the resolved depth, rounds, and lens list before spending anything.

See [METHODOLOGY.md](METHODOLOGY.md) for the design rationale behind within-lens depth, multi-round orchestration, the meta-orchestrator, and cross-lens linking.

## CLI Reference

```
Usage: repolens.sh --project <path|url> --agent <agent> [OPTIONS]
       repolens.sh status [run-id] [OPTIONS]
```

### Commands

| Command           | Description                                                                                                                                                    |
| ----------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `status [run-id]` | Show a live run snapshot from `logs/<run-id>/status.json`. If `run-id` is omitted, RepoLens selects the newest run that has a status file. Requires only `jq`. |

### Required Flags

| Flag                    | Description                                                         |
| ----------------------- | ------------------------------------------------------------------- |
| `--project <path\|url>` | Local path, APK file, or remote Git URL (cloned read-only if URL)   |
| `--agent <agent>`       | `claude \| codex \| spark \| sparc \| opencode \| opencode/<model>` |

### Optional Flags

| Flag                   | Description                                                                                                                                                                                                                                                                                              |
| ---------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `--mode <mode>`        | `audit` (default) \| `feature` \| `bugfix` \| `bugreport` \| `discover` \| `deploy` \| `custom` \| `opensource` \| `content`                                                                                                                                                                            |
| `--bug-report <file\|text>` | Required for `--mode bugreport`. Path to a text file or inline symptom text (read verbatim). Env fallback: `REPOLENS_BUG_REPORT_PATH`. 100 KB max for file mode.                                                                                                                                  |
| `--change <statement>` | Change impact statement (implies `--mode custom`)                                                                                                                                                                                                                                                        |
| `--source <file>`      | Source material (PDF, text, markdown) for content creation or reference                                                                                                                                                                                                                                  |
| `--logs <path>`        | Runtime log file or directory for the `logs` domain (path string only — agent reads it)                                                                                                                                                                                                                  |
| `--focus <lens-id>`    | Run a single lens (e.g., `injection`, `dead-code`)                                                                                                                                                                                                                                                       |
| `--lens <lens-id>`     | Alias for `--focus`                                                                                                                                                                                                                                                                                      |
| `--domain <domain-id>` | Run all lenses in one domain (e.g., `security`)                                                                                                                                                                                                                                                          |
| `--relevant-domains <csv>` | Comma-separated allowlist of domain ids — the "missing middle" between `--focus` (1 lens) and full fan-out. The mode-filtered lens list is intersected with this allowlist; unknown or wrong-mode ids abort startup with the offending token named. Whitespace and empty tokens in the CSV are tolerated. Bypassed when `--focus` or `--domain` is set (those win). Composes with `--scope-by-keywords` (AND semantics) and with the triage-side relevant-domains filter. Example: `--relevant-domains concurrency,database`. |
| `--scope-by-keywords`  | Deterministic, LLM-free pruning for `--mode bugreport`: case-insensitive substring-match the bug-report text against each domain's optional `keywords` field in `config/domains.json`. Domains without a `keywords` field are always kept (back-compat). A zero-match result falls through with no pruning so the lens list never goes empty. Only effective in `--mode bugreport` (no-op in every other mode). Env fallback: `REPOLENS_SCOPE_BY_KEYWORDS=1`. |
| `--parallel`           | Run lenses in parallel (one agent process per lens)                                                                                                                                                                                                                                                      |
| `--max-parallel <n>`   | Max concurrent agents in parallel mode (default: 8)                                                                                                                                                                                                                                                      |
| `--resume <run-id>`    | Resume a previous interrupted run                                                                                                                                                                                                                                                                        |
| `--spec <file>`        | Spec/PRD/roadmap to guide analysis (any text file, max 100 KB)                                                                                                                                                                                                                                           |
| `--max-issues <n>`     | Stop after creating _n_ total issues                                                                                                                                                                                                                                                                     |
| `--depth <n>`          | DONE streak depth per lens. Defaults to `3` for `audit`, `feature`, and `bugfix`; defaults to `1` for all other modes. Must be between `1` and `19`                                                                                        |
| `--rounds <n>`         | Validated cross-lens round count for multi-round orchestration. Defaults to `1` for every pre-existing mode; `bugreport` defaults to `3`. `audit`, `feature`, `bugfix`, `custom`, and `bugreport` accept `1`-`10`; `deploy`, `opensource`, `content`, and `discover` are locked to `1`. `--rounds >= 4` requires `--i-know-this-is-expensive`. The resolved value is shown by `--dry-run` and sizes the `logs/<run-id>/rounds/round-N/` artifact layout |
| `--strategy <name>`    | Bugreport round-1 dispatch strategy: `fanout` (default — every lens runs in round 1, identical to today's `--mode bugreport`) \| `waves` (a narrow set of triage-seeded GENERIC investigators dispatch in round 1; subsequent rounds use the existing role-aware dispatch). `waves` requires `--mode bugreport` and rejects with a clear error on any other mode. The resolved value is shown by `--dry-run` under `--mode bugreport`. Env fallback: `REPOLENS_STRATEGY`. Wave width is controlled by `REPOLENS_WAVE_WIDTH` (default `7`, clamped to `1..50`). |
| `--local`              | Write findings as local markdown files instead of creating remote issues. No forge CLI required                                                                                                                                                                                                          |
| `--output <path>`      | Output directory for local markdown files (requires `--local`, default: `logs/<run-id>/rounds/round-1/lens-outputs/`)                                                                                                                                                                                   |
| `--forge <provider>`   | Override forge auto-detection: `gh` for GitHub, `tea` for Gitea, `fj` for Forgejo/Codeberg. Codeberg is auto-detected; use this for self-hosted Gitea/Forgejo remotes whose hostname is not auto-detected. Self-hosted Forgejo needs an HTTPS or SSH `origin` remote so RepoLens can pass `fj -H <host>` |
| `--hosted`             | Spin up Docker Compose for DAST scanning (used with `toolgate` domain)                                                                                                                                                                                                                                   |
| `--remote <ssh-target>` | Remote deploy server target. Accepts `host`, `host:port`, `user@host`, or `user@host:port`; only valid with `--mode deploy` server targets; incompatible with `--hosted` and Android deploy targets. The target is validated, exported to deploy agents, shown in `--dry-run`, and repeated in deploy authorization and normal run confirmation prompts. |
| `--remote-key <path>`  | SSH private key path for `--remote`. The path must exist and be a regular file. If omitted, remote SSH uses normal SSH key resolution. |
| `--remote-label <text>` | Human-readable label for the remote target. When provided, confirmation prompts show the label and a separate `Raw target: ...` line with the exact SSH target. Multi-word labels can be quoted or passed as adjacent words before the next option. |
| `--deploy-target <target>` | Deploy target resolver: `--deploy-target auto\|server\|android`, with `auto` as the default. Only valid with `--mode deploy`. `auto` opportunistically selects Android only for a direct APK, discovered APK, or shallow Android source marker (`gradlew`, `build.gradle`, `build.gradle.kts`, `app/build.gradle`, or `app/build.gradle.kts`); otherwise it preserves live-server deploy behavior. `server` skips Android detection and build handling. Only explicit `--deploy-target android` receives the no-source/no-APK Android exit when no APK or shallow marker exists. |
| `--build-android-apk` | In Android deploy mode, allow the optional source build fallback to run `./gradlew assembleDebug` when no APK is already resolved. The fallback is gated behind deploy authorization and the normal run confirmation, and is never executed during `--dry-run`. |
| `--max-cost <amount>`  | Warn if the **minimum cost estimate** exceeds this dollar amount (e.g., `--max-cost 10`). The estimate is a lower bound — real runs typically cost 2–5× more due to tool-call churn and iteration non-convergence. Budget accordingly.                                                                   |
| `--cross-link <mode>`  | Synthesizer cross-link strategy: `off` \| `comment` \| `suggest-reopen`. Controls whether the synthesizer links related findings across lenses/domains in the synthesized output. Defaults to `comment` for `bugreport`, `off` for every other mode. Env fallback: `REPOLENS_CROSS_LINK`.                |
| `--i-know-this-is-expensive` | Cost-acknowledgement gate required for `--rounds >= 4`. Does not bypass the `REPOLENS_MAX_ROUNDS` hard ceiling (default `5`). Equivalent to passing `--max-cost <budget>` together with `--yes`.                                                                                                  |
| `--dry-run`            | Validate config and show which lenses would run, then exit (no agents executed)                                                                                                                                                                                                                          |
| `--yes, -y`            | Skip confirmation prompt (for CI/automation)                                                                                                                                                                                                                                                             |
| `--version`            | Show version and sponsor information, then exit                                                                                                                                                                                                                                                          |
| `--about`              | Show tool description and sponsor information, then exit                                                                                                                                                                                                                                                 |
| `-h, --help`           | Show help                                                                                                                                                                                                                                                                                                |

### Hosted DAST Scanning

Use `--hosted` with the `toolgate` domain when the target project has a Docker Compose file and you want RepoLens to run live DAST tools against the services:

```bash
./repolens.sh --project ~/my-app --agent claude --domain toolgate --hosted
```

RepoLens starts or reuses the Compose project, connects scanner containers to the same Compose network, and lists services as `http://<service>:<internal-port>`. Discovery prefers Docker-network container ports from Compose metadata, falls back to exposed TCP ports from container metadata, and only uses a published host port when no internal port is known. If a service maps host port `8080` to container port `80`, DAST tools are pointed at `http://service:80`; the published host port is kept only as context. Services with no discovered TCP port are shown as `service:none`, marked `[not probed]` in service details, and are not guessed.

Hosted service details include a compact health label so agents can tell whether a target is ready before scanning:

```text
- web: http://web:80 (internal, nginx:alpine) [healthy]
- api: http://api:8000 (internal, python:3.12) [responding HTTP 404]
- job: no discovered port (example/job) [not probed]
```

RepoLens uses Docker Compose health/status data when available. Services without an explicit health status are probed from inside the Compose network at `http://<service>:<port>/`: 2xx and 3xx responses are `[healthy]`, 4xx responses are `[responding HTTP NNN]`, 5xx responses are `[unhealthy HTTP NNN]`, connection failures are `[unreachable]`, and unavailable probe state is `[unknown]`. If every discovered HTTP service is unhealthy or unreachable, RepoLens logs a warning before agents start so you can fix the Compose stack before spending scan iterations.

Hosted mode also checks common OpenAPI and Swagger locations from inside the Compose network. When RepoLens finds a raw JSON/YAML schema, or a docs UI that may point to one, the hosted prompt includes a separate API spec block using the same scanner-reachable service name and port:

```text
**Detected API specs:**
- api: http://api:8000/openapi.json (OpenAPI JSON)
- gateway: http://gateway:8080/api/docs (Swagger UI/docs, schema URL not confirmed)
```

Raw OpenAPI/Swagger schemas are preferred over docs pages. If no service exposes a recognized schema or docs endpoint, the block is omitted.

### Environment Variables

Agent timeouts are resolved per invocation with this precedence: `REPOLENS_AGENT_TIMEOUT_<AGENT>` > `REPOLENS_AGENT_TIMEOUT` > `REPOLENS_AGENT_TIMEOUT_<MODE>` > the mode default. `REPOLENS_LENS_MAX_WALL` caps the whole lens loop and each invocation is limited to the smaller of the resolved agent timeout and the remaining lens budget. Worst-case agent wall time per lens is bounded by `min(resolved agent timeout * MAX_ITERATIONS_PER_LENS, REPOLENS_LENS_MAX_WALL)` before rate-limit sleep and non-agent I/O; for a global override, that is `min(REPOLENS_AGENT_TIMEOUT * MAX_ITERATIONS_PER_LENS, REPOLENS_LENS_MAX_WALL)`. With the 1800s default and `MAX_ITERATIONS_PER_LENS=20`, the raw cap is 30 min * 20 = 10 hours before the default 3600s wall budget applies. Use an agent-specific variable when one backend needs a different cap, or a mode-specific variable when only one workflow needs a different per-invocation cap:

```bash
# Let live-server deploy investigations run longer without changing audit runs
REPOLENS_AGENT_TIMEOUT_DEPLOY=2400 ./repolens.sh --project /srv/myapp --agent claude --mode deploy

# Cap every mode for a short smoke run
REPOLENS_AGENT_TIMEOUT=300 ./repolens.sh --project ~/my-app --agent codex --focus injection

# Let OpenCode run longer without slowing Claude or Codex runs
REPOLENS_AGENT_TIMEOUT_OPENCODE=3600 ./repolens.sh --project ~/my-app --agent opencode/gpt-5.3
```

| Variable                             | Default  | Description                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| ------------------------------------ | -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `REPOLENS_AGENT_TIMEOUT`             | unset    | Global per-invocation timeout override in seconds. Wins over every mode-specific timeout, but agent-specific timeout variables win over this global value. Every agent call is wrapped with `timeout(1)` at the resolved cap; if an agent reaches the cap, the iteration is logged with `[ERROR] agent timed out after Ns`, and the lens loop continues.                                                                                                                                                       |
| `REPOLENS_AGENT_KILL_GRACE`          | `30`     | Seconds to wait after `timeout(1)` sends `SIGTERM` before escalating to `SIGKILL` via `--kill-after`. A clean timeout exits `124`; hard kill exits `137`. Must be a positive integer.                                                                                                                                                                                                                                                                                                                          |
| `REPOLENS_LENS_MAX_WALL`             | `3600`   | Per-lens wall-clock budget in seconds. Prevents one slow lens from holding a sequential run or parallel worker slot until `MAX_ITERATIONS_PER_LENS × resolved agent timeout`. Each iteration receives the remaining wall time as its effective timeout when that is lower than the resolved agent timeout. When the budget is exhausted, the lens stops with summary status `max-wall`. Must be a positive integer.                                                                                                      |
| `REPOLENS_AGENT_TIMEOUT_CLAUDE`      | unset    | Claude per-invocation timeout override. Wins over `REPOLENS_AGENT_TIMEOUT` and mode-specific timeout variables when `--agent claude` is selected.                                                                                                                                                                                                                                                                                                                                                              |
| `REPOLENS_AGENT_TIMEOUT_CODEX`       | unset    | Codex per-invocation timeout override. Wins over `REPOLENS_AGENT_TIMEOUT` and mode-specific timeout variables when `--agent codex` is selected.                                                                                                                                                                                                                                                                                                                                                                |
| `REPOLENS_AGENT_TIMEOUT_OPENCODE`    | unset    | OpenCode per-invocation timeout override. Wins over `REPOLENS_AGENT_TIMEOUT` and mode-specific timeout variables when `--agent opencode` or `--agent opencode/<model>` is selected.                                                                                                                                                                                                                                                                                                                           |
| `REPOLENS_AGENT_TIMEOUT_SPARK`       | unset    | Codex Spark per-invocation timeout override. Wins over `REPOLENS_AGENT_TIMEOUT` and mode-specific timeout variables when `--agent spark` is selected, and also applies to `sparc` when `REPOLENS_AGENT_TIMEOUT_SPARC` is unset.                                                                                                                                                                                                                                                                               |
| `REPOLENS_AGENT_TIMEOUT_SPARC`       | unset    | SPARC alias per-invocation timeout override. Wins over `REPOLENS_AGENT_TIMEOUT` and mode-specific timeout variables when `--agent sparc` is selected, and also applies to `spark` when `REPOLENS_AGENT_TIMEOUT_SPARK` is unset.                                                                                                                                                                                                                                                                               |
| `REPOLENS_AGENT_TIMEOUT_AUDIT`       | `1800`   | Audit-mode timeout when no agent-specific or global override is set.                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| `REPOLENS_AGENT_TIMEOUT_FEATURE`     | `1800`   | Feature-mode timeout when no agent-specific or global override is set.                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| `REPOLENS_AGENT_TIMEOUT_BUGFIX`      | `1800`   | Bugfix-mode timeout when no agent-specific or global override is set.                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| `REPOLENS_AGENT_TIMEOUT_DISCOVER`    | `1800`   | Discover-mode timeout when no agent-specific or global override is set.                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| `REPOLENS_AGENT_TIMEOUT_DEPLOY`      | `1800`   | Deploy-mode timeout when no agent-specific or global override is set.                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| `REPOLENS_AGENT_TIMEOUT_CUSTOM`      | `1800`   | Custom/change-impact timeout when no agent-specific or global override is set.                                                                                                                                                                                                                                                                                                                                                                                                                               |
| `REPOLENS_AGENT_TIMEOUT_OPENSOURCE`  | `1800`   | Open-source readiness timeout when no agent-specific or global override is set.                                                                                                                                                                                                                                                                                                                                                                                                                              |
| `REPOLENS_AGENT_TIMEOUT_CONTENT`     | `1800`   | Content-mode timeout when no agent-specific or global override is set.                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| `REPOLENS_AGENT_TIMEOUT_BUGREPORT`   | `1800`   | Bug-report mode timeout when no agent-specific or global override is set.                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| `REPOLENS_RATE_LIMIT_MAX_SLEEP`      | `21600`  | Maximum parsed agent rate-limit wait in seconds before RepoLens falls back to the terminal rate-limit abort path. When an agent exits non-zero with a known rate-limit signature and a parseable resume time within this cap, RepoLens sleeps until that time plus a 60-second buffer, retries the same lens once, and records `rate_limit_sleep_seconds` in `summary.json`. Unparseable resume times, waits beyond this cap, or a second rate-limit after retry abort the run.                                                                                 |
| `REPOLENS_NO_PROGRESS_LIMIT`         | `3`      | Consecutive degraded iterations allowed before RepoLens stops the lens with summary status `agent-no-progress`. A degraded iteration is a non-zero agent exit or near-empty output without `DONE`, issue URLs, or newly created local findings. Must be a positive integer no greater than the per-lens safety cap.                                                                                                                                                                                            |
| `REPOLENS_NO_PROGRESS_MIN_BYTES`     | `512`    | Output-size threshold, in bytes, used by the no-progress guard. Agent output below this size is treated as degraded unless the iteration still shows progress through `DONE`, issue URLs, or local findings. Must be a non-negative integer up to `1048576`.                                                                                                                                                                                                                                                     |
| `REPOLENS_DEGENERATE_THRESHOLD`      | `90`     | Percentage of run lenses that may end with status `max-iterations` before a zero-finding run is treated as broken. Must be an integer from `1` to `100`.                                                                                                                                                                                                                                                                                                                                                      |
| `REPOLENS_ALLOW_DEGENERATE`          | `false`  | Set to `true` to let a degenerate zero-finding run exit `0`. The run still records `health: "broken"` and `stopped_reason: "degenerate-no-findings"` in `summary.json`.                                                                                                                                                                                                                                                                          |
| `REPOLENS_CHILD_MAX_WAIT`            | `144000` | Per-child deadline in seconds for parallel-mode workers. `wait_all` polls each background lens with `kill -0` + `sleep 1` and, if a child exceeds this deadline, sends SIGTERM (10s grace) then SIGKILL, logs `[lens_id] exceeded REPOLENS_CHILD_MAX_WAIT=Ns`, and continues reaping the remaining children. Outer safety net above `REPOLENS_LENS_MAX_WALL`; keep it large enough to cover the lens wall budget plus rate-limit sleep and non-agent I/O (forge queries, file locks). |
| `REPOLENS_LABEL_CACHE_DIR`           | `${XDG_CACHE_HOME:-$HOME/.cache}/repolens/labels` | Directory for the short-lived remote-label bootstrap cache. RepoLens uses it to coordinate startup label setup across concurrent runs against the same repository.                                                                                                                                                                                                                                                                                                                            |
| `REPOLENS_LABEL_CACHE_TTL`           | `600`    | Freshness window, in seconds, for skipping repeated remote-label bootstrap work when the desired label set has already been seeded. Set to `0` to disable the skip hint while keeping normal label creation behavior.                                                                                                                                                                                                                                                                       |
| `DONE_STREAK_REQUIRED`               | unset    | Deprecated alias for `--depth`. Used only when `--depth` is unset, emits a warning, and must be between `1` and `19`.                                                                                                                                                                                                                                                                                                                            |
| `REPOLENS_ROUNDS`                    | `1`      | Fallback for `--rounds` when the CLI flag is unset. Must be a positive integer within the mode cap; CLI `--rounds` wins when both are provided.                                                                                                                                                                                                                                                                                                      |
| `REPOLENS_STRATEGY`                  | unset    | Fallback for `--strategy` when the CLI flag is unset. Accepts `fanout` or `waves`; any other value aborts startup. Only meaningful for `--mode bugreport` — `waves` is rejected on any other mode, and the resolved value is shown by `--dry-run` only under `--mode bugreport`. CLI `--strategy` wins when both are provided.                                                                                                                  |
| `REPOLENS_WAVE_WIDTH`                | `7`      | Number of GENERIC investigators dispatched in `--strategy waves` round 1. Non-positive or non-integer values fall back to `7`; values above `50` are clamped to `50`. Has no effect under `--strategy fanout`.                                                                                                                                                                                                                                          |
| `REPOLENS_SCOPE_BY_KEYWORDS`         | unset    | Fallback for `--scope-by-keywords` when the CLI flag is unset. Truthy values (`1`, `true`, `yes`, `on`) enable the deterministic keyword-based domain pruner; falsy or unrecognized values leave it disabled. CLI `--scope-by-keywords` wins when both are set. Only effective in `--mode bugreport`.                                                                                                                                                              |
| `REPOLENS_HEARTBEAT_INTERVAL`        | `60` for parallel log output, `15` for per-lens files | Shared heartbeat interval in seconds. While more than one parallel child is still running, `wait_all` logs `[heartbeat] N running: domain/lens (elapsed)` through the standard logging channels. Active lenses also write JSON heartbeat files under `logs/<run-id>/.heartbeat/` when `REPOLENS_LENS_HEARTBEAT_INTERVAL` is unset. Set to `0` to disable parallel log heartbeats and, when no lens-specific override is set, per-lens heartbeat files.                                                                      |
| `REPOLENS_LENS_HEARTBEAT_INTERVAL`   | unset    | Per-lens heartbeat file interval override in seconds. Wins over `REPOLENS_HEARTBEAT_INTERVAL` for files only; default file interval is `15` seconds when both variables are unset. Set to `0` to disable per-lens heartbeat files without changing parallel log heartbeats.                                                                                                                                                                                                                                     |
| `REPOLENS_STATUS_INTERVAL`           | `10`     | Whole-run `logs/<run-id>/status.json` refresh interval in seconds. Must be a positive integer; invalid values and `0` fall back to `10`. RepoLens writes the first snapshot immediately after run setup, then refreshes it while the run is active and writes a final `finished`, `finished-empty`, `failed`, or `interrupted` snapshot on exit.                                                                                                                                                                  |
| `REPOLENS_CLEANUP_GRACE`             | `5`      | Interrupt cleanup grace in seconds for tracked parallel workers. When a parallel run receives Ctrl-C or TERM, RepoLens asks tracked workers to stop, waits up to this many seconds, then force-stops any workers still running so cleanup returns. Set to `0` to skip the grace wait. Must be a non-negative integer.                                                                                                                                                                                            |

### Per-Lens Heartbeat Files

Each running lens writes a machine-readable heartbeat at:

```text
logs/<run-id>/.heartbeat/<domain>__<lens-id>.json
```

Inspect the file from another terminal while a run is active:

```bash
jq . logs/<run-id>/.heartbeat/<domain>__<lens-id>.json
```

The file is rewritten atomically while the lens is active and removed after clean lens completion. If the process dies abnormally, the last heartbeat is left behind so status tools and operators can treat it as stale. The JSON contains `run_id`, `domain`, `lens_id`, numeric `pid`, current `iteration`, `started_at`, `last_heartbeat_at`, and `state: "running"`.

### Run Status Snapshot

Each run also writes a whole-run progress snapshot at:

```text
logs/<run-id>/status.json
```

Show the newest run from another terminal while RepoLens is active:

```bash
./repolens.sh status
```

Show a specific run by id:

```bash
./repolens.sh status 20260315T120000Z-a1b2c3d4
```

The status command prints run metadata, started/updated times, progress counters, and active lenses with running time and heartbeat age. Active lenses whose heartbeat age is greater than 120 seconds are marked `[STALE?]`; use `--stale-after <seconds>` to change that threshold. A missing run exits `1` and lists available runs. A non-watch render with stale active lenses exits `2`, which is useful for CI or external monitoring.

Use raw JSON for scripts:

```bash
./repolens.sh status <run-id> --json
```

Refresh the terminal view until Ctrl-C:

```bash
./repolens.sh status <run-id> --watch 5 --no-color
```

Omit the watch interval to use the 5-second default. Use `--no-color` when piping output or capturing snapshots without ANSI color.

`status.json` is refreshed atomically at `REPOLENS_STATUS_INTERVAL` seconds and is safe for humans, scripts, and monitoring tools to read while RepoLens is running. It includes run metadata, `state`, `health`, `total_lenses`, `completion_percentage`, aggregate `counts`, and the `active`, `queued`, and `completed` lens lists.

The `state` value is `running` during execution, then `finished` when at least one finding was created, `finished-empty` when no findings were created without a degenerate failure, `failed` when the run health gate detects a broken zero-finding run, or `interrupted` after Ctrl-C or TERM. Final snapshots also include `health`: `ok` when findings exist, `no-findings` for a clean zero-finding run, `empty` when no lenses ran, or `broken` when zero findings were created and at least `REPOLENS_DEGENERATE_THRESHOLD` percent of run lenses ended as `max-iterations`. `active` entries come from per-lens heartbeat files and include `pid`, `iteration`, `started_at`, `last_heartbeat_at`, `age_seconds`, and `heartbeat_age_seconds`; stale heartbeat files are still reported. `queued` lists resolved lenses that are neither active nor completed. `completed` reflects completed lenses, including existing completed state when using `--resume`. `counts.issues_created` comes from `logs/<run-id>/summary.json`.

## Domains & Lenses (335 total across 32 domains)

### Code Analysis Domains (used by `audit`, `feature`, `bugfix`, `custom`)

| Domain                       | Lenses | Focus                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| ---------------------------- | ------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Security**                 | 11     | Injection, XSS/CSRF, auth, secrets, CVEs, headers, crypto, input validation, data exposure, rate limiting                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| **Code Quality**             | 14     | Naming, complexity, dead code, duplication, magic values, smells, linting, formatting, comments, types, immutability, readability, consistency                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| **Architecture**             | 9      | SoC, module boundaries, circular deps, coupling, SRP, dependency direction, API contracts, state, extensibility                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| **Testing**                  | 9      | Unit/integration/e2e gaps, quality, anti-patterns, edge cases, error paths, maintainability, determinism                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| **Error Handling**           | 6      | Unhandled errors, swallowing, messages, boundaries, graceful degradation, timeout/retry                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| **Performance**              | 9      | Queries, memory, blocking I/O, frontend perf, caching, algorithms, pagination, connections, startup                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| **API Design**               | 6      | REST conventions, validation, response consistency, versioning, idempotency, documentation                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| **Database**                 | 6      | Schema, migrations, indexes, transactions, integrity, query safety                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| **Frontend**                 | 5      | Component architecture, accessibility, responsive design, routing, frontend security                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| **Visual Design**            | 5      | Color system, typography scale, spacing system, visual hierarchy, icon consistency                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| **Design System**            | 4      | Design tokens, component library usage, CSS architecture, UI copy consistency                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| **Interaction Design**       | 8      | Loading states, error states, form UX, animations, interactive feedback, touch targets, scroll behavior, keyboard navigation                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| **Information Architecture** | 6      | Empty states, navigation patterns, content hierarchy, search UX, help context, dashboard patterns                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| **Adaptive UX**              | 5      | Adaptive content, theme adaptation, viewport sizing, RTL layout, print stylesheet                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| **UX Anti-Patterns**         | 6      | Dark patterns, cognitive overload, destructive actions, flow dead-ends, permission anti-patterns, notification interrupts                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| **Observability**            | 5      | Logging, structured logging, metrics, audit trail, health monitoring                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| **DevOps**                   | 6      | CI, Docker, env config, deployment safety, infra reproducibility, dependency management                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| **Compliance**               | 56     | GDPR/DSGVO, NIS2, HIPAA, PCI-DSS, AI Act, DORA, AML/KYC, sovereignty, privacy-by-design, data retention, consent flows, and 45 more                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| **Maintainability**          | 6      | Tech debt, upgrade paths, config patterns, error traceability, modularity, dependency health                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| **Internationalization**     | 2      | String internationalization, locale-aware formatting                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| **Documentation**            | 4      | Code docs, architecture docs, operational docs, onboarding                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| **Concurrency**              | 4      | Race conditions, async patterns, resource contention, transaction concurrency                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| **Tool Gate**                | 18     | Lint, typecheck, SAST, dependency CVEs, quality gates, test suite, DAST (web, injection, scanner, headers, API), session-based tools (ZAP, sqlmap, Nuclei, Lighthouse, k6, ZAP API, Schemathesis)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| **Runtime Log Analysis**     | 21     | Error storm detection for repeated log/event fingerprints above threshold; error cascade reconstruction across components with root cause, chain, terminal symptom, and break-point evidence; retry-loop detection for unchanged operations failing identically across repeated attempts; recursive-growth detection for depth, fan-out, queue, hop, and nesting counters that climb without convergence; resource-leak trajectory detection for handles, memory, connections, file descriptors, locks, caches, and queues whose repeated measurements climb across long-running logs; resource-exhaustion detection for OOM, file-descriptor, pool, thread/worker, disk/inode, socket, and conntrack hard-limit events; log-gap detection for abnormal silence in normally-busy components, workers, or subsystems; missing-heartbeat detection for periodic signals that stop, drift, never start, or report degraded payload state; silent-failure detection for start events with no terminal event; state-machine violation detection for illegal, skipped, regressed, incompatible, or cross-component lifecycle states; race-condition symptom detection for optimistic-lock exhaustion, double-processing, interleaved operations, split-brain leadership, and stale-read warnings visible in logs; lifecycle-order detection for terminal-before-start, duplicate start, duplicate terminal, swapped timestamp, and worker/thread reorder bugs; orphaned-event detection for missing acquire/release, begin/end, span/scope close, transaction terminal, or audit counterpart events after expected closure time; process-orphan detection for PIDs, sessions, lockfiles, pidfiles, temp dirs, worktrees, and sockets that survive past owner exit or cleanup; latency-degradation detection for same-operation durations, startup times, and p99 tails growing over time while work still completes; clock-skew detection for out-of-order, future-dated, timezone-less, precision-mixed, or cross-host drifted timestamps; timeout-cluster detection for rc=124/137, deadline, retry-chain, watchdog, and time-window timeout patterns; `--logs` passes a log file or directory path into lens prompts without orchestrator-level content reads                                                                                 |
| **Kubernetes**               | 7      | Pod/container security contexts, NetworkPolicy coverage, HPA/PDB coverage, resource requests/limits, LimitRange/ResourceQuota guardrails, image tags, pull policies, registry trust, Ingress TLS, cert-manager, HSTS, SSL redirect, RBAC least privilege, ServiceAccount scoping, secret manifests, SealedSecrets, SOPS, External Secrets, secret RBAC                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| **LLM Security**             | 5      | LLM output sanitization, rendering safety, prompt injection, RAG/tool/chat-history injection, agent sandbox boundaries, container privilege, subprocess fallbacks, credential exposure in agent environments, LLM API key isolation, secret redaction in tool output/logs, cost/token budget enforcement, rate limits on LLM-triggering endpoints, spend anomaly detection, tier/model access controls, markdown/link injection, external system forwarding, structured output validation, filesystem and command injection risks                                                                                                                                                                                                                                                                                                                               |
| **Infrastructure as Code**   | 5      | Terraform completeness, placeholder stubs, empty resource blocks, dead modules, missing outputs, broken references, provider/backend hygiene, Terraform security groups, encryption, IAM, public access, disabled resources, zero-resource plans, README-vs-code infrastructure promises, tfvars secrets, Terraform/OpenTofu state exposure, missing sensitive annotations, backend credentials, CI -var secret handling, VPC design, public/private subnet topology, NAT gateways, VPC Flow Logs, route tables, security groups, NACLs, peering, transit gateways, DNS, VPN, load balancer placement, database subnet exposure, backups, monitoring alarms, tagging policy, cost alerts, CloudTrail, S3 versioning, server-side encryption, lifecycle, access logging, replication, WAF, SNS alerting, service logging, maintenance windows, disaster recovery |

### Mode-Specific Domains

| Domain                    | Mode         | Lenses    | Focus                                                                                                                                                                                                                                                |
| ------------------------- | ------------ | --------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Product Discovery**     | `discover`   | 14 lenses | Product gaps, integration opportunities, UX improvements, monetization, developer experience, automation, data insights, scale readiness, community, competitive edge, accessibility, content/education, AI augmentation, workflow orchestration     |
| **Deployment**            | `deploy`     | 26 lenses | Service health, TLS, DNS, NTP, network security, load balancing, reverse proxy, disk/memory/CPU, containers, database, queues, secrets, SSH, hardening, logs, monitoring, backups, disaster recovery, config drift, dependencies, updates, cron jobs |
| **Android**               | `deploy`     | 17 lenses | APK overview, package metadata, bundled dependency CVE inventory, native `.so` inventory, JNI surface, binary hardening, AndroidManifest permissions and component flags, exported IPC components, intent filters, deeplinks, App Links, Android intent fuzzing for exported activities, providers, broadcasts, and malformed IPC inputs, drozer attack-surface enumeration for exported activities, services, receivers, providers, backup posture, and shared UID exposure, APK secrets, credentials, internal URLs, WebView security settings, JavaScript bridges, Network Security Config, TLS trust, certificate pinning, MITM traffic observation, logcat sensitive-data leaks, Frida runtime behavior hooks for crypto, file I/O, network, process, reflection, IPC, logging anomalies, anti-tamper and detection-bypass robustness, Android KeyStore, EncryptedSharedPreferences, SQLCipher/Realm secure-storage misuse, Android Lint, detekt, ktlint, Spotless, Gradle SDK consistency, manifest merger, R8/ProGuard posture, suppressions, baselines, and device-aware Android audit context |
| **Open Source Readiness** | `opensource` | 13 lenses | Secret leaks, license compliance, dependency licensing, internal exposure, git history secrets, community readiness, documentation gaps, monetization exposure, PII, build reproducibility, security posture, code attribution, trademarks           |
| **Content Quality**       | `content`    | 17 lenses | Content inventory, metadata, staleness, accessibility, linking, duplication, completeness, consistency, code examples, PII, multimedia, versioning, audience targeting, localization, topic extraction, planning, exercise design                    |

## How It Works

1. Validates target repo, server, APK target, or Android source tree, agent CLI, and forge CLI auth (skipped with `--local`)
2. Resolves lens list (all, `--domain`, `--focus`, or `--lens`) and creates the run artifact layout under `logs/<run-id>/`
3. If `--dry-run`: prints mode, agent, project path, resolved round count, remote target metadata when `--remote` is set, and the full lens list, then exits — no agents run, no prompts are shown, and no Android Gradle build is executed
4. For `--agent claude`: prompts for acknowledgment that `--dangerously-skip-permissions` only skips interactive permission prompts, not safety filters. `--yes` bypasses this prompt
5. For `deploy` mode: resolves `--deploy-target auto|server|android`, then prompts for explicit authorization confirmation (`I confirm I am authorized to audit this server [y/N]`). Displays legal references (§202a StGB, CFAA, EU Directive 2013/40/EU). When `--remote` is set, this prompt also shows `Remote target: ...`; labelled targets show `Raw target: ...` on the next line, followed by `Local commands will be wrapped in: ssh -S <socket> <target> '...'`. `--yes` bypasses this prompt
6. Shows confirmation prompt (target repo, mode, lens count, estimated cost) — requires `y` to proceed, or use `--yes` to skip. Remote deploy runs repeat the remote target and SSH wrapper preview before `Proceed? [y/N]`. For Android APK deploy targets, the prompt also shows the resolved APK path, detected package name or `unknown`, connected device status, `android` domain, queued lens count, and selected agent before `Proceed? [y/N]`. If no device is connected, dynamic lenses report no device and exit cleanly. If `--max-cost` is set and the estimate exceeds it, a warning is displayed
7. For Android source deploy targets with no resolved APK, `--build-android-apk` may then run `./gradlew assembleDebug`. RepoLens uses debug builds rather than release builds because debug builds are the predictable local artifact most Gradle projects can produce without release keystores, Play signing, publishing credentials, minification, or other release-only paths.
8. Ensures remote labels exist (skipped with `--local`). For remote runs, RepoLens coordinates this startup step across concurrent runs against the same repository and skips repeated setup for the same desired label set while the label cache is fresh
9. For each lens:
   - Composes prompt from base template + lens expert focus
   - Runs agent in target repo directory
   - Agent reads code, finds issues, and creates remote issues (or writes markdown files in `--local` mode)
   - Loops until DONE detected (3× streak for audit/feature/bugfix, 1× for other modes)
10. Writes `logs/<run-id>/status.json` while the run is active and generates `logs/<run-id>/summary.json`

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

- **Remote Issues** — Created directly in the target repo with severity-prefixed titles and domain labels (default)
- **Local Markdown** — With `--local`, findings are written as individual markdown files to `<output-dir>/<domain>/<lens-id>/NNN-slug.md` with YAML frontmatter (title, severity, domain, lens, labels). Default output directory: `logs/<run-id>/rounds/round-1/lens-outputs/`
- **Round Artifacts** — Every run creates `logs/<run-id>/rounds/round-N/` for each resolved round, including `metadata.json`, `lens-outputs/`, and `digest.md`. `round-N/.completed` appears only after that round finishes cleanly. Multi-round runs write between-round `dispatch.md` handoff files on completed rounds before the final round
- **Final Artifacts** — Every run creates `logs/<run-id>/final/` and `logs/<run-id>/final/filed/`. Successful multi-round runs promote a schema-validated `logs/<run-id>/final/manifest.json`; later filing stages record filed issue links under `final/filed/`
- **Logs** — `logs/<run-id>/<domain>/<lens>/iteration-N-TIMESTAMP.txt`
- **Heartbeats** — Active lenses write `logs/<run-id>/.heartbeat/<domain>__<lens-id>.json`; files are removed after clean lens completion and left behind if a worker exits abnormally
- **Status** — `logs/<run-id>/status.json`, refreshed during the run with queued, active, completed, issue-count, completion-percentage, run-health, and final-state data; render it with `./repolens.sh status [run-id]`
- **Summary** — `logs/<run-id>/summary.json`, including per-lens status, iterations, issue counts, `rate_limit_sleep_seconds`, final `health`, and run-level `stopped_reason` when an agent abort guard or the run-health gate stops the run

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

Set `REPOLENS_TEST_DOCKER=1` to also run integration tests requiring Docker.

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

`deploy` mode can target live servers, Android APK files, or shallow Android source trees. Live-server deploy runs read-only inspection commands (e.g., `systemctl`, `journalctl`, `ss`, `df`). Android deploy inspects the resolved APK or source tree. **You must have explicit authorization to audit the target before running deploy mode.**

`--remote <ssh-target>` is accepted only for deploy server targets and may be written as `host`, `host:port`, `user@host`, or `user@host:port`. It is rejected with `--hosted` and Android deploy targets. Remote deploy confirmations show the target before authorization and again before the run starts. If `--remote-label` is set, prompts show the label plus a separate `Raw target: ...` line. The same prompt block shows the SSH wrapper form agents will use, for example `Local commands will be wrapped in: ssh -S <socket> ubuntu@host.example.com:2222 '...'`.

**Legal risk:** Running RepoLens deploy mode against infrastructure you do not own or are not explicitly authorized to audit may constitute a criminal offense, including but not limited to:

- **Germany:** [§202a StGB](https://www.gesetze-im-internet.de/stgb/__202a.html) — Ausspähen von Daten (data espionage)
- **EU:** Directive 2013/40/EU — Attacks against information systems
- **United States:** Computer Fraud and Abuse Act (CFAA), 18 U.S.C. §1030
- **United Kingdom:** Computer Misuse Act 1990

RepoLens enforces read-only operation through prompt instructions, but **responsibility for authorization lies entirely with the user**. The CLI will prompt for explicit authorization confirmation before executing deploy mode. Using `--yes` to skip this prompt implies acceptance of this responsibility.

Android source builds are the exception to read-only inspection. If you pass `--build-android-apk` for an Android source target with no resolved APK, RepoLens may execute the target-controlled `./gradlew assembleDebug` after deploy authorization and the normal run confirmation. That build never runs during `--dry-run`.

For Android deploy prompts, `$REPOLENS_ANDROID_APK_PATH` exposes the resolved APK path to agents. The value comes from user input or files discovered inside the target project, so treat it as untrusted target-controlled data and quote it in shell usage, for example `aapt dump badging "$REPOLENS_ANDROID_APK_PATH"`.

### About `--dangerously-skip-permissions`

RepoLens passes `--dangerously-skip-permissions` to the Claude agent CLI. This flag is required for autonomous operation — agents need to create remote issues and read project files without interactive permission prompts. Despite its name, the flag does **not** disable safety filters, content guardrails, or ethical guidelines. Safety is enforced through detailed prompt instructions (not the CLI permissions system), which restrict agents to read-only analysis and remote issue creation commands.

When using `--agent claude`, RepoLens displays an explanation of the flag and asks for acknowledgment before running any agents. Use `--yes` to skip this prompt in CI/automation.

## Troubleshooting

Most first-run failures fall into one of these patterns. Errors are quoted verbatim from the script except placeholders such as `<host>`, which stand in for values RepoLens prints at runtime.

| Error / Symptom                                                                                                                      | Cause                                                                                                        | Fix                                                                                                                                                                                 |
| ------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ERROR: RepoLens requires bash 4.0 or newer.`                                                                                        | bash < 4 (macOS ships 3.2 by default)                                                                        | `brew install bash`, then re-run with the Homebrew `bash` first on `PATH`                                                                                                           |
| `Missing required command: jq`                                                                                                       | jq not installed                                                                                             | `apt install jq` / `brew install jq` / `nix-env -i jq`                                                                                                                              |
| `Missing required command: gh`                                                                                                       | GitHub CLI not installed for a GitHub target                                                                 | Install from [cli.github.com](https://cli.github.com), or pass `--local` to skip remote issue output                                                                                |
| `gh is not authenticated. Run 'gh auth login'.`                                                                                      | `gh` not authenticated, or token expired                                                                     | `gh auth login` (or `gh auth refresh` if your token is stale)                                                                                                                       |
| `Missing required command: tea`                                                                                                      | Gitea CLI not installed for a Gitea target                                                                   | Install from [gitea.com/gitea/tea](https://gitea.com/gitea/tea), or pass `--local` to skip remote issue output                                                                      |
| `tea is not authenticated. Run 'tea login add'.`                                                                                     | `tea` has no configured login for your Gitea account                                                         | `tea login add`                                                                                                                                                                     |
| `fj not found — install from https://codeberg.org/forgejo-contrib/forgejo-cli`                                                       | Forgejo CLI not installed for a Forgejo or Codeberg target                                                   | Install from [forgejo-contrib/forgejo-cli](https://codeberg.org/forgejo-contrib/forgejo-cli), or pass `--local` to skip remote issue output                                         |
| `fj is not authenticated. Run 'fj -H <host> auth login' or 'fj -H <host> auth add-key <user>'.`                                      | `fj` has no configured login for the detected Codeberg or Forgejo host                                       | Run the command shown in the error, for example `fj -H codeberg.org auth login`                                                                                                     |
| `Forgejo fj backend requires an HTTPS or SSH origin remote so RepoLens can pass fj --host; insecure HTTP origins are not supported.` | `--forge fj` was selected, but the target repo has no secure `origin` remote to derive the Forgejo host from | Add an HTTPS or SSH `origin` remote such as `https://forge.example.com/owner/repo.git`, or use `--local`                                                                            |
| `Missing required command: claude` (or `codex` / `opencode`)                                                                         | Agent CLI not installed                                                                                      | See [Supported Agent CLIs](#supported-agent-clis) for install + auth                                                                                                                |
| Agent prompts for login on every iteration                                                                                           | Agent CLI not authenticated                                                                                  | Authenticate the CLI directly — see [Supported Agent CLIs](#supported-agent-clis)                                                                                                   |
| `Invalid agent: …`                                                                                                                   | Typo in `--agent` value                                                                                      | Must be one of `claude`, `codex`, `spark`, `sparc`, `opencode`, `opencode/<model>`                                                                                                  |
| `Not a git repository: …`                                                                                                            | `--project` path is not a git repo                                                                           | Use `git init`, pass a real repo path, or use `--mode deploy` (which doesn't require git)                                                                                           |
| `--remote requires --mode deploy`                                                                                                    | `--remote` was passed outside deploy mode                                                                    | Add `--mode deploy`, or remove `--remote` for normal repository audits                                                                                                               |
| `--remote and --hosted are mutually exclusive`                                                                                       | Remote server metadata and hosted Docker Compose scanning were requested together                            | Choose either remote deploy server metadata with `--mode deploy --remote ...` or local hosted DAST scanning with `--hosted`                                                         |
| `--remote is incompatible with android deploy targets`                                                                               | `--remote` was combined with a direct APK, detected Android source tree, or `--deploy-target android`        | Remove `--remote`, or force server deploy with `--deploy-target server` when the path should be treated as a live-server target                                                      |
| `Remote key file does not exist or is not a regular file: …`                                                                         | `--remote-key` points to a missing path or a directory                                                       | Pass an existing private key file path, or omit `--remote-key` to rely on default SSH key resolution                                                                                 |
| `Cannot reach remote target … BatchMode requires no password prompt`                                                                  | SSH needs a passphrase or password but RepoLens remote preflight is non-interactive                          | `ssh-add` your key first, or pass an unlocked key with `--remote-key <path>`                                                                                                        |
| `Cannot reach remote target … kex_exchange_identification`                                                                            | The target or network is rejecting new SSH handshakes; fail2ban or a similar protection may have tripped     | Wait 10 minutes, verify direct SSH works, then retry with lower concurrency such as `--max-issues 1` or `--parallel --max-parallel 1`                                                |
| `[WARN] remote control socket lost; reopening`                                                                                        | The SSH ControlMaster socket was dropped or expired during a long-running lens                               | This can be expected on long-running lenses; if the run aborts, reduce concurrency and check `ServerAliveInterval` on the target's sshd and `ClientAliveInterval` on the master       |
| `agent ran an unwrapped local command`                                                                                                | A deploy lens executed a target command without the SSH wrapper                                              | Re-run with `--max-issues 1`, watch the transcript, and consider opening an issue with the offending lens-id                                                                         |
| `--hosted requires Docker to be installed`                                                                                           | Docker missing or daemon stopped                                                                             | Install Docker, then `sudo systemctl start docker` (or open Docker Desktop)                                                                                                         |
| `--hosted requires a docker-compose.yml or compose.yml in the project`                                                               | No compose file at project root                                                                              | Add a compose file, or drop `--hosted` and audit statically                                                                                                                         |
| `All discovered hosted HTTP services are unhealthy or unreachable`                                                                   | Every discovered hosted HTTP target failed its Compose health status or HTTP probe                           | Check `docker compose ps`, service logs, healthchecks, and the service root HTTP paths before spending DAST scan iterations                                                         |
| `Lens '…' not found in domains.json`                                                                                                 | Typo in `--focus` / `--lens` lens id, or wrong mode                                                          | List available lenses: `jq -r '.domains[].lenses[]' config/domains.json`                                                                                                            |
| `Domain '…' not found in domains.json`                                                                                               | Typo in `--domain` id, or mode mismatch                                                                      | `discover` / `deploy` / `opensource` / `content` modes only see their own domain — see the [Modes](#modes) table                                                                    |
| `Mode 'custom' requires --change "your change statement"`                                                                            | `--mode custom` without a change statement                                                                   | Pass `--change "your statement"`                                                                                                                                                    |
| `Hit safety cap (N iterations). Stopping lens.`                                                                                      | Agent never emitted `DONE` 3× in a row                                                                       | Inspect `logs/<run-id>/<domain>/<lens>.log` — usually a model output-format issue, rate limit, or context overflow. Retry with a smaller `--max-parallel` or a different `--agent`. |
| `Agent rate-limited / quota exceeded. Aborting run.`                                                                                 | Agent hit a provider quota and RepoLens could not use the one-shot sleep retry                               | Inspect the lens log for the provider message, then wait for quota reset, retry with lower `--max-parallel`, rerun with `--resume <run-id>`, or raise `REPOLENS_RATE_LIMIT_MAX_SLEEP` before starting a new run. |
| `No-progress circuit breaker tripped`                                                                                                | The agent repeatedly exited non-zero or produced near-empty output without `DONE`, issue URLs, or local findings | Inspect the lens log for provider outages, auth failures, crashed agent CLIs, or unexpected empty output. Fix the agent/backend issue, then rerun with `--resume <run-id>`. Tune `REPOLENS_NO_PROGRESS_LIMIT` or `REPOLENS_NO_PROGRESS_MIN_BYTES` only for agents that are expected to be unusually terse. |
| `Run health: BROKEN`                                                                                                                  | The run created zero findings and at least `REPOLENS_DEGENERATE_THRESHOLD` percent of run lenses stopped at `max-iterations` | Inspect the affected lens logs for agents that repeatedly missed the required `DONE` streak. Retry with a smaller scope or different agent, lower concurrency if provider instability is suspected, or set `REPOLENS_ALLOW_DEGENERATE=true` only when CI should accept this known-broken result while preserving `summary.health="broken"`. |
| `Pricing data is N days old — estimates may be inaccurate`                                                                           | `config/agent-pricing.json` has not been refreshed in over 60 days                                           | Update the pricing file with current model prices from your AI provider's pricing page, and set the top-level `updated_at` field to today's date                                    |
| `Running non-interactively without --yes flag.`                                                                                      | CI / non-TTY without confirmation                                                                            | Pass `--yes` (read [Security & Safe Use](#security--safe-use) first)                                                                                                                |

**Still stuck?** Check `logs/<run-id>/` — every lens writes its full agent transcript there, including the prompt sent and the raw output received. The run id is printed at startup. To list past runs: `ls -1 logs/`.

## Support

RepoLens is free, open source, and maintained on a best-effort basis. **We do not offer free user support.** Please do not open GitHub issues asking for help with installation, environment setup, or general usage — the [Troubleshooting](#troubleshooting) section above covers the predictable failures, and `logs/<run-id>/` covers the rest.

**Bug reports** (with reproduction steps) and **well-scoped feature requests** are welcome via [GitHub Issues](https://github.com/TheMorpheus407/RepoLens/issues).

**Commercial / paid support** for companies — installation help, custom lens development, integration consulting, prioritized fixes — is available. Email [hallo@bootstrap.academy](mailto:hallo@bootstrap.academy).

Supported by [Patreon patrons](https://patreon.com/themorpheus) — thank you.
