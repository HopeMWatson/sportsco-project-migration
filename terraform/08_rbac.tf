# ─────────────────────────────────────────────────────────────────────────────
# RBAC — Val Project Lockdown (Phase 6)
#
# Apply this ONLY after the migration has been fully validated end-to-end.
#
# Strategy:
#   1. Create a "Val Archived — Job Viewer" group with job_viewer-level
#      permissions scoped to the val project only.
#   2. Flip the Developer group's val project permission to read-only (or remove
#      the val project entry entirely from its group_permissions block if that
#      group is also managed in Terraform).
#   3. For groups not managed by this Terraform config, use the dbt Cloud UI or
#      the API call documented in scripts/rbac_lockdown.sh to strip write access.
#
# Apply with a targeted plan first to avoid touching other resources:
#   terraform plan  -target=dbtcloud_group.val_archived_readonly
#   terraform apply -target=dbtcloud_group.val_archived_readonly
# ─────────────────────────────────────────────────────────────────────────────

resource "dbtcloud_group" "val_archived_readonly" {
  name              = "Val Project — Archived (Job Viewer)"
  assign_by_default = false

  group_permissions {
    project_id       = dbtcloud_project.val.id
    # job_viewer: read-only access to job results, run status, and logs.
    # Cannot trigger jobs, cannot edit anything. Ideal for archival — people
    # can still audit historical runs but the project is effectively frozen.
    #
    # Per dbt Cloud enterprise permissions docs:
    #   job_viewer < job_runner < job_admin < developer < analyst < member < owner
    permission_set   = "job_viewer"
    all_projects     = false
  }
}

# ── Removing write access from the Developer group ────────────────────────────
# If your Developer group is managed in this Terraform config, update it below
# by removing the val project from its group_permissions blocks.
#
# Example (uncomment and adjust group ID / name to match your setup):
#
# resource "dbtcloud_group" "developers" {
#   name = "Developers"
#
#   group_permissions {
#     # val project intentionally omitted — write access revoked
#     project_id       = dbtcloud_project.prod.id
#     permission_level = "developer"
#     all_projects     = false
#   }
# }
#
# If the group was created outside Terraform:
#   terraform import dbtcloud_group.developers <group_id>
# then edit accordingly.
