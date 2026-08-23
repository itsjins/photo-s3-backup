#!/usr/bin/env bash

set -Eeuo pipefail

# Keep newly created logs private to the current user.
umask 077

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly CONFIG_FILE="${SCRIPT_DIR}/config.env"
readonly DEFAULT_LOG_DIR="${SCRIPT_DIR}/logs"

LOG_FILE=""

timestamp() {
  date '+%Y-%m-%d %H:%M:%S'
}

log() {
  local level="$1"
  shift

  local line
  printf -v line '%s [%s] %s' "$(timestamp)" "$level" "$*"
  printf '%s\n' "$line"

  if [[ -n "${LOG_FILE}" ]] && ! printf '%s\n' "$line" >>"${LOG_FILE}"; then
    printf '%s [ERROR] cannot write to log file: %s\n' "$(timestamp)" "$LOG_FILE" >&2
  fi
}

log_info() {
  log "INFO" "$@"
}

log_warn() {
  log "WARN" "$@"
}

log_error() {
  log "ERROR" "$@" >&2
}

fail() {
  log_error "$@"
  exit 1
}

on_error() {
  local exit_code="$1"
  local line_number="$2"

  trap - ERR
  log_error "unexpected error (exit ${exit_code}, line ${line_number})"
  exit "$exit_code"
}

trap 'on_error "$?" "$LINENO"' ERR

setup_log_file() {
  local requested_log_dir="$1"
  local resolved_log_dir

  if [[ "$requested_log_dir" == /* ]]; then
    resolved_log_dir="$requested_log_dir"
  else
    resolved_log_dir="${SCRIPT_DIR}/${requested_log_dir#./}"
  fi

  if ! mkdir -p -- "$resolved_log_dir"; then
    fail "cannot create log directory: ${resolved_log_dir}"
  fi

  if ! resolved_log_dir="$(cd -- "$resolved_log_dir" && pwd -P)"; then
    fail "cannot resolve log directory: ${resolved_log_dir}"
  fi

  LOG_FILE="${resolved_log_dir}/backup.log"
  if ! touch -- "$LOG_FILE"; then
    LOG_FILE=""
    fail "cannot create log file in: ${resolved_log_dir}"
  fi
}

load_config() {
  setup_log_file "$DEFAULT_LOG_DIR"

  if [[ ! -f "$CONFIG_FILE" ]]; then
    fail "config.env not found: ${CONFIG_FILE}"
  fi

  # Values must come from config.env rather than accidentally inherited variables.
  unset IMMICH_VOLUME_PATH IMMICH_UPLOAD_PATH IMMICH_COMPOSE_DIR POSTGRES_CONTAINER
  unset AWS_PROFILE S3_BUCKET LOG_DIR

  # config.env is a trusted, local shell configuration file and is never committed.
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
}

validate_config() {
  local variable_name
  local required_variables=(
    IMMICH_VOLUME_PATH
    IMMICH_UPLOAD_PATH
    IMMICH_COMPOSE_DIR
    POSTGRES_CONTAINER
    AWS_PROFILE
    S3_BUCKET
    LOG_DIR
  )

  for variable_name in "${required_variables[@]}"; do
    if [[ -z "${!variable_name-}" ]]; then
      fail "required configuration is missing or empty: ${variable_name}"
    fi
  done

  if [[ "$IMMICH_VOLUME_PATH" != /* ]]; then
    fail "IMMICH_VOLUME_PATH must be an absolute path"
  fi

  if [[ "$IMMICH_UPLOAD_PATH" != /* ]]; then
    fail "IMMICH_UPLOAD_PATH must be an absolute path"
  fi

  if [[ "$S3_BUCKET" == s3://* ]]; then
    fail "S3_BUCKET must be a bucket name without the s3:// prefix"
  fi
}

check_commands() {
  local command_name
  local required_commands=(docker aws diskutil plutil)

  for command_name in "${required_commands[@]}"; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      fail "required command not found: ${command_name}"
    fi
  done

  log_info "required commands are available"
}

check_volume() {
  local volume_path="${IMMICH_VOLUME_PATH%/}"
  local volume_info
  local actual_mount_point

  if [[ -z "$volume_path" ]]; then
    volume_path="/"
  fi

  if ! volume_info="$(diskutil info -plist "$volume_path" 2>/dev/null)"; then
    fail "backup volume is not mounted: ${volume_path}"
  fi

  if ! actual_mount_point="$(printf '%s' "$volume_info" | plutil -extract MountPoint raw - 2>/dev/null)"; then
    fail "cannot determine mount point for backup volume: ${volume_path}"
  fi

  actual_mount_point="${actual_mount_point%/}"
  if [[ -z "$actual_mount_point" ]]; then
    actual_mount_point="/"
  fi

  if [[ "$actual_mount_point" != "$volume_path" ]]; then
    fail "backup volume is not mounted: ${volume_path}"
  fi

  log_info "backup volume is mounted: ${volume_path}"
}

check_immich_path() {
  local volume_path="${IMMICH_VOLUME_PATH%/}"

  if [[ -z "$volume_path" ]]; then
    volume_path="/"
  fi

  case "$IMMICH_UPLOAD_PATH" in
    "$volume_path"/*) ;;
    *) fail "Immich upload path is outside the backup volume: ${IMMICH_UPLOAD_PATH}" ;;
  esac

  if [[ ! -d "$IMMICH_UPLOAD_PATH" ]]; then
    fail "Immich upload path is not a directory: ${IMMICH_UPLOAD_PATH}"
  fi

  if [[ ! -r "$IMMICH_UPLOAD_PATH" ]]; then
    fail "Immich upload path is not readable: ${IMMICH_UPLOAD_PATH}"
  fi

  log_info "Immich upload path is readable: ${IMMICH_UPLOAD_PATH}"
}

check_docker() {
  if ! docker info >/dev/null 2>&1; then
    fail "Docker daemon is unavailable"
  fi

  log_info "Docker daemon is available"
}

check_postgres() {
  local running
  local health_status

  if ! docker inspect "$POSTGRES_CONTAINER" >/dev/null 2>&1; then
    fail "PostgreSQL container does not exist: ${POSTGRES_CONTAINER}"
  fi

  if ! running="$(docker inspect --format '{{.State.Running}}' "$POSTGRES_CONTAINER" 2>/dev/null)"; then
    fail "cannot inspect PostgreSQL container: ${POSTGRES_CONTAINER}"
  fi

  if [[ "$running" != "true" ]]; then
    fail "PostgreSQL container is not running: ${POSTGRES_CONTAINER}"
  fi

  if health_status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}not-configured{{end}}' "$POSTGRES_CONTAINER" 2>/dev/null)"; then
    log_info "PostgreSQL container is running (health: ${health_status})"
  else
    log_info "PostgreSQL container is running"
  fi
}

check_aws_identity() {
  if ! AWS_PAGER="" aws sts get-caller-identity \
    --profile "$AWS_PROFILE" \
    --output json \
    >/dev/null 2>&1; then
    fail "AWS identity check failed for profile: ${AWS_PROFILE}"
  fi

  log_info "AWS identity check passed"
}

check_s3_access() {
  if ! AWS_PAGER="" aws s3api head-bucket \
    --bucket "$S3_BUCKET" \
    --profile "$AWS_PROFILE" \
    >/dev/null 2>&1; then
    fail "cannot access S3 bucket: ${S3_BUCKET}"
  fi

  log_info "S3 bucket access check passed"
}

main() {
  if (( $# != 0 )); then
    setup_log_file "$DEFAULT_LOG_DIR"
    fail "backup.sh does not accept command-line arguments"
  fi

  load_config
  validate_config
  setup_log_file "$LOG_DIR"

  log_info "backup pre-check started"
  check_commands
  check_volume
  check_immich_path
  check_docker
  check_postgres
  check_aws_identity
  check_s3_access
  log_info "All pre-checks passed. Backup can safely proceed."
}

main "$@"
