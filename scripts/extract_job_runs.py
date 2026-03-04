#!/usr/bin/env python3
"""
extract_job_runs.py
-------------------
Backs up run_results.json artifacts from the val dbt Cloud project to S3,
limited to runs completed within the last N days (default: 90).

For each job in the project, the script:
  1. Fetches the job's run history (most-recent-first) until runs fall
     outside the lookback window — no over-fetching.
  2. For each qualifying run, downloads the run_results.json artifact
     from the dbt Cloud API and uploads it to S3.

S3 layout produced:
  s3://<bucket>/<prefix>/
    jobs_manifest.json                  all job definitions at snapshot time
    summary.json                        index: job → runs → artifacts uploaded
    artifacts/
      job_<id>_<safe_name>/
        run_<run_id>_run_results.json   one artifact per run

Usage:
    python scripts/extract_job_runs.py \\
        --account-id      123456 \\
        --project-id      789012 \\
        --bucket          sportsco-dbt-job-run-backups \\
        [--days           90]           # lookback window (default: 90)
        [--concurrency    5]            # parallel workers (default: 5)
        [--limit-jobs     10]           # only process first N jobs (testing)
        [--resume]                      # skip jobs already in checkpoint
        [--checkpoint-file PATH]
        [--prefix         val-project-backup/2024-01-15]
        [--dry-run]

Requirements:
    pip install boto3 requests
"""

import argparse
import json
import logging
import os
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timedelta, timezone
from functools import wraps
from pathlib import Path
from threading import Lock

import boto3
import requests

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-8s  %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%SZ",
)
log = logging.getLogger(__name__)

_progress_lock = Lock()
_completed = 0


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


def get_jobs(session, host, account_id, project_id) -> list:
    log.info("Fetching all jobs for project %s …", project_id)
    url = f"{host.rstrip('/')}/v2/accounts/{account_id}/jobs/"
    all_jobs, offset, page_size = [], 0, 100
    while True:
        body = _get_page(session, url, {"project_id": project_id, "limit": page_size, "offset": offset})
        chunk = body.get("data", [])
        all_jobs.extend(chunk)
        total = body.get("extra", {}).get("pagination", {}).get("total_count", len(all_jobs))
        if not chunk or len(all_jobs) >= total:
            break
        offset += page_size
    log.info("Found %d job(s) in project %s", len(all_jobs), project_id)
    return all_jobs


def parse_run_date(run: dict) -> datetime | None:
    """Return the run's created_at as a UTC-aware datetime, or None if unparseable."""
    raw = run.get("created_at") or run.get("started_at")
    if not raw:
        return None
    try:
        return datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError:
        return None


def get_recent_runs(session, host, account_id, job_id, cutoff: datetime) -> list:
    """
    Fetch runs for a job ordered most-recent-first, stopping as soon as a run
    falls outside the cutoff window. Avoids fetching the full history.
    """
    url = f"{host.rstrip('/')}/v2/accounts/{account_id}/runs/"
    recent, offset, page_size = [], 0, 100

    while True:
        body = _get_page(session, url, {
            "job_definition_id": job_id,
            "order_by":          "-id",
            "limit":             page_size,
            "offset":            offset,
        })
        chunk = body.get("data", [])
        if not chunk:
            break

        stop_early = False
        for run in chunk:
            run_date = parse_run_date(run)
            if run_date is not None and run_date < cutoff:
                stop_early = True
                break
            recent.append(run)

        if stop_early:
            break

        total = body.get("extra", {}).get("pagination", {}).get("total_count", len(recent))
        if len(recent) >= total:
            break
        offset += page_size

    return recent


@with_retry()
def get_run_results_artifact(session: requests.Session, host: str,
                              account_id: int, run_id: int) -> dict | None:
    """
    Download run_results.json for a completed run.
    Returns None if the artifact does not exist (run may have errored before dbt ran).
    """
    url = f"{host.rstrip('/')}/v2/accounts/{account_id}/runs/{run_id}/artifacts/run_results.json"
    resp = session.get(url)
    if resp.status_code == 404:
        return None
    resp.raise_for_status()
    return resp.json()


# ─── Checkpoint helpers ───────────────────────────────────────────────────────

def load_checkpoint(path: Path) -> set:
    if path.exists():
        data = json.loads(path.read_text())
        ids = set(int(i) for i in data.get("completed_job_ids", []))
        log.info("Checkpoint loaded: %d job(s) already completed", len(ids))
        return ids
    return set()


def save_checkpoint(path: Path, completed_ids: set) -> None:
    path.write_text(json.dumps({"completed_job_ids": sorted(completed_ids)}, indent=2))


# ─── S3 helpers ───────────────────────────────────────────────────────────────

def upload_json(s3_client, bucket: str, key: str, data, dry_run: bool) -> None:
    body = json.dumps(data, indent=2, default=str).encode("utf-8")
    size_kb = len(body) / 1024
    if dry_run:
        log.info("[DRY RUN] s3://%s/%s  (%.1f KB)", bucket, key, size_kb)
        return
    s3_client.put_object(Bucket=bucket, Key=key, Body=body, ContentType="application/json")
    log.info("Uploaded %.1f KB → s3://%s/%s", size_kb, bucket, key)


# ─── Per-job worker ───────────────────────────────────────────────────────────

def process_job(job: dict, *, token: str, host: str, account_id: int,
                bucket: str, prefix: str, cutoff: datetime,
                dry_run: bool, total_jobs: int) -> dict:
    """
    For a single job: fetch runs within the lookback window, download
    run_results.json for each, and upload to S3.
    Runs in a thread-pool worker — creates its own session for thread safety.
    """
    global _completed

    job_id   = job["id"]
    job_name = job.get("name", f"job_{job_id}")
    safe     = (job_name.lower()
                .replace(" ", "_").replace("/", "_")
                .replace("→", "to").replace("—", "-"))[:60]
    job_dir  = f"{prefix}/artifacts/job_{job_id}_{safe}"

    session = make_session(token)
    s3      = boto3.client("s3")

    # Fetch only runs within the lookback window
    recent_runs = get_recent_runs(session, host, account_id, job_id, cutoff)
    log.info("Job %s (%s): %d run(s) in window", job_id, job_name, len(recent_runs))

    uploaded_keys = []
    missing_artifact = 0

    for run in recent_runs:
        run_id   = run["id"]
        artifact = get_run_results_artifact(session, host, account_id, run_id)

        if artifact is None:
            missing_artifact += 1
            log.debug("No run_results.json for run %s (job %s) — skipping", run_id, job_id)
            continue

        s3_key = f"{job_dir}/run_{run_id}_run_results.json"
        upload_json(s3, bucket, s3_key, artifact, dry_run=dry_run)
        uploaded_keys.append(s3_key)

    with _progress_lock:
        _completed += 1
        if _completed % 10 == 0 or _completed == total_jobs:
            log.info("Progress: %d / %d jobs (%.0f%%)",
                     _completed, total_jobs, 100 * _completed / total_jobs)

    return {
        "job_id":             job_id,
        "job_name":           job_name,
        "runs_in_window":     len(recent_runs),
        "artifacts_uploaded": len(uploaded_keys),
        "missing_artifact":   missing_artifact,
        "s3_keys":            uploaded_keys,
    }


# ─── Argument parsing ─────────────────────────────────────────────────────────

def parse_args():
    p = argparse.ArgumentParser(
        description="Back up run_results.json artifacts from val project to S3",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    p.add_argument("--account-id",      required=True, type=int)
    p.add_argument("--project-id",      required=True, type=int)
    p.add_argument("--token",           default=None,
                   help="dbt Cloud API token. Defaults to DBT_TOKEN env var.")
    p.add_argument("--bucket",          required=True)
    p.add_argument("--host",            default="https://cloud.getdbt.com/api")
    p.add_argument("--days",            type=int, default=90,
                   help="Lookback window in days. Only runs completed within this "
                        "many days are backed up.")
    p.add_argument("--prefix",          default=None,
                   help="S3 key prefix (default: val-project-backup/<UTC timestamp>)")
    p.add_argument("--concurrency",     type=int, default=5,
                   help="Parallel workers for fetching + uploading")
    p.add_argument("--limit-jobs",      type=int, default=None,
                   help="Only process the first N jobs (testing / incremental)")
    p.add_argument("--resume",          action="store_true",
                   help="Skip jobs already recorded in the checkpoint file")
    p.add_argument("--checkpoint-file", default=".extract_checkpoint.json",
                   help="Local file tracking completed job IDs for resume support")
    p.add_argument("--dry-run",         action="store_true",
                   help="Fetch and count artifacts but do not upload to S3")
    return p.parse_args()


# ─── Main ─────────────────────────────────────────────────────────────────────

def main():
    args = parse_args()

    token = args.token or os.environ.get("DBT_TOKEN")
    if not token:
        sys.exit("ERROR: dbt Cloud token required — pass --token or set DBT_TOKEN env var")
    args.token = token

    cutoff    = datetime.now(timezone.utc) - timedelta(days=args.days)
    timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H-%M-%SZ")
    prefix    = args.prefix or f"val-project-backup/{timestamp}"

    log.info("Snapshot prefix:   s3://%s/%s/", args.bucket, prefix)
    log.info("Lookback window:   last %d days (since %s)", args.days,
             cutoff.strftime("%Y-%m-%d"))
    log.info("Concurrency:       %d workers", args.concurrency)

    checkpoint_path = Path(args.checkpoint_file)
    completed_ids   = load_checkpoint(checkpoint_path) if args.resume else set()

    # ── 1. Fetch all job definitions ─────────────────────────────────────────
    root_session = make_session(args.token)
    all_jobs     = get_jobs(root_session, args.host, args.account_id, args.project_id)

    if not all_jobs:
        log.warning("No jobs found — nothing to back up.")
        sys.exit(0)

    jobs_to_process = all_jobs[: args.limit_jobs] if args.limit_jobs else all_jobs

    if args.resume and completed_ids:
        before = len(jobs_to_process)
        jobs_to_process = [j for j in jobs_to_process if j["id"] not in completed_ids]
        log.info("Resuming: skipping %d already-completed job(s), %d remaining",
                 before - len(jobs_to_process), len(jobs_to_process))

    if not jobs_to_process:
        log.info("All jobs already completed — nothing to do.")
        sys.exit(0)

    # Upload job manifest
    s3_root = boto3.client("s3")
    upload_json(
        s3_root, args.bucket,
        f"{prefix}/jobs_manifest.json",
        {"exported_at": timestamp, "project_id": args.project_id,
         "days": args.days, "cutoff": cutoff.isoformat(),
         "total_jobs": len(all_jobs), "jobs": all_jobs},
        dry_run=args.dry_run,
    )

    # ── 2. Fetch runs + upload artifacts concurrently ─────────────────────────
    total = len(jobs_to_process)
    log.info("Processing %d job(s) with %d worker(s) …", total, args.concurrency)

    summary     = []
    failed_jobs = []

    with ThreadPoolExecutor(max_workers=args.concurrency) as pool:
        future_to_job = {
            pool.submit(
                process_job, job,
                token      = args.token,
                host       = args.host,
                account_id = args.account_id,
                bucket     = args.bucket,
                prefix     = prefix,
                cutoff     = cutoff,
                dry_run    = args.dry_run,
                total_jobs = total,
            ): job
            for job in jobs_to_process
        }

        for future in as_completed(future_to_job):
            job = future_to_job[future]
            try:
                result = future.result()
                summary.append(result)
                completed_ids.add(job["id"])
                if not args.dry_run:
                    save_checkpoint(checkpoint_path, completed_ids)
            except Exception as exc:
                log.error("FAILED job %s (%s): %s", job["id"], job.get("name"), exc)
                failed_jobs.append({
                    "job_id":   job["id"],
                    "job_name": job.get("name"),
                    "error":    str(exc),
                })

    # ── 3. Upload summary ─────────────────────────────────────────────────────
    total_artifacts = sum(r["artifacts_uploaded"] for r in summary)
    total_runs      = sum(r["runs_in_window"] for r in summary)

    upload_json(
        s3_root, args.bucket,
        f"{prefix}/summary.json",
        {
            "exported_at":       timestamp,
            "account_id":        args.account_id,
            "project_id":        args.project_id,
            "days":              args.days,
            "cutoff":            cutoff.isoformat(),
            "total_jobs":        len(all_jobs),
            "processed_jobs":    len(summary),
            "failed_jobs":       len(failed_jobs),
            "total_runs":        total_runs,
            "total_artifacts":   total_artifacts,
            "jobs":              summary,
            "failures":          failed_jobs,
        },
        dry_run=args.dry_run,
    )

    if failed_jobs:
        log.warning("%d job(s) failed. Re-run with --resume to retry.", len(failed_jobs))
        for f in failed_jobs:
            log.warning("  FAILED: %s (id=%s) — %s", f["job_name"], f["job_id"], f["error"])

    log.info(
        "Done. %d run_results.json artifact(s) across %d run(s) in %d job(s) "
        "→ s3://%s/%s/  (%d job(s) failed)",
        total_artifacts, total_runs, len(summary), args.bucket, prefix, len(failed_jobs),
    )


if __name__ == "__main__":
    main()
