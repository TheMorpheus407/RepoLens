# Contributing to RepoLens

Thank you for your interest in contributing to RepoLens — an open-source, multi-lens code audit and analysis tool. Whether you're adding a new analysis lens, fixing a bug, or improving documentation, your contribution helps make automated code review more thorough and accessible.

## Table of Contents

- [Quick Start: Adding a Lens](#quick-start-adding-a-lens)
- [Lens Prompt Conventions](#lens-prompt-conventions)
- [Domain Taxonomy](#domain-taxonomy)
- [Registering in domains.json](#registering-in-domainsjson)
- [PR Workflow](#pr-workflow)
- [Commit Messages](#commit-messages)
- [DCO Sign-Off](#dco-sign-off)
- [Code Style](#code-style)
- [Running Tests](#running-tests)
- [Reporting Bugs](#reporting-bugs)
- [Suggesting Features](#suggesting-features)
- [Proposing a Lens](#proposing-a-lens)
- [Prerequisites](#prerequisites)
- [Code of Conduct](#code-of-conduct)
- [License](#license)

## Quick Start: Adding a Lens

The fastest way to contribute is to add a new analysis lens. Follow these steps:

1. Pick a domain from `config/domains.json` (see [Domain Taxonomy](#domain-taxonomy))
2. Create your lens file at `prompts/lenses/<domain>/<your-lens-id>.md`
3. Write the YAML frontmatter and prompt body (see [Lens Prompt Conventions](#lens-prompt-conventions))
4. Add your lens ID to the `"lenses"` array in `config/domains.json` (see [Registering in domains.json](#registering-in-domainsjson))
5. Run `make check` to verify nothing is broken
6. Commit with DCO sign-off and open a pull request

No code changes are needed — the template engine picks up new lenses automatically.

## Lens Prompt Conventions

Every lens file lives at `prompts/lenses/<domain>/<lens-id>.md` and follows this exact structure. Use kebab-case for lens IDs (e.g., `race-conditions`, `xss-csrf`, `error-propagation`).

All 4 frontmatter fields are required: `id`, `domain`, `name`, `role`. The template engine in `lib/template.sh` parses these fields using `read_frontmatter()`.

Here is an annotated example:

```yaml
---
id: race-conditions
domain: concurrency
name: Race Condition Detection
role: Race Condition Specialist
---

## Your Expert Focus

You specialize in identifying race conditions, data races, and unsafe concurrent access patterns.

### What You Hunt For

**Shared State Issues**
- Unprotected shared mutable state across threads or goroutines
- Missing synchronization primitives (mutexes, semaphores, channels)
- Time-of-check to time-of-use (TOCTOU) vulnerabilities

**Deadlock Risks**
- Lock ordering violations
- Nested lock acquisition without consistent ordering

### How You Investigate

1. Identify all shared mutable state and its access patterns
2. Trace lock acquisition order across call paths
3. Check for missing atomic operations on counters and flags
4. Look for channel or queue usage without proper backpressure
```

### Structure Breakdown

| Section | Purpose |
|---|---|
| `id` | Unique kebab-case identifier, matches the filename (without `.md`) |
| `domain` | Must match a domain ID in `config/domains.json` |
| `name` | Human-readable display name for the lens |
| `role` | The expert persona the agent adopts |
| `## Your Expert Focus` | One-sentence description of the specialty area |
| `### What You Hunt For` | Categorized list of specific issues, anti-patterns, or vulnerabilities |
| `### How You Investigate` | Step-by-step investigation methodology |

## Domain Taxonomy

RepoLens organizes its 27 domains into default-mode domains (available in audit/feature/bugfix modes) and mode-specific domains (exclusive to their respective modes). See `config/domains.json` for the complete and authoritative list — it is the source of truth for domain definitions.

### Default-Mode Domains (23)

| Domain ID | Name | Lenses |
|---|---|---|
| security | Security | 11 |
| code-quality | Code Quality | 14 |
| architecture | Architecture | 9 |
| testing | Testing | 9 |
| error-handling | Error Handling | 6 |
| performance | Performance | 9 |
| api-design | API Design | 6 |
| database | Database | 6 |
| frontend | Frontend | 5 |
| visual-design | Visual Design | 5 |
| design-system | Design System | 4 |
| interaction-design | Interaction Design | 8 |
| information-architecture | Information Architecture | 6 |
| adaptive-ux | Adaptive UX | 5 |
| ux-antipatterns | UX Anti-Patterns | 6 |
| observability | Observability | 5 |
| devops | DevOps | 6 |
| compliance | Compliance | 56 |
| maintainability | Maintainability | 6 |
| i18n | Internationalization | 2 |
| documentation | Documentation | 4 |
| concurrency | Concurrency | 4 |
| toolgate | Tool Gate | 18 |

### Mode-Specific Domains (4)

These domains have a `"mode"` field in `config/domains.json` that restricts them to a specific run mode. Each mode only sees domains matching its mode value.

| Domain ID | Name | Mode | Lenses |
|---|---|---|---|
| discovery | Product Discovery | `discover` | 14 |
| deployment | Deployment | `deploy` | 26 |
| open-source-readiness | Open Source Readiness | `opensource` | 13 |
| content-quality | Content Quality | `content` | 17 |

## Registering in domains.json

After creating your lens file, add its ID to the appropriate domain's `"lenses"` array in `config/domains.json`:

```json
{
  "id": "concurrency",
  "name": "Concurrency",
  "order": 22,
  "lenses": [
    "race-conditions",
    "async-patterns",
    "resource-contention",
    "transaction-concurrency",
    "your-new-lens-id"
  ]
}
```

Add your lens ID to the end of the `"lenses"` array in the domain that matches your lens's `domain` frontmatter field. The lens ID must match the filename (without `.md`) and use kebab-case.

## PR Workflow

1. **Fork** the repository on GitHub
2. **Branch** — create a feature branch from `master`:
   ```bash
   git checkout -b feat/add-my-new-lens master
   ```
3. **Implement** your changes and run `make check` to ensure all tests pass before committing
4. **Commit** with a [Conventional Commits](#commit-messages) message and [DCO sign-off](#dco-sign-off):
   ```bash
   git commit -s -m "feat: add buffer-overflow detection lens"
   ```
5. **Pull request** — submit a PR against `master` with a clear description of what your lens detects
6. **Review** — a maintainer will review your PR. Address any feedback
7. **Merge** — once approved, a maintainer will merge your contribution

## Commit Messages

This project follows the [Conventional Commits](https://www.conventionalcommits.org/) convention. Every commit message must use the `<type>: <description>` pattern:

- `feat:` — a new feature or lens (e.g., `feat: add sql-injection detection lens`)
- `fix:` — a bug fix (e.g., `fix: correct frontmatter parsing for multiline roles`)
- `docs:` — documentation changes
- `test:` — adding or updating tests
- `chore:` — maintenance tasks

Keep the description lowercase and concise. No scope parentheses are used in this project.

## DCO Sign-Off

All contributions must include a Developer Certificate of Origin (DCO) sign-off. This certifies that you have the right to submit the contribution under the project's open-source license.

Add the sign-off by using the `-s` flag when committing:

```bash
git commit -s -m "feat: add my new lens"
```

This appends a `Signed-off-by` line to your commit message:

```
Signed-off-by: Your Name <your-email@example.com>
```

The DCO is a lightweight alternative to a full CLA — it simply means you agree to the [Developer Certificate of Origin](https://developercertificate.org/).

## Code Style

All shell scripts in RepoLens follow these conventions:

- Use `set -uo pipefail` at the top of every script — do not use `set -e` (callers handle errors explicitly)
- Functions should be pure where possible — side effects must be documented in comments
- Config is JSON, parsed with `jq`
- Logs follow structured format: `[LEVEL] [timestamp] message`
- Quote all variable expansions: `"$var"` not `$var`
- Use `local` for function-scoped variables

## Running Tests

Run the full test suite with:

```bash
make check
```

Tests live in the `tests/` directory and follow the `test_*.sh` naming pattern. Each test script is a standalone bash script that validates a specific aspect of the project (documentation, configuration, lens structure, etc.).

When adding a new lens, run `make check` to verify your lens file is correctly structured and registered.

CI runs ShellCheck and the full test suite automatically on every pull request and push to `master`. You will see the results as a status check on your PR.

## Reporting Bugs

Open a [GitHub issue](https://github.com/TheMorpheus407/RepoLens/issues) with:

- A clear description of the bug
- Steps to reproduce
- Expected vs. actual behavior
- Your environment (OS, bash version, agent CLI used)

## Suggesting Features

Open an issue with the `enhancement` label. Describe the use case and why it would benefit the project.

## Proposing a Lens

Have an idea for a new analysis lens but don't want to implement it yourself? Open an issue using the **Lens Request** template. Describe what the lens should detect, which domain it belongs to, and give a few example findings. The community or maintainers can pick it up from there.

## Prerequisites

To contribute to RepoLens, you need:

- **Bash 4.0+** — the shell runtime
- **jq** — for JSON processing
- **git** — for repository operations
- At least one supported **agent CLI** (`claude`, `codex`, `opencode`, or `sparc`)

## Code of Conduct

This project follows the [Contributor Covenant Code of Conduct](CODE_OF_CONDUCT.md). By participating, you are expected to uphold this code. Please report unacceptable behavior via the channels described in the Code of Conduct.

## License

By contributing, you agree that your contributions will be licensed under the [Apache License 2.0](LICENSE).
