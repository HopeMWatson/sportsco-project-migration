# ─────────────────────────────────────────────────────────────────────────────
# Projects
#
# val  → the legacy project being deprecated. Once migration is validated it
#        will be RBAC-locked to read-only as an archive.
#
# prod → the consolidated destination project. All val jobs are re-homed here
#        into the prod_val_environment (val branch) and will eventually cut
#        over to prod_deployment (main branch) once stable.
# ─────────────────────────────────────────────────────────────────────────────

resource "dbtcloud_project" "val" {
  name = "sportsco Analytics - Val (Deprecating)"
}

resource "dbtcloud_project" "prod" {
  name = "sportsco Analytics - Prod"
}
