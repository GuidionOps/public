# Container script guidance

`podman-sync-secrets.ps1` and `podman-sync-secrets-host.cmd` must remain
compatible with Windows PowerShell 5.1 (`powershell.exe`), not only PowerShell
7+ (`pwsh`). Do not introduce PowerShell 7-only syntax, APIs, or assumptions.

For PowerShell edits:

- Keep script text ASCII-only.
- Parenthesize cmdlet calls when combining them with logical operators.
- Avoid ambiguous interpolation such as `"$name:"`; use `${name}` or the `-f`
  format operator when a variable is immediately followed by `:`.
- When Windows PowerShell is available, parse-check the changed script with
  `powershell.exe -NoProfile -Command "[scriptblock]::Create((Get-Content -LiteralPath 'container/podman-sync-secrets.ps1' -Raw)) | Out-Null"`.
