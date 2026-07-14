Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Log {
    param([string]$Message)
    [Console]::Error.WriteLine("[podman-sync-secrets] $Message")
}

function Fail {
    param([string]$Message)
    throw $Message
}

function Require-Command {
    param([string]$Name)
    if ($null -eq (Get-Command -Name $Name -ErrorAction SilentlyContinue)) {
        Fail "Missing required command: $Name"
    }
}

function Normalize-EnvName {
    param([string]$Name)

    $normalized = $Name.ToUpperInvariant()
    $normalized = [regex]::Replace($normalized, "[^A-Z0-9]+", "_")
    $normalized = $normalized.Trim("_")
    $normalized = [regex]::Replace($normalized, "_+", "_")

    if ([string]::IsNullOrWhiteSpace($normalized)) {
        Fail "Unable to derive environment variable name from secret key '$Name'"
    }

    return $normalized
}

function Read-Config {
    param([string]$Path)

    $config = @{}
    $lineNumber = 0

    foreach ($line in (Get-Content -LiteralPath $Path)) {
        $lineNumber += 1

        if (($line -eq "") -or ($line -match "^\s*#")) {
            continue
        }

        if ($line -notmatch "^([A-Z_][A-Z0-9_]*)=(.*)$") {
            Fail "Invalid config entry at ${Path}:$lineNumber. Expected KEY=VALUE with uppercase shell-safe names."
        }

        $key = $Matches[1]
        $value = $Matches[2]

        if ($value.Length -ge 2) {
            $first = $value.Substring(0, 1)
            $last = $value.Substring($value.Length - 1, 1)

            if ((($first -eq '"') -and ($last -eq '"')) -or (($first -eq "'") -and ($last -eq "'"))) {
                $value = $value.Substring(1, $value.Length - 2)
            }
        }

        $config[$key] = $value
    }

    return $config
}

function Require-Config {
    param(
        [hashtable]$Config,
        [string]$Key,
        [string]$Path
    )

    if ((-not $Config.ContainsKey($Key)) -or [string]::IsNullOrWhiteSpace($Config[$Key])) {
        Fail "$Key must be set in $Path"
    }

    return [string]$Config[$Key]
}

function Get-AwsCredentialHelp {
    param([string]$CommandOutput)

    $patterns = @(
        "Error when retrieving token from sso",
        "The SSO session associated with this profile has expired or is otherwise invalid",
        "Token has expired and refresh failed",
        "Unable to locate credentials",
        "Unable to find credentials",
        "NoCredentialsError",
        "ExpiredToken",
        "ExpiredTokenException",
        "InvalidClientTokenId",
        "UnrecognizedClientException"
    )

    foreach ($pattern in $patterns) {
        if ($CommandOutput -like "*$pattern*") {
            return "AWS credentials were not found or have expired. Run: aws sso login --sso-session guidion"
        }
    }

    return $null
}

function Invoke-Checked {
    param(
        [string]$Command,
        [string[]]$Arguments
    )

    $output = & $Command @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $renderedOutput = ($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine

    if ($exitCode -ne 0) {
        if ($Command -eq "aws") {
            $credentialHelp = Get-AwsCredentialHelp $renderedOutput
            if ($null -ne $credentialHelp) {
                Fail $credentialHelp
            }
        }

        $commandLine = @($Command) + $Arguments

        if ([string]::IsNullOrWhiteSpace($renderedOutput)) {
            Fail "Command failed: $($commandLine -join ' ')"
        }

        Fail "Command failed: $($commandLine -join ' ')`n$renderedOutput"
    }

    return $renderedOutput
}

function Save-PodmanSecret {
    param(
        [string]$Name,
        [string]$Value
    )

    $tempFile = [System.IO.Path]::GetTempFileName()

    try {
        [System.IO.File]::WriteAllBytes($tempFile, [System.Text.Encoding]::UTF8.GetBytes($Value))
        Invoke-Checked "podman" @("secret", "create", "--replace", $Name, $tempFile) | Out-Null
    }
    finally {
        if (Test-Path -LiteralPath $tempFile) {
            Remove-Item -LiteralPath $tempFile -Force
        }
    }
}

try {
    $configArgument = $null
    for ($i = 0; $i -lt $args.Count; $i++) {
        if ($args[$i] -eq "--config") {
            if (($i + 1) -ge $args.Count) {
                Fail "--config requires a path"
            }

            $configArgument = $args[$i + 1]
            $i += 1
            continue
        }

        Fail "Unsupported argument: $($args[$i])"
    }

    Require-Command "aws"
    Require-Command "podman"

    $repoRoot = Resolve-Path (Get-Location)
    $configFile = $configArgument
    if ([string]::IsNullOrWhiteSpace($configFile)) {
        $configFile = $env:PODMAN_SECRET_CONFIG
    }
    if ([string]::IsNullOrWhiteSpace($configFile)) {
        $configFile = Join-Path $repoRoot ".devcontainer/podman-secrets.conf"
    }

    if (-not (Test-Path -LiteralPath $configFile -PathType Leaf)) {
        Fail "Config file not found: $configFile"
    }

    $config = Read-Config $configFile
    $awsRegion = Require-Config $config "AWS_REGION" $configFile
    $awsSecretNamespace = Require-Config $config "AWS_SECRET_NAMESPACE" $configFile
    $podmanSecretPrefix = Require-Config $config "PODMAN_SECRET_PREFIX" $configFile
    $podmanSecretType = Require-Config $config "PODMAN_SECRET_TYPE" $configFile

    if ($podmanSecretType -ne "env") {
        Fail "Unsupported PODMAN_SECRET_TYPE '$podmanSecretType'. Expected 'env'."
    }

    $secretPrefix = $awsSecretNamespace.TrimEnd("/") + "/"
    Log "Discovering AWS secrets under $secretPrefix"

    $secretNamesText = Invoke-Checked "aws" @(
        "secretsmanager", "list-secrets",
        "--region", $awsRegion,
        "--filters", "Key=name,Values=$secretPrefix",
        "--query", "SecretList[].Name",
        "--output", "text"
    )

    $secretNames = @(
        $secretNamesText -split "[`t`r`n]+" |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Sort-Object
    )

    if ($secretNames.Count -eq 0) {
        Fail "No AWS secrets found under namespace '$secretPrefix'"
    }

    $sourcesByEnvName = @{}
    foreach ($secretName in $secretNames) {
        $envName = Normalize-EnvName (Split-Path -Leaf $secretName)

        if ($sourcesByEnvName.ContainsKey($envName)) {
            $existingSecret = $sourcesByEnvName[$envName]
            Fail "Secrets '$existingSecret' and '$secretName' both normalize to '$envName'. Rename one secret to avoid a Podman target collision."
        }

        $sourcesByEnvName[$envName] = $secretName
    }

    $secretArgs = @()
    $missingCurrentSecrets = @()

    foreach ($secretName in $secretNames) {
        $envName = Normalize-EnvName (Split-Path -Leaf $secretName)
        $podmanSecretName = "${podmanSecretPrefix}__${envName}"

        $versionStages = Invoke-Checked "aws" @(
            "secretsmanager", "describe-secret",
            "--region", $awsRegion,
            "--secret-id", $secretName,
            "--query", "VersionIdsToStages",
            "--output", "text"
        )

        if (@($versionStages -split "\s+") -notcontains "AWSCURRENT") {
            Log "Skipping ${secretName}: no AWSCURRENT version is available yet"
            $missingCurrentSecrets += $secretName
            continue
        }

        $hasSecretString = Invoke-Checked "aws" @(
            "secretsmanager", "get-secret-value",
            "--region", $awsRegion,
            "--secret-id", $secretName,
            "--query", 'SecretString != `null`',
            "--output", "text"
        )

        if ($hasSecretString -ne "True") {
            Fail "Secret '$secretName' does not contain a SecretString value"
        }

        $secretValue = Invoke-Checked "aws" @(
            "secretsmanager", "get-secret-value",
            "--region", $awsRegion,
            "--secret-id", $secretName,
            "--query", "SecretString",
            "--output", "text"
        )

        if ([string]::IsNullOrEmpty($secretValue) -or ($secretValue -eq "None")) {
            Fail "Secret '$secretName' has an empty SecretString value"
        }

        Save-PodmanSecret $podmanSecretName $secretValue
        $secretArgs += "--secret"
        $secretArgs += "source=${podmanSecretName},type=${podmanSecretType},target=${envName}"

        Log "Synced $secretName as $podmanSecretName"
    }

    if ($secretArgs.Count -eq 0) {
        if ($missingCurrentSecrets.Count -gt 0) {
            $missingSecrets = $missingCurrentSecrets -join " "
            Fail "AWS secrets exist under '$secretPrefix', but none have an AWSCURRENT value yet. Populate the secret values in AWS Secrets Manager first: $missingSecrets"
        }

        Fail "No usable AWS secrets found under namespace '$secretPrefix'"
    }

    Write-Output ($secretArgs -join " ")
}
catch {
    Log "ERROR: $($_.Exception.Message)"
    exit 1
}
