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
success or successful rollback. Raw round evidence is never changed.
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
    """Stage and publish a complete delivery, restoring files and receipt on failure."""
    root = output.resolve(strict=True)
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
        # Scalar replacements precede the retained original metadata. The body
        # and every remaining metadata line retain the raw segment's bytes.
        fm = re.sub(r"^(?:title|lens|generic_source_id|source_finding_path|source_finding_segment):[^\n]*\n?",
                    "", row["frontmatter"], flags=re.M)
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
            markers = [line for line in frontmatter if re.match(r"^\s*generic_source_id\s*:", line)]
            if markers != [f"generic_source_id: {old[name]}"]:
                raise ValueError(f"Generic delivery ownership changed: {path}")

    stage = Path(tempfile.mkdtemp(prefix=".generic-delivery-", dir=root))
    receipt_stage = receipt_backup = None
    receipt_attempted = False
    changed, backups = [], {}
    keep_stage = False
    try:
        for i, (name, path) in enumerate(paths.items()):
            if path.exists():
                backup = stage / f"backup-{i}"
                shutil.copy2(path, backup)
                backups[name] = backup
        for i, (name, text) in enumerate(desired.items()):
            (stage / f"new-{i}").write_text(text)
        fd, temporary = tempfile.mkstemp(prefix=".generic-receipt-", dir=receipt.parent)
        receipt_stage = Path(temporary)
        with os.fdopen(fd, "w") as stream:
            json.dump(identities, stream, sort_keys=True)
            stream.write("\n")
        if receipt.exists():
            fd, temporary = tempfile.mkstemp(prefix=".generic-receipt-backup-", dir=receipt.parent)
            os.close(fd)
            receipt_backup = Path(temporary)
            shutil.copy2(receipt, receipt_backup)
        try:
            for i, (name, text) in enumerate(desired.items()):
                path = checked_path(root, name)
                if path.exists() and path.read_text() == text:
                    continue
                path.parent.mkdir(parents=True, exist_ok=True)
                # Track intent before a syscall: cancellation may arrive after
                # the mutation succeeds but before the next Python instruction.
                changed.append(name)
                os.replace(stage / f"new-{i}", path)
            for name in old.keys() - desired.keys():
                path = checked_path(root, name)
                if path.exists():
                    changed.append(name)
                    path.unlink()
            receipt_attempted = True
            os.replace(receipt_stage, receipt)
        except BaseException:
            # Drain cancellation only after restoring the transaction; a second
            # signal must not interrupt rollback and delete its backups.
            blocked = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGINT, signal.SIGTERM, signal.SIGHUP})
            try:
                _rollback(root, changed, backups)
                if receipt_attempted:
                    if receipt_backup is None:
                        receipt.unlink(missing_ok=True)
                    else:
                        os.replace(receipt_backup, receipt)
            except (OSError, ValueError) as rollback_error:
                keep_stage = True
                print(f"Generic delivery rollback pending in {stage}: {rollback_error}", file=sys.stderr)
            finally:
                signal.pthread_sigmask(signal.SIG_SETMASK, blocked)
            raise
    finally:
        if receipt_stage is not None:
            receipt_stage.unlink(missing_ok=True)
        if not keep_stage:
            if receipt_backup is not None:
                receipt_backup.unlink(missing_ok=True)
            shutil.rmtree(stage)


def _rollback(root, changed, backups):
    """Restore every attempted mutation, including a syscall interrupted on return."""
    errors = []
    for name in reversed(changed):
        try:
            path = checked_path(root, name)
            if name in backups:
                os.replace(backups[name], path)
            else:
                path.unlink(missing_ok=True)
        except (OSError, ValueError) as error:
            errors.append(str(error))
    if errors:
        raise OSError("; ".join(errors))


def main():
    """Load the staged plan and report retryable publication failures."""
    def interrupted(signum, _frame):
        """Translate ordinary cancellation into transaction rollback."""
        raise InterruptedError(f"delivery interrupted by {signal.Signals(signum).name}")

    for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(signum, interrupted)
    try:
        plan = [json.loads(line) for line in Path(sys.argv[1]).read_text().splitlines()]
        publish(plan, Path(sys.argv[2]), Path(sys.argv[3]), sys.argv[4])
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"Generic delivery failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
