# Changelog

All notable changes to RepoLens will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/), and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Fixed

- `config/agent-pricing.json` refreshed to current Anthropic pricing (2026-05-24): corrected `claude-opus-4-6` from $15/$75 to $5/$25 per MTok, added `claude-sonnet-4-6` ($3/$15) and `claude-opus-4-7` ($5/$25), and updated the default model for `--agent claude` from `claude-sonnet-4-5` to `claude-sonnet-4-6`. Cost estimates shown by `--dry-run` and the confirmation prompt are now within ±10% of current published pricing ([#249](https://github.com/TheMorpheus407/RepoLens/issues/249))
- Parallel rate-limit aborts now preserve operator-visible terminal state: lens-level provider quota aborts finish as `status.json.state: "rate-limit-pending"` with CLI exit `3`, while SIGHUP, SIGINT, or SIGTERM during a rate-limit retry sleep finish as `interrupted` with the corresponding stopped reason and exit code `129`, `130`, or `143` ([#276](https://github.com/TheMorpheus407/RepoLens/issues/276))
- Greenfield planning now refreshes current backlog state before every planner iteration: forge runs read all currently open issues, `--local` runs read current draft markdown files, and planning stops instead of filing blind when forge backlog checks are unavailable ([#285](https://github.com/TheMorpheus407/RepoLens/issues/285))

### Changed

- Polish mode now collects structured JSON suggestions, writes `logs/<run-id>/polish/ranked-suggestions.json`, and emits one `[POLISH]` lens-scoped polishing shortlist per lens with ranked top-N suggestions (default 3) and a voice-fit justification for each listed item. Forge runs create remote shortlist issues; `--local` runs write grouped markdown drafts under `logs/<run-id>/polish/filed/` ([#301](https://github.com/TheMorpheus407/RepoLens/issues/301), [#302](https://github.com/TheMorpheus407/RepoLens/issues/302))

### Added

- `--local` runs now also write the canonical finding registry — `logs/<run-id>/final/findings.jsonl` and the flat `findings.csv` — indexing the `NNN-<slug>.md` finding files RepoLens dumps into the output directory. Previously a `--local` audit produced an unindexed tree of markdown with no machine-readable manifest; now each registry record's `markdown_path` resolves to its source file, the registry is written under `final/` (the output directory stays markdown-only), the build is non-fatal (a failure warns and the run still succeeds), and the end-of-run summary prints the index path ([#349](https://github.com/TheMorpheus407/RepoLens/issues/349))
- Per-lens wall-clock timing in `summary.json`: each non-skipped lens object now carries `started_at` and `completed_at` (ISO-8601 UTC) plus an integer `duration_seconds`, so you can tell which lenses dominate a multi-hour run. Skipped lenses report `null` timestamps and `0` duration ([#337](https://github.com/TheMorpheus407/RepoLens/issues/337))
- End-of-run time breakdown: every run now prints a `Time breakdown` section to stdout, just before the `=== RepoLens Run Summary ===` JSON dump, that rolls up the per-lens `duration_seconds`. It reports total wall time, total lens-seconds, the 10 slowest individual lenses, and per-domain duration totals (descending), all human-formatted (e.g. `2h 13m`). Runs whose `summary.json` predates per-lens timing degrade gracefully to a single `Time breakdown: no timing data` line instead of erroring ([#340](https://github.com/TheMorpheus407/RepoLens/issues/340))
- `--human-review` flag (with `REPOLENS_HUMAN_REVIEW` env fallback): the entry point for a forthcoming curated, noise-budgeted human-review digest that renders at finalize time instead of dumping every finding (a full run can emit hundreds). The flag takes no argument, accepts truthy/falsy values via the env fallback (`1`/`true`/`yes`/`on` enable, `0`/`false`/`no`/`off`/empty disable, any other value aborts startup with an error mentioning `REPOLENS_HUMAN_REVIEW`), honors CLI-over-env precedence, and shows the resolved value in `--dry-run` as `Human review: <bool>`. No digest is rendered yet — the bucketing, renderer, and held-back accounting land in follow-up issues ([#325](https://github.com/TheMorpheus407/RepoLens/issues/325))
- `--mode greenfield`: a spec-led backlog planning mode that requires `--spec`, runs the new Greenfield Planning domain, avoids repository code inspection, stays locked to `--rounds 1`, and creates one implementation-sized `[P0]`-`[P3]` issue per invocation until existing issues sufficiently cover the specification ([#283](https://github.com/TheMorpheus407/RepoLens/issues/283))
- `repolens.sh clean` subcommand: removes old run directories under `logs/` by age (`--older-than <dur>`, default `30d`) and count (`--keep-last <n>`, default `50`), with `--dry-run`, `--force`, and `--remove-incomplete`. It uses a strictly positive selector — only run-id-named children of `logs/` carrying `summary.json` or `status.json` are ever considered — keeps resume candidates by default, and always keeps currently-live runs. The confirmation prompt is auto-skipped when stdin is not a terminal. Opt-in startup auto-retention runs the same prune in the background when `REPOLENS_AUTO_CLEAN=true` (`REPOLENS_RETENTION_DAYS` default `30`, `REPOLENS_KEEP_LAST` default `50`) and logs the resolved retention settings at INFO; off by default. Per-lens forensic `iteration-N-TIMESTAMP.txt` captures are now gzipped after a lens finishes, keeping the most recent `REPOLENS_ITERATION_KEEP` (default `3`) uncompressed — this data is never read by synthesis, verification, or `--resume` ([#251](https://github.com/TheMorpheus407/RepoLens/issues/251))
- Pricing staleness warning: when `config/agent-pricing.json` is more than 60 days old, the confirmation prompt and `--dry-run` output emit `[WARN] Pricing data is N days old — estimates may be inaccurate`. The warning is informational and does not block execution ([#249](https://github.com/TheMorpheus407/RepoLens/issues/249))
- `repolens.sh supersede <run-id>` subcommand: explicitly retires a run by writing a `.superseded` marker into `logs/<run-id>/`. A superseded run is skipped by `status` no-arg auto-selection (even when it is the newest) and becomes eligible for `clean` removal without `--remove-incomplete`, while a currently-live run is still never removed. The run id must be a direct `logs/` child and a genuine run dir; ids containing `/`, `.`, or `..` are rejected ([#312](https://github.com/TheMorpheus407/RepoLens/issues/312))

## [0.2.0] — 2026-05-24

### Security

- `--spec` file content is now sanitized to prevent prompt injection via `<spec>`/`</spec>` tag breakout — a malicious spec file could previously close the content boundary early and inject arbitrary top-level instructions into the agent prompt ([#50](https://github.com/TheMorpheus407/RepoLens/issues/50))

### Fixed

- Runs that create zero findings and mostly end at the per-lens `max-iterations` safety cap are now classified as broken instead of clean: `summary.json` records `health: "broken"` and `stopped_reason: "degenerate-no-findings"`, `status.json` reports `state: "failed"`, and the CLI exits `2` unless `REPOLENS_ALLOW_DEGENERATE=true`. Clean zero-finding runs now report `health: "no-findings"` with final state `finished-empty`; tune the broken-run percentage with `REPOLENS_DEGENERATE_THRESHOLD` ([#220](https://github.com/TheMorpheus407/RepoLens/issues/220)).
- Persistent agent failures that do not match the rate-limit detector now stop early through a no-progress circuit breaker instead of burning the full per-lens iteration cap. Configure it with `REPOLENS_NO_PROGRESS_LIMIT` and `REPOLENS_NO_PROGRESS_MIN_BYTES`; affected lenses remain resumable with status `agent-no-progress`, and systemic failures report `stopped_reason=agent-degraded` ([#212](https://github.com/TheMorpheus407/RepoLens/issues/212)).
- Agent rate-limit messages with parseable resume times now sleep within `REPOLENS_RATE_LIMIT_MAX_SLEEP`, retry the same lens once, and record `rate_limit_sleep_seconds`; unparseable, stale, too-far, or repeated rate limits still abort cleanly ([#115](https://github.com/TheMorpheus407/RepoLens/issues/115))
- Concurrent runs against the same repository now coordinate remote label setup, create only missing labels when supported, and reuse fresh matching bootstrap results while preserving normal issue-count behavior ([#186](https://github.com/TheMorpheus407/RepoLens/issues/186))
- Ctrl-C/TERM cleanup during parallel runs now returns after a bounded grace period, force-stopping unresponsive workers instead of waiting indefinitely. Configure the grace period with `REPOLENS_CLEANUP_GRACE` ([#114](https://github.com/TheMorpheus407/RepoLens/issues/114))
- `--hosted` service discovery now uses Docker Compose internal/container TCP ports for DAST URLs, falls back to exposed container ports when needed, and keeps published host ports as secondary context instead of pointing scanner containers at host-only NAT ports ([#83](https://github.com/TheMorpheus407/RepoLens/issues/83))
- `trademark-branding` lens (`--mode opensource`) no longer searches for hardcoded author-specific brand names when auditing third-party repositories — it now dynamically derives search terms from the audited repo's owner and name, plus any additional brand terms the agent discovers from the README or package manifest

### Changed

- Agent invocation timeouts now use a layered resolver instead of one 6000-second fallback: agent-specific overrides (`REPOLENS_AGENT_TIMEOUT_CLAUDE`, `REPOLENS_AGENT_TIMEOUT_CODEX`, `REPOLENS_AGENT_TIMEOUT_OPENCODE`, `REPOLENS_AGENT_TIMEOUT_SPARK`, and `REPOLENS_AGENT_TIMEOUT_SPARC`) win over `REPOLENS_AGENT_TIMEOUT`, which wins over mode-specific `REPOLENS_AGENT_TIMEOUT_<MODE>` values; every supported mode now defaults to 1800 seconds. `opencode/<model>` uses the OpenCode override, and the Spark/SPARC aliases fall back to each other when only one alias variable is set ([#110](https://github.com/TheMorpheus407/RepoLens/issues/110), [#184](https://github.com/TheMorpheus407/RepoLens/issues/184))

### Added

- README and METHODOLOGY now document remote deploy mode end-to-end, including `--remote` examples, SSH key and ControlMaster behavior, remote troubleshooting, workstation-local forge actions, and the remote deploy security warning ([#201](https://github.com/TheMorpheus407/RepoLens/issues/201)).
- Remote deploy authorization and normal pre-run confirmation prompts now show the selected `--remote` target before the operator starts the run. Labelled targets show both `Remote target: <label>` and `Raw target: <ssh-target>`, and remote prompts include the SSH wrapper preview `ssh -S <socket> <target> '...'` ([#199](https://github.com/TheMorpheus407/RepoLens/issues/199)).
- `--remote <ssh-target>`, `--remote-key <path>`, and `--remote-label <text>` deploy-mode support. Remote targets accept `host`, `host:port`, `user@host`, or `user@host:port`, default to port `22`, require server deploy mode, reject `--hosted` and Android deploy targets, validate key paths as regular files, and appear in deploy `--dry-run` output ([#196](https://github.com/TheMorpheus407/RepoLens/issues/196)).
- `--deploy-target auto|server|android` for deploy mode. `auto` remains the default and falls back to live-server deployment lenses unless an APK or shallow Android source marker is found; `server` skips Android detection and build handling; `android` requires an APK or shallow Android source tree ([#188](https://github.com/TheMorpheus407/RepoLens/issues/188)).
- Android deploy fallback now reuses discovered APKs or, with `--build-android-apk`, builds a debug APK via `./gradlew assembleDebug` only after deploy authorization and normal run confirmation; deploy prompts receive `REPOLENS_DEPLOY_TARGET_KIND` and `REPOLENS_ANDROID_APK_PATH`, APK paths are sanitized for deploy log display, and default `--deploy-target auto` still falls back to live-server deploy when no Android target exists ([#87](https://github.com/TheMorpheus407/RepoLens/issues/87), [#192](https://github.com/TheMorpheus407/RepoLens/issues/192)).
- `--strategy <fanout|waves>` flag for `--mode bugreport`: selects the round-1 dispatch shape. `fanout` (default) keeps the existing behavior — every lens runs in round 1. `waves` dispatches a narrow set of triage-seeded GENERIC investigators in round 1; subsequent rounds fall back to the existing role-aware dispatch. `--strategy waves` requires `--mode bugreport` and rejects on any other mode with a clear error. The resolved value is shown by `--dry-run` under `--mode bugreport`. Env fallback: `REPOLENS_STRATEGY`. Wave width is controlled by `REPOLENS_WAVE_WIDTH` (default `7`, clamped to `1..50`) ([#226](https://github.com/TheMorpheus407/RepoLens/issues/226))
- `--relevant-domains <csv>` flag: comma-separated allowlist of domain ids — the "missing middle" between `--focus` (1 lens) and full fan-out. Intersects with the mode-filtered lens list; unknown or wrong-mode ids abort startup with the offending token named. Whitespace and empty tokens in the CSV are tolerated. Bypassed when `--focus` or `--domain` is set (those win). Composes with `--scope-by-keywords` and with the triage-side relevant-domains filter using AND semantics ([#228](https://github.com/TheMorpheus407/RepoLens/issues/228))
- `--scope-by-keywords` flag: deterministic, LLM-free pruning for `--mode bugreport`. Case-insensitive substring-matches the bug-report text against each domain's optional `keywords` field in `config/domains.json`; matching domains are kept, non-matching domains are dropped. Domains without a `keywords` field are always kept (back-compat), and a zero-match result falls through with no pruning so the lens list never goes empty. Only effective in `--mode bugreport`. Env fallback: `REPOLENS_SCOPE_BY_KEYWORDS=1`. Initial `keywords` populated on `security`, `error-handling`, `performance`, `database`, and `concurrency` ([#228](https://github.com/TheMorpheus407/RepoLens/issues/228))
- `--depth <n>` flag: within-lens iteration depth control — the DONE-streak length the agent must reach before a lens is considered complete. Defaults to `3` for `audit`, `feature`, and `bugfix`; defaults to `1` for every other mode (including `bugreport`). Must be between `1` and `19`. Supersedes the legacy `DONE_STREAK_REQUIRED` env var (honored as a fallback when `--depth` is unset).
- `bugreport` mode: symptom-driven multi-round bug-investigation pipeline. Requires `--bug-report <file|text>`; defaults to `--rounds 3` with the triage prefix phase enabled and the synthesizer's `--cross-link comment` strategy.
- `--cross-link <mode>` flag: synthesizer cross-link strategy (`off` | `comment` | `suggest-reopen`) for linking related findings across lenses/domains in the synthesized output. Defaults to `comment` for `bugreport`, `off` for every other mode. Env fallback: `REPOLENS_CROSS_LINK`.
- `--rounds <n>` now accepts a validated cross-lens round count, honors `REPOLENS_ROUNDS` as a fallback with CLI precedence, applies per-mode caps (`audit`, `feature`, `bugfix`, `custom`, and `bugreport` up to `10`; `deploy`, `opensource`, `content`, and `discover` locked to `1`), refuses to launch at `--rounds >= 4` unless `--i-know-this-is-expensive` (or `--max-cost <dollars>` + `--yes`) is set, and shows the resolved value in `--dry-run` ([#140](https://github.com/TheMorpheus407/RepoLens/issues/140))
- Runs now create an inspectable round artifact layout under `logs/<run-id>/rounds/round-N/` with round metadata, per-round lens outputs, completion barriers, and a top-level `final/` directory reserved for synthesis output ([#147](https://github.com/TheMorpheus407/RepoLens/issues/147))
- `logs/lifecycle-violations` lens for detecting out-of-order lifecycle pairs, duplicate starts, duplicate terminals, swapped timestamps, and cross-worker lifecycle reordering in runtime logs supplied through `--logs` ([#141](https://github.com/TheMorpheus407/RepoLens/issues/141))
- `logs/state-machine-violations` lens for detecting illegal, skipped, regressed, incompatible, or cross-component lifecycle states in runtime logs supplied through `--logs` ([#139](https://github.com/TheMorpheus407/RepoLens/issues/139))
- `repolens.sh status [run-id]` now renders the newest or named `logs/<run-id>/status.json` snapshot with human-readable progress, raw `--json`, `--watch`, `--stale-after`, `--no-color`, stale worker exit code `2`, and no normal `--project` / `--agent` requirement ([#122](https://github.com/TheMorpheus407/RepoLens/issues/122))
- Aggregated run status snapshots under `logs/<run-id>/status.json` now expose whole-run state, queued/active/completed lenses, issue totals, completion percentage, and final `finished`/`interrupted` state for operators and monitoring tools; configure refreshes with `REPOLENS_STATUS_INTERVAL` (default `10`) ([#121](https://github.com/TheMorpheus407/RepoLens/issues/121))
- Per-lens heartbeat files under `logs/<run-id>/.heartbeat/<domain>__<lens-id>.json` now expose active lens liveness, current iteration, timestamps, and worker PID for operators and status tooling; configure file heartbeats with `REPOLENS_LENS_HEARTBEAT_INTERVAL` or the shared `REPOLENS_HEARTBEAT_INTERVAL` fallback ([#120](https://github.com/TheMorpheus407/RepoLens/issues/120))
- Android APK deploy targets now show the resolved APK path, package name, device status, `android` domain, queued lens count, and selected agent in the confirmation preview before `Proceed? [y/N]` ([#90](https://github.com/TheMorpheus407/RepoLens/issues/90))
- `--hosted` now surfaces detected OpenAPI/Swagger JSON/YAML schemas, or useful docs UI hints, in a `Detected API specs` prompt block for DAST agents ([#85](https://github.com/TheMorpheus407/RepoLens/issues/85))
- `--hosted` service details now include Docker/HTTP health labels for discovered DAST targets and warn before scanning when every discovered HTTP service is unhealthy or unreachable ([#84](https://github.com/TheMorpheus407/RepoLens/issues/84))
- `iac/iac-compliance` lens for auditing IaC backups, monitoring alarms, tagging policy, automatic upgrades, CloudTrail, S3 versioning, server-side encryption, lifecycle, access logging, replication, WAF, cost alerts, SNS alerting, service logging, maintenance windows, and disaster recovery controls ([#82](https://github.com/TheMorpheus407/RepoLens/issues/82))
- `iac/iac-networking` lens for auditing VPC design, subnet topology, NAT gateways, VPC Flow Logs, route tables, security groups, NACLs, peering, transit gateways, DNS, VPN, load balancer placement, and database subnet exposure across Terraform, CloudFormation, Pulumi, and CDK ([#81](https://github.com/TheMorpheus407/RepoLens/issues/81))
- `llm-security/agent-isolation` lens for auditing agent sandbox boundaries, container privilege, writable host mounts, network reach, subprocess fallbacks, resource limits, and process cleanup ([#75](https://github.com/TheMorpheus407/RepoLens/issues/75))
- `llm-security/prompt-injection` lens for auditing prompt composition, instruction hierarchy, RAG/tool/chat-history injection, multi-step agent propagation, output validation, and prompt template management ([#74](https://github.com/TheMorpheus407/RepoLens/issues/74))
- `llm-security/output-sanitization` lens for treating LLM-generated content as untrusted data across HTML rendering, Markdown/external system forwarding, dangerous URL handling, filesystem/command sinks, and structured output validation ([#73](https://github.com/TheMorpheus407/RepoLens/issues/73))
- `kubernetes/secrets-management` lens for Kubernetes-native secret manifests, SealedSecrets, SOPS, External Secrets Operator references, secret RBAC, ServiceAccount token mounting, ConfigMap secret leakage, and rotation evidence ([#72](https://github.com/TheMorpheus407/RepoLens/issues/72))
- `kubernetes/ingress-tls` lens for Ingress TLS coverage, cert-manager evidence, HSTS, SSL redirect, NGINX Ingress hardening annotations, host/path conflicts, backend protocol checks, and TLS Secret cross-checking ([#70](https://github.com/TheMorpheus407/RepoLens/issues/70))
- `kubernetes/image-security` lens for deterministic image tags, explicit pull policies, registry trust, image pull secret coverage, and admission signature verification evidence ([#69](https://github.com/TheMorpheus407/RepoLens/issues/69))
- `kubernetes/resource-management` lens for HPA coverage, PodDisruptionBudget effectiveness, resource requests/limits, request-to-limit ratios, namespace LimitRange/ResourceQuota guardrails, and single-replica StatefulSet risk ([#68](https://github.com/TheMorpheus407/RepoLens/issues/68))
- Gitea `tea` backend for remote forge operations: RepoLens can authenticate with `tea login list`, create labels with `tea labels create --name ...`, and count matching open issues with `tea issues list --limit 1000 --output json` when `--forge tea` is selected or a Gitea origin is detected
- Forgejo/Codeberg `fj` backend for remote forge operations: RepoLens can authenticate with `fj -H <host> whoami`, create labels with `fj -H <host> repo labels ...`, and count matching open issues with `fj -H <host> issue search` when Codeberg is detected or `--forge fj` is selected for a Forgejo origin
- `--local` flag: write findings as local markdown files instead of creating remote issues — no forge CLI required
- `--output <path>` flag: custom output directory for local markdown files (requires `--local`; omitted output now defaults to `logs/<run-id>/rounds/round-1/lens-outputs/`)

### Deprecated

- `DONE_STREAK_REQUIRED` env var: superseded by `--depth`. The env var continues to work for the current release cycle (honored as a fallback when `--depth` is unset) and emits a deprecation warning at startup. Scheduled for removal in a future minor release (target removal: v0.3.0).

### Backward compatibility

- Defaults preserve all prior behavior: `--depth` defaults to the prior `3` for `audit` / `feature` / `bugfix` and `1` for every other mode (including the new `bugreport`); `--rounds` defaults to `1` for every pre-existing mode (single round, identical to pre-rounds runs), with `bugreport` defaulting to `3`; `bugreport` mode is opt-in; `--cross-link` defaults to `off` outside `bugreport`; `--strategy` defaults to `fanout` so today's `--mode bugreport` invocations dispatch every lens in round 1 exactly as before; `--relevant-domains` and `--scope-by-keywords` are both opt-in, and domains without a `keywords` field are always kept by the keyword pruner. Existing invocations work identically without any flag changes.

### Documentation

- "Adding a Lens" section in README now links to CONTRIBUTING.md for the full contribution workflow (fork, branch, PR process)
- `GOVERNANCE.md` documenting project leadership (BDFL model), decision-making, contribution acceptance criteria, conflict resolution, and governance evolution
- Governance section in README linking to `GOVERNANCE.md`
- New "Advanced controls" section in README covering `--depth`, `--rounds`, three realistic example invocations (deep audit, focused single-lens deep-dive, full bugreport pipeline), a cost-discipline note pointing at `--max-cost` / `--i-know-this-is-expensive` / `--dry-run`, and a pointer to METHODOLOGY.md
- "Warnings & Limits → Cost" section now documents multiplicative `depth × rounds` scaling and the `--rounds >= 4` cost-acknowledgement gate (with the separate `REPOLENS_MAX_ROUNDS` hard ceiling)

### Compliance

- All `.sh` source files now include the standard Apache 2.0 license header (copyright, license grant, and disclaimer) after the shebang line, per the Apache License 2.0 APPENDIX recommendation. This ensures individual files remain license-identifiable when extracted or redistributed outside the full repository context

### Security

- `.gitignore` now covers common sensitive file patterns (`.env`, `.env.*`, `*.pem`, `*.key`, `*.p12`, `*.jks`, `*.keystore`, `*.pfx`, `key.properties`, `google-services.json`, `GoogleService-Info.plist`, `credentials.json`, `secrets.yaml`, `secrets.yml`) to prevent accidental secret commits. `.env.example` is excluded so contributors can commit environment variable templates

### Infrastructure

- Docker-backed remote deploy integration coverage now runs in CI with `REPOLENS_TEST_DOCKER=1`, exercising the `--remote` deploy path against a disposable SSH container ([#202](https://github.com/TheMorpheus407/RepoLens/issues/202)).
- GitHub Actions CI workflow: ShellCheck linting and test suite (`make check`) run on every push to `master` and pull request
- CI status badge in README
- `.github/CODEOWNERS` for automatic reviewer assignment on pull requests
- `.github/FUNDING.yml` to activate the GitHub "Sponsor" button linking to GitHub Sponsors and Patreon

## [0.1.0] - 2026-04-14

### Added

- Multi-lens code audit engine with 280 expert analysis agents
  - 192 code analysis lenses across 22 domains
  - 18 tool gate lenses for static/dynamic analysis
  - 14 product discovery lenses
  - 26 deployment/server audit lenses
  - 13 open-source readiness lenses
  - 17 content quality lenses
- Eight operational modes: audit, feature, bugfix, discover, deploy, custom, opensource, content
- Agent-agnostic design: supports claude, codex, spark/sparc, opencode
- Parallel execution with configurable concurrency (`--parallel`)
- DONE x3 streak detection for autonomous agent completion
- Resume support (`--resume <run-id>`) for interrupted runs
- Cost estimation display before run confirmation
- Deploy mode with live server investigation (read-only)
- Automatic GitHub issue creation for findings
- Domain and lens filtering (`--domain`, `--lens`)
- Maximum issue cap (`--max-issues`)
- `--hosted` Docker Compose integration for DAST scanning
- Spec file support (`--spec`) for focused analysis
- Prompt composition via template engine
- Structured logging with severity levels

_This is the first public release. Previous development was private._

### Infrastructure

- Apache 2.0 license
- Contributor Covenant 2.1 Code of Conduct
- Comprehensive README with CLI reference and shields.io badges (license, version, stars)
- AUTHORS.md with project credits and contributor listing
- CONTRIBUTING.md with lens contribution workflow, domain taxonomy, and DCO sign-off guide
- GitHub issue template for community lens proposals
- Pull request template with lens checklist and DCO sign-off reminder
- Test suite with 17 test suites
- Modular library architecture (`lib/`)

[Unreleased]: https://github.com/TheMorpheus407/RepoLens/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/TheMorpheus407/RepoLens/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/TheMorpheus407/RepoLens/releases/tag/v0.1.0
