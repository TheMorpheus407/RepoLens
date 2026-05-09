# Changelog

All notable changes to RepoLens will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/), and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Security

- `--spec` file content is now sanitized to prevent prompt injection via `<spec>`/`</spec>` tag breakout — a malicious spec file could previously close the content boundary early and inject arbitrary top-level instructions into the agent prompt ([#50](https://github.com/TheMorpheus407/RepoLens/issues/50))

### Fixed

- Agent rate-limit messages with parseable resume times now sleep within `REPOLENS_RATE_LIMIT_MAX_SLEEP`, retry the same lens once, and record `rate_limit_sleep_seconds`; unparseable, stale, too-far, or repeated rate limits still abort cleanly ([#115](https://github.com/TheMorpheus407/RepoLens/issues/115))
- Ctrl-C/TERM cleanup during parallel runs now returns after a bounded grace period, force-stopping unresponsive workers instead of waiting indefinitely. Configure the grace period with `REPOLENS_CLEANUP_GRACE` ([#114](https://github.com/TheMorpheus407/RepoLens/issues/114))
- `--hosted` service discovery now uses Docker Compose internal/container TCP ports for DAST URLs, falls back to exposed container ports when needed, and keeps published host ports as secondary context instead of pointing scanner containers at host-only NAT ports ([#83](https://github.com/TheMorpheus407/RepoLens/issues/83))
- `trademark-branding` lens (`--mode opensource`) no longer searches for hardcoded author-specific brand names when auditing third-party repositories — it now dynamically derives search terms from the audited repo's owner and name, plus any additional brand terms the agent discovers from the README or package manifest

### Changed

- Agent invocation timeouts now resolve per mode instead of using one 6000-second default: audit, feature, bugfix, discover, custom, opensource, and content default to 600 seconds; deploy defaults to 1800 seconds; `REPOLENS_AGENT_TIMEOUT` still overrides all mode-specific `REPOLENS_AGENT_TIMEOUT_<MODE>` values ([#110](https://github.com/TheMorpheus407/RepoLens/issues/110))

### Added

- `--rounds <n>` now accepts a validated cross-lens round count, honors `REPOLENS_ROUNDS` as a fallback with CLI precedence, applies per-mode caps (`audit`, `feature`, `bugfix`, and `custom` up to `10`; `deploy`, `opensource`, `content`, and `discover` locked to `1`), and shows the resolved value in `--dry-run` ([#140](https://github.com/TheMorpheus407/RepoLens/issues/140))
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
- `--output <path>` flag: custom output directory for local markdown files (requires `--local`, defaults to `logs/<run-id>/issues/`)

### Documentation

- "Adding a Lens" section in README now links to CONTRIBUTING.md for the full contribution workflow (fork, branch, PR process)
- `GOVERNANCE.md` documenting project leadership (BDFL model), decision-making, contribution acceptance criteria, conflict resolution, and governance evolution
- Governance section in README linking to `GOVERNANCE.md`

### Compliance

- All `.sh` source files now include the standard Apache 2.0 license header (copyright, license grant, and disclaimer) after the shebang line, per the Apache License 2.0 APPENDIX recommendation. This ensures individual files remain license-identifiable when extracted or redistributed outside the full repository context

### Security

- `.gitignore` now covers common sensitive file patterns (`.env`, `.env.*`, `*.pem`, `*.key`, `*.p12`, `*.jks`, `*.keystore`, `*.pfx`, `key.properties`, `google-services.json`, `GoogleService-Info.plist`, `credentials.json`, `secrets.yaml`, `secrets.yml`) to prevent accidental secret commits. `.env.example` is excluded so contributors can commit environment variable templates

### Infrastructure

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

[0.1.0]: https://github.com/TheMorpheus407/RepoLens/releases/tag/v0.1.0
