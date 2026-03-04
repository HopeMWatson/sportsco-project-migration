# ─── Snowflake connections ────────────────────────────────────────────────────
# Provider v1.x replaced the project-scoped dbtcloud_connection with
# dbtcloud_global_connection (account-level) + dbtcloud_project_connection
# (which pins a global connection to a specific project).

resource "dbtcloud_global_connection" "val" {
  name = "Snowflake - Val"

  snowflake = {
    account   = var.snowflake_account
    database  = var.snowflake_database
    warehouse = var.snowflake_warehouse
    role      = var.snowflake_role
    allow_sso = true
  }
}

resource "dbtcloud_global_connection" "prod" {
  name = "Snowflake - Prod"

  snowflake = {
    account   = var.snowflake_account
    database  = var.snowflake_database
    warehouse = var.snowflake_warehouse
    role      = var.snowflake_role
    allow_sso = true
  }
}

# ─── Snowflake credentials ────────────────────────────────────────────────────
# Credentials are project-scoped and linked to an environment via credential_id.

resource "dbtcloud_snowflake_credential" "val" {
  project_id   = dbtcloud_project.val.id
  auth_type    = "keypair"
  num_threads  = 8
  schema       = "dbt_val"
  user         = var.snowflake_user
  private_key  = var.snowflake_private_key
}

resource "dbtcloud_snowflake_credential" "prod" {
  project_id   = dbtcloud_project.prod.id
  auth_type    = "keypair"
  num_threads  = 16
  schema       = "dbt_prod"
  user         = var.snowflake_user
  private_key  = var.snowflake_private_key
}
