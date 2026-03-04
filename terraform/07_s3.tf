# ─────────────────────────────────────────────────────────────────────────────
# S3 — Job Run History Backup
#
# This bucket is the landing zone for all job run metadata extracted from the
# val project by scripts/extract_job_runs.py.
#
# Structure written by the script:
#   s3://<bucket>/val-project-backup/<timestamp>/
#     jobs_manifest.json          — all job definitions
#     summary.json                — run count index per job
#     runs/
#       job_<id>_<name>.json      — full run + step history per job
#
# Even after the val project is archived in dbt Cloud, this bucket preserves
# the audit trail of what ran, when, and whether it succeeded.
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_s3_bucket" "job_run_backup" {
  bucket = var.s3_bucket_name

  tags = {
    Project   = "sportsco-project-migration"
    Purpose   = "dbt-cloud-job-run-history-backup"
    Source    = "val-project"
    ManagedBy = "terraform"
  }
}

resource "aws_s3_bucket_versioning" "job_run_backup" {
  bucket = aws_s3_bucket.job_run_backup.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "job_run_backup" {
  bucket = aws_s3_bucket.job_run_backup.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "job_run_backup" {
  bucket = aws_s3_bucket.job_run_backup.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Move older backups to cheaper storage tiers automatically.
resource "aws_s3_bucket_lifecycle_configuration" "job_run_backup" {
  bucket = aws_s3_bucket.job_run_backup.id

  rule {
    id     = "archive-old-run-history"
    status = "Enabled"

    filter {}

    transition {
      days          = 90
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = 365
      storage_class = "GLACIER"
    }
  }
}
