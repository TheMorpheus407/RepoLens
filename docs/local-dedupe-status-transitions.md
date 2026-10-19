# Local dedupe status transitions

`C` requests canonical annotation; `D` requests a non-canonical duplicate mark.
A supported custom status occupies one complete line. Its exact line is retained
once in `repolens_dedupe_original_status` before assigning the sole root
`status: duplicate`. Promotion restores that line at the current root, consumes
the backup and preserves nested metadata. Status line position may change;
anchor definitions and alias nodes are refused when they would need relocation.

Every row below has a named scenario in
[`test_local_dedupe_status_transitions.sh`](../tests/test_local_dedupe_status_transitions.sh).
Repeated identical roles are fixed points. Repeated role swaps reduce to rows
T03–T05; edits between calls fall into the validation and repair rows. The table
covers status behavior for group members, plus singleton and stale-link handling.

| Test | Starting state and event order | Intended behavior |
| --- | --- | --- |
| T01 | Custom status → C → C | Keep the original status in place; no backup. |
| T02 | Custom status → C → D | Archive the exact line once; write one authoritative duplicate status. |
| T03 | Custom status → D → D | Keep the same backup and byte-identical duplicate document. |
| T04 | Custom status → D → C | Restore the exact status line and consume the backup. |
| T05 | Custom status → C → D → C → D → D → C → C, including quotes in flow plain scalars | Each swap restores or archives once; repeated roles remain identical. |
| T06 | No status → C → D → D → C | Generate no custom backup; final canonical has no status. |
| T07 | Spaced/tabbed exact managed duplicate → C or D | C removes the mark; D replaces it with one duplicate status; never archive it. |
| T08 | Archive → replace generated status with conflicting custom status → D → C | Reject both calls and retain all bytes, including the backup. |
| T09 | Archive → reintroduce the identical saved custom line → D → C | Accept the matching data and restore one original status. |
| T10 | Archive → change root indentation → D → C | D retains the backup; C refuses obsolete indentation without consuming it. |
| T11 | Archive → change indentation → refused C → repair indentation → C | Restore the original line after repair. |
| T12 | Status defines anchors (direct, tagged or in flow nodes, including compact explicit keys) → C → D → D → C | Keep canonical definitions before their aliases; refuse relocation on both D attempts; C remains safe. |
| T13 | Unsupported multiline/block/unfinished status → D → C | Reject each operation without changing the file. |
| T14 | Invalid, conflicting, multiline, managed-duplicate or anchored backup → D → C | Reject each operation without consuming or publishing saved data. |
| T15 | CR-bearing original status → C or D | Keep a canonical line in place; refuse creation of an unrestorable backup on D. |
| T16 | Status changes between scan and rewrite during D | Reject the stale rewrite and retain the newer edit. |
| T17 | Archive → publication failure during C → repaired retry C | Preserve the complete duplicate file and backup on failure; retry restores the status. |
| T18 | Grouped duplicate → canonical title changes → singleton dedupe → registry rebuild | Keep singleton Markdown annotations; invalidate the stale link and make both records review-eligible. |
| T19 | Alias status between repeated anchor definitions → C → D → D → C | Preserve its binding on C; refuse relocation on D without changing any bytes. |

Refusal removes any temporary rewrite. The public grouping pass emits its
existing per-file warning and continues with other files. It does not promise a
transaction across a whole group. Registry link validation prevents stale,
chained or self-referential links from suppressing the only actionable record.
The freshness and status-value suites cover both canonical-selection orderings,
role swaps, stale links and JSONL/CSV/TODO/HUMAN_REVIEW consumers. The retention
suite expands the validation rows across whitespace, indentation, scalar forms,
quoted/comment/plain ampersands, nested flow anchors and both requested roles.
The [alias suite](../tests/test_local_dedupe_status_aliases.sh) also covers flow
aliases, existing saved aliases, literal asterisks and real grouping with repair.

The writer detects status edits between its two reads; it does not lock against
all concurrent file writes. Incomplete frontmatter and write failures leave the
original file intact. Full configured gates remain controller-owned.
