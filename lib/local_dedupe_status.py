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

"""Preserve displaced local status scalars before the dedupe Markdown rewrite."""

import json
import re
import sys
from pathlib import Path


ARCHIVE = "repolens_dedupe_original_status"
KEY = re.compile(r"^(\s*)([^#\s-][^:]*):")
STATUS = re.compile(r"^status\s*:")
MANAGED = re.compile(r"^status\s*:\s*(duplicate|\"duplicate\"|'duplicate')(\s+#.*)?\s*$")
QUOTED = re.compile(r"""(?:"(?:[^"\\]|\\.)*"|'(?:[^']|'')*')(?:\s+#.*)?\s*""")


def preserve_status(text, mode):
    """Return lossless status surgery, or refuse ambiguous/user-edited metadata.

    None means restore-only found no archive. The caller leaves that singleton
    byte-identical, including its unrelated body and annotations.
    """
    lines = text.split("\n")
    if lines[0] != "---" or "---" not in lines[1:]:
        raise ValueError("incomplete leading frontmatter")
    end = lines.index("---", 1)
    mappings = [(i, KEY.match(lines[i])) for i in range(1, end)]
    mappings = [(i, match) for i, match in mappings if match]
    root_indent = min((len(match[1]) for _, match in mappings), default=0)
    root = [(i, match) for i, match in mappings if len(match[1]) == root_indent]
    statuses = [i for i, match in root if match[2].rstrip() == "status"]
    archives = [i for i, match in root if match[2].rstrip() == ARCHIVE]

    # Inspect the complete entry before classifying its first line as managed.
    # A plain scalar such as `duplicate\n  pending` is a custom folded value;
    # removing just the first line would attach its continuation to another key.
    for index in statuses:
        value = lines[index].split(":", 1)[1].lstrip()
        # Quoted continuations may be unindented and resemble root mappings.
        # Require a complete first-line scalar before trusting next_root;
        # escaped double quotes and doubled single quotes do not close it.
        if value.startswith(('"', "'")) and not QUOTED.fullmatch(value):
            raise ValueError("custom status is not a single-line scalar")
        next_root = next((i for i, _ in root if i > index), end)
        if value.startswith(("|", ">")) or any(
            line.strip() and not line.lstrip().startswith("#")
            for line in lines[index + 1:next_root]
        ):
            raise ValueError("custom status is not a single-line scalar")
    custom = [i for i in statuses if not MANAGED.fullmatch(lines[i].lstrip())]

    if archives:
        if len(archives) != 1 or custom or len(statuses) != 1:
            raise ValueError("status archive conflicts with current status entries")
        index = archives[0]
        try:
            original = json.loads(lines[index].split(":", 1)[1])
        except (ValueError, TypeError) as exc:
            raise ValueError("incompatible status archive") from exc
        if not isinstance(original, str) or any(c in original for c in "\n\r\x00"):
            raise ValueError("incompatible status archive")
        match = KEY.match(original)
        if (not match or len(match[1]) != root_indent
                or not STATUS.match(original[root_indent:])
                or MANAGED.fullmatch(original[root_indent:])):
            raise ValueError("incompatible status archive")
        if mode != "duplicate":
            lines[index] = original
            del lines[statuses[0]]
    elif mode == "restore-only":
        return None
    elif mode == "duplicate" and custom:
        if len(custom) != 1 or len(statuses) > 2:
            raise ValueError("multiple custom status entries")
        index = custom[0]
        prefix = lines[index][:root_indent]
        lines[index] = prefix + ARCHIVE + ": " + json.dumps(lines[index], ensure_ascii=True)
    return "\n".join(lines)


def main():
    """Emit staged Markdown; failures leave the caller's original untouched."""
    path, mode = sys.argv[1:]
    try:
        text = Path(path).read_bytes().decode("utf-8", errors="surrogateescape")
        result = preserve_status(text, mode)
        if result is None:
            return 3
        sys.stdout.buffer.write(result.encode("utf-8", errors="surrogateescape"))
    except (OSError, ValueError) as exc:
        print(f"local dedupe: preserving {path}: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
