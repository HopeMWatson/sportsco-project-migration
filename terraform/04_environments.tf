# ─────────────────────────────────────────────────────────────────────────────
# Environments
#
#  val_deployment        → inside val project, runs on the val branch.
#                          This is where the legacy jobs currently run.
#
#  prod_deployment       → inside prod project, runs on main.
#                          Standard production cadence post-migration.
#
#  prod_val_environment  → inside prod project, pinned to the val branch.
#                          This is the landing zone for migrated val jobs.
#                          Jobs run here are identical in config to val_deployment
#                          but are now managed by the prod project — the key step
#                          in collapsing the two projects into one.
# ─────────────────────────────────────────────────────────────────────────────

resource "dbtcloud_environment" "val_deployment" {
  project_id        = dbtcloud_project.val.id
  name              = "Val Deployment"
  dbt_version       = "latest"
  type              = "deployment"
  use_custom_branch = true
  custom_branch     = var.val_branch
  connection_id     = dbtcloud_global_connection.val.id
  credential_id     = dbtcloud_snowflake_credential.val.credential_id

  depends_on = [
    dbtcloud_repository.val,
    dbtcloud_global_connection.val,
    dbtcloud_snowflake_credential.val,
  ]
}

resource "dbtcloud_environment" "prod_deployment" {
  project_id        = dbtcloud_project.prod.id
  name              = "Prod Deployment"
  dbt_version       = "latest"
  type              = "deployment"
  use_custom_branch = false
  connection_id     = dbtcloud_global_connection.prod.id
  credential_id     = dbtcloud_snowflake_credential.prod.credential_id

  depends_on = [
    dbtcloud_repository.prod,
    dbtcloud_global_connection.prod,
    dbtcloud_snowflake_credential.prod,
  ]
}

# This environment is the bridge: prod project infra, val branch execution.
# Once the team is satisfied, jobs here are re-pointed at prod_deployment.
resource "dbtcloud_environment" "val_environment" {
  project_id        = dbtcloud_project.prod.id
  name              = "Val (Migrated from Val Project)"
  dbt_version       = "latest"
  type              = "deployment"
  use_custom_branch = true
  custom_branch     = var.val_branch
  connection_id     = dbtcloud_global_connection.prod.id
  credential_id     = dbtcloud_snowflake_credential.prod.credential_id

  depends_on = [
    dbtcloud_repository.prod,
    dbtcloud_global_connection.prod,
    dbtcloud_snowflake_credential.prod,
  ]
}
