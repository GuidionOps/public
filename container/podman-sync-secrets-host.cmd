: <<'__POSIX__'
@echo off
setlocal

rem Dummy shared-repo example:
rem set "PODMAN_SYNC_SECRETS_BASE_URL=https://raw.githubusercontent.com/GuidionOps/public/container/container"
if "%PODMAN_SYNC_SECRETS_BASE_URL%"=="" set "PODMAN_SYNC_SECRETS_BASE_URL=https://raw.githubusercontent.com/GuidionOps/public/container/container"

set "SYNC_SCRIPT=%TEMP%\podman-sync-secrets.ps1"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference = 'Stop'; Invoke-WebRequest -UseBasicParsing -Uri '%PODMAN_SYNC_SECRETS_BASE_URL%/podman-sync-secrets.ps1' -OutFile '%SYNC_SCRIPT%'"
if errorlevel 1 exit /b %ERRORLEVEL%

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SYNC_SCRIPT%" %*
exit /b %ERRORLEVEL%
__POSIX__

set -eu

# Dummy shared-repo example:
# PODMAN_SYNC_SECRETS_BASE_URL=https://raw.githubusercontent.com/GuidionOps/public/container/container
BASE_URL="${PODMAN_SYNC_SECRETS_BASE_URL:-https://raw.githubusercontent.com/GuidionOps/public/container/container}"
SCRIPT_FILE="${TMPDIR:-/tmp}/podman-sync-secrets-$$.sh"

cleanup() {
  rm -f "${SCRIPT_FILE}"
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
