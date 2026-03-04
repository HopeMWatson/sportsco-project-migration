#!/usr/bin/env python3
"""
patch_terraformed_jobs.py  (Phase 2, Step 2)
-----------------------------------------
Post-processes the raw HCL output of dbt-terraforming to redirect migrated
val jobs into the prod project's val environment.

Changes applied:
  • project_id     → dbtcloud_project.prod.id
  • environment_id → dbtcloud_environment.prod_val_environment.environment_id
  • Resource labels prefixed with "migrated_" to avoid state collisions
  • Job names prefixed with "[Val→Prod] " for UI clarity #TODO remove this logic and keep job name completely unchanged. 
  • is_active set to false — jobs are created dark; activate deliberately
    after validating each one

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
# Source:  generated/val_jobs_raw.tf   (dbt-terraforming snapshot of val project)
# Patched: scripts/patch_terraformed_jobs.py
#
# These jobs are re-homed in the prod project but pinned to the val branch
# via prod_val_environment. They run identically to how they ran in val.
#
# To activate a job after validating it:
#   1. Set is_active = true for that resource
#   2. terraform apply -target=dbtcloud_job.migrated_<name>
# ─────────────────────────────────────────────────────────────────────────────

"""

# Each entry is (description, compiled_regex, replacement_string)
# Order matters: resource label rename must come after project/environment patches.
PATCHES = [
    (
        "Re-target project_id to prod",
        re.compile(r'project_id\s*=\s*\d+'),
        'project_id     = dbtcloud_project.prod.id',
    ),
    (
        "Re-target environment_id to prod_val_environment",
        re.compile(r'environment_id\s*=\s*\d+'),
        'environment_id = dbtcloud_environment.prod_val_environment.environment_id',
    ),
    (
        "Prefix resource labels with 'migrated_'",
        re.compile(r'resource\s+"dbtcloud_job"\s+"(?!migrated_)(\w+)"'),
        r'resource "dbtcloud_job" "migrated_\1"',
    ),
    (
        "Prefix job name strings with '[Val→Prod] '",
        re.compile(r'(^\s*name\s*=\s*")(?!\[Val→Prod\])(.+?)(")', re.MULTILINE),
        r'\1[Val→Prod] \2\3',
    ),
    (
        "Create jobs dark (is_active = false) — activate after validation",
        re.compile(r'is_active\s*=\s*true'),
        'is_active = false  # flip to true after validating this job',
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
    print("  2. terraform -chdir=terraform plan")
    print("  3. terraform -chdir=terraform apply")
    print("  4. Validate jobs in dbt Cloud UI (prod project → Val environment)")
    print("  5. For each validated job, set is_active = true and re-apply")


if __name__ == "__main__":
    main()
