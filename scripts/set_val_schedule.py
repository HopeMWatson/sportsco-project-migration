#!/usr/bin/env python3
"""
set_val_schedule.py  (Phase 5b)
--------------------------------
Toggles the schedule trigger on val project jobs in terraform/05_jobs_val.tf.
Only modifies resource blocks whose label starts with "val_"; prod_* blocks are
left untouched.

Uses brace-counting to locate each val_* resource block so prod_* jobs with
schedule = true are never touched.

Usage:
    python scripts/set_val_schedule.py --disable   # set schedule = false
    python scripts/set_val_schedule.py --enable    # set schedule = true
    python scripts/set_val_schedule.py --disable --dry-run

Run via make instead of calling directly:
    make disable-val-schedule   (Phase 5b)
"""

import argparse
import re
import sys
from pathlib import Path

DEFAULT_FILE = "terraform/05_jobs_val.tf"


def find_val_job_spans(content: str) -> list[tuple[int, int]]:
    """Return (start, end) character spans for every resource block whose
    label starts with 'val_'.  Uses brace-counting to find the closing '}'.
    """
    spans = []
    pattern = re.compile(r'resource\s+"dbtcloud_job"\s+"(val_\w+)"\s*\{')
    for m in pattern.finditer(content):
        depth = 0
        i = m.start()
        while i < len(content):
            if content[i] == "{":
                depth += 1
            elif content[i] == "}":
                depth -= 1
                if depth == 0:
                    spans.append((m.start(), i + 1))
                    break
            i += 1
    return spans


def toggle_schedule(content: str, enable: bool) -> tuple[str, int]:
    """Flip schedule = true/false inside all val_* blocks only.

    Returns (new_content, number_of_replacements).
    """
    from_val = "false" if enable else "true"
    to_val = "true" if enable else "false"
    pattern = re.compile(r"(\bschedule\s*=\s*)" + from_val)

    spans = find_val_job_spans(content)
    if not spans:
        return content, 0

    count = 0
    parts = []
    prev = 0
    for start, end in spans:
        parts.append(content[prev:start])
        block = content[start:end]
        new_block, n = pattern.subn(r"\g<1>" + to_val, block)
        count += n
        parts.append(new_block)
        prev = end
    parts.append(content[prev:])
    return "".join(parts), count


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Toggle schedule on val project jobs in 05_jobs_val.tf",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--enable", action="store_true", help="Set schedule = true on val jobs")
    group.add_argument("--disable", action="store_true", help="Set schedule = false on val jobs")
    parser.add_argument(
        "--file",
        default=DEFAULT_FILE,
        help="Path to the jobs Terraform file",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print result to stdout without writing",
    )
    args = parser.parse_args()

    path = Path(args.file)
    if not path.exists():
        print(f"ERROR: {path} not found.", file=sys.stderr)
        sys.exit(1)

    content = path.read_text()
    new_content, count = toggle_schedule(content, enable=args.enable)

    if count == 0:
        action = "enabled" if args.enable else "disabled"
        print(f"No changes — schedule already {action} on all val jobs in {path}")
        return

    if args.dry_run:
        print(new_content)
        return

    path.write_text(new_content)
    action = "Enabled" if args.enable else "Disabled"
    print(f"{action} schedule on {count} val job(s) in {path}")
    print("")
    print("Next step:  make apply (or make disable-val-schedule which runs apply automatically)")


if __name__ == "__main__":
    main()
