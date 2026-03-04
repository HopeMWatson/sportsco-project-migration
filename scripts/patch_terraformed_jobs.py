#!/usr/bin/env python3
"""
patch_terraformed_jobs.py  (Phase 2, Step 2)
-----------------------------------------
Post-processes the raw HCL output of dbt-terraforming to redirect migrated
val jobs into the prod project's val environment.

Changes applied:
  • project_id     → dbtcloud_project.prod.id
  • environment_id → dbtcloud_environment.val_environment.environment_id
  • Resource labels prefixed with "migrated_" to avoid state collisions

Note: triggers.schedule = false and generate_docs = false are set at
generation time by run_dbt_terraforming.sh (structured data, not regex).
By the time this script runs, those values are already correct in the input.

Note on job state: dbt Cloud has no "is_active" concept. The API uses
  state = 1 (active) and state = 2 (deleted). Migrated jobs are always
  created as state = 1. Use triggers.schedule = false to keep them dormant.

Input:   generated/val_jobs_raw.tf        (from run_dbt_terraforming.sh)
Output:  terraform/06_jobs_migrated.tf    (reviewed, then applied to prod)

Usage:
    python scripts/patch_terraformed_jobs.py
    python scripts/patch_terraformed_jobs.py --input PATH --output PATH
    python scripts/patch_terraformed_jobs.py --dry-run   # print to stdout
"""

import argparse
import re
import sys
from pathlib import Path

GENERATED_HEADER = """\
# ─────────────────────────────────────────────────────────────────────────────
# 06_jobs_migrated.tf  (GENERATED — do not hand-edit)
#
# Source:  generated/val_jobs_raw.tf   (snapshot from run_dbt_terraforming.sh)
# Patched: scripts/patch_terraformed_jobs.py
#
# These jobs are re-homed in the prod project but pinned to the val branch
# via val_environment. They run identically to how they ran in val.
#
# Jobs are active (state=1) with schedule=false. dbt Cloud: state=1 active,
# state=2 deleted. Jobs are always triggered on demand — never on a schedule.
# Phase flow:
#   Phase 3: make apply-migrated-jobs → provisions jobs (active, schedule=false)
# ─────────────────────────────────────────────────────────────────────────────

"""

# Each entry is (description, compiled_regex, replacement_string)
# Order matters: resource label rename must come after project/environment patches.
#
# Note: schedule=false and generate_docs=false are applied at the data level
# in run_dbt_terraforming.sh before HCL is emitted. The patches here handle
# only the Terraform cross-references that must be re-targeted to prod.
PATCHES = [
    (
        "Re-target project_id to prod",
        re.compile(r'project_id\s*=\s*\d+'),
        'project_id     = dbtcloud_project.prod.id',
    ),
    (
        "Re-target environment_id to val_environment",
        re.compile(r'environment_id\s*=\s*\d+'),
        'environment_id = dbtcloud_environment.val_environment.environment_id',
    ),
    (
        "Prefix resource labels with 'migrated_'",
        re.compile(r'resource\s+"dbtcloud_job"\s+"(?!migrated_)(\w+)"'),
        r'resource "dbtcloud_job" "migrated_\1"',
    ),
]


def patch_hcl(raw: str) -> tuple[str, list[dict]]:
    """Apply all patches and return (patched_hcl, patch_report)."""
    patched = raw
    report = []

    for description, pattern, replacement in PATCHES:
        matches = pattern.findall(patched)
        count = len(matches)
        patched = pattern.sub(replacement, patched)
        report.append({"patch": description, "replacements": count})

    return GENERATED_HEADER + patched, report


def main():
    parser = argparse.ArgumentParser(
        description="Patch dbt-terraforming HCL to target prod project + val environment",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument(
        "--input",
        default="generated/val_jobs_raw.tf",
        help="Raw HCL from run_dbt_terraforming.sh",
    )
    parser.add_argument(
        "--output",
        default="terraform/06_jobs_migrated.tf",
        help="Patched HCL destination (included in next terraform apply)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print patched HCL to stdout; do not write file",
    )
    args = parser.parse_args()

    input_path = Path(args.input)
    if not input_path.exists():
        print(f"ERROR: {input_path} not found.", file=sys.stderr)
        print("Run scripts/run_dbt_terraforming.sh first.", file=sys.stderr)
        sys.exit(1)

    raw = input_path.read_text()
    if not raw.strip():
        print("ERROR: Input file is empty — dbt-terraforming may have found no jobs.", file=sys.stderr)
        sys.exit(1)

    patched, report = patch_hcl(raw)

    if args.dry_run:
        print(patched)
        return

    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(patched)

    # Print report
    print("")
    print("Patch report:")
    for entry in report:
        print(f"  [{entry['replacements']:>3}]  {entry['patch']}")
    print("")
    print(f"Output written to: {output_path}")
    print("")
    print("Next steps:")
    print("  1. Review terraform/06_jobs_migrated.tf")
    print("     (verify schedule = false and generate_docs = false on all jobs)")
    print("  2. make apply-migrated-jobs   # provision jobs in prod (active, schedule=false)")
    print("  3. Verify jobs in dbt Cloud UI (prod project → Val environment)")
    print("  4. make trigger-migrated      # trigger jobs on demand to validate")


if __name__ == "__main__":
    main()
