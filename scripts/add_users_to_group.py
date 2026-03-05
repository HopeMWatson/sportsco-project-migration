#!/usr/bin/env python3
"""
add_users_to_group.py  (Phase 6 — RBAC backfill)
-------------------------------------------------
Adds all existing account users to the Val Project — Archived (Job Viewer)
group created by `make rbac-lockdown`.

`assign_by_default = true` on the Terraform group covers NEW users only
(new invites and SSO sign-ins). This script backfills existing users.

For each user in the account, it:
  1. Reads their current group IDs from the list-users response.
  2. Adds the target group ID (if not already present).
  3. POSTs to /v3/accounts/{id}/assign-groups/ with the merged list.
     This endpoint sets the user's complete group list, so existing
     group memberships are preserved.

Usage:
    python scripts/add_users_to_group.py \\
        --account-id  123456 \\
        --group-id    <val_archived_readonly_group_id> \\
        --token       dbtc_xxxx \\
        [--host       https://cloud.getdbt.com/api] \\
        [--dry-run]

    The group ID is available after `make rbac-lockdown` via:
        terraform -chdir=terraform output val_archived_readonly_group_id

Requirements:
    pip install requests
"""

import argparse
import logging
import os
import sys

import requests

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-8s  %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%SZ",
)
log = logging.getLogger(__name__)

DEFAULT_HOST = "https://cloud.getdbt.com/api"


# ─── API helpers ──────────────────────────────────────────────────────────────

def make_session(token: str) -> requests.Session:
    s = requests.Session()
    s.headers.update({"Authorization": f"Token {token}", "Content-Type": "application/json"})
    return s


def list_users(session: requests.Session, host: str, account_id: int) -> list:
    """Fetch all users in the account via paginated GET /v2/accounts/{id}/users/."""
    log.info("Fetching all users in account %s …", account_id)
    url = f"{host.rstrip('/')}/v2/accounts/{account_id}/users/"
    all_users = []
    offset = 0
    limit  = 100

    while True:
        resp = session.get(url, params={"limit": limit, "offset": offset})
        resp.raise_for_status()
        body  = resp.json()
        chunk = body.get("data", [])
        if isinstance(chunk, dict):
            chunk = [chunk]
        all_users.extend(chunk)

        total = body.get("extra", {}).get("pagination", {}).get("total_count", len(all_users))
        if not chunk or len(all_users) >= total:
            break
        offset += limit

    log.info("Found %d user(s)", len(all_users))
    return all_users


def current_group_ids(user: dict, account_id: int) -> list:
    """
    Extract group IDs from the user object's permissions array,
    filtered to this account (a user may belong to multiple accounts).
    """
    ids = []
    for perm in user.get("permissions", []):
        if perm.get("account_id") == account_id:
            for grp in perm.get("groups", []):
                gid = grp.get("id")
                if gid:
                    ids.append(gid)
    return list(set(ids))


def assign_groups(session: requests.Session, host: str, account_id: int,
                  user_id: int, desired_group_ids: list) -> None:
    """
    POST /v3/accounts/{id}/assign-groups/
    Sets the user's complete group list (replaces, so existing groups must
    be included in desired_group_ids to be preserved).
    """
    url = f"{host.rstrip('/')}/v3/accounts/{account_id}/assign-groups/"
    resp = session.post(url, json={"user_id": user_id, "desired_group_ids": desired_group_ids})
    resp.raise_for_status()


# ─── Argument parsing ─────────────────────────────────────────────────────────

def parse_args():
    parser = argparse.ArgumentParser(
        description="Add all existing account users to the val RBAC group",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument("--account-id", required=True, type=int,
                        help="dbt Cloud account ID")
    parser.add_argument("--group-id",   required=True, type=int,
                        help="Target group ID (from: terraform output val_archived_readonly_group_id)")
    parser.add_argument("--token",      default=None,
                        help="dbt Cloud API token. Defaults to DBT_TOKEN env var.")
    parser.add_argument("--host",       default=DEFAULT_HOST,
                        help="dbt Cloud API host")
    parser.add_argument("--dry-run",    action="store_true",
                        help="Show what would change without making any API calls")
    return parser.parse_args()


# ─── Main ─────────────────────────────────────────────────────────────────────

def main():
    args  = parse_args()
    token = args.token or os.environ.get("DBT_TOKEN")
    if not token:
        sys.exit("ERROR: dbt Cloud token required — pass --token or set DBT_TOKEN env var")

    session = make_session(token)
    users   = list_users(session, args.host, args.account_id)

    already = 0
    updated = 0
    failed  = 0

    for user in users:
        uid   = user["id"]
        email = user.get("email", str(uid))
        cur   = current_group_ids(user, args.account_id)

        if args.group_id in cur:
            log.info("SKIP  %-45s  (already in group)", email)
            already += 1
            continue

        merged = sorted(set(cur) | {args.group_id})
        log.info("ADD   %-45s  %s → %s", email, cur or "[]", merged)

        if args.dry_run:
            continue

        try:
            assign_groups(session, args.host, args.account_id, uid, merged)
            updated += 1
        except requests.HTTPError as exc:
            log.error("FAIL  %s — %s", email, exc)
            failed += 1

    if args.dry_run:
        log.info("[DRY RUN] No changes made.")
        return

    log.info("Done.  added=%d  skipped=%d  failed=%d", updated, already, failed)
    if failed:
        sys.exit(1)


if __name__ == "__main__":
    main()
