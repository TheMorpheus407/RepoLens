#!/usr/bin/env python3
# Copyright 2025-2026 Bootstrap Academy
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Publish ordinary local Markdown projected from the round parser's segments.

Only receipt-owned files are replaced/retired. Staging and rollback copies are
necessary for publication, contain derived findings only, and are removed after
success or successful rollback. A private pending record permits exact-state
recovery and terminal cleanup after process death. Raw round evidence is never
changed.
"""

import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import sys
import tempfile


def digest(value):
    """Hash a complete identity without filesystem component limits."""
    return hashlib.sha256(value.encode()).hexdigest()


def checked_path(root, relative):
    """Validate a managed path without following nested symlinks."""
    if not re.fullmatch(r"generic/[a-f0-9]{32}/[0-9]+\.md", relative):
        raise ValueError("invalid Generic delivery receipt path")
    path = root / relative
    for part in (path.parent.parent, path.parent, path):
        if part.is_symlink():
            raise ValueError(f"Generic delivery refuses symlink: {part}")
    if path.exists() and not path.is_file():
        raise ValueError(f"Generic delivery target is not a file: {path}")
    return path


def publish(plan, output, receipt, run_id):
    """Publish with rollback before commit and resumable cleanup after commit."""
    root = output.resolve(strict=True)
    pending = receipt.with_name(receipt.name + ".pending")
    _recover_pending(root, receipt, pending, run_id)
    old = json.loads(receipt.read_text()) if receipt.exists() else {}
    if not isinstance(old, dict):
        raise ValueError("invalid Generic delivery receipt")
    desired, identities = {}, {}
    for row in plan:
        source_key = digest(run_id + "\0" + row["relative"])[:32]
        identity = digest(row["relative"] + "\0" + str(row["segment"]))
        relative = f"generic/{source_key}/{row['segment']:03d}.md"
        if relative in desired:
            raise ValueError("duplicate Generic delivery segment")
        # Header and source metadata share a root mapping at column zero.
        # Preserve nested indentation relative to that root and the parsed body.
        fm = row["frontmatter"]
        indents = re.findall(r"^([ \t]*)[^#\s-][^:\n]*:", fm, flags=re.M)
        root_indent = min((len(prefix) for prefix in indents), default=0)
        if root_indent:
            fm = re.sub(rf"^[ \t]{{{root_indent}}}", "", fm, flags=re.M)
        fm = re.sub(r"^(?:title|lens|generic_source_id|source_finding_path|source_finding_segment)[ \t]*:[^\n]*\n?",
                    "", fm, flags=re.M)
        header = (
            f"title: {json.dumps(row['title'], ensure_ascii=False)}\n"
            f"lens: {json.dumps(row['lens'], ensure_ascii=False)}\n"
            f"generic_source_id: {identity}\n"
            f"source_finding_path: {json.dumps(row['source'], ensure_ascii=False)}\n"
            f"source_finding_segment: {row['segment']}\n"
        )
        desired[relative] = "---\n" + header + fm.rstrip("\n") + "\n---\n" + row["body"]
        identities[relative] = identity

    # Complete admission before touching any publication. Unknown files and
    # nested symlinks are never adopted, overwritten or traversed.
    paths = {name: checked_path(root, name) for name in old.keys() | desired.keys()}
    for name, path in paths.items():
        if path.exists():
            if name not in old:
                raise ValueError(f"Generic delivery would overwrite an unowned file: {path}")
            lines = path.read_text().splitlines()
            frontmatter = lines[1:lines.index("---", 1)] if lines and lines[0] == "---" and "---" in lines[1:] else []
            # Managed projections always emit this ownership key at column zero.
            # Nested provenance markers cannot alter ownership on retry.
            markers = [line for line in frontmatter if re.match(r"^generic_source_id\s*:", line)]
            if markers != [f"generic_source_id: {old[name]}"]:
                raise ValueError(f"Generic delivery ownership changed: {path}")

    stage = Path(tempfile.mkdtemp(prefix=".generic-delivery-", dir=root))
    receipt_stage = None
    keep_stage = False
    try:
        states = {}
        for i, (name, path) in enumerate(paths.items()):
            before = _content_hash(path)
            if before is not None:
                shutil.copy2(path, stage / f"backup-{i}")
            states[name] = {"before": before,
                            "after": digest(desired[name]) if name in desired else None,
                            "backup": f"backup-{i}"}
        for i, (name, text) in enumerate(desired.items()):
            (stage / f"new-{i}").write_text(text)
        fd, temporary = tempfile.mkstemp(prefix=".generic-receipt-", dir=receipt.parent)
        receipt_stage = Path(temporary)
        with os.fdopen(fd, "w") as stream:
            json.dump(identities, stream, sort_keys=True)
            stream.write("\n")
        if receipt.exists():
            shutil.copy2(receipt, stage / "receipt-before")
        journal = {"root": str(root), "run_id": run_id, "stage": str(stage), "phase": "rollback",
                   "files": states, "receipt_stage": str(receipt_stage.resolve()),
                   "receipt_before": _content_hash(receipt),
                   "receipt_after": _content_hash(receipt_stage)}
        # An atomic, flushed intent record precedes every public mutation. It
        # binds exact pre/post bytes to this run and destination, not just an ID.
        _write_pending(pending, journal)
        try:
            for i, (name, text) in enumerate(desired.items()):
                path = checked_path(root, name)
                if path.exists() and path.read_text() == text:
                    continue
                path.parent.mkdir(parents=True, exist_ok=True)
                os.replace(stage / f"new-{i}", path)
            for name in old.keys() - desired.keys():
                checked_path(root, name).unlink(missing_ok=True)
            os.replace(receipt_stage, receipt)
            # Commit before removing backups, retaining their exact cleanup
            # pointer until deletion finishes. Recovery must never roll back a
            # terminal transaction whose backups may already be partly deleted.
            journal["phase"] = "cleanup"
            _write_pending(pending, journal)
            _cleanup_pending(stage, receipt_stage, pending)
        except BaseException:
            blocked = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGINT, signal.SIGTERM, signal.SIGHUP})
            try:
                _recover_pending(root, receipt, pending, run_id)
            except (OSError, ValueError) as rollback_error:
                keep_stage = True
                print(f"Generic delivery rollback pending in {stage}: {rollback_error}", file=sys.stderr)
            finally:
                signal.pthread_sigmask(signal.SIG_SETMASK, blocked)
            raise
    finally:
        if receipt_stage is not None:
            receipt_stage.unlink(missing_ok=True)
        # Preserve backups whenever intent survives, including a signal as
        # its atomic rename returns.
        if not keep_stage and not pending.exists() and stage.exists():
            shutil.rmtree(stage)


def _content_hash(path):
    """Fingerprint exact file bytes; absence is an explicit transaction state."""
    return hashlib.sha256(path.read_bytes()).hexdigest() if path.exists() else None


def _write_pending(path, journal):
    """Publish a flushed private intent record before touching delivered files."""
    fd, temporary = tempfile.mkstemp(prefix=".generic-intent-", dir=path.parent)
    temporary = Path(temporary)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(journal, stream, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def _restore_copy(backup, destination):
    """Restore atomically while keeping the backup for repeated crash recovery."""
    fd, temporary = tempfile.mkstemp(prefix=".generic-restore-", dir=destination.parent)
    os.close(fd)
    temporary = Path(temporary)
    try:
        shutil.copy2(backup, temporary)
        os.replace(temporary, destination)
    finally:
        temporary.unlink(missing_ok=True)


def _cleanup_pending(stage, receipt_stage, pending):
    """Remove only journal-owned stages, keeping the pointer until cleanup ends."""
    receipt_stage.unlink(missing_ok=True)
    if stage.exists():
        shutil.rmtree(stage)
    pending.unlink()


def _recover_pending(root, receipt, pending, run_id):
    """Restore interrupted publication or finish a terminal cleanup phase."""
    if pending.is_symlink():
        raise ValueError("Generic delivery refuses symlink pending record")
    if not pending.exists():
        return
    journal = json.loads(pending.read_text())
    if journal["root"] != str(root) or journal["run_id"] != run_id:
        raise ValueError("Generic delivery pending record belongs to another run/destination")
    stage = Path(journal["stage"])
    if stage.parent != root or not re.fullmatch(r"\.generic-delivery-[a-z0-9_]+", stage.name) or stage.is_symlink():
        raise ValueError("invalid Generic recovery stage")
    receipt_stage = Path(journal["receipt_stage"])
    if (receipt_stage.parent != receipt.parent.resolve()
            or not re.fullmatch(r"\.generic-receipt-[a-z0-9_]+", receipt_stage.name)
            or receipt_stage.is_symlink()):
        raise ValueError("invalid Generic recovery receipt staging path")
    phase = journal.get("phase", "rollback")  # Legacy intent records roll back.
    if phase == "cleanup":
        _cleanup_pending(stage, receipt_stage, pending)
        return
    if phase != "rollback":
        raise ValueError("invalid Generic recovery phase")
    # Complete admission before restoration: even a matching frontmatter marker
    # cannot authorize overwriting bytes edited after an interrupted publication.
    restores = []
    for name, state in journal["files"].items():
        path = checked_path(root, name)
        current = _content_hash(path)
        if current not in (state["before"], state["after"]):
            raise ValueError(f"Generic recovery ownership/content changed: {path}")
        if not re.fullmatch(r"backup-[0-9]+", state["backup"]):
            raise ValueError("invalid Generic recovery backup")
        backup = stage / state["backup"]
        if current != state["before"]:
            if state["before"] is not None and (backup.is_symlink() or _content_hash(backup) != state["before"]):
                raise ValueError(f"Generic recovery backup changed: {backup}")
            restores.append((path, backup, state["before"]))
    current_receipt = _content_hash(receipt)
    if receipt.is_symlink() or current_receipt not in (journal["receipt_before"], journal["receipt_after"]):
        raise ValueError("Generic recovery receipt changed")
    backup = stage / "receipt-before"
    restore_receipt = current_receipt != journal["receipt_before"]
    if restore_receipt and journal["receipt_before"] is not None:
        if backup.is_symlink() or _content_hash(backup) != journal["receipt_before"]:
            raise ValueError("Generic recovery receipt backup changed")
    for path, saved, before in restores:
        if before is None:
            path.unlink(missing_ok=True)
        else:
            _restore_copy(saved, path)
    if restore_receipt:
        if journal["receipt_before"] is None:
            receipt.unlink(missing_ok=True)
        else:
            _restore_copy(backup, receipt)
    # Restoration is complete. A crash during deletion now needs cleanup only,
    # even when some backups no longer exist.
    journal["phase"] = "cleanup"
    _write_pending(pending, journal)
    _cleanup_pending(stage, receipt_stage, pending)


def main():
    """Select a capped plan, count its segments or publish with retryable failure.

    Optional trailing CLI args: action (publish/count), limit, source-relative.
    The count action never invokes publication or pending-transaction recovery.
    """
    def interrupted(signum, _frame):
        """Translate ordinary cancellation into transaction rollback."""
        raise InterruptedError(f"delivery interrupted by {signal.Signals(signum).name}")

    for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(signum, interrupted)
    try:
        plan = [json.loads(line) for line in Path(sys.argv[1]).read_text().splitlines()]
        action = sys.argv[5] if len(sys.argv) > 5 else "publish"
        if len(sys.argv) > 6 and sys.argv[6]:
            limit = int(sys.argv[6])
            if limit < 0:
                raise ValueError("negative Generic finding limit")
            plan = plan[:limit]
        if action == "count":
            source = sys.argv[7] if len(sys.argv) > 7 else ""
            print(sum(1 for row in plan if not source or row["relative"] == source))
        elif action == "publish":
            publish(plan, Path(sys.argv[2]), Path(sys.argv[3]), sys.argv[4])
        else:
            raise ValueError("unknown Generic plan action")
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"Generic delivery failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
