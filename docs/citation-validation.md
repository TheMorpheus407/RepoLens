# Citation validation behavior

The shared extractor masks excluded spans without joining surrounding bytes,
preserves complete backtick citations as opaque list members, and checks each
whitespace token as an atomic comma/semicolon list. It tries member formatting
first, then retries after each outer formatting layer. Only a complete valid
interpretation supersedes a malformed interpretation; failed attempts retain
their errors. Supporting references undergo scope and live-source checks even
when another anchor is valid.

The tables cover the observable orderings of these operations. Both separators
and both list-member orders have the same result. No real models or forge writes
run in the tests. Scope acceptance and live-source acceptance are separate:
an existing file can be out of scope, and an in-scope line can be nonexistent.

| Row | Input or ordering | Intended behavior | Targeted test |
| --- | --- | --- | --- |
| B1 | Supported bare path, including mid-path `+`, then scope/live checks | Preserve the complete path; verify its own scope and lines | citation suite Cases 1–4, 6, 8–9 |
| B2 | Unsupported bare character or incomplete prefix before a separator | Never extract a suffix twin; reject a recognized malformed list | citation suite Cases 5, 7, 10–11, 13 |
| B3 | Formatting around a single citation, then verification | Preserve the citation and reject invalid supporting files/lines | citation suite Case 12 |
| B4 | Whole-list or individual-member formatting | Accept only complete members; preserve all supporting paths | citation suite Cases 13, 17 |
| B5 | Quoted member before/after bare member | Preserve both citations, including quoted spaces and separators | citation suite Cases 14–15 |
| B6 | Excluded span or marker-like input before/between path bytes | Never join bytes or impersonate a quoted member | citation suite Cases 14–15 |
| B7 | Recognized malformed list before/after another valid anchor | Extraction fails; both validators reject the entire body | citation suite Cases 16–17; filing governance malformed-list cases |
| B8 | A failed normalization follows a recognized malformed interpretation | Retain the error; a wholly valid alternative can still succeed | citation suite Case 17 |
| N1 | Outer formatting followed by member formatting, both member orders/separators | Recheck each layer; retain the missing supporting citation | citation suite Case 18, full 10 × 10 wrapper matrix |
| N2 | Outer quotes with emphasized valid members | Extract and verify the valid citation | citation suite Case 18 N2 |
| N3 | Valid anchor first, then quoted/emphasized missing supporting member first | Extract both; scope and live checks reject | citation suite Case 18 N3 |
| N4 | Supporting member last, valid separate anchor last | Same rejection as N3 | citation suite Case 18 N4 |
| N5 | Outer angles, member underscores, invalid supporting line | Preserve the supporting citation; live checks reject its line | citation suite Case 18 N5 |
| N6 | Parentheses, quotes, then emphasis around members of a valid list | Preserve both; live checks pass and narrower scope rejects | citation suite Case 18 N6 |
| N7 | Valid anchor, then nested malformed citation/prose list | Extraction and both validators fail | citation suite Case 18 N7 |
| N8 | Nested prose/citation list before a valid anchor | Same rejection as N7 | citation suite Case 18 N8 |
| N9 | Quoted citation marker inside nested malformed list | Retain the malformed-list error | citation suite Case 18 N9 |
| N10 | Nested mixed quoted/bare complete list with missing supporting file | Extract both; verify and reject the missing file | citation suite Case 18 N10 |
| N11 | Nested incomplete path prefix before separator and suffix twin | Extraction fails; never validate the twin | citation suite Case 18 N11 |
| N12 | Nested ordinary prose list alongside a valid anchor | Ignore prose; scope and live checks pass | citation suite Case 18 N12 |
| N13 | Nested standalone unsupported bare token alongside a valid anchor | Ignore unsupported token whole; verify the valid anchor | citation suite Case 18 N13 |
| N14 | Excluded backtick snippet inside nested bare path | Never fabricate a path; existing snippet validation still applies | citation suite Case 18 N14 |
| N15 | Nested supporting path fails scope, then directory filtering | Preserve exact evidence and reason naming that path | citation suite Case 18 N15 |
| N16 | Nested invalid evidence as issue body | Record failure; zero issue creates | filing governance nested invalid-body cases |
| N17 | Valid parent checked before nested invalid action evidence | Record action failure; zero comment creates | filing governance nested invalid-body cases |
| N18 | Invalid nested parent checked before valid action evidence | Parent failure rejects action; zero comment creates | filing governance N18 |
| N19 | Valid nested evidence as issue or action body | Publish once through mocked structured readback | filing governance N19 |
| N20 | Valid independent parent, action containing unsupported file-like citations (including conventional root files), alone or alongside valid bare/quoted anchors | Reject the action with a diagnostic and zero comment POSTs | filing governance unsupported-action cases |
| N21 | Valid parent, citation-free action prose, opaque URL (including commas/semicolons), comma-terminated timestamp or backtick sample (including multiline fences) with no recognized source citation | Preserve ordinary comment publication | filing governance citation-free action cases |
| N22 | Action citation extraction/classification cannot complete | Return retry status; preserve pending actions and saved receipts; zero comment creates until repaired | filing governance citation probe failure; scope retry-caller cross-scan cases |
| N23 | Valid parent, recognized source citation inside a multiline fence | Apply live-source and branch-scope checks; reject missing files, nonexistent lines or out-of-scope paths with zero comment POSTs | filing governance fenced-citation cases |

The action guard classifies every body and requires nonempty strict extraction
for each bare candidate. Quoted members stay opaque during classification;
only the original body supplies evidence to scope and live-source validation.
This action publication check is stricter than extraction alone (N13).
Action classification retains scanner failures through its output filter even
when a sourceable caller disables `pipefail`; partial output cannot authorize a
comment POST. Operational failures in action extraction, classification, output
filtering or candidate input setup return retry status 2 without a permanent
rejection or reservation of a fresh action for POST. Saved receipts, payloads
and their attempt guards remain intact. A repaired retry publishes a fresh
action once and reattests saved actions without another POST; malformed or
unsupported citations still receive permanent rejection.
Backtick masking in the classifier spans the complete body, including multiline
fenced samples. The shared extractor still scans the original body: recognized
bare or quoted source citations, including those inside fences, undergo
live-source and branch-scope checks. For example, a fenced `src/$route/a.sh:1`
sample remains publishable, while a fenced `src/missing.sh:1` fails if that file
does not exist.
Commas and semicolons within URL tokens remain URL bytes. A following bare
source reference requires whitespace and is checked independently.
URL masking accepts schemes beginning with a letter, followed by letters,
digits, `+`, `.` or `-`, and then `://`, including uppercase and custom schemes.
URL bytes cannot supply source evidence or a snippet boundary. The dedicated
`tests/test_opaque_url_citations.sh` suite checks extraction, live verification,
mocked cross-link publication, and snippet binding before and after URL tokens.

Inline citation spans use complete matching backtick runs on the same line,
including double or longer delimiters. Shorter runs inside a span are literal
text; ticks from distinct spans cannot form a new citation. Noncitation spans
remain opaque and never join surrounding path fragments. Multiline fences
leave each content line available for citation extraction, preserving N23.
The citation suite tests matching runs of one through four ticks, supporting
references, and shorter literal ticks; filing governance also tests missing
and invalid-line double-backtick action references with zero comment POSTs.

“Citation suite” means `tests/test_branch_scope_plus_citation.sh`; “filing
governance” means `tests/test_filing_governance.sh`. The existing separate product
decisions require atomic complete lists and body-level malformed-list rejection.
Nested formatting implements those same rules and adds no new product policy.

Optional inline snippets bind to the preceding citation on the same logical line, before the next source reference. Repeated references each retain their own snippet check. The first citation also retains the snippet-before-location form when it has no following snippet. These checks apply to issue and cross-link bodies alike (filing governance same-line snippet cases).

Snippet boundaries come from the same parsed citation occurrences used for
scope and live-source checks, including emphasis and mixed bare/quoted lists.
Citation-like text within a snippet or URL never supplies a boundary. Complete
matching backtick runs delimit snippets too, retaining shorter literal ticks as
part of the evidence. Repeated quoted references without snippets do not turn
intervening prose into evidence. Location-shaped URL/timestamp spans retain
their existing exclusion from optional snippet checks. The filing governance
parsed-snippet cases exercise issue and cross-link publication with mocked
forge readback, including rejection before any POST.

Live-source verification rejects unsuccessful line-count, final-byte and
snippet-context reads, including reads that return partial output. Empty files
have no line 1; nonempty final lines count even without a newline, including
lines ending in spaces or tabs. `tests/test_citation_read_errors.sh` covers these
boundaries and confirms that a failed final-byte read prevents publication and
a success receipt.

Branch-scope verification returns 1 only for semantic rejection (malformed or
missing citations, or a path outside the scope) and 2 when verification cannot
complete. Scanner, sorting, membership-check and shell input setup failures
remain operational failures even when their command status is 1. Directory
filtering leaves findings pending; synthesis preserves saved publications and
the complete candidate for a repaired retry. The scope retry-caller suite
injects status-1 failures and real Bash here-string failures and checks both
publication preservation and successful recovery.

Mandatory live-source revalidation preserves scanner execution status too,
including the later scan that binds snippets. An unavailable extraction returns
2 through the issue governor and both parent/action cross-link guards. These
paths retain pending work and saved receipts without a new terminal failure;
repair permits publication once or reattests a saved success without another
POST. Malformed citations and source-evidence mismatches retain status 1.
Building the action's live-verification JSON is checked separately: a failed
serializer returns 2 before verification, even if it emitted valid JSON first.
`tests/test_branch_scope_retry_callers.sh` injects scanner status 1 specifically
inside these live guards, with empty/partial output and caller `pipefail`
disabled for comments, covering fresh work and saved receipts. It also covers
failed action-evidence serialization with empty or complete valid output.

Failure to set up the outer live-verification loop's captured citation-list input
also returns retry status 2 with `could not read citations`. The dedicated
`tests/test_filing_citation_input_failure.sh` suite induces a real Bash temporary
file failure after extraction, then checks repaired semantic rejection and valid
evidence. The separate inner snippet-input loop is outside this guarantee.
