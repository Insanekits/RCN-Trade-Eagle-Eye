#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Copy the local OneDrive-synced PCH workbook into the repo, commit, and push to main.
  Windows / PowerShell equivalent of scripts/sync.sh.

.DESCRIPTION
  Vercel auto-deploys from main, so within ~30 seconds the dashboard at your
  Vercel URL is showing the new data.

  Configuration (scripts/sync.env, gitignored - same file the bash script uses):
    RCN_MIS_SOURCE   absolute path to the .xlsx in your OneDrive folder (required)
    RCN_MIS_DEST     repo-relative destination path (default: data/rcn-mis.xlsx)
    SYNC_BRANCH  branch to push to (default: main)

.PARAMETER Source
  One-off override of the source path. Positional, so you can also pass it
  as the first argument without -Source.

.PARAMETER NoPush
  Commit locally but don't push to origin.

.PARAMETER DryRun
  Print the plan and exit. Nothing on disk or in git is touched.

.EXAMPLE
  .\scripts\sync.ps1
  # Uses RCN_MIS_SOURCE from scripts\sync.env

.EXAMPLE
  .\scripts\sync.ps1 "C:\Users\me\OneDrive - Acme\Logistics\PCH.xlsx"
  # One-off override

.EXAMPLE
  .\scripts\sync.ps1 -DryRun
  # Just print the plan

.NOTES
  If PowerShell refuses to run this script due to execution policy, invoke it as:
    powershell -ExecutionPolicy Bypass -File .\scripts\sync.ps1
  or (PowerShell 7+):
    pwsh -ExecutionPolicy Bypass -File .\scripts\sync.ps1
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Source,

    [switch]$NoPush,

    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# ------------------------------------------------------------ paths & config
$ScriptDir  = $PSScriptRoot
$RepoDir    = (Resolve-Path (Join-Path $ScriptDir '..')).Path
$ConfigFile = Join-Path $ScriptDir 'sync.env'

function Expand-EnvValue {
    param([string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return $Value }

    $resolver = {
        param($match)
        $name = $match.Groups[1].Value
        if ($name -eq 'HOME') { return $HOME }
        $v = [Environment]::GetEnvironmentVariable($name)
        if ($null -eq $v) { return $match.Value }
        return $v
    }

    $Value = [regex]::Replace($Value, '\$\{([A-Za-z_][A-Za-z0-9_]*)\}', $resolver)
    $Value = [regex]::Replace($Value, '\$([A-Za-z_][A-Za-z0-9_]*)',     $resolver)
    $Value = [Environment]::ExpandEnvironmentVariables($Value)

    if ($Value.StartsWith('~')) { $Value = $HOME + $Value.Substring(1) }
    return $Value
}

$envConfig = @{}
if (Test-Path -LiteralPath $ConfigFile) {
    foreach ($rawLine in Get-Content -LiteralPath $ConfigFile) {
        $line = $rawLine.Trim()
        if ($line -eq '' -or $line.StartsWith('#')) { continue }
        if ($line -match '^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') {
            $key = $Matches[1]
            $val = $Matches[2].Trim()
            if ($val.Length -ge 2 -and (
                ($val.StartsWith('"') -and $val.EndsWith('"')) -or
                ($val.StartsWith("'") -and $val.EndsWith("'"))
            )) {
                $val = $val.Substring(1, $val.Length - 2)
            }
            $envConfig[$key] = Expand-EnvValue $val
        }
    }
}

$SourcePath = if ($Source) { Expand-EnvValue $Source } else { $envConfig['RCN_MIS_SOURCE'] }
$DestRel    = if ($envConfig['RCN_MIS_DEST']) { $envConfig['RCN_MIS_DEST'] } else { 'data/rcn-mis.xlsx' }
$Branch     = if ($envConfig['SYNC_BRANCH']) { $envConfig['SYNC_BRANCH'] } else { 'main' }
$DestAbs    = Join-Path $RepoDir $DestRel

# ------------------------------------------------------------ small helpers
function Write-Step { param([string]$m) Write-Host ""; Write-Host "▶ $m" -ForegroundColor Cyan }
function Write-Log  { param([string]$m) Write-Host "  $m" }
function Write-Err  { param([string]$m) Write-Host ""; Write-Host "ERROR: $m" -ForegroundColor Red; exit 1 }

function Format-Size {
    param([long]$Bytes)
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N1} KB' -f ($Bytes / 1KB)) }
    return "$Bytes B"
}

function Invoke-Git {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
    & git @Args
    return $LASTEXITCODE
}

# ------------------------------------------------------------ validate source
if (-not $SourcePath) {
    Write-Host ""
    Write-Host "ERROR: No source path provided." -ForegroundColor Red
    Write-Host ""
    Write-Host "Either:"
    Write-Host "  1. Create scripts\sync.env (copy scripts\sync.env.example), set RCN_MIS_SOURCE"
    Write-Host "  2. Or pass the path as the first argument:"
    Write-Host "       .\scripts\sync.ps1 'C:\Users\$env:USERNAME\OneDrive - YourCo\PCH.xlsx'"
    Write-Host ""
    exit 1
}

if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
    Write-Err @"
Source file not found:
    $SourcePath
  Hint: open it once in File Explorer / Finder to make sure OneDrive has
  downloaded the file locally (not just kept it 'online only').
"@
}

# ------------------------------------------------------------ size guard (GitHub: 100 MB hard, 50 MB warn)
$SizeBytes = (Get-Item -LiteralPath $SourcePath).Length
$SizeMB    = [int][Math]::Floor($SizeBytes / 1MB)
if ($SizeMB -gt 100) {
    Write-Err "File is $SizeMB MB - exceeds GitHub's 100 MB file limit. Use Git LFS or shrink the workbook."
}
if ($SizeMB -gt 50) {
    Write-Log "Warning: file is $SizeMB MB; GitHub recommends keeping files under 50 MB."
}

# ------------------------------------------------------------ validate repo
Set-Location -LiteralPath $RepoDir

& git rev-parse --is-inside-work-tree *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Err @"
$RepoDir is not a git repository.
  Run inside this folder once:
    git init; git remote add origin <your GitHub repo URL>; git fetch origin
"@
}

if (-not $NoPush) {
    & git remote get-url origin *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Err @"
No 'origin' remote configured. Add one with:
    git remote add origin <your GitHub repo URL>
"@
    }
}

# ------------------------------------------------------------ summary
Write-Step "Plan"
Write-Log ("Source:       {0}  ({1})" -f $SourcePath, (Format-Size $SizeBytes))
Write-Log ("Destination:  {0}" -f $DestRel)
Write-Log ("Repo:         {0}" -f $RepoDir)
Write-Log ("Branch:       {0}" -f $Branch)
Write-Log ("Push:         {0}" -f $(if ($NoPush) { 'no' } else { 'yes' }))

if ($DryRun) {
    Write-Log "Dry run - nothing was changed."
    exit 0
}

# ------------------------------------------------------------ copy
Write-Step "Copying workbook into repo"
$DestDir = Split-Path -Parent $DestAbs
if (-not (Test-Path -LiteralPath $DestDir)) {
    New-Item -ItemType Directory -Path $DestDir -Force | Out-Null
}
Copy-Item -LiteralPath $SourcePath -Destination $DestAbs -Force
Write-Log "Wrote $DestRel"

# ------------------------------------------------------------ branch + pull
Write-Step "Syncing git branch $Branch"
$CurrentBranch = (& git rev-parse --abbrev-ref HEAD).Trim()
if ($CurrentBranch -ne $Branch) {
    Write-Log "Switching from '$CurrentBranch' to '$Branch'"
    & git checkout $Branch
    if ($LASTEXITCODE -ne 0) { Write-Err "git checkout $Branch failed." }
}

& git remote get-url origin *> $null
if ($LASTEXITCODE -eq 0) {
    & git ls-remote --exit-code --heads origin $Branch *> $null
    if ($LASTEXITCODE -eq 0) {
        Write-Log "Pulling latest from origin/$Branch (rebase)..."
        & git pull --rebase origin $Branch
        if ($LASTEXITCODE -ne 0) { Write-Err "git pull --rebase failed." }
    } else {
        Write-Log "Remote branch origin/$Branch does not exist yet - will create on push."
    }
}

# ------------------------------------------------------------ stage + diff check
& git add -- $DestRel
if ($LASTEXITCODE -ne 0) { Write-Err "git add failed." }

& git diff --cached --quiet -- $DestRel
if ($LASTEXITCODE -eq 0) {
    Write-Log "No changes detected - workbook is identical to what's already on $Branch."
    exit 0
}

# ------------------------------------------------------------ commit
$Timestamp  = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz')
$SourceName = Split-Path -Leaf $SourcePath
$CommitMsg  = "data: sync $SourceName ($Timestamp)"

Write-Step "Committing"
Write-Log $CommitMsg
& git commit -m $CommitMsg -- $DestRel
if ($LASTEXITCODE -ne 0) { Write-Err "git commit failed." }

# ------------------------------------------------------------ push
if ($NoPush) {
    Write-Log "-NoPush set; commit stays local."
    exit 0
}

Write-Step "Pushing to origin/$Branch"
& git push -u origin $Branch
if ($LASTEXITCODE -ne 0) { Write-Err "git push failed." }

Write-Host ""
Write-Host "Done. Vercel should redeploy in ~20-60 seconds." -ForegroundColor Green
Write-Host "  Watch progress at: https://vercel.com/dashboard"
Write-Host ""
Write-Host "  Once the build turns green, refresh your dashboard URL and the new data"
Write-Host "  will appear automatically."
Write-Host ""

