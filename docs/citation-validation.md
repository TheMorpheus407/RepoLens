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

“Citation suite” means `tests/test_branch_scope_plus_citation.sh`; “filing
governance” means `tests/test_filing_governance.sh`. The existing separate product
decisions require atomic complete lists and body-level malformed-list rejection.
Nested formatting implements those same rules and adds no new product policy.
