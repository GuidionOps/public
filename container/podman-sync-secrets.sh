#!/usr/bin/env bash
set -Eeuo pipefail

log() {
  printf '[podman-sync-secrets] %s\n' "$*" >&2
}

fail() {
  log "ERROR: $*"
  exit 1
}

resolve_repo_root() {
  local directory
  directory="${PODMAN_REPO_ROOT:-$(pwd -P)}"
  [[ -d "${directory}" ]] || fail "Repository search directory does not exist: ${directory}"
  directory="$(cd -- "${directory}" && pwd -P)"

  while :; do
    if [[ -d "${directory}/.git" && -f "${directory}/.devcontainer/podman-config.conf" ]]; then
      printf '%s' "${directory}"
      return
    fi
    [[ "${directory}" == "/" ]] && break
    directory="$(dirname -- "${directory}")"
  done

  fail "Unable to locate repository root"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

resolve_podman_command() {
  local candidate

  if [[ -n "${PODMAN_CMD:-}" ]]; then
    require_command "${PODMAN_CMD}"
    printf '%s' "${PODMAN_CMD}"
    return
  fi

  for candidate in podman podman-remote podman-remote-static-linux_amd64; do
    if command -v "${candidate}" >/dev/null 2>&1; then
      printf '%s' "${candidate}"
      return
    fi
  done

  fail "Missing required command: podman, podman-remote, or podman-remote-static-linux_amd64"
}

is_aws_credentials_error() {
  case "$1" in
    *"Error when retrieving token from sso"*|*"The SSO session associated with this profile has expired or is otherwise invalid"*|*"Token has expired and refresh failed"*|*"Unable to locate credentials"*|*"Unable to find credentials"*|*"NoCredentialsError"*|*"ExpiredToken"*|*"ExpiredTokenException"*|*"InvalidClientTokenId"*|*"UnrecognizedClientException"*)
      return 0
      ;;
  esac
  return 1
}

run_aws() {
  local output
  if output="$(aws "$@" 2>&1)"; then
    printf '%s' "${output}"
    return
  fi
  is_aws_credentials_error "${output}" \
    && fail "AWS credentials were not found or have expired. Run: aws sso login --sso-session guidion"
  fail "AWS command failed"
}

normalize_env_name() {
  local normalized
  normalized="$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | sed -E 's/[^A-Z0-9]+/_/g; s/^_+//; s/_+$//; s/_+/_/g')"
  [[ -n "${normalized}" ]] || fail "Unable to derive environment variable name from secret key '$1'"
  printf '%s' "${normalized}"
}

load_config() {
  local path="$1" line key value line_number=0

  while IFS= read -r line || [[ -n "${line}" ]]; do
    line_number=$((line_number + 1))
    [[ ! "${line}" =~ ^[[:space:]]*$ ]] || continue
    [[ "${line}" =~ ^[[:space:]]*# ]] && continue
    [[ "${line}" =~ ^[A-Z_][A-Z0-9_]*= ]] \
      || fail "Invalid config entry at ${path}:${line_number}. Expected KEY=VALUE."

    key="${line%%=*}"
    value="${line#*=}"
    if [[ ${#value} -ge 2 ]]; then
      if [[ "${value:0:1}" == '"' && "${value: -1}" == '"' ]]; then
        value="${value:1:${#value}-2}"
      elif [[ "${value:0:1}" == "'" && "${value: -1}" == "'" ]]; then
        value="${value:1:${#value}-2}"
      fi
    fi

    case "${key}" in
      AWS_REGION|AWS_SECRET_NAMESPACE|PODMAN_SECRET_PREFIX)
        printf -v "${key}" '%s' "${value}"
        ;;
    esac
  done <"${path}"
}

write_secret_string() {
  local secret_name="$1"
  local target="$2"
  local error_file="${target}.error"
  local size ending trim=0 trimmed

  if ! aws secretsmanager get-secret-value \
    --region "${AWS_REGION}" \
    --secret-id "${secret_name}" \
    --query SecretString \
    --output text >"${target}" 2>"${error_file}"; then
    local error_output
    error_output="$(<"${error_file}")"
    rm -f -- "${error_file}" "${target}"
    is_aws_credentials_error "${error_output}" \
      && fail "AWS credentials were not found or have expired. Run: aws sso login --sso-session guidion"
    fail "Failed to retrieve SecretString for secret '${secret_name}'"
  fi
  rm -f -- "${error_file}"

  # Remove only the line ending added by AWS CLI's text formatter.
  size="$(wc -c <"${target}")"
  if ((size > 0)); then
    ending="$(tail -c 2 "${target}" 2>/dev/null | od -An -t x1 | tr -d '[:space:]')"
    case "${ending}" in
      *0d0a) trim=2 ;;
      *0a) trim=1 ;;
    esac
  fi
  if ((trim > 0)); then
    trimmed="${target}.trimmed"
    dd if="${target}" of="${trimmed}" bs=1 count="$((size - trim))" 2>/dev/null
    mv -f -- "${trimmed}" "${target}"
  fi
}

assert_safe_destination() {
  local destination="$1" allowed_directory="${2:-}" entry
  [[ ! -L "${destination}" ]] || fail "Refusing symbolic-link secret directory: ${destination}"
  [[ -d "${destination}" ]] || fail "Required secret directory does not exist: ${destination}"
  while IFS= read -r -d '' entry; do
    if [[ -n "${allowed_directory}" && "${entry}" == "${destination}/${allowed_directory}" && ! -L "${entry}" && -d "${entry}" ]]; then
      continue
    fi
    [[ ! -L "${entry}" && -f "${entry}" ]] \
      || fail "Secret directory contains an unexpected symbolic link or directory: ${entry}"
  done < <(find "${destination}" -mindepth 1 -maxdepth 1 -print0)
}

STAGE=""
BACKUP=""
DESTINATION=""

cleanup() {
  if [[ -n "${STAGE}" && -d "${STAGE}" && ! -L "${STAGE}" ]]; then
    rm -rf -- "${STAGE}"
  fi
  if [[ -n "${BACKUP}" && -d "${BACKUP}" && ! -L "${BACKUP}" && -n "${DESTINATION}" && ! -e "${DESTINATION}" ]]; then
    mv -- "${BACKUP}" "${DESTINATION}" || true
  fi
}
trap cleanup EXIT

publish_files() {
  local parent="$1"
  if [[ ! -e "${DESTINATION}" && ! -L "${DESTINATION}" ]]; then
    mv -- "${STAGE}" "${DESTINATION}"
    STAGE=""
    return
  fi

  BACKUP="$(mktemp -d "${parent}/.secret-backup.XXXXXX")"
  rmdir -- "${BACKUP}"
  mv -- "${DESTINATION}" "${BACKUP}"
  if ! mv -- "${STAGE}" "${DESTINATION}"; then
    mv -- "${BACKUP}" "${DESTINATION}" || fail "Failed to restore previous secret files"
    BACKUP=""
    fail "Failed to publish secret files"
  fi
  STAGE=""
  rm -rf -- "${BACKUP}"
  BACKUP=""
}

CONFIG_FILE="${PODMAN_SECRET_CONFIG:-}"
while (($#)); do
  case "$1" in
    --config)
      shift
      (($#)) || fail "--config requires a path"
      CONFIG_FILE="$1"
      ;;
    *) fail "Unsupported argument: $1" ;;
  esac
  shift
done

REPO_ROOT="$(resolve_repo_root)"
[[ -n "${CONFIG_FILE}" ]] || CONFIG_FILE="${REPO_ROOT}/.devcontainer/podman-config.conf"
[[ -f "${CONFIG_FILE}" ]] || fail "Config file not found: ${CONFIG_FILE}"
load_config "${CONFIG_FILE}"

require_command aws
PODMAN_CMD="$(resolve_podman_command)"
[[ -n "${AWS_REGION:-}" ]] || fail "AWS_REGION must be set in ${CONFIG_FILE}"
[[ -n "${AWS_SECRET_NAMESPACE:-}" ]] || fail "AWS_SECRET_NAMESPACE must be set in ${CONFIG_FILE}"
[[ -n "${PODMAN_SECRET_PREFIX:-}" ]] || fail "PODMAN_SECRET_PREFIX must be set in ${CONFIG_FILE}"

cache_directory="${REPO_ROOT}/.devcontainer/.cache"
assert_safe_destination "${cache_directory}" "compose-secrets"
DESTINATION="${cache_directory}/compose-secrets"
if [[ -e "${DESTINATION}" || -L "${DESTINATION}" ]]; then
  assert_safe_destination "${DESTINATION}"
fi
STAGE="$(mktemp -d "${REPO_ROOT}/.devcontainer/.secret-stage.XXXXXX")"

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
    --output text | tr '\t' '\n' | sed '/^$/d' | sort
)
((${#secret_names[@]} > 0)) || fail "No AWS secrets found under namespace '${secret_prefix}'"

normalized_names=()
normalized_sources=()
for secret_name in "${secret_names[@]}"; do
  env_name="$(normalize_env_name "${secret_name##*/}")"
  for ((i = 0; i < ${#normalized_names[@]}; i++)); do
    [[ "${normalized_names[i]}" != "${env_name}" ]] \
      || fail "Secrets '${normalized_sources[i]}' and '${secret_name}' both normalize to '${env_name}'"
  done
  normalized_names+=("${env_name}")
  normalized_sources+=("${secret_name}")
done

secret_args=()
synced=0
for secret_name in "${secret_names[@]}"; do
  env_name="$(normalize_env_name "${secret_name##*/}")"
  stages="$(run_aws secretsmanager describe-secret --region "${AWS_REGION}" --secret-id "${secret_name}" --query VersionIdsToStages --output text)"
  if ! grep -qw AWSCURRENT <<<"${stages}"; then
    log "Skipping ${secret_name}: no AWSCURRENT version is available yet"
    continue
  fi

  has_string="$(run_aws secretsmanager get-secret-value --region "${AWS_REGION}" --secret-id "${secret_name}" --query 'SecretString != `null`' --output text)"
  [[ "${has_string}" == "True" ]] || fail "Secret '${secret_name}' does not contain a SecretString value"

  secret_file="${STAGE}/${env_name}"
  write_secret_string "${secret_name}" "${secret_file}"
  [[ -s "${secret_file}" ]] || fail "Secret '${secret_name}' has an empty SecretString value"

  podman_name="${PODMAN_SECRET_PREFIX}__${env_name}"
  podman_value="$(<"${secret_file}")"
  [[ -n "${podman_value}" && "${podman_value}" != None ]] \
    || fail "Secret '${secret_name}' has an empty SecretString value"
  printf '%s' "${podman_value}" | "${PODMAN_CMD}" secret create --replace "${podman_name}" - >/dev/null
  secret_args+=(--secret "source=${podman_name},type=env,target=${env_name}")
  synced=$((synced + 1))
  log "Synced ${secret_name} as ${podman_name} and ${env_name}"
done

((synced > 0)) || fail "No usable AWS secrets found under namespace '${secret_prefix}'"
publish_files "${REPO_ROOT}/.devcontainer"
printf '%s' "${secret_args[0]}"
for ((i = 1; i < ${#secret_args[@]}; i++)); do
  printf ' %s' "${secret_args[i]}"
done
printf '\n'
