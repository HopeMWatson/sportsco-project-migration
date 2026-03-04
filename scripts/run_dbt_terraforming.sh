#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# run_dbt_terraforming.sh  (Phase 2, Step 1)
#
# Generates a raw Terraform HCL snapshot of the val project's jobs by reading
# directly from Terraform state (`terraform show -json`).
#
# NOTE: We originally used dbtcloud-terraforming for this step, but v0.12.3
# has a bug where it cannot find dbtcloud_job in the provider schema for
# provider v1.x and silently emits nothing. Reading from state is equivalent
# and more reliable for jobs that were themselves created via Terraform.
#
# Required env vars:
#   DBT_VAL_PROJECT_ID   val project ID (filters jobs to this project only)
#
# Usage:
#   ./scripts/run_dbt_terraforming.sh
#
# After this runs, execute:
#   python scripts/patch_terraformed_jobs.py
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

PROJECT_ID="${DBT_VAL_PROJECT_ID:?'Set DBT_VAL_PROJECT_ID env var'}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
TF_DIR="$REPO_ROOT/terraform"
OUTDIR="$REPO_ROOT/generated"
OUTFILE="$OUTDIR/val_jobs_raw.tf"

mkdir -p "$OUTDIR"

echo ""
echo "Snapshotting val project $PROJECT_ID jobs from Terraform state …"
echo ""

python3 - "$TF_DIR" "$PROJECT_ID" "$OUTFILE" << 'PYEOF'
import json, sys, subprocess

tf_dir, project_id, outfile = sys.argv[1], int(sys.argv[2]), sys.argv[3]

result = subprocess.run(
    ['terraform', 'show', '-json'],
    capture_output=True, text=True, cwd=tf_dir
)
if result.returncode != 0:
    print('ERROR: terraform show -json failed:\n' + result.stderr, file=sys.stderr)
    sys.exit(1)

state = json.loads(result.stdout)
resources = state.get('values', {}).get('root_module', {}).get('resources', [])
val_jobs = [
    r for r in resources
    if r['type'] == 'dbtcloud_job' and r['values']['project_id'] == project_id
]

if not val_jobs:
    print(f'WARNING: no dbtcloud_job resources found for project_id={project_id}', file=sys.stderr)
    open(outfile, 'w').close()
    sys.exit(0)

# Fields that are computed-only, deprecated, or mutually exclusive — omit from generated HCL
SKIP = {
    'id',
    'job_id',           # computed alias for id
    'job_type',         # computed
    'timeout_seconds',  # deprecated; use execution.timeout_seconds instead
    'schedule_interval', # mutually exclusive with schedule_hours; only valid for interval_cron type
}

def hcl_val(v, indent=2):
    pad = ' ' * indent
    inner_pad = ' ' * (indent + 2)
    if v is None:
        return 'null'
    if isinstance(v, bool):
        return 'true' if v else 'false'
    if isinstance(v, (int, float)):
        return str(v)
    if isinstance(v, str):
        return json.dumps(v, ensure_ascii=False)
    if isinstance(v, list):
        if not v:
            return '[]'
        items = ', '.join(hcl_val(i, indent) for i in v)
        return '[' + items + ']'
    if isinstance(v, dict):
        if not v:
            return '{}'
        lines = ['{']
        for k, val in v.items():
            lines.append(f'{inner_pad}{k} = {hcl_val(val, indent + 2)}')
        lines.append(pad + '}')
        return '\n'.join(lines)
    return repr(v)

blocks = []
for r in val_jobs:
    vals = r['values']
    lines = [f'resource "dbtcloud_job" "{r["name"]}" {{']
    for k, v in vals.items():
        if k in SKIP:
            continue
        if v is None or v == [] or v == '':
            continue
        lines.append(f'  {k} = {hcl_val(v)}')
    lines.append('}')
    blocks.append('\n'.join(lines))

with open(outfile, 'w') as f:
    f.write('\n\n'.join(blocks) + '\n')

print(f'Captured {len(blocks)} val project job(s) from Terraform state.')
PYEOF

JOB_COUNT=$(grep -c 'resource "dbtcloud_job"' "$OUTFILE" 2>/dev/null || true)
JOB_COUNT="${JOB_COUNT:-0}"

echo ""
echo "──────────────────────────────────────────────────────"
echo "  Raw HCL snapshot:  $OUTFILE"
echo "  Jobs captured:     $JOB_COUNT"
echo "──────────────────────────────────────────────────────"
echo ""
echo "Next step:"
echo "  make patch-jobs"
echo ""
