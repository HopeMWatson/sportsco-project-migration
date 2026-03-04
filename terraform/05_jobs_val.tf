# ─────────────────────────────────────────────────────────────────────────────
# Jobs
#
# Four daily scheduled jobs — one dbt build and one dbt run per project.
# All jobs run at 06:00 UTC every day.
# ─────────────────────────────────────────────────────────────────────────────

resource "dbtcloud_job" "val_daily_build" {
  project_id     = dbtcloud_project.val.id
  environment_id = dbtcloud_environment.val_deployment.environment_id
  name           = "Val — Daily Build"

  execute_steps = ["dbt build"]

  triggers = {
    github_webhook       = false
    git_provider_webhook = false
    schedule             = true
    on_merge             = false
  }

  schedule_type = "every_day"
  schedule_hours = [6]
  num_threads   = 4
  target_name   = "val"

  execution = {
    timeout_seconds = 3600
  }

  generate_docs = true
  is_active     = true
}

resource "dbtcloud_job" "val_daily_run" {
  project_id     = dbtcloud_project.val.id
  environment_id = dbtcloud_environment.val_deployment.environment_id
  name           = "Val — Daily Run"

  execute_steps = ["dbt run"]

  triggers = {
    github_webhook       = false
    git_provider_webhook = false
    schedule             = true
    on_merge             = false
  }

  schedule_type  = "every_day"
  schedule_hours = [6]
  num_threads    = 4
  target_name    = "val"

  execution = {
    timeout_seconds = 3600
  }

  generate_docs = false
  is_active     = true
}

resource "dbtcloud_job" "prod_daily_build" {
  project_id     = dbtcloud_project.prod.id
  environment_id = dbtcloud_environment.prod_deployment.environment_id
  name           = "Prod — Daily Build"

  execute_steps = ["dbt build"]

  triggers = {
    github_webhook       = false
    git_provider_webhook = false
    schedule             = true
    on_merge             = false
  }

  schedule_type  = "every_day"
  schedule_hours = [6]
  num_threads    = 8
  target_name    = "prod"

  execution = {
    timeout_seconds = 3600
  }

  generate_docs = true
  is_active     = true
}

resource "dbtcloud_job" "prod_daily_run" {
  project_id     = dbtcloud_project.prod.id
  environment_id = dbtcloud_environment.prod_deployment.environment_id
  name           = "Prod — Daily Run"

  execute_steps = ["dbt run"]

  triggers = {
    github_webhook       = false
    git_provider_webhook = false
    schedule             = true
    on_merge             = false
  }

  schedule_type  = "every_day"
  schedule_hours = [6]
  num_threads    = 8
  target_name    = "prod"

  execution = {
    timeout_seconds = 3600
  }

  generate_docs = false
  is_active     = true
}
