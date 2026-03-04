#!/usr/bin/env python3
"""
trigger_migrated_jobs.py  (Phase 5)
------------------------------------
Triggers all active migrated val jobs in the prod project's val environment.

Only jobs whose name starts with "[Val→Prod]" and whose is_active == true
are triggered. Jobs created dark (is_active = false) are logged and skipped.

This validates the migration end-to-end: each job runs on the val branch,
in the prod_val_environment, inside the prod project — exactly matching
the execution profile of the deprecated val project.

Designed for large accounts (1,000–10,000+ migrated jobs):
  • Exponential backoff retry on 429 rate-limit and 5xx server errors
  • Paginated job listing — fetches all matching jobs, not just the first 100
  • --delay N   adds a pause between trigger calls (gentle on the scheduler)
  • --dry-run   lists matching jobs without triggering anything

Usage:
    python scripts/trigger_migrated_jobs.py \\
        --account-id     123456 \\
        --project-id     <prod_project_id> \\
        --environment-id <prod_val_environment_id> \\
        --token          dbtc_xxxx \\
        [--cause         "Migration validation run"] \\
        [--wait]                 # poll until each run completes \\
        [--delay         2]      # seconds between trigger calls (default 2) \\
        [--poll-interval 15]     # seconds between status polls (default 15) \\
        [--max-wait      1800]   # max seconds to wait per run (default 1800) \\
        [--dry-run]              # list matching jobs without triggering

Requirements:
    pip install requests
"""

import argparse
import logging
import os
import sys
import time
from functools import wraps

import requests

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-8s  %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%SZ",
)
log = logging.getLogger(__name__)

DEFAULT_NAME_PREFIX = "[Val→Prod]"


# ─── Retry decorator ──────────────────────────────────────────────────────────

def with_retry(max_attempts: int = 5, base_delay: float = 2.0, max_delay: float = 120.0):
    """Exponential backoff retry for 429 rate-limit and 5xx server errors."""
    def decorator(fn):
        @wraps(fn)
        def wrapper(*args, **kwargs):
            for attempt in range(max_attempts):
                try:
                    return fn(*args, **kwargs)
                except requests.exceptions.HTTPError as exc:
                    status = exc.response.status_code if exc.response is not None else 0
                    if status == 429:
                        retry_after = int(exc.response.headers.get("Retry-After", 0))
                        delay = max(retry_after, min(base_delay * (2 ** attempt), max_delay))
                        log.warning("429 rate-limited — waiting %.0fs (attempt %d/%d) …",
                                    delay, attempt + 1, max_attempts)
                        time.sleep(delay)
                    elif status >= 500:
                        delay = min(base_delay * (2 ** attempt), max_delay)
                        log.warning("%d server error — retrying in %.0fs (attempt %d/%d) …",
                                    status, delay, attempt + 1, max_attempts)
                        time.sleep(delay)
                    else:
                        raise
                except requests.exceptions.RequestException as exc:
                    delay = min(base_delay * (2 ** attempt), max_delay)
                    log.warning("Request error: %s — retrying in %.0fs (attempt %d/%d) …",
                                exc, delay, attempt + 1, max_attempts)
                    time.sleep(delay)
            raise RuntimeError(f"Exhausted {max_attempts} retry attempts")
        return wrapper
    return decorator


# ─── dbt Cloud API helpers ────────────────────────────────────────────────────

def make_session(token: str) -> requests.Session:
    s = requests.Session()
    s.headers.update({"Authorization": f"Token {token}", "Content-Type": "application/json"})
    return s


@with_retry()
def _get_page(session: requests.Session, url: str, params: dict) -> dict:
    resp = session.get(url, params=params)
    resp.raise_for_status()
    return resp.json()


def dbt_get_paginated(session: requests.Session, host: str, path: str,
                      params: dict = None, max_records: int = None) -> list:
    """
    GET from dbt Cloud API with transparent offset pagination and retry.
    max_records: stop after collecting this many records (None = fetch all).
    Page size is capped at 100 — the dbt Cloud API maximum.
    """
    url = f"{host.rstrip('/')}{path}"
    all_data = []
    page_size = 100
    offset = 0

    while True:
        remaining = None
        if max_records is not None:
            remaining = max_records - len(all_data)
            if remaining <= 0:
                break

        this_limit = min(page_size, remaining) if remaining is not None else page_size
        merged = {"limit": this_limit, "offset": offset, **(params or {})}
        body = _get_page(session, url, merged)

        chunk = body.get("data", [])
        if isinstance(chunk, dict):
            return [chunk]
        all_data.extend(chunk)

        total = body.get("extra", {}).get("pagination", {}).get("total_count", len(all_data))
        if not chunk or len(all_data) >= total:
            break
        offset += page_size

    return all_data


def get_jobs(session: requests.Session, host: str, account_id: int,
             project_id: int, environment_id: int) -> list:
    """Fetch ALL jobs in the given project + environment (paginated)."""
    log.info("Fetching all jobs for project %s, environment %s …", project_id, environment_id)
    jobs = dbt_get_paginated(
        session, host,
        f"/v2/accounts/{account_id}/jobs/",
        params={"project_id": project_id, "environment_id": environment_id},
    )
    log.info("Found %d total job(s) in environment %s", len(jobs), environment_id)
    return jobs


@with_retry()
def trigger_job(session: requests.Session, host: str, account_id: int,
                job_id: int, cause: str) -> dict:
    url = f"{host.rstrip('/')}/v2/accounts/{account_id}/jobs/{job_id}/run/"
    resp = session.post(url, json={"cause": cause})
    resp.raise_for_status()
    return resp.json().get("data", {})


def poll_run(session: requests.Session, host: str, account_id: int,
             run_id: int, interval: int = 15, max_wait: int = 1800) -> dict | None:
    """Poll a run until it reaches a terminal state or max_wait is exceeded."""
    url = f"{host.rstrip('/')}/v2/accounts/{account_id}/runs/{run_id}/"
    elapsed = 0

    while elapsed < max_wait:
        try:
            resp = session.get(url)
            resp.raise_for_status()
            run = resp.json().get("data", {})
        except requests.exceptions.RequestException as exc:
            log.warning("Poll error for run %s: %s — retrying …", run_id, exc)
            time.sleep(interval)
            elapsed += interval
            continue

        status = run.get("status_humanized", "Running")
        log.info("    run %-8s  status: %s", run_id, status)

        if run.get("is_complete"):
            return run

        time.sleep(interval)
        elapsed += interval

    log.warning("Run %s did not complete within %ds — leaving in flight.", run_id, max_wait)
    return None


# ─── Argument parsing ─────────────────────────────────────────────────────────

def parse_args():
    parser = argparse.ArgumentParser(
        description="Trigger migrated val jobs in prod project's val environment",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument("--account-id",     required=True, type=int)
    parser.add_argument("--project-id",     required=True, type=int,
                        help="prod project ID")
    parser.add_argument("--environment-id", required=True, type=int,
                        help="prod_val_environment ID")
    parser.add_argument("--token",          default=None,
                        help="dbt Cloud API token. Defaults to DBT_TOKEN env var.")
    parser.add_argument("--host",           default="https://cloud.getdbt.com/api")
    parser.add_argument("--cause",
                        default="Phase 5 migration validation — triggered by trigger_migrated_jobs.py")
    parser.add_argument("--wait",           action="store_true",
                        help="Poll until each run completes before triggering the next")
    parser.add_argument("--delay",          type=float, default=2.0,
                        help="Seconds to wait between trigger calls (avoids scheduler overload)")
    parser.add_argument("--poll-interval",  type=int, default=15,
                        help="Seconds between status polls when --wait is set")
    parser.add_argument("--max-wait",       type=int, default=1800,
                        help="Max seconds to wait per run before giving up (--wait only)")
    parser.add_argument("--name-prefix",    default=DEFAULT_NAME_PREFIX,
                        help="Only trigger jobs whose name starts with this prefix. "
                             "Pass an empty string to trigger all active jobs in the environment.")
    parser.add_argument("--dry-run",        action="store_true",
                        help="List matching active jobs without triggering them")
    return parser.parse_args()


# ─── Main ─────────────────────────────────────────────────────────────────────

def main():
    args = parse_args()

    token = args.token or os.environ.get("DBT_TOKEN")
    if not token:
        sys.exit("ERROR: dbt Cloud token required — pass --token or set DBT_TOKEN env var")

    session = make_session(token)

    # ── 1. Fetch all jobs in prod_val_environment (paginated) ─────────────────
    all_jobs = get_jobs(session, args.host, args.account_id,
                        args.project_id, args.environment_id)

    prefix = args.name_prefix
    if prefix:
        migrated = [j for j in all_jobs if j.get("name", "").startswith(prefix)]
        log.info("Matched %d job(s) with prefix '%s' out of %d total",
                 len(migrated), prefix, len(all_jobs))
    else:
        migrated = all_jobs
        log.info("No name filter applied — matched all %d job(s) in environment", len(migrated))

    if not migrated:
        log.warning(
            "No jobs found matching prefix '%s'. Check the project/environment IDs "
            "and that jobs exist.", prefix
        )
        sys.exit(0)

    active   = [j for j in migrated if j.get("state", 2) == 1]
    inactive = [j for j in migrated if j.get("state", 2) != 1]

    log.info("%d active, %d inactive (dark) out of %d matched", len(active), len(inactive), len(migrated))
    for j in inactive:
        log.info("SKIP  [inactive] %s  (id=%s)", j["name"], j["id"])

    if not active:
        log.info("No active jobs to trigger. Ensure is_active = true in the job's "
                 "Terraform config and re-apply.")
        sys.exit(0)

    # ── 2. Trigger (or dry-run) active migrated jobs ──────────────────────────
    if args.dry_run:
        log.info("[DRY RUN] Would trigger %d job(s):", len(active))
        for j in active:
            log.info("  %s  (id=%s)", j["name"], j["id"])
        sys.exit(0)

    results      = []
    failed_count = 0

    for idx, job in enumerate(active, start=1):
        job_id   = job["id"]
        job_name = job["name"]

        log.info("[%d/%d] Triggering: %s  (id=%s)", idx, len(active), job_name, job_id)

        try:
            run_data = trigger_job(session, args.host, args.account_id, job_id, args.cause)
        except Exception as exc:
            log.error("FAILED to trigger %s (id=%s): %s", job_name, job_id, exc)
            results.append({"job": job_name, "job_id": job_id, "run_id": None, "status": "trigger_failed"})
            failed_count += 1
            continue

        run_id = run_data.get("id")
        log.info("  → run %s created", run_id)

        if args.wait and run_id:
            final = poll_run(
                session, args.host, args.account_id, run_id,
                interval=args.poll_interval,
                max_wait=args.max_wait,
            )
            if final:
                outcome = "success" if final.get("is_success") else "failed"
                if outcome == "failed":
                    failed_count += 1
                log.info("  → run %s finished: %s", run_id, outcome.upper())
                results.append({"job": job_name, "job_id": job_id, "run_id": run_id, "status": outcome})
            else:
                results.append({"job": job_name, "job_id": job_id, "run_id": run_id, "status": "timeout"})
        else:
            results.append({"job": job_name, "job_id": job_id, "run_id": run_id, "status": "triggered"})

        # Pause between triggers — avoids overwhelming the dbt Cloud scheduler
        if idx < len(active) and args.delay > 0:
            time.sleep(args.delay)

    # ── 3. Summary ────────────────────────────────────────────────────────────
    print("")
    print("Trigger summary:")
    print(f"  {'Job':<55}  {'Run ID':<10}  Status")
    print(f"  {'-'*55}  {'-'*10}  ------")
    for r in results:
        print(f"  {r['job']:<55}  {str(r.get('run_id') or '—'):<10}  {r['status']}")
    print("")

    triggered = [r for r in results if r["status"] not in ("trigger_failed", "skipped_inactive")]
    log.info(
        "Done. Triggered %d/%d active migrated jobs. %d failure(s).",
        len(triggered), len(active), failed_count,
    )

    if failed_count:
        log.warning("%d job(s) ended in an error state. Check the dbt Cloud UI for details.", failed_count)
        sys.exit(1)


if __name__ == "__main__":
    main()
