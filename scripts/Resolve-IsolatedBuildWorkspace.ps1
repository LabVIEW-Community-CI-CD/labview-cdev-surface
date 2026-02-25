[CmdletBinding()]
param(
    [Parameter()]
    [string]$PolicyManifestPath,

    [Parameter()]
    [string[]]$WindowsRootCandidates,

    [Parameter()]
    [string]$WorkspaceKind = 'build',

    [Parameter()]
    [string]$RunId = $env:GITHUB_RUN_ID,

    [Parameter()]
    [string]$RunAttempt = $env:GITHUB_RUN_ATTEMPT,

    [Parameter()]
    [string]$JobName = $env:GITHUB_JOB,

    [Parameter()]
    [string]$RunnerName = $env:RUNNER_NAME,

    [Parameter()]
    [string]$OutputPath,

    [Parameter()]
    [switch]$ExportGitHubEnv
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-NormalizedPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $full = [System.IO.Path]::GetFullPath($Path)
    if ($full.Length -gt 3 -and $full.EndsWith('\\')) {
        $full = $full.TrimEnd('\\')
    }
    return $full
}

function ConvertTo-SafeToken {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter()][string]$Default = 'token',
        [Parameter()][int]$MaxLength = 48
    )

    $token = ($Value -replace '[^A-Za-z0-9._-]', '-')
    $token = ($token -replace '-{2,}', '-')
    $token = $token.Trim('-')
    if ([string]::IsNullOrWhiteSpace($token)) {
        $token = $Default
    }
    if ($token.Length -gt $MaxLength) {
        $token = $token.Substring(0, $MaxLength)
    }
    return $token
}

function Get-ShortHashToken {
    param([Parameter(Mandatory = $true)][string]$Value)

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha.ComputeHash($bytes)
    } finally {
        $sha.Dispose()
    }

    return [System.BitConverter]::ToString($hashBytes).Replace('-', '').ToLowerInvariant().Substring(0, 10)
}

function Get-CandidateRoots {
    param(
        [string[]]$ExplicitCandidates,
        [string]$ManifestPath
    )

    $candidates = @()

    if ($null -ne $ExplicitCandidates -and @($ExplicitCandidates).Count -gt 0) {
        $candidates = @($ExplicitCandidates)
    } elseif (-not [string]::IsNullOrWhiteSpace($ManifestPath) -and (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
        $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json -ErrorAction Stop
        $manifestCandidates = @($manifest.installer_contract.build_workspace_policy.windows_root_candidates)
        $candidates = @($manifestCandidates | ForEach-Object { [string]$_ })
    }

    if (@($candidates).Count -eq 0) {
        $candidates = @('D:\\dev', 'C:\\dev')
    }

    $result = New-Object 'System.Collections.Generic.List[string]'
    foreach ($candidate in @($candidates)) {
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }

        $normalized = ConvertTo-NormalizedPath -Path $candidate
        if (-not $result.Contains($normalized)) {
            [void]$result.Add($normalized)
        }
    }

    if ($result.Count -eq 0) {
        throw 'No candidate workspace roots were resolved.'
    }

    return @($result)
}

function Test-RootWritable {
    param([Parameter(Mandatory = $true)][string]$RootPath)

    try {
        if (-not (Test-Path -LiteralPath $RootPath -PathType Container)) {
            New-Item -Path $RootPath -ItemType Directory -Force | Out-Null
        }

        $probeRoot = Join-Path $RootPath '_lvie-ci-probe'
        New-Item -Path $probeRoot -ItemType Directory -Force | Out-Null

        # SmartApp policies may block .tmp extension writes; use a deterministic non-.tmp probe extension.
        $probeFile = Join-Path $probeRoot ("{0}.probe" -f [Guid]::NewGuid().ToString('N'))
        'probe' | Set-Content -LiteralPath $probeFile -Encoding ascii
        Remove-Item -LiteralPath $probeFile -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $probeRoot -Force -ErrorAction SilentlyContinue
        return $true
    } catch {
        return $false
    }
}

$candidateRoots = Get-CandidateRoots -ExplicitCandidates $WindowsRootCandidates -ManifestPath $PolicyManifestPath
$selectedRoot = $null
foreach ($candidateRoot in @($candidateRoots)) {
    if (Test-RootWritable -RootPath $candidateRoot) {
        $selectedRoot = $candidateRoot
        break
    }
}

if ([string]::IsNullOrWhiteSpace($selectedRoot)) {
    throw ("Unable to select a writable isolated root from candidates: {0}" -f ([string]::Join(', ', $candidateRoots)))
}

$effectiveRunId = if ([string]::IsNullOrWhiteSpace($RunId)) { 'local' } else { $RunId }
$effectiveRunAttempt = if ([string]::IsNullOrWhiteSpace($RunAttempt)) { '1' } else { $RunAttempt }
$safeWorkspaceKind = ConvertTo-SafeToken -Value $WorkspaceKind -Default 'build'
$seed = [string]::Join('|', @(
    $effectiveRunId,
    $effectiveRunAttempt,
    $JobName,
    $RunnerName,
    $safeWorkspaceKind
))
$jobHash = Get-ShortHashToken -Value $seed
$runSegment = ConvertTo-SafeToken -Value ("{0}-{1}" -f $effectiveRunId, $effectiveRunAttempt) -Default 'local-1' -MaxLength 64
$jobSegment = ConvertTo-SafeToken -Value ("{0}-{1}" -f $safeWorkspaceKind, $jobHash) -Default ("build-{0}" -f $jobHash) -MaxLength 64

$jobRoot = Join-Path $selectedRoot (Join-Path '_lvie-ci\surface' (Join-Path $runSegment $jobSegment))
$workspaceRoot = Join-Path $jobRoot 'workspace'
$reposRoot = Join-Path $jobRoot 'repos'
$evidenceRoot = Join-Path $jobRoot 'evidence'

foreach ($requiredPath in @($jobRoot, $workspaceRoot, $reposRoot, $evidenceRoot)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Container)) {
        New-Item -Path $requiredPath -ItemType Directory -Force | Out-Null
    }
}

$result = [ordered]@{
    workspace_kind = $safeWorkspaceKind
    selection_source = if ($null -ne $WindowsRootCandidates -and @($WindowsRootCandidates).Count -gt 0) { 'parameter' } elseif (-not [string]::IsNullOrWhiteSpace($PolicyManifestPath)) { 'manifest' } else { 'default' }
    selected_drive_root = $selectedRoot
    candidate_roots = @($candidateRoots)
    run_id = $effectiveRunId
    run_attempt = $effectiveRunAttempt
    job_name = [string]$JobName
    runner_name = [string]$RunnerName
    job_hash = $jobHash
    job_root = $jobRoot
    workspace_root = $workspaceRoot
    repos_root = $reposRoot
    evidence_root = $evidenceRoot
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

if ($ExportGitHubEnv -and -not [string]::IsNullOrWhiteSpace($env:GITHUB_ENV)) {
    @(
        "LVIE_ISOLATED_DRIVE_ROOT=$($result.selected_drive_root)",
        "LVIE_ISOLATED_JOB_ROOT=$($result.job_root)",
        "LVIE_ISOLATED_WORKSPACE_ROOT=$($result.workspace_root)",
        "LVIE_ISOLATED_REPOS_ROOT=$($result.repos_root)",
        "LVIE_ISOLATED_EVIDENCE_ROOT=$($result.evidence_root)"
    ) | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding ascii
}

[pscustomobject]$result
