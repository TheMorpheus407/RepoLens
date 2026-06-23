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
- **`--local` runs** write `NNN-<slug>.md` markdown files with YAML frontmatter
  (`lib/template.sh`, LOCAL MODE OVERRIDE block, ~line 521). The builder reads
  that frontmatter and emits one normalized record per file.

Because the registry is derived, several fields below are **added or derived by
the builder** and are present in neither upstream source (notably `id`,
`confidence`, `primary_location`, `status`, `type`, `duplicate_group`,
`validation`). Do not conflate the synthesizer's per-run `cluster_id` (a
non-stable grouping handle) with the registry `id` (content-derived, stable).

**Empty run:** an empty manifest is `[]`; the corresponding registry is an
**empty `findings.jsonl`** (zero lines) plus a **header-only `findings.csv`**.

## Record schema

One JSON object per line in `findings.jsonl`, with these 12 fields:

| field | type | allowed values / shape | owner / notes |
|---|---|---|---|
| `id` | string | content-derived, **stable across runs** | algorithm owned by **#311** (`finding_id` helper in `lib/ledger.sh`). This doc records "content-derived, stable"; it does **not** define the hash. |
| `title` | string | free text | from manifest `title` / frontmatter `title`. |
| `severity` | string enum | `critical` \| `high` \| `medium` \| `low` | normalized via `severity_normalize` (`lib/core.sh`); single-source-of-truth + filename/frontmatter mismatch detector owned by **#331**. |
| `type` | string enum | `security` \| `reliability` \| `performance` \| `maintainability` \| `test-gap` \| `external-dependency` | **taxonomy owned by `finding-types` (#320)**; normalize helper #327; `type:` parse + `domain → type` back-compat #344. This doc records the field and its current enum only. |
| `domain` | string | a lens domain (`config/domains.json`) | from manifest/frontmatter `domain`. |
| `lens` | string | a lens id (`config/domains.json`) | from manifest/frontmatter `lens`. |
| `status` | string enum | `new` \| `duplicate` \| `needs-validation` \| `likely-false-positive` | default `new`; `duplicate` set by **dedupe** (#335); `needs-validation` / `likely-false-positive` set by the **validation** classifier (#334). |
| `primary_location` | string | `"file:line"` or `""` (empty) | **derived by the builder** (#314 / #319) from finding content — present in neither upstream source. This doc defines the field shape only; it does not invent an extraction algorithm. |
| `confidence` | number | float in `[0, 1]` | consumed by risk ranking (#315: `severity rank × confidence`). `low` \| `medium` \| `high` are accepted only as **optional authoring aliases** that normalize to numeric (mapping owned by triage / #315), never as the stored type. |
| `duplicate_group` | string or null | opaque group key; `null` when the finding is not part of a duplicate cluster | dedup internals owned by the **dedupe** agent (#316 canonical selection, #322 matching, #335 marking, #353 thresholds, #343 over `--local`). |
| `markdown_path` | string | path to the `NNN-<slug>.md` file when one exists; `""` (or absent) otherwise | present for `--local` findings; bugreport-only findings may have none. Consumed by triage artifacts and html-report. |
| `validation` | object | opaque object slot (may be `{}`) | **contents owned by the `validation-hints` agent**: #317 (block contract), #332 (parser → structured object), #345 (proof-anchor validator), #334 (status classifier). This doc records only that the key exists and is an object. |

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
- `type` — current enum: `security` \| `reliability` \| `performance` \|
  `maintainability` \| `test-gap` \| `external-dependency`. The taxonomy itself
  is owned by `finding-types` (#320); this doc only records that the field
  exists and its current values.
- `domain` / `lens` — the lens domain and lens id (both from
  `config/domains.json`).
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
| schema validator + test | **#329** |

## `findings.csv`

`findings.csv` is a flat projection of the **same** records: one row per finding,
one column per scalar field. Object/array fields (e.g. `validation`) are
serialized or omitted in the CSV; the JSONL remains the authoritative,
fully-structured form. An empty run produces a **header-only** `findings.csv`
(column headers, zero data rows), matching the empty (zero-line) `findings.jsonl`.
