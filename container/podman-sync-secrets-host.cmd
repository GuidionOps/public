: <<'__POSIX__'
@echo off
setlocal

if not exist ".devcontainer\.cache\" (
  echo [podman-sync-secrets] ERROR: Missing required directory: .devcontainer\.cache 1>&2
  exit /b 1
)

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference = 'Stop'; Invoke-WebRequest -UseBasicParsing -Uri 'https://raw.githubusercontent.com/GuidionOps/public/container/container/podman-sync-secrets.ps1' -OutFile '.devcontainer\.cache\podman-sync-secrets.ps1'"
if errorlevel 1 exit /b %ERRORLEVEL%

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File ".devcontainer\.cache\podman-sync-secrets.ps1" %*
exit /b %ERRORLEVEL%
__POSIX__

set -eu

if [ ! -d ".devcontainer/.cache" ]; then
  printf '[podman-sync-secrets] ERROR: Missing required directory: .devcontainer/.cache\n' >&2
  exit 1
fi

if command -v curl >/dev/null 2>&1; then
  curl -fsSL -o ".devcontainer/.cache/podman-sync-secrets.sh" "https://raw.githubusercontent.com/GuidionOps/public/container/container/podman-sync-secrets.sh"
elif command -v wget >/dev/null 2>&1; then
  wget -q -O ".devcontainer/.cache/podman-sync-secrets.sh" "https://raw.githubusercontent.com/GuidionOps/public/container/container/podman-sync-secrets.sh"
else
  printf '[podman-sync-secrets] ERROR: Missing required command: curl or wget\n' >&2
  exit 1
fi

bash ".devcontainer/.cache/podman-sync-secrets.sh" "$@"
