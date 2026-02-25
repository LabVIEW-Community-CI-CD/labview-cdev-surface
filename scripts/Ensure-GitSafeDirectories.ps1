[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string[]]$Paths,

    [Parameter()]
    [switch]$IncludeGitWorktrees,

    [Parameter()]
    [switch]$ValidateGitStatus,

    [Parameter()]
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-NormalizedPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $resolved = [System.IO.Path]::GetFullPath($Path)
    if ($resolved.Length -gt 3 -and $resolved.EndsWith('\')) {
        $resolved = $resolved.TrimEnd('\')
    }
    return $resolved
}

function ConvertTo-NormalizedPathOrRaw {
    param([Parameter(Mandatory = $true)][string]$Path)

    $trimmed = ([string]$Path).Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        return ''
    }

    try {
        return ConvertTo-NormalizedPath -Path $trimmed
    } catch {
        # Preserve non-path safe.directory values (for example '*') instead of failing normalization.
        return $trimmed
    }
}

function New-CaseInsensitiveSet {
    return New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
}

function Test-GitRepoPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return $false
    }

    if (Test-Path -LiteralPath (Join-Path $Path '.git')) {
        return $true
    }

    return $false
}

function Get-GitWorktreePaths {
    param([Parameter(Mandatory = $true)][string]$RepoPath)

    $output = & git -C $RepoPath worktree list --porcelain 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to read git worktree list for '$RepoPath'."
    }

    $paths = @()
    foreach ($line in @($output)) {
        $text = [string]$line
        if ($text -like 'worktree *') {
            $paths += $text.Substring(9).Trim()
        }
    }

    return @($paths)
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw "Required command 'git' was not found on PATH."
}

$inputSet = New-CaseInsensitiveSet
foreach ($path in @($Paths)) {
    if ([string]::IsNullOrWhiteSpace($path)) {
        continue
    }
    [void]$inputSet.Add((ConvertTo-NormalizedPath -Path $path))
}

if ($inputSet.Count -eq 0) {
    throw 'No non-empty paths were provided to Ensure-GitSafeDirectories.'
}

$targetSet = New-CaseInsensitiveSet
foreach ($path in @($inputSet)) {
    [void]$targetSet.Add($path)
}

$existingRaw = @(& git config --global --get-all safe.directory 2>$null)
if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 1) {
    throw 'Failed to query existing git safe.directory entries.'
}

$existingSet = New-CaseInsensitiveSet
foreach ($line in @($existingRaw)) {
    $value = [string]$line
    if ([string]::IsNullOrWhiteSpace($value)) {
        continue
    }
    [void]$existingSet.Add((ConvertTo-NormalizedPathOrRaw -Path $value))
}

$added = New-Object 'System.Collections.Generic.List[string]'
$alreadyPresent = New-Object 'System.Collections.Generic.List[string]'

if ($IncludeGitWorktrees) {
    foreach ($path in @($inputSet)) {
        if (-not (Test-GitRepoPath -Path $path)) {
            continue
        }

        # Ensure the repo root itself is safe before probing worktrees.
        if (-not $existingSet.Contains($path)) {
            & git config --global --add safe.directory $path 2>$null
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to configure git safe.directory entry for '$path'."
            }
            [void]$existingSet.Add($path)
            [void]$added.Add($path)
        }

        foreach ($worktreePath in @(Get-GitWorktreePaths -RepoPath $path)) {
            if ([string]::IsNullOrWhiteSpace($worktreePath)) {
                continue
            }
            [void]$targetSet.Add((ConvertTo-NormalizedPath -Path $worktreePath))
        }
    }
}
foreach ($path in @($targetSet)) {
    if ($existingSet.Contains($path)) {
        if (-not $added.Contains($path)) {
            [void]$alreadyPresent.Add($path)
        }
        continue
    }

    & git config --global --add safe.directory $path 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to configure git safe.directory entry for '$path'."
    }
    [void]$existingSet.Add($path)
    [void]$added.Add($path)
}

$validation = New-Object 'System.Collections.Generic.List[object]'
if ($ValidateGitStatus) {
    foreach ($path in @($targetSet)) {
        $entry = [ordered]@{
            path = $path
            exists = (Test-Path -LiteralPath $path -PathType Container)
            is_git_repo = $false
            status_check = 'skipped'
            details = ''
        }

        if (-not $entry.exists) {
            [void]$validation.Add([pscustomobject]$entry)
            continue
        }

        $isRepo = Test-GitRepoPath -Path $path
        $entry.is_git_repo = $isRepo
        if (-not $isRepo) {
            [void]$validation.Add([pscustomobject]$entry)
            continue
        }

        $statusOutput = @(& git -C $path status --porcelain --untracked-files=no 2>&1)
        if ($LASTEXITCODE -eq 0) {
            $entry.status_check = 'pass'
        } else {
            $entry.status_check = 'fail'
            $entry.details = [string]::Join("`n", @($statusOutput | ForEach-Object { [string]$_ }))
            if ($entry.details -match 'detected dubious ownership') {
                $entry.details = "detected_dubious_ownership`n$($entry.details)"
            }
        }
        [void]$validation.Add([pscustomobject]$entry)
    }

    $failedValidation = @($validation | Where-Object { [string]$_.status_check -eq 'fail' })
    if ($failedValidation.Count -gt 0) {
        throw ("Git safe.directory validation failed for {0} path(s)." -f $failedValidation.Count)
    }
}

$inputPathCount = [int]$inputSet.Count
$targetPathCount = [int]$targetSet.Count
$addedPaths = @($added.ToArray())
$alreadyPresentPaths = @($alreadyPresent.ToArray())
$validationEntries = @($validation.ToArray())

$result = [ordered]@{
    status = 'pass'
    include_git_worktrees = [bool]$IncludeGitWorktrees
    validate_git_status = [bool]$ValidateGitStatus
    input_path_count = $inputPathCount
    target_path_count = $targetPathCount
    added_count = @($addedPaths).Count
    already_present_count = @($alreadyPresentPaths).Count
    added_paths = $addedPaths
    already_present_paths = $alreadyPresentPaths
    validation = $validationEntries
    machine_name = [string]$env:COMPUTERNAME
    user_name = [string]$env:USERNAME
    timestamp_utc = (Get-Date).ToUniversalTime().ToString('o')
}

if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $resolvedOutputPath = ConvertTo-NormalizedPath -Path $OutputPath
    $outputDir = Split-Path -Parent $resolvedOutputPath
    if (-not [string]::IsNullOrWhiteSpace($outputDir) -and -not (Test-Path -LiteralPath $outputDir -PathType Container)) {
        New-Item -Path $outputDir -ItemType Directory -Force | Out-Null
    }
    $result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resolvedOutputPath -Encoding utf8
}

[pscustomobject]$result
