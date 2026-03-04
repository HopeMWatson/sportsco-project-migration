#!/usr/bin/env python3
"""
empty_s3_bucket.py  (called by make delete-all)
------------------------------------------------
Deletes all object versions and delete markers from a versioned S3 bucket
so that Terraform can then delete the bucket itself.

Handles pagination automatically — safe for buckets with any number of objects.

Usage:
    python scripts/empty_s3_bucket.py <bucket-name>
"""

import sys
import boto3


def main():
    if len(sys.argv) != 2:
        print("Usage: python scripts/empty_s3_bucket.py <bucket-name>", file=sys.stderr)
        sys.exit(1)

    bucket_name = sys.argv[1]
    print(f"  Emptying s3://{bucket_name} (all versions + delete markers) ...")

    bucket = boto3.resource("s3").Bucket(bucket_name)
    responses = bucket.object_versions.delete()

    count = sum(len(r.get("Deleted", [])) for r in responses) if responses else 0
    errors = sum(len(r.get("Errors", [])) for r in responses) if responses else 0

    print(f"  Deleted {count} version(s)/marker(s).")

    if errors:
        print(f"  WARNING: {errors} deletion error(s) — bucket may not be fully empty.", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
