# Finding Registry Schema (`findings.jsonl` + `findings.csv`)

## Overview

RepoLens writes a canonical finding registry at `logs/<run-id>/final/findings.jsonl`
— one JSON object per finding per line (JSON Lines). `findings.csv` is a flat,
column-per-field projection of the **same** records (one row per finding) for
spreadsheet and `grep` consumption.

The registry is a **derived, normalized projection — not a new source of truth.**
It is built from the existing finding outputs; it does not replace them.

**Upstream sources (the registry is derived from these):**

- **Multi-round bugreport runs** synthesize `logs/<run-id>/final/manifest.json`
  (a JSON array of cluster objects; see `lib/synthesize.sh`, `run_synthesizer`
  and the `validate_manifest` schema block). `manifest.json` is the upstream
  source; the registry builder reads it and writes one normalized record per
  finding.
- **`--local` multi-round bugreport runs with default output** use the synthesized
  manifest alone after successful synthesis in the current attempt. Raw Markdown
  cannot reintroduce findings excluded by verification or synthesis. Manifest ingestion preserves duplicate
  status and `also_reported_by` provenance, and links `markdown_path` to the
  absolute path of the first existing file in `source_finding_paths` without
  reading source contents. Relative contributor Markdown links are also made
  absolute so they resolve from `DUPLICATES.md` under `final/`. The original
  manifest and `source_finding_paths` remain unchanged.
  Relative source and contributor paths resolve from `--project`, where the
  synthesizer runs, even when RepoLens is launched from another directory.
  Standalone library callers without `PROJECT_PATH` use their current directory.
- **Other `--local` runs** write `NNN-<slug>.md` markdown files with YAML frontmatter
  (`lib/template.sh`, LOCAL MODE OVERRIDE block, ~line 521). The builder reads
  that frontmatter and emits one normalized record per file. It preserves local
  dedupe's `status: duplicate` marks only when their direct relative
  `duplicate_of` link identifies a different parsed record with a raw
  non-duplicate status in the same current deterministic group. The builder
  reuses current similarity thresholds and transitive connected components.
  Missing, filtered, invalid or now-unrelated canonicals (including after title
  edits or threshold changes), self-links, chains and cycles restore records to
  `new` in the registry. Markdown evidence remains unchanged. Only validated
  links reconstruct `also_reported_by` contributors on canonical records;
  referenced paths are never opened. Simple `duplicate_of` paths stay plain;
  paths with quotes, whitespace, backslashes or line breaks use JSON-compatible
  YAML strings, decoded before matching so filename bytes are preserved.
  Trailing line feeds remain part of the decoded path; an unindexed target
  such as `"a.md\n"` cannot validate a link to `a.md`.

For explicit-local bugreports, eligible ordinary destination files reserve the
shared `--max-issues` capacity, including files from earlier runs and files
written before an interrupted lens saved its summary. Generic evidence and
projections are excluded from ordinary usage. Summary
`totals.ordinary_issues_created` stores this inventory snapshot;
`totals.governed_issues_created` stores the admitted Generic segment count.
Per-lens `issues_created` values remain execution deltas. The run total is the
sum of the two snapshots, so replaying a lens or reconciliation does not add
existing findings again. Existing ordinary files above the cap are preserved.

For Generic investigators with `bugreport --local --output`, finalization converts
private multi-finding evidence to one ordinary Markdown file per segment in the
requested output. Each projection records `source_finding_path`,
`source_finding_segment` and `generic_source_id`; its `lens` comes from `lens_id`
and its title comes from a supplied title or the hypothesis. The registry uses
that source/segment identity alongside title/domain/lens, preserving distinct
records when titles match. Private evidence, digests and verifier IDs are unchanged.
Only findings with valid severity meeting `--min-severity` and a round-dispatched
Generic identity are delivered. Round layout metadata, saved dispatch and completion
receipts establish that identity; source files cannot grant themselves trust.
Overlapping output is supported: generated projections are excluded from private
digest/verifier/synthesizer discovery, and explicit delivery excludes private raw
Generic evidence from local dedupe/indexing. Default builder source selection is
unchanged. Only generated, receipt-owned projection paths with matching leading
frontmatter identities may be replaced or retired. A run/destination-bound pending
publication record saves exact before/after content hashes and rollback copies.
After process termination, resume restores that interrupted transaction before
retrying saved evidence. Recovery refuses changed content or nested symlinks,
preserving the pending record and backups for repair. This covers process crashes;
power-loss durability is not guaranteed.
Failed requested Generic delivery keeps the previous registry and reports and
fails the invocation with a nonzero exit and `generic-delivery-failed` reason.
The terminal status, attempt history and completion event reflect that failure;
accepted interruption signals keep precedence. Repair the destination and use
the printed resume hint to retry saved evidence without rerunning completed
investigations. Successful delivery clears its saved failure reason. Optional
report rendering remains non-fatal.

An explicit `--output` uses a user-selected shared Markdown directory, which may
overlap the round-only verifier/synthesizer inventory. It retains direct Markdown
indexing, even when round synthesis writes an empty manifest; these findings have
not been checked by that cross-round verifier. Default local multi-round bugreport
finalization preserves the previous registry and reports if rounds, verifier
preparation or required synthesis fails, including when an older manifest remains.
It also preserves them when no required manifest exists. Fresh failed runs leave
these reports unpublished. A successful empty synthesis rebuilds the empty index
and removes stale action reports. Other default local modes retain direct
Markdown indexing when no manifest exists.

The registry collapses identical IDs to one record, preferring a non-duplicate
record over a marked duplicate while preserving the ID's first position.
Otherwise the first record wins (manifest before local). Colliding non-duplicate
records merge their `also_reported_by` contributor lists, deduplicated by domain,
lens and markdown path, while retaining the winner's other fields. The human-review
digest excludes marked duplicates from review buckets and accounts for them separately;
the registry retains those records when their IDs differ from the canonical ID.

Because the registry is derived, several fields below are **added or derived by
the builder** and are present in neither upstream source (notably `id`,
`confidence`, `primary_location`, `type`, `duplicate_group`, `validation`).
`status` also preserves upstream duplicate marks. Do not conflate the synthesizer's per-run `cluster_id` (a
non-stable grouping handle) with the registry `id` (content-derived, stable).

**Empty run:** an authoritative empty manifest is `[]`; the corresponding registry
is an **empty `findings.jsonl`** (zero lines) plus a **header-only `findings.csv`**.
After a successful empty local rebuild, finalization removes stale `TODO.md`,
`SUMMARY.md`, `NEEDS_REVIEW.md` and `DUPLICATES.md`. Failed or interrupted rebuilds
retain existing reports. Failed traversal or an unreadable local finding also
preserves the prior registry, CSV and reports. This also applies when enumeration
succeeds but the staged file list disappears, becomes unreadable or is truncated
before ingestion finishes. Registry assembly checks the exit status of `cat` when
appending staged manifest or local records. A nonzero status, including after
partial output, discards the candidate before replacing JSONL or CSV. Concurrent
truncation that leaves valid JSONL and a successful `cat` exit is not detected.
A repaired retry rebuilds the artifacts from the current findings. Branch-review
scope filtering aborts on a failed read without quarantining that source. Readable malformed
frontmatter still produces a warning and is skipped. Each local finding is
parsed from one complete temporary snapshot created with owner-only permissions;
normal success and failure paths remove the snapshot. Raw Markdown evidence is
retained in every case.

Triage and human-review Markdown reports percent-encode finding and contributor
link destinations while preserving directory separators. Labels escape Markdown
and HTML syntax and replace carriage returns and newlines with spaces; the
encoded destination retains the original path bytes.

Standalone local registry building replaces the exact requested file path
atomically. Directory and directory-symlink destinations fail without changing
their contents, and failed publication removes staged registry files. Relative
sourcing of `lib/ledger.sh` remains valid after the caller changes directories.

Triage reports replace their requested file paths atomically. A directory or
symlink to a directory at a report path causes generation to fail, preserving
the directory contents and cleaning staged Markdown. Promotion never puts a
staged report inside a directory, even if another writer creates that directory
during generation. Finalization warns and continues when a report cannot be
written; the duplicate report is linked only after successful generation.

## Record schema

One JSON object per line in `findings.jsonl`, with these 13 fields:

| field | type | allowed values / shape | owner / notes |
|---|---|---|---|
| `id` | string | content-derived, **stable across runs** | algorithm owned by **#311** (`finding_id` helper in `lib/ledger.sh`). This doc records "content-derived, stable"; it does **not** define the hash. |
| `title` | string | free text | from manifest `title` / frontmatter `title`. |
| `severity` | string enum | `critical` \| `high` \| `medium` \| `low` | normalized via `severity_normalize` (`lib/core.sh`); single-source-of-truth + filename/frontmatter mismatch detector owned by **#331**. |
| `type` | string enum | `security-vulnerability` \| `reliability-bug` \| `performance-risk` \| `maintainability` \| `test-gap` \| `external-dependency` | **taxonomy owned by `finding-types` (#320)**; normalize helper #327. Resolved per finding (#344): an explicit valid frontmatter `type:` wins, else inferred from `domain`. Always populated — never `null`. The validator also tolerates the legacy short forms (`security` / `reliability` / `performance`) for back-compat. |
| `domain` | string | a lens domain (`config/domains.json`) | from manifest/frontmatter `domain`. |
| `lens` | string | a lens id (`config/domains.json`) | from manifest/frontmatter `lens`. |
| `status` | string enum | `new` \| `duplicate` \| `needs-validation` \| `likely-false-positive` | default `new`; `duplicate` set by **dedupe** (#335); `needs-validation` / `likely-false-positive` set by the **validation** classifier (#334). |
| `primary_location` | string | `"file:line"` or `""` (empty) | **derived by the builder** (#314 / #319) from finding content — present in neither upstream source. This doc defines the field shape only; it does not invent an extraction algorithm. |
| `confidence` | number | float in `[0, 1]` | consumed by risk ranking (#315: `severity rank × confidence`). `low` \| `medium` \| `high` are accepted only as **optional authoring aliases** that normalize to numeric (mapping owned by triage / #315), never as the stored type. |
| `duplicate_group` | string or null | opaque group key; `null` when the finding is not part of a duplicate cluster | dedup internals owned by the **dedupe** agent (#316 canonical selection, #322 matching, #335 marking, #353 thresholds, #343 over `--local`). |
| `markdown_path` | string or null | path to the source Markdown when available; `null` otherwise (legacy inputs may use `""` or omit it) | populated by local ingestion or from the first existing manifest source file. Consumed by triage artifacts and html-report. |
| `validation` | object | opaque object slot (may be `{}`) | **contents owned by the `validation-hints` agent**: #317 (block contract), #332 (parser → structured object), #345 (proof-anchor validator), #334 (status classifier). This doc records only that the key exists and is an object. |
| `complexity` | number or null | integer `1`–`5`, or `null` | **optional routing tier authored by the audit model (#385)**. Estimates the implementation *effort* to fix the finding — orthogonal to `severity`. Absent, non-integer, or out-of-range (`0`, `6`, …) normalizes to `null` (rejected, never clamped). Consumed by downstream semantic model routing. |

### Field details

- `id` — content-derived and **stable across runs**: the same finding produces
  the same `id` in any run. The hash algorithm is owned by **#311**; it is not
  defined here.
- `title` — free-text finding title, from the manifest `title` or the local
  markdown `title` frontmatter.
- `severity` — the canonical lowercase enum produced by `severity_normalize`
  (`lib/core.sh`). Manifest severities are already normalized before promotion
  (`_synthesize_normalize_manifest_severities` in `lib/synthesize.sh`); local
  frontmatter severities are normalized by the ingest builder (#319).
- `type` — one of the six canonical taxonomy ids: `security-vulnerability` \|
  `reliability-bug` \| `performance-risk` \| `maintainability` \| `test-gap` \|
  `external-dependency`. Resolved per finding (#344): an explicit, valid `type:`
  in the finding's frontmatter wins (normalized via `finding_type_normalize`,
  `lib/core.sh`); when it is missing or unrecognized the type is inferred from
  the finding's `domain` (the `domain → type` map in `domain_default_finding_type`,
  e.g. `security` / `llm-security` → `security-vulnerability`, `testing` →
  `test-gap`, `performance` → `performance-risk`, `error-handling` /
  `concurrency` / `database` → `reliability-bug`, everything unmapped →
  `maintainability`). The field is therefore always populated, never `null`. The
  taxonomy itself is owned by `finding-types` (#320). For back-compat the schema
  validator additionally accepts the legacy short forms `security`, `reliability`,
  and `performance`.
- `domain` / `lens` — the lens domain and lens id (both from
  `config/domains.json`). Missing local frontmatter values fall back to the
  first two directory components beneath the output root, including when
  findings are nested further in dispatch directories. Trailing slashes on
  that root do not change the metadata or finding IDs. A symlinked output root
  is traversed; symlinks inside the tree are not followed. Flat findings without
  these frontmatter fields retain empty values.
- `status` — `new` \| `duplicate` \| `needs-validation` \|
  `likely-false-positive`; defaults to `new`.
- `primary_location` — `"file:line"` or empty string; derived by the builder.
- `confidence` — float in `[0, 1]`.
- `duplicate_group` — string group key or `null`; dedup internals owned by the
  `dedupe` agent.
- `validation` — an object slot; its internals are owned by the
  `validation-hints` agent.
- `markdown_path` — path to the human-readable `NNN-<slug>.md` file when one
  exists.
- `complexity` — optional integer `1`–`5` estimating the implementation
  **effort** to fix the finding (`1` Trivial, `2` Easy, `3` Medium, `4` High,
  `5` Critical/Complex), or `null` when the model gave no valid estimate. It is
  **orthogonal to `severity`**: a `critical` finding can be `complexity` 1 (a
  one-line fix) and a `low` finding can be `complexity` 4 (a cross-cutting
  refactor). Authored by the audit model, never computed by RepoLens; an
  out-of-range value is rejected to `null` rather than clamped. Downstream
  automation routes each fix to a cheap or flagship model tier by this value
  (e.g. `gh issue list --label repolens/complexity/1`).

## Ownership map

Each field / concern and the sibling issue (or agent) that owns it. This doc
(#309) is the first in the dependency chain; every builder and consumer below
references this schema. Each deferred enum is **current as of #309**; the
authoritative source is the named owner.

| concern / field | owning sibling(s) / agent |
|---|---|
| `id` (stable content-derived hash) | **#311** — `finding_id` helper in `lib/ledger.sh` |
| `type` taxonomy (the enum itself) | **`finding-types` (#320)** — closed taxonomy in `config/finding-types.json`; #327 (`finding_type_normalize`), #344 (parse `type:` + back-compat), #339 (required `type:` in LOCAL frontmatter), #331 (mismatch detector) |
| `severity` normalization / single source | `severity_normalize` (`lib/core.sh`, this repo); #331 mismatch detector |
| `status` classification | **#334** (`validation` classifier); **#335** (`dedupe` sets `status=duplicate`) |
| `duplicate_group` + dedup semantics | **`dedupe` agent** — #316 (canonical selection), #322 (matching), #335 (marking), #353 (thresholds), #343 (over `--local`), #328 (`also_reported_by[]`) |
| `validation` object internals | **`validation-hints` agent** — #332 (parser), #317 (block contract), #345 (proof-anchor validator), #334 (status classifier) |
| `confidence` consumer (risk rank) | **#315** — `severity rank × confidence` helper |
| builder: manifest clusters → `findings.jsonl` | **#314** |
| builder: `--local` md frontmatter → `findings.jsonl` | **#319** |
| `findings.csv` flat projection | **#324** |
| `complexity` estimate + `repolens/complexity/<n>` routing labels | **#385** |
| schema validator + test | **#329** |

## `findings.csv`

`findings.csv` is a flat projection of the **same** records: a fixed header row
followed by one row per finding, preserving `findings.jsonl` line order. It is a
convenience view for spreadsheets and `grep`; `findings.jsonl` stays the
authoritative, full-fidelity registry.

The columns are exactly, in this order:

```
id,title,severity,type,domain,lens,status,primary_location,confidence,duplicate_group,markdown_path,complexity
```

`complexity` is **appended at the end** so every pre-existing column index stays
stable for consumers that read the CSV positionally.

The `validation` object (and any array field, e.g. `source_finding_paths`) is
**omitted** — it does not flatten to a single cell; read it from `findings.jsonl`
when needed. CSV quoting is RFC-4180-safe: a value containing a comma, a double
quote, or a newline (e.g. a title) is quoted and inner quotes are doubled. A JSON
`null` or absent field renders as an empty cell; numbers (e.g. `confidence` and
`complexity`) are unquoted. An empty run produces a **header-only** `findings.csv` (column headers,
zero data rows), matching the empty (zero-line) `findings.jsonl`.
