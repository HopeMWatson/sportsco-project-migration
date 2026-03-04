# sportsco dbt Cloud — Project Deprecation & Consolidation

Collapses a legacy **val** dbt Cloud project into a single consolidated **prod** project, preserving run history and enforcing access controls on the archived project.

---

## What this does, in one paragraph

Before dbt Platform (fka dbt Cloud) had global connections, each warehouse connection required its own project. This repo automates the migration away from that pattern: it creates both projects via Terraform, snapshots the val project's jobs using `dbt-terraforming`, re-homes those jobs inside prod (on the val branch, in a dedicated environment), backs up the full run history to S3, triggers a validation run, and finally locks the val project down to `job_viewer`-only access so no one can accidentally trigger or modify anything in it.

---

## Prerequisites

| Tool | Version | Notes |
|---|---|---|
| Terraform | ≥ 1.5.0 | `brew install terraform` |
| AWS CLI | v2 | Authenticated via IAM role, `aws-vault`, or `AWS_PROFILE` |
| Python | 3.9+ | Used by helper scripts |
| pip packages | — | `pip install -r requirements.txt` |
| dbt Cloud account | Enterprise | job_viewer permission requires Enterprise plan |

You need AWS credentials in your shell with permission to:
- `secretsmanager:GetSecretValue` on `sportsco-project-migration/*`
- Full S3 access on the backup bucket
- Any IAM permissions your org requires for Terraform state

---

## Step 0 — One-time credential setup

### 0a. Create the two secrets in AWS Secrets Manager

Run these once in terminal. After this, no credentials ever live in a file.

```bash
# dbt Cloud API token
aws secretsmanager create-secret \
  --name "sportsco-project-migration/dbtcloud" \
  --description "dbt Cloud API token for sportsco project migration" \
  --secret-string '{"token":"dbtc_xxxxxxxxxxxxxxxxxxxxxxxxxxxx"}'

# Snowflake service account (keypair auth)
aws secretsmanager create-secret \
  --name "sportsco-project-migration/snowflake-svc" \
  --description "Snowflake service account keypair for dbt Cloud" \
  --secret-string "{\"user\":\"HOPE_MIGRATION_DBT_SVC_USER\",\"private_key\":\"$(cat snowflake_rsa.p8)\"}"
```

To rotate a secret later:
```bash
aws secretsmanager put-secret-value \
  --secret-id "sportsco-project-migration/dbtcloud" \
  --secret-string '{"token":"dbtc_new_token_here"}'
# Then just re-run make apply — the wrapper script always fetches the latest value.
```

The IAM policy your terraform role needs:
```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["secretsmanager:GetSecretValue"],
    "Resource": "arn:aws:secretsmanager:<region>:<account-id>:secret:sportsco-project-migration/*"
  }]
}
```

### 0b. Fill in `terraform/terraform.tfvars`

Copy the example and fill in **non-sensitive** values only. Secrets stay in Secrets Manager — do not put them here.

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
```

Edit `terraform/terraform.tfvars`:

```hcl
# ── dbt Cloud ──────────────────────────────────────────────────────────────
dbt_account_id = 123456          # find this in your Cloud URL:
                                  # cloud.getdbt.com/accounts/123456/
dbt_host_url   = "https://cloud.getdbt.com/api"
                                  # single-tenant: "https://YOUR_DOMAIN/api"

# ── AWS ────────────────────────────────────────────────────────────────────
aws_region     = "us-east-1"
s3_bucket_name = "sportsco-dbt-job-run-backups"   # must be globally unique

# ── Snowflake (config only — credentials are in Secrets Manager) ───────────
snowflake_account   = "xy12345.us-east-1"    # Snowflake account identifier
snowflake_database  = "sportsco_ANALYTICS"
snowflake_warehouse = "TRANSFORMING_WH"
snowflake_role      = "TRANSFORMER"

# ── GitHub ──────────────────────────────────────────────────────────────────
github_repo_url        = "git@github.com:dbt-labs/hope_watson_sandbox.git"
github_installation_id = 9876543             # Settings → Integrations in Cloud

# ── Branches ─────────────────────────────────────────────────────────────────
val_branch  = "val"    # the branch the old val project ran on
prod_branch = "main"   # the branch prod will eventually run on
```

> **Branch names** live in `terraform.tfvars` as `val_branch` and `prod_branch`.
> The defaults (`val` / `main`) are set in `variables.tf` — only override them here if your branch names differ.

### 0c. Install Python dependencies

```bash
pip install -r requirements.txt
```

---

## Credential flow at a glance

```
┌──────────────────────────────────────────────────────────────┐
│  What goes where                                             │
├──────────────────────────────┬───────────────────────────────┤
│  terraform/terraform.tfvars  │  Non-sensitive config only:   │
│  (committed after review)    │  account_id, warehouse, repo, │
│                              │  bucket name, branch names    │
├──────────────────────────────┼───────────────────────────────┤
│  AWS Secrets Manager         │  dbt Cloud token              │
│  sportsco-project-migration/      │  Snowflake user + password    │
│  dbtcloud, snowflake         │                               │
├──────────────────────────────┼───────────────────────────────┤
│  .env  (gitignored)          │  Project IDs, env IDs, bucket │
│  generated by               │  name — populated AFTER        │
│  export_env_secrets.sh       │  Phase 1 apply                │
└──────────────────────────────┴───────────────────────────────┘
```

**Terraform targets** (`make plan`, `make apply`, etc.) call `scripts/tf_with_secrets.sh` automatically — they fetch the secrets themselves, no sourcing needed.

**Python script targets** (`make backup-runs`, `make trigger-migrated`, etc.) read from environment variables. Populate your shell first:

```bash
# One-time per shell session (or after every token rotation):
source <(bash scripts/export_env_secrets.sh)

# Or write to .env so make picks it up automatically:
bash scripts/export_env_secrets.sh > .env
```

---

## Run order

### Phase 1a — Infrastructure

Creates both dbt Cloud projects, environments, Snowflake connections, sample val jobs, and the S3 backup bucket.

```bash
make init    # terraform init — downloads providers (dbt-labs/dbtcloud ~> 1.8, aws ~> 5.0)
make plan    # preview what will be created (fetches secrets automatically)
make apply   # create all resources
```

After apply, populate your shell with the output IDs:

```bash
bash scripts/export_env_secrets.sh > .env
# or: source <(bash scripts/export_env_secrets.sh)
```

> **Manual step required after `make apply`:**
>
> **Link the GitHub repository to each project**
>
> Terraform creates the repository record but cannot link it to the project — this must be done in the dbt Cloud UI:
> 1. **Account Settings → Projects → sportsco Analytics - Val (Deprecating)** → Edit → Repository → select **hope_watson_sandbox**
> 2. **Account Settings → Projects → sportsco Analytics - Prod** → Edit → Repository → select **hope_watson_sandbox**
>
> Jobs will not run until the repository is linked — runs will be Cancelled at the queue stage with "project does not have a Git repository configured".

---

### Phase 1b — Run val jobs

Trigger the val project's daily build and run jobs to produce at least one
round of run results and artifacts in dbt Cloud. The S3 backup in Phase 4
captures this run history — if no runs have occurred yet, the backup will be empty.

First, make sure your `.env` is current — `DBT_VAL_ENV_ID` was added in this
phase and won't be present in a `.env` generated before it existed:

```bash
bash scripts/export_env_secrets.sh > .env
```

Then trigger the jobs:

```bash
make trigger-val-jobs-dry  # confirm the right jobs will be triggered
make trigger-val-jobs       # trigger + wait for completion
```

Confirm in the dbt Cloud UI: **val project → Deploy → Runs** — you should see a
completed build run and a completed run before proceeding to Phase 4.

---

### Phase 2 — Snapshot val jobs with dbt-terraforming

Takes a live "image" of all job definitions in the val project and converts them into Terraform HCL that targets the prod project + val environment.

```bash
make terraform-image   # snapshot val jobs → generated/val_jobs_raw.tf
                       # (schedule=false and generate_docs=false forced at generation time)
make migrate-jobs      # re-targets project_id, environment_id → terraform/06_jobs_migrated.tf
```

**Review `terraform/06_jobs_migrated.tf` before proceeding.** Check that:
- `project_id` references `dbtcloud_project.prod.id`
- `environment_id` references `dbtcloud_environment.val_environment.environment_id`
- `triggers.schedule = false` on all jobs — jobs are always triggered on demand, never on a schedule
- `generate_docs = false` on all jobs — set at generation time; docs takes a long time to run and we don't want that. 

Once you've reviewed the file and are satisfied, proceed to Phase 3 to apply. Jobs will be active (state=1) but will not run on a schedule.

> **Note on job state:** dbt Cloud uses `state = 1` (active) and `state = 2` (deleted). There is no "inactive" state. Dormancy is controlled by `triggers.schedule = false` — the job exists and can be triggered manually but won't fire on its schedule.

---

### Phase 3 — Provision migrated jobs in prod

Applies the patched HCL to provision the migrated jobs inside the prod project's val environment.
This step is placing the `val` jobs into the `val env` within the `prod` project. 
It is NOT yet running the jobs. 

```bash
make apply-migrated-jobs
```

Verify in the dbt Cloud UI: **prod project → Environments → Val (Migrated from Val Project)** — you should see all your jobs listed. They are active (state=1) with schedule=false; jobs are triggered on demand only.

---

### Phase 4 — Back up val job run history to S3

Exports the full run history (all runs, all steps, trigger metadata) from the val project to the S3 bucket as JSON. This is the permanent audit trail that survives archival.

To preview what would be uploaded without actually uploading:
```bash
make backup-runs-dry
```

```bash
make backup-runs
```

S3 layout after backup:
```
s3://sportsco-dbt-job-run-backups/val-project-backup/<timestamp>/
  jobs_manifest.json         all job definitions at snapshot time
  summary.json               index: job → run count → s3 key
  runs/
    job_<id>_<name>.json     full run history per job
```

---

### Phase 5 — Validate: run migrated jobs

Trigger all jobs in the val environment and wait for completion. All jobs are already active (state=1) — no activation step needed. The trigger script fires all jobs in the environment that are state=1.

```bash
make trigger-migrated-dry  # list jobs in the val environment without triggering
# make trigger-migrated      # trigger all jobs in val environment + poll to completion
```

Confirm results in the dbt Cloud UI: **prod project → Runs**.

---

### Phase 6 — RBAC lockdown on val project

Once migration is validated, lock down the val project. Creates a **"Val Project — Archived (Job Viewer)"** group scoped to the val project only, auto-assigned to all users in the account.

**`job_viewer`** is the correct permission level here:
- ✅ Can view job run results, status, and logs (audit trail preserved)
- ❌ Cannot trigger jobs
- ❌ Cannot edit jobs, environments, or any settings

> ⚠️ **Account Admin and Account Owner roles always supersede group permissions.** Users with those roles retain full access to the val project regardless. There is no way to restrict account admins via group-level RBAC in dbt Cloud.

```bash
make rbac-lockdown   # prompts for confirmation, then applies 08_rbac.tf
```

After Terraform applies:

1. **Add existing non-SSO users** — `assign_by_default = true` covers new invites and SSO sign-ins automatically. For existing users who joined before this group was created, go to **Account Settings → Groups → Val Project — Archived (Job Viewer)** and add them manually.
2. **Strip write access from other groups** — for every group that previously had Developer/Admin access to the val project, edit that group in the UI and remove the val project from its permissions.

> You cannot remove group permissions that Terraform didn't create via `terraform destroy` alone — step 2 must be done in the UI for pre-existing groups.

---

## File reference

```
sportsco-project-migration/
├── terraform/
│   ├── 00_providers.tf         dbt-labs/dbtcloud ~> 1.8, AWS ~> 5.0
│   ├── variables.tf            all input variables (sensitive ones have no defaults)
│   ├── terraform.tfvars        YOUR non-sensitive values (gitignored)
│   ├── terraform.tfvars.example  template — copy to terraform.tfvars
│   ├── 01_projects.tf          val + prod dbt Cloud projects
│   ├── 02_repositories.tf      GitHub repos (both point at same monorepo)
│   ├── 03_connections.tf       Snowflake connections + credentials per project
│   ├── 04_environments.tf      val_deployment, prod_deployment, prod_val_environment
│   ├── 05_jobs_val.tf          sample val jobs (source of truth for dbt-terraforming)
│   ├── 06_jobs_migrated.tf     GENERATED by Phase 2 — review before apply
│   ├── 07_s3.tf                versioned + encrypted S3 bucket for run history backup
│   ├── 08_rbac.tf              job_viewer lockdown group for val project
│   ├── 09_secrets.tf           documents Secrets Manager structure + IAM policy
│   └── outputs.tf              project/env IDs + .env snippet
├── scripts/
│   ├── tf_with_secrets.sh      wraps terraform — fetches secrets, sets TF_VAR_*
│   ├── export_env_secrets.sh   prints export KEY=VALUE for shell/make use
│   ├── run_dbt_terraforming.sh    Phase 2: snapshot val jobs → generated/val_jobs_raw.tf
│   ├── patch_terraformed_jobs.py  Phase 2: re-target HCL for prod (called by make migrate-jobs)
│   ├── extract_job_runs.py        Phase 4: paginated API pull → S3
│   ├── trigger_migrated_jobs.py   Phase 5: trigger jobs on demand, poll to done
│   └── empty_s3_bucket.py         Teardown: delete all versions/markers so Terraform can remove bucket
├── generated/                  ephemeral dbt-terraforming output (gitignored)
├── Makefile                    single entry point — run `make help`
├── requirements.txt            boto3, requests, dbt-terraforming
└── .env.example                template for .env (IDs only, no secrets)
```

---

## Quick reference — all make targets

```bash
make help                # full target list with descriptions

# Phase 1 — Infrastructure
make init                # terraform init
make plan                # terraform plan (secrets fetched automatically)
make apply               # terraform apply
make outputs             # print project/env IDs
                         # ⚠ then manually link the GitHub repo to each project in dbt Cloud UI

# Credential loading (for Python targets)
make secrets             # print the source command
                         # then run: source <(bash scripts/export_env_secrets.sh)

# Phase 1b — Run val jobs
make trigger-val-jobs-dry  # list val jobs without triggering
make trigger-val-jobs      # run val project jobs to produce run history for backup

# Phase 2 — Snapshot val jobs
make terraform-image       # snapshot val jobs → generated/val_jobs_raw.tf
make migrate-jobs          # re-target val jobs for prod → terraform/06_jobs_migrated.tf

# Phase 3 — Provision migrated jobs in prod (active, schedule off)
make apply-migrated-jobs   # terraform apply (jobs active state=1, schedule = false)

# Phase 4 — Backup
make backup-runs-dry       # dry run (no upload)
make backup-runs           # export val run_results.json artifacts → S3 (last 90 days)

# Phase 5 — Validate
make trigger-migrated-dry  # list all jobs in val environment without triggering
make trigger-migrated      # trigger all jobs in val environment + poll to completion

# Phase 6 — Lockdown
make rbac-lockdown         # apply job_viewer RBAC to val project

# Utilities
make clean                 # remove generated/ directory
make delete-all            # destroy ALL cloud resources + wipe local files (prompts for confirmation)
```
