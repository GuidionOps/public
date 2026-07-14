# Container script guidance

`podman-sync-secrets.ps1` and `podman-sync-secrets-host.cmd` must remain
compatible with Windows PowerShell 5.1 (`powershell.exe`), not only PowerShell
7+ (`pwsh`). Do not introduce PowerShell 7-only syntax, APIs, or assumptions.

`podman-sync-secrets-host.cmd` is intentionally a Cmd/POSIX-shell polyglot: the
same downloaded file must run on Windows hosts and on Linux/macOS hosts before
the dev container exists. Preserve both sections when editing it. The caller
must select the host interpreter explicitly; do not use `windows-command || sh
script` as OS detection, because `||` also runs the POSIX fallback after a real
Windows synchronization failure and hides the useful error.

The wrapper caches its downloaded PowerShell and Bash payloads at fixed paths
under `.devcontainer/.cache/`, overwriting them on each run. Do not reintroduce
random operating-system temporary paths or extra path variables.

Calling repositories must create and ignore `.devcontainer/.cache/` before
`initializeCommand` runs. The wrapper is called from the repository root.

`initializeCommand` only creates or replaces Podman secrets; its stdout cannot
modify `devcontainer.json`. Calling repositories must explicitly add every
required secret to `runArgs` using `source=<PODMAN_SECRET_PREFIX>__<NORMALIZED_SECRET_KEY>,type=env,target=<NORMALIZED_SECRET_KEY>`.

For PowerShell edits:

- Keep script text ASCII-only.
- Parenthesize cmdlet calls when combining them with logical operators.
- Avoid ambiguous interpolation such as `"$name:"`; use `${name}` or the `-f`
  format operator when a variable is immediately followed by `:`.
- When Windows PowerShell is available, parse-check the changed script with
  `powershell.exe -NoProfile -Command "[scriptblock]::Create((Get-Content -LiteralPath 'container/podman-sync-secrets.ps1' -Raw)) | Out-Null"`.
