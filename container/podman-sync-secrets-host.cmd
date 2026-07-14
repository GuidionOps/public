: <<'__POSIX__'
@echo off
setlocal

if not defined PODMAN_SYNC_SECRETS_BASE_URL set "PODMAN_SYNC_SECRETS_BASE_URL=https://raw.githubusercontent.com/GuidionOps/public/container/container"

set "SYNC_SCRIPT=%TEMP%\podman-sync-secrets-%RANDOM%%RANDOM%.ps1"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference = 'Stop'; $baseUrl = $env:PODMAN_SYNC_SECRETS_BASE_URL.TrimEnd('/'); Invoke-WebRequest -UseBasicParsing -Uri ($baseUrl + '/podman-sync-secrets.ps1') -OutFile $env:SYNC_SCRIPT"
if errorlevel 1 exit /b %ERRORLEVEL%

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SYNC_SCRIPT%" %*
set "EXIT_CODE=%ERRORLEVEL%"
del /q "%SYNC_SCRIPT%" >nul 2>&1
exit /b %EXIT_CODE%
__POSIX__

set -eu

BASE_URL="${PODMAN_SYNC_SECRETS_BASE_URL:-https://raw.githubusercontent.com/GuidionOps/public/container/container}"
SCRIPT_FILE="$(mktemp "${TMPDIR:-/tmp}/podman-sync-secrets.XXXXXX")"

cleanup() {
  rm -f -- "${SCRIPT_FILE}"
}
trap cleanup EXIT INT TERM

if command -v curl >/dev/null 2>&1; then
  curl -fsSL -o "${SCRIPT_FILE}" "${BASE_URL}/podman-sync-secrets.sh"
elif command -v wget >/dev/null 2>&1; then
  wget -q -O "${SCRIPT_FILE}" "${BASE_URL}/podman-sync-secrets.sh"
else
  printf '[podman-sync-secrets] ERROR: Missing required command: curl or wget\n' >&2
  exit 1
fi

bash "${SCRIPT_FILE}" "$@"
