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

function Resolve-RepoRoot {
    $directory = $env:PODMAN_REPO_ROOT
    if ([string]::IsNullOrWhiteSpace($directory)) {
        $directory = (Get-Location).Path
    }
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        Fail "Repository search directory does not exist: $directory"
    }

    $directory = (Resolve-Path -LiteralPath $directory).Path
    while ($true) {
        $gitDirectory = Join-Path $directory ".git"
        $configFile = Join-Path $directory ".devcontainer/podman-config.conf"
        if ((Test-Path -LiteralPath $gitDirectory -PathType Container) -and (Test-Path -LiteralPath $configFile -PathType Leaf)) {
            return $directory
        }
        $parent = Split-Path -Parent $directory
        if ($parent -eq $directory) {
            break
        }
        $directory = $parent
    }

    Fail "Unable to locate repository root"
}

function Resolve-PodmanCommand {
    if (-not [string]::IsNullOrWhiteSpace($env:PODMAN_CMD)) {
        Require-Command $env:PODMAN_CMD
        return $env:PODMAN_CMD
    }
    foreach ($candidate in @("podman", "podman-remote", "podman-remote-static-linux_amd64")) {
        if ($null -ne (Get-Command -Name $candidate -ErrorAction SilentlyContinue)) {
            return $candidate
        }
    }
    Fail "Missing required command: podman, podman-remote, or podman-remote-static-linux_amd64"
}

function Normalize-EnvName {
    param([string]$Name)
    $normalized = [regex]::Replace($Name.ToUpperInvariant(), "[^A-Z0-9]+", "_")
    $normalized = [regex]::Replace($normalized.Trim("_"), "_+", "_")
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
        if ([string]::IsNullOrWhiteSpace($line) -or ($line -match "^\s*#")) {
            continue
        }
        if ($line -notmatch "^([A-Z_][A-Z0-9_]*)=(.*)$") {
            Fail "Invalid config entry at ${Path}:$lineNumber. Expected KEY=VALUE."
        }
        $value = $Matches[2]
        if ($value.Length -ge 2) {
            $first = $value.Substring(0, 1)
            $last = $value.Substring($value.Length - 1, 1)
            if ((($first -eq '"') -and ($last -eq '"')) -or (($first -eq "'") -and ($last -eq "'"))) {
                $value = $value.Substring(1, $value.Length - 2)
            }
        }
        $config[$Matches[1]] = $value
    }
    return $config
}

function Require-Config {
    param([hashtable]$Config, [string]$Key, [string]$Path)
    if ((-not $Config.ContainsKey($Key)) -or [string]::IsNullOrWhiteSpace($Config[$Key])) {
        Fail "$Key must be set in $Path"
    }
    return [string]$Config[$Key]
}

function Get-AwsCredentialHelp {
    param([string]$Output)
    foreach ($pattern in @(
        "Error when retrieving token from sso",
        "The SSO session associated with this profile has expired or is otherwise invalid",
        "Token has expired and refresh failed",
        "Unable to locate credentials",
        "Unable to find credentials",
        "NoCredentialsError",
        "ExpiredToken",
        "InvalidClientTokenId",
        "UnrecognizedClientException"
    )) {
        if ($Output -like "*$pattern*") {
            return "AWS credentials were not found or have expired. Run: aws sso login --sso-session guidion"
        }
    }
    return $null
}

function Invoke-Checked {
    param([string]$Command, [string[]]$Arguments, [bool]$Sensitive = $false, [string]$SecretName = "")
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $output = & $Command @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }

    $text = ($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
    if ($exitCode -ne 0) {
        if ($Command -eq "aws") {
            $help = Get-AwsCredentialHelp $text
            if ($null -ne $help) {
                Fail $help
            }
        }
        if ($Sensitive) {
            Fail "Failed to retrieve SecretString for secret '$SecretName'"
        }
        Fail "Command failed: $Command"
    }
    return $text
}

function Get-SecretString {
    param([string]$Region, [string]$SecretName)
    $json = Invoke-Checked "aws" @(
        "secretsmanager", "get-secret-value",
        "--region", $Region,
        "--secret-id", $SecretName,
        "--query", "SecretString",
        "--output", "json"
    ) $true $SecretName
    try {
        $value = ConvertFrom-Json -InputObject $json
    }
    catch {
        Fail "AWS returned an invalid SecretString response for secret '$SecretName'"
    }
    if ($null -eq $value) {
        Fail "Secret '$SecretName' does not contain a SecretString value"
    }
    return [string]$value
}

function Save-PodmanSecret {
    param([string]$Podman, [string]$Name, [string]$Value)
    $tempFile = [System.IO.Path]::GetTempFileName()
    try {
        [System.IO.File]::WriteAllBytes($tempFile, [System.Text.Encoding]::UTF8.GetBytes($Value))
        Invoke-Checked $Podman @("secret", "create", "--replace", $Name, $tempFile) | Out-Null
    }
    finally {
        Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
    }
}

function Test-IsReparsePoint {
    param([System.IO.FileSystemInfo]$Item)
    return (($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Assert-SafeDestination {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (($null -eq $item) -or -not $item.PSIsContainer) {
        Fail "Required secret directory does not exist: $Path"
    }
    if (Test-IsReparsePoint $item) {
        Fail "Refusing reparse-point secret directory: $Path"
    }
    foreach ($child in (Get-ChildItem -LiteralPath $Path -Force)) {
        if ((Test-IsReparsePoint $child) -or $child.PSIsContainer) {
            Fail "Secret directory contains an unexpected reparse point or directory: $($child.FullName)"
        }
    }
}

function Publish-Files {
    param([string]$Stage, [string]$Destination, [string]$Parent)
    $backup = Join-Path $Parent (".secret-backup." + [Guid]::NewGuid().ToString("N"))
    [System.IO.Directory]::Move($Destination, $backup)
    try {
        [System.IO.Directory]::Move($Stage, $Destination)
    }
    catch {
        [System.IO.Directory]::Move($backup, $Destination)
        throw
    }
    Remove-Item -LiteralPath $backup -Recurse -Force
}

$stage = $null
try {
    $configArgument = $null
    for ($index = 0; $index -lt $args.Count; $index++) {
        if ($args[$index] -ne "--config") {
            Fail "Unsupported argument: $($args[$index])"
        }
        if (($index + 1) -ge $args.Count) {
            Fail "--config requires a path"
        }
        $configArgument = $args[$index + 1]
        $index += 1
    }

    $repoRoot = Resolve-RepoRoot
    $configFile = $configArgument
    if ([string]::IsNullOrWhiteSpace($configFile)) {
        $configFile = $env:PODMAN_SECRET_CONFIG
    }
    if ([string]::IsNullOrWhiteSpace($configFile)) {
        $configFile = Join-Path $repoRoot ".devcontainer/podman-config.conf"
    }
    if (-not (Test-Path -LiteralPath $configFile -PathType Leaf)) {
        Fail "Config file not found: $configFile"
    }

    $config = Read-Config $configFile
    $region = Require-Config $config "AWS_REGION" $configFile
    $namespace = Require-Config $config "AWS_SECRET_NAMESPACE" $configFile
    $podmanPrefix = Require-Config $config "PODMAN_SECRET_PREFIX" $configFile
    Require-Command "aws"
    $podman = Resolve-PodmanCommand

    $devcontainer = Join-Path $repoRoot ".devcontainer"
    $destination = Join-Path $devcontainer ".cache"
    Assert-SafeDestination $destination
    $stage = Join-Path $devcontainer (".secret-stage." + [Guid]::NewGuid().ToString("N"))
    [System.IO.Directory]::CreateDirectory($stage) | Out-Null

    $secretPrefix = $namespace.TrimEnd("/") + "/"
    Log "Discovering AWS secrets under $secretPrefix"
    $namesText = Invoke-Checked "aws" @(
        "secretsmanager", "list-secrets",
        "--region", $region,
        "--filters", "Key=name,Values=$secretPrefix",
        "--query", "SecretList[].Name",
        "--output", "text"
    )
    $secretNames = @($namesText -split "[`t`r`n]+" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object)
    if ($secretNames.Count -eq 0) {
        Fail "No AWS secrets found under namespace '$secretPrefix'"
    }

    $sources = @{}
    foreach ($secretName in $secretNames) {
        $envName = Normalize-EnvName (Split-Path -Leaf $secretName)
        if ($sources.ContainsKey($envName)) {
            Fail "Secrets '$($sources[$envName])' and '$secretName' both normalize to '$envName'"
        }
        $sources[$envName] = $secretName
    }

    $secretArgs = @()
    $synced = 0
    foreach ($secretName in $secretNames) {
        $envName = Normalize-EnvName (Split-Path -Leaf $secretName)
        $stages = Invoke-Checked "aws" @("secretsmanager", "describe-secret", "--region", $region, "--secret-id", $secretName, "--query", "VersionIdsToStages", "--output", "text")
        if (@($stages -split "\s+") -notcontains "AWSCURRENT") {
            Log "Skipping ${secretName}: no AWSCURRENT version is available yet"
            continue
        }

        $hasString = Invoke-Checked "aws" @("secretsmanager", "get-secret-value", "--region", $region, "--secret-id", $secretName, "--query", 'SecretString != `null`', "--output", "text")
        if ($hasString -ne "True") {
            Fail "Secret '$secretName' does not contain a SecretString value"
        }
        $value = Get-SecretString $region $secretName
        if ([string]::IsNullOrEmpty($value)) {
            Fail "Secret '$secretName' has an empty SecretString value"
        }

        $secretFile = Join-Path $stage $envName
        [System.IO.File]::WriteAllBytes($secretFile, [System.Text.Encoding]::UTF8.GetBytes($value))
        $podmanName = "${podmanPrefix}__${envName}"
        $podmanValue = $value.TrimEnd([char[]]"`r`n")
        if ([string]::IsNullOrEmpty($podmanValue) -or ($podmanValue -eq "None")) {
            Fail "Secret '$secretName' has an empty SecretString value"
        }
        Save-PodmanSecret $podman $podmanName $podmanValue
        $secretArgs += "--secret"
        $secretArgs += "source=${podmanName},type=env,target=${envName}"
        $synced += 1
        Log "Synced $secretName as $podmanName and $envName"
    }

    if ($synced -eq 0) {
        Fail "No usable AWS secrets found under namespace '$secretPrefix'"
    }
    Publish-Files $stage $destination $devcontainer
    $stage = $null
    Write-Output ($secretArgs -join " ")
}
catch {
    $message = $_.Exception.Message
    if ([string]::IsNullOrWhiteSpace($message)) {
        $message = "An unknown error occurred while synchronizing secrets."
    }
    Log "ERROR: $message"
    exit 1
}
finally {
    if (($null -ne $stage) -and (Test-Path -LiteralPath $stage -PathType Container)) {
        Remove-Item -LiteralPath $stage -Recurse -Force
    }
}
