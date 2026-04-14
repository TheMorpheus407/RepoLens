# Changelog

All notable changes to RepoLens will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/), and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- `--local` flag: write findings as local markdown files instead of creating GitHub issues — no `gh` CLI required
- `--output <path>` flag: custom output directory for local markdown files (requires `--local`, defaults to `logs/<run-id>/issues/`)

### Documentation

- "Adding a Lens" section in README now links to CONTRIBUTING.md for the full contribution workflow (fork, branch, PR process)

### Security

- `.gitignore` now covers common sensitive file patterns (`.env`, `.env.*`, `*.pem`, `*.key`, `*.p12`, `*.jks`, `*.keystore`, `*.pfx`, `key.properties`, `google-services.json`, `GoogleService-Info.plist`, `credentials.json`, `secrets.yaml`, `secrets.yml`) to prevent accidental secret commits. `.env.example` is excluded so contributors can commit environment variable templates

### Infrastructure

- GitHub Actions CI workflow: ShellCheck linting and test suite (`make check`) run on every push to `master` and pull request
- CI status badge in README

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
