#!/usr/bin/env bash
set -Eeuo pipefail

log() {
  printf '[podman-sync-secrets] %s\n' "$*" >&2
}

fail() {
  log "ERROR: $*"
  exit 1
}

on_error() {
  local exit_code="$?"
  log "ERROR: Command failed at line ${BASH_LINENO[0]}"
  exit "${exit_code}"
}

trap on_error ERR

resolve_repo_root() {
  local search_dir
  search_dir="${PODMAN_REPO_ROOT:-$(pwd -P)}"

  while [[ "${search_dir}" != "/" ]]; do
    if [[ -d "${search_dir}/.git" && -f "${search_dir}/.devcontainer/podman-secrets.conf" ]]; then
      printf '%s' "${search_dir}"
      return
    fi

    search_dir="$(dirname -- "${search_dir}")"
  done

  fail "Unable to locate repository root from $(pwd -P)"
}

require_command() {
  local command_name="$1"
  command -v "${command_name}" >/dev/null 2>&1 || fail "Missing required command: ${command_name}"
}

is_aws_credentials_error() {
  local output="$1"

  case "${output}" in
    *"Error when retrieving token from sso"*|    *"The SSO session associated with this profile has expired or is otherwise invalid"*|    *"Token has expired and refresh failed"*|    *"Unable to locate credentials"*|    *"Unable to find credentials"*|    *"NoCredentialsError"*|    *"ExpiredToken"*|    *"ExpiredTokenException"*|    *"InvalidClientTokenId"*|    *"UnrecognizedClientException"*)
      return 0
      ;;
  esac

  return 1
}

run_aws() {
  local output status
  set +e
  output="$(aws "$@" 2>&1)"
  status=$?
  set -e

  (( status == 0 )) && { printf '%s' "${output}"; return 0; }
  is_aws_credentials_error "${output}" && fail "AWS credentials were not found or have expired. Run: aws sso login --sso-session guidion"
  fail "Command failed: aws $*${output:+$'\n'${output}}"
}

resolve_podman_command() {
  if [[ -n "${PODMAN_CMD:-}" ]]; then
    command -v "${PODMAN_CMD}" >/dev/null 2>&1 || fail "Configured PODMAN_CMD not found on PATH: ${PODMAN_CMD}"
    printf '%s' "${PODMAN_CMD}"
    return
  fi

  if command -v podman >/dev/null 2>&1; then
    printf 'podman'
    return
  fi

  if command -v podman-remote >/dev/null 2>&1; then
    printf 'podman-remote'
    return
  fi

  if command -v podman-remote-static-linux_amd64 >/dev/null 2>&1; then
    printf 'podman-remote-static-linux_amd64'
    return
  fi

  fail "Missing required command: podman, podman-remote, or podman-remote-static-linux_amd64"
}

normalize_env_name() {
  local raw_name="$1"
  local normalized

  normalized="$(printf '%s' "${raw_name}" \
    | tr '[:lower:]' '[:upper:]' \
    | sed -E 's/[^A-Z0-9]+/_/g; s/^_+//; s/_+$//; s/_+/_/g')"

  [[ -n "${normalized}" ]] || fail "Unable to derive environment variable name from secret key '${raw_name}'"
  printf '%s' "${normalized}"
}

load_config_file() {
  local config_file="$1"
  local line_number=0
  local line key value

  while IFS= read -r line || [[ -n "${line}" ]]; do
    line_number=$((line_number + 1))

    [[ -n "${line}" ]] || continue
    [[ "${line}" =~ ^[[:space:]]*# ]] && continue
    [[ "${line}" =~ ^[A-Z_][A-Z0-9_]*= ]] || fail "Invalid config entry at ${config_file}:${line_number}. Expected KEY=VALUE with uppercase shell-safe names."

    key="${line%%=*}"
    value="${line#*=}"

    if [[ ${#value} -ge 2 ]]; then
      if [[ "${value:0:1}" == '"' && "${value: -1}" == '"' ]]; then
        value="${value:1:${#value}-2}"
      elif [[ "${value:0:1}" == "'" && "${value: -1}" == "'" ]]; then
        value="${value:1:${#value}-2}"
      fi
    fi

    printf -v "${key}" '%s' "${value}"
  done < "${config_file}"
}

CONFIG_FILE="${PODMAN_SECRET_CONFIG:-}"
while (($#)); do
  case "$1" in
    --config)
      shift
      (($#)) || fail "--config requires a path"
      CONFIG_FILE="$1"
      ;;
    *)
      fail "Unsupported argument: $1"
      ;;
  esac

  shift
done

if [[ -z "${CONFIG_FILE}" ]]; then
  REPO_ROOT="$(resolve_repo_root)"
  CONFIG_FILE="${REPO_ROOT}/.devcontainer/podman-secrets.conf"
fi

[[ -f "${CONFIG_FILE}" ]] || fail "Config file not found: ${CONFIG_FILE}"
load_config_file "${CONFIG_FILE}"

require_command aws
PODMAN_CMD="$(resolve_podman_command)"

[[ -n "${AWS_REGION:-}" ]] || fail "AWS_REGION must be set in ${CONFIG_FILE}"
[[ -n "${AWS_SECRET_NAMESPACE:-}" ]] || fail "AWS_SECRET_NAMESPACE must be set in ${CONFIG_FILE}"
[[ -n "${PODMAN_SECRET_PREFIX:-}" ]] || fail "PODMAN_SECRET_PREFIX must be set in ${CONFIG_FILE}"
[[ -n "${PODMAN_SECRET_TYPE:-}" ]] || fail "PODMAN_SECRET_TYPE must be set in ${CONFIG_FILE}"
[[ "${PODMAN_SECRET_TYPE}" == "env" ]] || fail "Unsupported PODMAN_SECRET_TYPE '${PODMAN_SECRET_TYPE}'. Expected 'env'."

secret_prefix="${AWS_SECRET_NAMESPACE%/}/"

log "Discovering AWS secrets under ${secret_prefix}"

secret_names=()
while IFS= read -r secret_name; do
  secret_names+=("${secret_name}")
done < <(
  run_aws secretsmanager list-secrets \
    --region "${AWS_REGION}" \
    --filters "Key=name,Values=${secret_prefix}" \
    --query 'SecretList[].Name' \
    --output text \
  | tr '\t' '\n' \
  | sed '/^$/d' \
  | sort
)

(( ${#secret_names[@]} > 0 )) || fail "No AWS secrets found under namespace '${secret_prefix}'"

normalized_secret_names=()
normalized_secret_sources=()
secret_args=()
synced_count=0
missing_current_secrets=()

for secret_name in "${secret_names[@]}"; do
  secret_key="${secret_name##*/}"
  env_name="$(normalize_env_name "${secret_key}")"

  for ((i = 0; i < ${#normalized_secret_names[@]}; i++)); do
    if [[ "${normalized_secret_names[i]}" == "${env_name}" ]]; then
      fail "Secrets '${normalized_secret_sources[i]}' and '${secret_name}' both normalize to '${env_name}'. Rename one secret to avoid a Podman target collision."
    fi
  done

  normalized_secret_names+=("${env_name}")
  normalized_secret_sources+=("${secret_name}")
done

for secret_name in "${secret_names[@]}"; do
  secret_key="${secret_name##*/}"
  env_name="$(normalize_env_name "${secret_key}")"
  podman_secret_name="${PODMAN_SECRET_PREFIX}__${env_name}"

  version_stages="$(
    run_aws secretsmanager describe-secret \
      --region "${AWS_REGION}" \
      --secret-id "${secret_name}" \
      --query 'VersionIdsToStages' \
      --output text
  )"

  if ! grep -qw 'AWSCURRENT' <<<"${version_stages}"; then
    log "Skipping ${secret_name}: no AWSCURRENT version is available yet"
    missing_current_secrets+=("${secret_name}")
    continue
  fi

  has_secret_string="$(
    run_aws secretsmanager get-secret-value \
      --region "${AWS_REGION}" \
      --secret-id "${secret_name}" \
      --query "SecretString != \`null\`" \
      --output text
  )"

  [[ "${has_secret_string}" == "True" ]] || fail "Secret '${secret_name}' does not contain a SecretString value"

  secret_value="$(
    run_aws secretsmanager get-secret-value \
      --region "${AWS_REGION}" \
      --secret-id "${secret_name}" \
      --query 'SecretString' \
      --output text
  )"

  [[ -n "${secret_value}" && "${secret_value}" != "None" ]] || fail "Secret '${secret_name}' has an empty SecretString value"

  printf '%s' "${secret_value}" | "${PODMAN_CMD}" secret create --replace "${podman_secret_name}" - >/dev/null

  secret_args+=(
    "--secret"
    "source=${podman_secret_name},type=${PODMAN_SECRET_TYPE},target=${env_name}"
  )
  synced_count=$((synced_count + 1))

  log "Synced ${secret_name} as ${podman_secret_name}"
done

if (( synced_count == 0 )); then
  if (( ${#missing_current_secrets[@]} > 0 )); then
    fail "AWS secrets exist under '${secret_prefix}', but none have an AWSCURRENT value yet. Populate the secret values in AWS Secrets Manager first: ${missing_current_secrets[*]}"
  fi

  fail "No usable AWS secrets found under namespace '${secret_prefix}'"
fi

printf '%s' "${secret_args[0]}"
for ((i = 1; i < ${#secret_args[@]}; i++)); do
  printf ' %s' "${secret_args[i]}"
done
printf '\n'
