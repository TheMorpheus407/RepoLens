# tests/baselines/

Captured-output baselines for `tests/test_rounds_default_no_regression.sh`.

## What's here

One file per default-rounds=1 mode:

```
audit.txt   feature.txt   bugfix.txt   custom.txt
discover.txt   deploy.txt   opensource.txt   content.txt
```

Each file is the **normalized** stdout+stderr of:

```
repolens.sh --project <empty git repo> --agent codex --mode <mode> \
            --focus <mode-default> --local --output <tmp> --dry-run --yes
```

after stripping inherently variable fields (run IDs, timestamps, absolute
paths — see normalization rules in the test file header).

The test pins the current epoch used for pricing freshness to the pricing
file's `updated_at` date. Pricing warnings therefore cannot appear solely
because the calendar advances; real date parsing and formatted timestamps
remain available. `test_pricing_freshness.sh` separately verifies the warning
and its 60/61-day boundary using the real clock.

`bugreport` is intentionally absent: its default `--rounds` is 3, not 1,
so it falls outside the single-pass backward-compat contract.

## Why

Locks in the backward-compat guarantee of the multi-round feature (issue
#177): invoking repolens without `--rounds` must produce byte-identical
output to today's single-pass run. If the multi-round driver accidentally
leaks `ROUND_INDEX=`, an extra `[round 2/...]` banner, or a meta-orchestrator
dispatch line into the default-path output, the diff in
`test_rounds_default_no_regression.sh` fails CI loudly.

## When to update

A baseline only needs to be refreshed when an **intentional** UX change
shifts the dry-run output (a reworded log line, a new cost-banner field,
an added lens). For unintentional drift, fix the code — not the baseline.

To regenerate:

```
bash tests/test_rounds_default_no_regression.sh --update-baseline
```

Reviewers must opt-in to baseline updates via PR review.

## Normalization is the failure surface

If a baseline diff flags a field that varies per run but you don't see in
the normalization regex set at the top of the test, add a regex there — do
not patch the baseline to embed the variable value.
