# ─────────────────────────────────────────────────────────────────────────────
# SportsCo Project Migration — Makefile
#
# End-to-end flow for collapsing the legacy val project into prod.
#
#   Phase 1   Infrastructure           make init && make apply
#   Phase 1b  Run val jobs             make trigger-val-jobs  (produces run history for backup)
#   Phase 2   Snapshot val jobs        make terraform-image && make migrate-jobs
#   Phase 3   Provision in prod        make apply-migrated-jobs  (jobs active, schedule off)
#   Phase 4   Backup run history       make backup-runs
#   Phase 5   Validate                 make trigger-migrated
#   Phase 6   RBAC lockdown            make rbac-lockdown
# ─────────────────────────────────────────────────────────────────────────────

TF_DIR      := terraform
SCRIPTS_DIR := scripts
GEN_DIR     := generated

# tf_with_secrets.sh wraps all terraform calls: it fetches credentials from
# AWS Secrets Manager and injects them as TF_VAR_* before exec-ing terraform.
TF := bash $(SCRIPTS_DIR)/tf_with_secrets.sh

# Load .env if present (non-sensitive values only — no tokens/passwords).
# Populate .env with: source <(bash scripts/export_env_secrets.sh)
-include .env
export

.PHONY: help init plan apply \
        trigger-val-jobs trigger-val-jobs-dry \
        terraform-image migrate-jobs apply-migrated-jobs \
        backup-runs backup-runs-dry \
        trigger-migrated trigger-migrated-dry \
        rbac-lockdown populate-rbac-group \
        outputs secrets clean delete-all

# ─── Help ─────────────────────────────────────────────────────────────────────

help:
	@echo ""
	@echo "  SportsCo dbt Cloud — Project Deprecation Flow"
	@echo "  ========================================="
	@echo ""
	@echo "  Phase 1 — Infrastructure"
	@echo "    make init                  terraform init"
	@echo "    make plan                  terraform plan (preview all resources)"
	@echo "    make apply                 Create projects, environments, val jobs, S3 bucket"
	@echo "    make outputs               Print terraform outputs (copy IDs into .env)"
	@echo ""
	@echo "  Phase 1b — Run val jobs (produces run history + artifacts for S3 backup)"
	@echo "    make trigger-val-jobs      Trigger all active val project jobs and wait"
	@echo "    make trigger-val-jobs-dry  List val jobs without triggering"
	@echo ""
	@echo "  Phase 2 — Snapshot val jobs and convert for prod"
	@echo "    make terraform-image           Snapshot val jobs → generated/val_jobs_raw.tf"
	@echo "    make migrate-jobs              Re-target snapshot for prod → terraform/06_jobs_migrated.tf"
	@echo ""
	@echo "  Phase 3 — Provision migrated jobs in prod (active, schedule off)"
	@echo "    make apply-migrated-jobs       terraform apply (jobs active, schedule = false)"
	@echo ""
	@echo "  Phase 4 — Backup"
	@echo "    make backup-runs               Export val job run history → S3"
	@echo "    make backup-runs-dry           Dry run (no upload)"
	@echo ""
	@echo "  Phase 5 — Validate migration"
	@echo "    make trigger-migrated          Trigger migrated jobs in prod/val-env and wait"
	@echo "    make trigger-migrated-dry      List matching jobs without triggering"
	@echo ""
	@echo "  Phase 6 — Lockdown"
	@echo "    make rbac-lockdown             Create read-only RBAC group + add all existing users"
	@echo "    make populate-rbac-group       Re-run user backfill only (if lockdown partially failed)"
	@echo ""
	@echo "  Utilities"
	@echo "    make clean                 Delete generated/ directory"
	@echo "    make delete-all            Destroy ALL cloud resources + wipe local files (prompts)"
	@echo ""
	@echo "  Credential setup (one-time):"
	@echo "    See terraform/09_secrets.tf for the aws secretsmanager create-secret commands."
	@echo "    Terraform calls use scripts/tf_with_secrets.sh (no secrets in terraform.tfvars)."
	@echo "    Python script calls need env vars — load them with:"
	@echo "      source <(bash scripts/export_env_secrets.sh)"
	@echo "    Or:  make secrets   (prints the source command)"
	@echo ""

# ─── Credentials ──────────────────────────────────────────────────────────────

secrets:
	@echo ""
	@echo "  Load secrets + terraform outputs into your current shell:"
	@echo ""
	@echo "    source <(bash $(SCRIPTS_DIR)/export_env_secrets.sh)"
	@echo ""
	@echo "  Or write them to .env (picked up automatically by make):"
	@echo ""
	@echo "    bash $(SCRIPTS_DIR)/export_env_secrets.sh > .env"
	@echo ""
	@echo "  Terraform targets call scripts/tf_with_secrets.sh automatically"
	@echo "  and do NOT need the above step — secrets are fetched per-invocation."
	@echo ""

# ─── Phase 1: Infrastructure ──────────────────────────────────────────────────

init:
	terraform -chdir=$(TF_DIR) init

plan:
	$(TF) plan

apply:
	$(TF) apply

outputs:
	@echo ""
	$(TF) output
	@echo ""
	@echo "Populate .env with these values:"
	@echo "  bash $(SCRIPTS_DIR)/export_env_secrets.sh > .env"
	@echo ""

# ─── Phase 1b: Trigger val project jobs ───────────────────────────────────────
# Runs the val project's daily build/run jobs on demand to produce run results
# and artifacts in dbt Cloud before backing them up to S3 in Phase 4.
# Requires: .env populated (make outputs → bash scripts/export_env_secrets.sh > .env)

trigger-val-jobs:
	@test -n "$(DBT_ACCOUNT_ID)"    || (echo "ERROR: DBT_ACCOUNT_ID not set"    && exit 1)
	@test -n "$(DBT_VAL_PROJECT_ID)" || (echo "ERROR: DBT_VAL_PROJECT_ID not set" && exit 1)
	@test -n "$(DBT_VAL_ENV_ID)"    || (echo "ERROR: DBT_VAL_ENV_ID not set"    && exit 1)
	@test -n "$(DBT_TOKEN)"          || (echo "ERROR: DBT_TOKEN not set"          && exit 1)
	python $(SCRIPTS_DIR)/trigger_migrated_jobs.py \
	    --account-id     $(DBT_ACCOUNT_ID) \
	    --project-id     $(DBT_VAL_PROJECT_ID) \
	    --environment-id $(DBT_VAL_ENV_ID) \
	    $(if $(DBT_HOST),--host $(DBT_HOST),) \
	    --name-prefix    "" \
	    --cause          "Phase 1b — triggering val jobs to produce run history (make trigger-val-jobs)" \
	    --delay          $(TRIGGER_DELAY) \
	    --wait

trigger-val-jobs-dry:
	@test -n "$(DBT_ACCOUNT_ID)"    || (echo "ERROR: DBT_ACCOUNT_ID not set"    && exit 1)
	@test -n "$(DBT_VAL_PROJECT_ID)" || (echo "ERROR: DBT_VAL_PROJECT_ID not set" && exit 1)
	@test -n "$(DBT_VAL_ENV_ID)"    || (echo "ERROR: DBT_VAL_ENV_ID not set"    && exit 1)
	@test -n "$(DBT_TOKEN)"          || (echo "ERROR: DBT_TOKEN not set"          && exit 1)
	python $(SCRIPTS_DIR)/trigger_migrated_jobs.py \
	    --account-id     $(DBT_ACCOUNT_ID) \
	    --project-id     $(DBT_VAL_PROJECT_ID) \
	    --environment-id $(DBT_VAL_ENV_ID) \
	    $(if $(DBT_HOST),--host $(DBT_HOST),) \
	    --name-prefix    "" \
	    --dry-run

# ─── Phase 2: Snapshot val jobs ───────────────────────────────────────────────

terraform-image:
	@test -n "$(DBT_ACCOUNT_ID)"     || (echo "ERROR: DBT_ACCOUNT_ID not set"     && exit 1)
	@test -n "$(DBT_VAL_PROJECT_ID)" || (echo "ERROR: DBT_VAL_PROJECT_ID not set" && exit 1)
	@test -n "$(DBT_TOKEN)"          || (echo "ERROR: DBT_TOKEN not set"           && exit 1)
	mkdir -p $(GEN_DIR)
	bash $(SCRIPTS_DIR)/run_dbt_terraforming.sh

migrate-jobs:
	@test -f $(GEN_DIR)/val_jobs_raw.tf || (echo "ERROR: Run 'make terraform-image' first" && exit 1)
	python $(SCRIPTS_DIR)/patch_terraformed_jobs.py \
	    --input  $(GEN_DIR)/val_jobs_raw.tf \
	    --output $(TF_DIR)/06_jobs_migrated.tf
	@echo ""
	@echo "Review $(TF_DIR)/06_jobs_migrated.tf, then run:"
	@echo "  make apply-migrated-jobs      (provisions jobs active, schedule=false)"

# ─── Phase 3: Provision migrated jobs ─────────────────────────────────────────

apply-migrated-jobs:
	@test -f $(TF_DIR)/06_jobs_migrated.tf || (echo "ERROR: Run 'make migrate-jobs' first" && exit 1)
	@echo ""
	@echo "Applying migrated job resources to prod project ..."
	@echo ""
	$(TF) apply

# ─── Phase 4: Backup val job run artifacts ────────────────────────────────────
# Uploads run_results.json for every run in the last BACKUP_DAYS days.
# Override window with: make backup-runs BACKUP_DAYS=60
BACKUP_DAYS ?= 90

backup-runs:
	@test -n "$(DBT_ACCOUNT_ID)"     || (echo "ERROR: DBT_ACCOUNT_ID not set"     && exit 1)
	@test -n "$(DBT_VAL_PROJECT_ID)" || (echo "ERROR: DBT_VAL_PROJECT_ID not set" && exit 1)
	@test -n "$(DBT_TOKEN)"          || (echo "ERROR: DBT_TOKEN not set"           && exit 1)
	@test -n "$(S3_BUCKET)"          || (echo "ERROR: S3_BUCKET not set"           && exit 1)
	python $(SCRIPTS_DIR)/extract_job_runs.py \
	    --account-id $(DBT_ACCOUNT_ID) \
	    --project-id $(DBT_VAL_PROJECT_ID) \
	    --bucket     $(S3_BUCKET) \
	    --days       $(BACKUP_DAYS) \
	    $(if $(DBT_HOST),--host $(DBT_HOST),)

backup-runs-dry:
	@test -n "$(DBT_ACCOUNT_ID)"     || (echo "ERROR: DBT_ACCOUNT_ID not set"     && exit 1)
	@test -n "$(DBT_VAL_PROJECT_ID)" || (echo "ERROR: DBT_VAL_PROJECT_ID not set" && exit 1)
	@test -n "$(DBT_TOKEN)"          || (echo "ERROR: DBT_TOKEN not set"           && exit 1)
	@test -n "$(S3_BUCKET)"          || (echo "ERROR: S3_BUCKET not set"           && exit 1)
	python $(SCRIPTS_DIR)/extract_job_runs.py \
	    --account-id $(DBT_ACCOUNT_ID) \
	    --project-id $(DBT_VAL_PROJECT_ID) \
	    --bucket     $(S3_BUCKET) \
	    --days       $(BACKUP_DAYS) \
	    $(if $(DBT_HOST),--host $(DBT_HOST),) \
	    --dry-run

# ─── Phase 5: Trigger migrated jobs for validation ────────────────────────────
# Override inter-trigger delay if needed, e.g.:  make trigger-migrated TRIGGER_DELAY=5
TRIGGER_DELAY ?= 2

trigger-migrated:
	@test -n "$(DBT_ACCOUNT_ID)"      || (echo "ERROR: DBT_ACCOUNT_ID not set"      && exit 1)
	@test -n "$(DBT_PROD_PROJECT_ID)" || (echo "ERROR: DBT_PROD_PROJECT_ID not set"  && exit 1)
	@test -n "$(DBT_PROD_VAL_ENV_ID)" || (echo "ERROR: DBT_PROD_VAL_ENV_ID not set"  && exit 1)
	@test -n "$(DBT_TOKEN)"           || (echo "ERROR: DBT_TOKEN not set"            && exit 1)
	python $(SCRIPTS_DIR)/trigger_migrated_jobs.py \
	    --account-id     $(DBT_ACCOUNT_ID) \
	    --project-id     $(DBT_PROD_PROJECT_ID) \
	    --environment-id $(DBT_PROD_VAL_ENV_ID) \
	    $(if $(DBT_HOST),--host $(DBT_HOST),) \
	    --cause "Phase 5 migration validation (make trigger-migrated)" \
	    --delay          $(TRIGGER_DELAY) \
	    --wait

trigger-migrated-dry:
	@test -n "$(DBT_ACCOUNT_ID)"      || (echo "ERROR: DBT_ACCOUNT_ID not set"      && exit 1)
	@test -n "$(DBT_PROD_PROJECT_ID)" || (echo "ERROR: DBT_PROD_PROJECT_ID not set"  && exit 1)
	@test -n "$(DBT_PROD_VAL_ENV_ID)" || (echo "ERROR: DBT_PROD_VAL_ENV_ID not set"  && exit 1)
	@test -n "$(DBT_TOKEN)"           || (echo "ERROR: DBT_TOKEN not set"            && exit 1)
	python $(SCRIPTS_DIR)/trigger_migrated_jobs.py \
	    --account-id     $(DBT_ACCOUNT_ID) \
	    --project-id     $(DBT_PROD_PROJECT_ID) \
	    --environment-id $(DBT_PROD_VAL_ENV_ID) \
	    $(if $(DBT_HOST),--host $(DBT_HOST),) \
	    --dry-run

# ─── Phase 6: RBAC lockdown ───────────────────────────────────────────────────

rbac-lockdown:
	@test -n "$(DBT_ACCOUNT_ID)" || (echo "ERROR: DBT_ACCOUNT_ID not set" && exit 1)
	@test -n "$(DBT_TOKEN)"      || (echo "ERROR: DBT_TOKEN not set"      && exit 1)
	@echo ""
	@echo "  WARNING: This will create a read-only RBAC group on the val project"
	@echo "  and add ALL existing account users to it."
	@echo "  The val project should no longer be used for active development."
	@echo ""
	@read -p "  Proceed with lockdown? [y/N] " confirm && [ "$$confirm" = "y" ]
	$(TF) apply -target=dbtcloud_group.val_archived_readonly
	@echo ""
	@echo "Adding all existing account users to the group ..."
	@GROUP_ID=$$($(TF) output -raw val_archived_readonly_group_id 2>/dev/null | grep -E '^[0-9]+$$' || true); \
	if [ -n "$$GROUP_ID" ]; then \
	  python3 $(SCRIPTS_DIR)/add_users_to_group.py \
	      --account-id $(DBT_ACCOUNT_ID) \
	      --group-id   $$GROUP_ID \
	      $(if $(DBT_HOST),--host $(DBT_HOST),); \
	else \
	  echo "  ERROR: Could not read group ID from terraform output."; \
	  echo "  Run manually: make populate-rbac-group"; \
	  exit 1; \
	fi
	@echo ""
	@echo "  Done. All existing users added to the val RBAC group."
	@echo "  Next: remove write-capable groups from the val project in the"
	@echo "  dbt Cloud UI (Account Settings → Groups) or via the API."

populate-rbac-group:
	@test -n "$(DBT_ACCOUNT_ID)" || (echo "ERROR: DBT_ACCOUNT_ID not set" && exit 1)
	@test -n "$(DBT_TOKEN)"      || (echo "ERROR: DBT_TOKEN not set"      && exit 1)
	@echo ""
	@echo "Adding all existing account users to the val RBAC group ..."
	@GROUP_ID=$$($(TF) output -raw val_archived_readonly_group_id 2>/dev/null | grep -E '^[0-9]+$$' || true); \
	if [ -n "$$GROUP_ID" ]; then \
	  python3 $(SCRIPTS_DIR)/add_users_to_group.py \
	      --account-id $(DBT_ACCOUNT_ID) \
	      --group-id   $$GROUP_ID \
	      $(if $(DBT_HOST),--host $(DBT_HOST),); \
	else \
	  echo "  ERROR: Could not read group ID from terraform output."; \
	  echo "  Has 'make rbac-lockdown' been run yet?"; \
	  exit 1; \
	fi

# ─── Utilities ────────────────────────────────────────────────────────────────

clean:
	rm -rf $(GEN_DIR)
	@echo "generated/ removed."

# ─── Teardown ─────────────────────────────────────────────────────────────────
# Destroys all Terraform-managed cloud resources (dbt Cloud projects, environments,
# jobs, connections, S3 bucket + contents) and wipes local generated files.
# The S3 bucket is emptied (all versions) before destroy so Terraform can delete it.

delete-all:
	@echo ""
	@echo "  ⚠  WARNING: This will permanently destroy:"
	@echo "       • All dbt Cloud resources (projects, environments, jobs, connections)"
	@echo "       • The S3 backup bucket and ALL its contents"
	@echo "       • Local generated/ directory and .env file"
	@echo ""
	@read -p "  Type 'delete' to confirm: " confirm && [ "$$confirm" = "delete" ]
	@echo ""
	@echo "Emptying S3 bucket (all versions + delete markers) ..."
	@BUCKET=$$($(TF) output -raw job_run_backup_bucket 2>/dev/null | grep -E '^[a-z0-9][a-z0-9._-]{1,61}[a-z0-9]$$' || true); \
	if [ -n "$$BUCKET" ]; then \
	  python3 $(SCRIPTS_DIR)/empty_s3_bucket.py "$$BUCKET"; \
	else \
	  echo "  No S3 bucket in state — skipping."; \
	fi
	@echo ""
	@echo "Running terraform destroy ..."
	@echo ""
	$(TF) destroy -auto-approve
	@echo ""
	@echo "Cleaning local files ..."
	rm -rf $(GEN_DIR)
	rm -f .env
	> $(TF_DIR)/06_jobs_migrated.tf
	@echo ""
	@echo "Done. All resources destroyed and local files cleared."
	@echo "Run 'make init && make apply' to start fresh."
	@echo ""
