# Filing proposal reference

Remote filing is performed by the deterministic governor in `lib/filing.sh`.
This file is a schema reference, not an executable agent prompt. No filing
model receives forge credentials, provider commands, or sentinel ownership.

A synthesizer proposes a manifest entry containing `cluster_id`, `title`,
`body`, `proposed_labels`, `source_finding_paths`, and
`dedup_against_existing`. These fields are untrusted data. The governor:

1. Validates the entry and reserves the cluster atomically.
2. Rechecks every `file:line` citation against local code, rejecting missing
   files, out-of-range lines, escaped paths, symlinks, and mismatched snippets.
3. Enforces the changed-file allowlist in branch-review mode.
4. Requires a fresh structured issue listing and rejects exact-title or
   explicitly identified open duplicates. Query failures stop publication.
5. Saves the exact request and records an attempt before a single create call.
6. Reads the issue back from the configured repository and compares its URL,
   number, title, complete body, state, and labels before writing `.url`.

The governor writes `.failed` on rejected evidence or provider failures.
An `.attempted` record is permanent until an operator reconciles remote state;
removing `.failed` alone never repeats a possibly successful create request.
The same action and readback checks apply to cross-link comments and reopen
suggestions. Unsupported structured provider operations fail closed.

The gate checks citation integrity and action execution. It does not prove a
finding's semantic correctness or sandbox earlier investigation agents.
