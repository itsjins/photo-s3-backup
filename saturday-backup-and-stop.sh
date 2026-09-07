#!/bin/bash

set -uo pipefail

BACKUP_DIR="/Users/songjin/project/photo-s3-backup"
IMMICH_DIR="/Users/songjin/docker/immich"

echo "=== Saturday Immich backup started ==="
date

echo
echo "Running S3 backup..."

if (
  cd "$BACKUP_DIR" &&
  ./backup.sh
); then
  echo
  echo "S3 backup completed successfully."
else
  rc=$?
  echo
  echo "ERROR: S3 backup failed with exit code $rc."
  echo "Immich will remain running."
  exit "$rc"
fi

echo
echo "Stopping Immich..."

if (
  cd "$IMMICH_DIR" &&
  docker compose stop -t 60
); then
  echo
  echo "Immich stopped successfully."
else
  rc=$?
  echo
  echo "ERROR: Backup succeeded, but Immich failed to stop."
  exit "$rc"
fi

echo
echo "=== Saturday workflow completed ==="
date
