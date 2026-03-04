# ─── Project IDs ──────────────────────────────────────────────────────────────
# These are consumed by the scripts via make targets or the .env file.

output "val_project_id" {
  description = "dbt Cloud project ID for the val (deprecated) project"
  value       = dbtcloud_project.val.id
}

output "prod_project_id" {
  description = "dbt Cloud project ID for the prod (consolidated) project"
  value       = dbtcloud_project.prod.id
}

# ─── Environment IDs ──────────────────────────────────────────────────────────

output "val_deployment_environment_id" {
  description = "Environment ID: val deployment (inside val project)"
  value       = dbtcloud_environment.val_deployment.environment_id
}

output "prod_deployment_environment_id" {
  description = "Environment ID: prod deployment (inside prod project, main branch)"
  value       = dbtcloud_environment.prod_deployment.environment_id
}

output "prod_val_environment_id" {
  description = "Environment ID: val-branch environment inside prod project — migrated jobs land here"
  value       = dbtcloud_environment.val_environment.environment_id
}

# ─── S3 ───────────────────────────────────────────────────────────────────────

output "job_run_backup_bucket" {
  description = "S3 bucket name for val project job run history backup"
  value       = aws_s3_bucket.job_run_backup.bucket
}

output "job_run_backup_bucket_arn" {
  description = "S3 bucket ARN"
  value       = aws_s3_bucket.job_run_backup.arn
}

# ─── Quick reference: .env snippet ───────────────────────────────────────────
# After `terraform apply`, copy these values into your .env file.

output "_env_snippet" {
  description = "Paste these into your .env file for use with make targets"
  value       = <<-EOT

    # ── Copy into .env ──────────────────────────────────────────
    DBT_VAL_PROJECT_ID=${dbtcloud_project.val.id}
    DBT_VAL_ENV_ID=${dbtcloud_environment.val_deployment.environment_id}
    DBT_PROD_PROJECT_ID=${dbtcloud_project.prod.id}
    DBT_PROD_VAL_ENV_ID=${dbtcloud_environment.val_environment.environment_id}
    S3_BUCKET=${aws_s3_bucket.job_run_backup.bucket}
    # ────────────────────────────────────────────────────────────
  EOT
}
