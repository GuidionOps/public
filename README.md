# Public Repo

Resources for which we need no read protection.

## Developer Terraform Preparation Script

[Terraform is run on the local developer machines for Development stages](https://guidiondev.atlassian.net/wiki/spaces/DIG/pages/4002414604/Development+Stage+Deploys).

To configure the backend correctly, a helper script is provided. The script takes two arguments; the project name, and the application name. For example, when configuring the development backend for the 'circleci' application in the 'web' project, run:

```sh
curl -s https://raw.githubusercontent.com/GuidionOps/public/master/prepare_terraform_backend.sh | bash -s -- web circleci
```

It will try and be helpful if arguments are not supplied:

```sh
# Without providing project name
#
curl -s https://raw.githubusercontent.com/GuidionOps/public/master/prepare_terraform_backend.sh | bash -s

Please provde the project name as the first argument (e.g. 'web'
Hint:
2023-03-21 13:15:37 aws-cloudtrail-logs-web-dev-events-test
2023-05-08 15:58:42 nuna-dev-afsprk-nl-origin
2023-05-17 10:37:55 web-dev-terraform-backends
```

```sh
# Without providing application name
#
curl -s https://raw.githubusercontent.com/GuidionOps/public/master/prepare_terraform_backend.sh | bash -s -- web

Please provde one of these for the 'workspace' name as the second argument:
                           PRE afsprk_nl/
                           PRE circleci/
```

## Devcontainer secret synchronization

`container/podman-sync-secrets-host.cmd` is the cross-platform bootstrap used by
devcontainer `initializeCommand`. It downloads and runs the canonical
PowerShell implementation on Windows or the canonical Bash implementation on
Linux and macOS. Calling repositories must create and ignore
`.devcontainer/.cache/` before invoking it.

Configure `.devcontainer/podman-config.conf` with uppercase `KEY=VALUE` entries:

```ini
AWS_REGION=eu-west-1
AWS_SECRET_NAMESPACE=path/to/application
PODMAN_SECRET_PREFIX=application
```

Every run performs both actions:

- Creates or replaces Podman secrets named
  `<PODMAN_SECRET_PREFIX>__<NORMALIZED_SECRET_KEY>` and prints the existing
  `--secret source=...,type=env,target=...` arguments.
- Replaces the complete file-secret set under
  `.devcontainer/cache/<NORMALIZED_SECRET_KEY>`.

The calling repository must create `.devcontainer/cache/` before running the
script; a missing directory is an error. `PODMAN_SECRET_TYPE` is no longer used
to select behavior and is ignored when present. The scripts do not run chmod or
ACL operations.

Secret keys are normalized by uppercasing them, replacing runs of non-alphanumeric
characters with `_`, trimming leading and trailing `_`, and collapsing repeated
`_`. A normalization collision fails the entire sync. Secrets without an
`AWSCURRENT` version are skipped; missing or empty `SecretString` values fail the
sync. The previously published file set stays in place when AWS retrieval
fails, and stale destination files are removed after a complete successful
sync.

Run the regression suite with:

```sh
bash container/tests/test-podman-sync-secrets.sh
```

On Windows, run the Windows PowerShell 5.1 harness from the repository root:

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File container/tests/Test-PodmanSyncSecrets.ps1 -Implementation container/podman-sync-secrets.ps1
```
