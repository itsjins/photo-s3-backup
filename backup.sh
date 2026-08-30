#!/bin/bash

set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${SCRIPT_DIR}/logs/backup.log"

mkdir -p "${SCRIPT_DIR}/logs"
exec >>"$LOG_FILE" 2>&1

trap 'status=$?; printf "%s FAILED line=%s status=%s\n" "$(date "+%Y-%m-%d %H:%M:%S")" "$LINENO" "$status"; exit "$status"' ERR

printf '%s START\n' "$(date '+%Y-%m-%d %H:%M:%S')"

# local file
source "${SCRIPT_DIR}/config.env"

DB_BACKUP_TEMP=""

finish() {
  local status="$?"
  local message="Photo backup failed (status ${status})"

  if [[ -n "$DB_BACKUP_TEMP" ]] && ! rm -f "$DB_BACKUP_TEMP"; then
    printf '%s ERROR could not remove temporary DB backup\n' "$(date '+%Y-%m-%d %H:%M:%S')"
  fi

  if (( status == 0 )); then
    message="Photo backup succeeded"
  fi

  if ! curl -fsS --max-time 15 -H 'Title: Photo S3 Backup' -d "$message" "$NTFY_TOPIC_URL" >/dev/null; then
    printf '%s ERROR ntfy notification failed\n' "$(date '+%Y-%m-%d %H:%M:%S')"
  fi

  exit "$status"
}

trap finish EXIT

if ! ACTUAL_MOUNT_POINT="$(diskutil info -plist "$IMMICH_VOLUME_PATH" 2>/dev/null | plutil -extract MountPoint raw - 2>/dev/null)"; then
  printf '%s ERROR external HDD is not mounted at %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$IMMICH_VOLUME_PATH"
  exit 1
fi

if [[ "${ACTUAL_MOUNT_POINT%/}" != "${IMMICH_VOLUME_PATH%/}" ]]; then
  printf '%s ERROR expected mount point %s, found %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$IMMICH_VOLUME_PATH" "$ACTUAL_MOUNT_POINT"
  exit 1
fi

printf '%s HDD mounted at %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$IMMICH_VOLUME_PATH"

DB_BACKUP_PATH="${DB_BACKUP_DIR%/}/${DB_BACKUP_PREFIX}.sql.gz"
DB_BACKUP_TEMP="${DB_BACKUP_PATH}.tmp"

printf '%s DB dump started\n' "$(date '+%Y-%m-%d %H:%M:%S')"
if ! docker exec "$POSTGRES_CONTAINER" \
  pg_dump \
  --clean \
  --if-exists \
  --dbname="$DB_DATABASE_NAME" \
  --username="$DB_USERNAME" \
  | gzip >"$DB_BACKUP_TEMP"; then
  printf '%s ERROR DB dump failed; confirm Docker Desktop is running and container %s is accessible\n' \
    "$(date '+%Y-%m-%d %H:%M:%S')" "$POSTGRES_CONTAINER"
  exit 1
fi

gzip -t "$DB_BACKUP_TEMP"
mv -f "$DB_BACKUP_TEMP" "$DB_BACKUP_PATH"
DB_BACKUP_TEMP=""
printf '%s DB backup replaced: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$DB_BACKUP_PATH"

printf '%s S3 sync started\n' "$(date '+%Y-%m-%d %H:%M:%S')"
AWS_PAGER="" aws s3 sync \
  "${IMMICH_UPLOAD_PATH%/}/" \
  "s3://${S3_BUCKET}/${S3_PREFIX%/}/" \
  --profile "$AWS_PROFILE" \
  --exclude 'thumbs/*' \
  --exclude 'encoded-video/*' \
  --no-follow-symlinks \
  --only-show-errors

trap - ERR
printf '%s SUCCESS\n' "$(date '+%Y-%m-%d %H:%M:%S')"
