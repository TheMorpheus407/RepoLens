# Cursor IDE handoff

`--agent cursor-ide` lets RepoLens use an existing Cursor IDE/Composer subscription session without `cursor-agent`. It does not automate Cursor's UI: Cursor has no supported unattended Composer API. RepoLens owns the queue and state; Composer services one durable filesystem request at a time.

Use `cursor` or `cursor/<model>` instead when you want a fully unattended CLI process.

## Start a run

Open the target project in Cursor, open Composer, and start RepoLens in Cursor's integrated terminal:

```bash
./repolens.sh \
  --project /absolute/path/to/project \
  --agent cursor-ide \
  --local \
  --focus injection
```

`cursor-ide` requires `--local`. Handoffs are ordered, so RepoLens ignores `--parallel` with a warning. You may also route selected local lenses to it with `--agent-override security/injection=cursor-ide`.

## Serve each handoff

RepoLens prints a line beginning with `REPOLENS_CTL` and appends the same JSON object to:

```text
logs/<run-id>/cursor-ide/events.ndjson
```

The event's `files` object names:

- `prompt`: the complete rendered RepoLens prompt and handoff instructions
- `response`: where Composer must publish its full answer
- `complete`: the atomic completion marker

Ask Composer to read `files.prompt`, execute it against the open project, and follow the footer. A lens response must contain a Method/Investigation/Analysis section, a Findings section, at least one real project-relative `path:line` citation, and a substantive explanation even when the conclusion is `DONE` or not applicable.

After writing the answer to the temporary response path, the footer gives the exact finalization command. Its essential sequence is:

```bash
mv -- response.md.tmp response.md
response_hash="$(git hash-object --no-filters response.md)"
jq -n \
  --arg request_id '<request id from request.json>' \
  --arg response_git_hash "$response_hash" \
  '{schema_version: 1, request_id: $request_id, status: "complete", response_git_hash: $response_git_hash}' \
  > complete.json.tmp
mv -- complete.json.tmp complete.json
```

Always use the absolute paths embedded in that request's prompt rather than the illustrative relative names above.

RepoLens first copies `response.md` and `complete.json` into invocation-private, mode-600 regular files while checking that neither source is replaced or changed into a symlink during the copy. It validates and consumes only those snapshots, so an edit after acceptance cannot change the bytes delivered to the pipeline. RepoLens accepts the result only when the snapshotted request id and response hash match. It also rejects binary/short responses and lens responses without the required structure and project-local citations; citations through symlinked project path components do not count as evidence. A rejection produces a `cursor_ide_response_rejected` event, removes only `complete.json`, and continues waiting so Composer can fix the same response and publish a new marker.

Keep servicing events until `kind` is `run_complete`.

## Stop and resume

During final summary rendering and result persistence, HUP, INT, and TERM still mark the invocation interrupted. RepoLens reconciles its attempt and latest-result pointer, prepares the completion JSON, then freezes the outcome immediately before publishing a single `run_complete` event. Signals received from that boundary through exit are ignored, so Composer, the attempt ledger, and the process retain the same outcome.

Cancellation stops optional finalization work at safe boundaries. The interrupted result can retain previous accounting counts and incomplete deduplication or review artifacts; resume rechecks accounting and regenerates those artifacts. A `run_complete` event with outcome `interrupted` reports the invocation's termination, without promising finished artifacts.

Pressing Ctrl-C leaves all handoff artifacts and the ordinary RepoLens run state intact. Resume with the command RepoLens prints:

```bash
./repolens.sh \
  --project /absolute/path/to/project \
  --agent cursor-ide \
  --local \
  --resume <run-id>
```

Completed lenses are skipped. An incomplete handoff receives a new random request id, so an old `complete.json` cannot accidentally complete the resumed request.

If a handoff reaches its wait limit, RepoLens emits `cursor_ide_timeout`, records the lens as resumable `agent-no-progress`, and stops instead of fabricating an empty result. Configure the wait with `REPOLENS_CURSOR_IDE_MAX_WAIT_SEC`; otherwise the resolved `REPOLENS_AGENT_TIMEOUT_CURSOR`/global/mode timeout applies.

## Protocol files

Each request lives in a unique directory below the lens log (or below `REPOLENS_CURSOR_IDE_HANDOFF_DIR` when configured):

```text
cursor-ide/
└── lens/
    └── <timestamp>-<pid>-<random>/
        ├── request.json
        ├── prompt.md
        ├── response.md
        └── complete.json
```

`request.json` is schema-versioned and records the run, phase, lens, iteration, project, request id, and exact file paths. These artifacts are forensic boundaries: do not copy completion markers between requests or edit a response after publishing its marker.
