# ─────────────────────────────────────────────────────────────────────────────
# RBAC — Val Project Lockdown (Phase 6)
#
# Apply this ONLY after the migration has been fully validated end-to-end.
#
# Strategy:
#   1. Create a "Val Archived — Job Viewer" group with job_viewer-level
#      permissions scoped to the val project only.
#   2. assign_by_default = true means dbt Cloud automatically assigns this
#      group to all users in the account (new invites and SSO sign-ins).
#      For existing non-SSO users, add them in the UI after apply:
#        Account Settings → Groups → Val Project — Archived (Job Viewer) → Add users
#   3. ⚠  Account Admin and Account Owner roles ALWAYS supersede group-level
#      permissions in dbt Cloud. Users with those roles have unrestricted access
#      to the val project regardless of what this group grants or restricts.
#      There is no Terraform-level way to restrict account admins.
#   4. To strip write access from other groups (Developer, etc.), update or
#      remove the val project from their group_permissions in the dbt Cloud UI
#      or via terraform import + edit if they're managed in this config.
#
# Apply with a targeted plan first to avoid touching other resources:
#   terraform plan  -target=dbtcloud_group.val_archived_readonly
#   terraform apply -target=dbtcloud_group.val_archived_readonly
# ─────────────────────────────────────────────────────────────────────────────

resource "dbtcloud_group" "val_archived_readonly" {
  name = "Val Project — Archived (Job Viewer)"

  # true = automatically assigned to all account users (new invites + SSO).
  # Existing non-SSO users must be added manually in the UI after apply.
  assign_by_default = true

  group_permissions {
    project_id = dbtcloud_project.val.id

    # job_viewer: read-only access to job results, run status, and logs.
    # Cannot trigger jobs, cannot edit anything. Ideal for archival — users
    # can still audit historical runs but the project is effectively frozen.
    #
    # Permission hierarchy (lowest → highest):
    #   job_viewer < job_runner < job_admin < developer < analyst < member < owner
    #
    # ⚠  Account Admin / Account Owner always supersede this permission.
    permission_set = "job_viewer"
    all_projects   = false
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
