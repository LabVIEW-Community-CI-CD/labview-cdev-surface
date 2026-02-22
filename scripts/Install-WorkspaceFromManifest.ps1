#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter()]
    [string]$WorkspaceRoot = 'C:\dev',

    [Parameter(Mandatory = $true)]
    [string]$ManifestPath,

    [Parameter()]
    [ValidateSet('Install', 'Verify')]
    [string]$Mode = 'Install',

    [Parameter(Mandatory = $true)]
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Ensure-Directory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

function Normalize-Url {
    param([string]$Url)
    if ([string]::IsNullOrWhiteSpace($Url)) {
        return ''
    }
    return ($Url.Trim().TrimEnd('/')).ToLowerInvariant()
}

function To-Bool {
    param($Value)
    return [bool]$Value
}

$resolvedWorkspaceRoot = [System.IO.Path]::GetFullPath($WorkspaceRoot)
$resolvedManifestPath = [System.IO.Path]::GetFullPath($ManifestPath)
$resolvedOutputPath = [System.IO.Path]::GetFullPath($OutputPath)
$payloadRoot = Split-Path -Parent $resolvedManifestPath

$errors = @()
$warnings = @()
$dependencyChecks = @()
$repositoryResults = @()
$payloadSync = [ordered]@{
    status = 'pending'
    files = @()
    message = ''
}
$governanceAudit = [ordered]@{
    invoked = $false
    status = 'not_run'
    exit_code = $null
    report_path = Join-Path $resolvedWorkspaceRoot 'artifacts\workspace-governance-latest.json'
    branch_only_failure = $false
    branch_failures = @()
    non_branch_failures = @()
    message = ''
}

try {
    Ensure-Directory -Path $resolvedWorkspaceRoot
    Ensure-Directory -Path (Split-Path -Parent $resolvedOutputPath)

    foreach ($commandName in @('pwsh', 'git', 'gh')) {
        $cmd = Get-Command $commandName -ErrorAction SilentlyContinue
        $check = [ordered]@{
            command = $commandName
            present = To-Bool ($null -ne $cmd)
            path = if ($null -ne $cmd) { $cmd.Source } else { '' }
        }
        $dependencyChecks += [pscustomobject]$check
        if (-not $check.present) {
            $errors += "Required command '$commandName' was not found on PATH."
        }
    }

    if (-not (Test-Path -LiteralPath $resolvedManifestPath -PathType Leaf)) {
        throw "Manifest not found: $resolvedManifestPath"
    }

    $manifest = Get-Content -LiteralPath $resolvedManifestPath -Raw | ConvertFrom-Json -ErrorAction Stop
    if ($null -eq $manifest.managed_repos -or @($manifest.managed_repos).Count -eq 0) {
        throw "Manifest does not contain managed_repos entries: $resolvedManifestPath"
    }

    foreach ($repo in @($manifest.managed_repos)) {
        $repoPath = [string]$repo.path
        $repoName = [string]$repo.repo_name
        $defaultBranch = [string]$repo.default_branch
        $requiredGhRepo = [string]$repo.required_gh_repo
        $pinnedSha = ([string]$repo.pinned_sha).ToLowerInvariant()
        $existsBefore = Test-Path -LiteralPath $repoPath -PathType Container

        $repoResult = [ordered]@{
            path = $repoPath
            repo_name = $repoName
            required_gh_repo = $requiredGhRepo
            default_branch = $defaultBranch
            pinned_sha = $pinnedSha
            exists_before = $existsBefore
            action = if ($existsBefore) { 'verify_existing' } else { 'clone_missing' }
            status = 'pass'
            issues = @()
            message = ''
            remote_checks = @()
            head_sha = ''
            branch_state = ''
        }

        try {
            if ($pinnedSha -notmatch '^[0-9a-f]{40}$') {
                throw "Manifest entry '$repoPath' has invalid pinned_sha '$pinnedSha'."
            }

            if (-not $existsBefore) {
                if ($Mode -eq 'Verify') {
                    throw "Repository path missing in Verify mode: $repoPath"
                }

                $originUrl = [string]$repo.required_remotes.origin
                if ([string]::IsNullOrWhiteSpace($originUrl)) {
                    throw "Manifest entry '$repoPath' is missing required_remotes.origin."
                }

                Ensure-Directory -Path (Split-Path -Parent $repoPath)
                $cloneOutput = & git clone $originUrl $repoPath 2>&1
                if ($LASTEXITCODE -ne 0) {
                    throw "git clone failed for '$repoPath'. $([string]::Join("`n", @($cloneOutput)))"
                }
            }

            if (-not (Test-Path -LiteralPath (Join-Path $repoPath '.git') -PathType Container)) {
                throw "Path is not a git repository: $repoPath"
            }

            foreach ($remoteProp in $repo.required_remotes.PSObject.Properties) {
                $remoteName = [string]$remoteProp.Name
                $expectedUrl = [string]$remoteProp.Value
                if ([string]::IsNullOrWhiteSpace($remoteName) -or [string]::IsNullOrWhiteSpace($expectedUrl)) {
                    continue
                }

                $currentUrlRaw = & git -C $repoPath remote get-url $remoteName 2>$null
                $currentExit = $LASTEXITCODE
                $currentUrl = if ($currentExit -eq 0) { [string]$currentUrlRaw.Trim() } else { '' }
                $remoteCheck = [ordered]@{
                    remote = $remoteName
                    expected = $expectedUrl
                    before = $currentUrl
                    after = $currentUrl
                    status = 'ok'
                    message = ''
                }

                if ($currentExit -ne 0) {
                    if ($existsBefore -or $Mode -eq 'Verify') {
                        $remoteCheck.status = 'missing'
                        $remoteCheck.message = 'Remote is missing on an existing repository.'
                        $repoResult.status = 'fail'
                        $repoResult.issues += "remote_missing_$remoteName"
                    } else {
                        $addOutput = & git -C $repoPath remote add $remoteName $expectedUrl 2>&1
                        if ($LASTEXITCODE -ne 0) {
                            throw "Failed to add remote '$remoteName' on '$repoPath'. $([string]::Join("`n", @($addOutput)))"
                        }
                        $afterUrl = (& git -C $repoPath remote get-url $remoteName).Trim()
                        $remoteCheck.after = $afterUrl
                        if ((Normalize-Url $afterUrl) -eq (Normalize-Url $expectedUrl)) {
                            $remoteCheck.status = 'added'
                        } else {
                            $remoteCheck.status = 'add_mismatch'
                            $remoteCheck.message = 'Added remote URL does not match expected value.'
                            $repoResult.status = 'fail'
                            $repoResult.issues += "remote_add_mismatch_$remoteName"
                        }
                    }
                } elseif ((Normalize-Url $currentUrl) -ne (Normalize-Url $expectedUrl)) {
                    if ($existsBefore -or $Mode -eq 'Verify') {
                        $remoteCheck.status = 'mismatch'
                        $remoteCheck.message = 'Existing remote URL does not match expected value.'
                        $repoResult.status = 'fail'
                        $repoResult.issues += "remote_mismatch_$remoteName"
                    } else {
                        $setOutput = & git -C $repoPath remote set-url $remoteName $expectedUrl 2>&1
                        if ($LASTEXITCODE -ne 0) {
                            throw "Failed to set remote '$remoteName' on '$repoPath'. $([string]::Join("`n", @($setOutput)))"
                        }
                        $afterUrl = (& git -C $repoPath remote get-url $remoteName).Trim()
                        $remoteCheck.after = $afterUrl
                        if ((Normalize-Url $afterUrl) -eq (Normalize-Url $expectedUrl)) {
                            $remoteCheck.status = 'updated'
                        } else {
                            $remoteCheck.status = 'update_mismatch'
                            $remoteCheck.message = 'Updated remote URL does not match expected value.'
                            $repoResult.status = 'fail'
                            $repoResult.issues += "remote_update_mismatch_$remoteName"
                        }
                    }
                }

                $repoResult.remote_checks += [pscustomobject]$remoteCheck
            }

            if (-not [string]::IsNullOrWhiteSpace($defaultBranch)) {
                $fetchOutput = & git -C $repoPath fetch --no-tags origin $defaultBranch 2>&1
                if ($LASTEXITCODE -ne 0) {
                    throw "Failed to fetch origin/$defaultBranch for '$repoPath'. $([string]::Join("`n", @($fetchOutput)))"
                }

                & git -C $repoPath show-ref --verify "refs/remotes/origin/$defaultBranch" *> $null
                if ($LASTEXITCODE -ne 0) {
                    $repoResult.status = 'fail'
                    $repoResult.issues += 'default_branch_missing_on_origin'
                }
            }

            if (-not $existsBefore -and $Mode -eq 'Install') {
                $checkoutOutput = & git -C $repoPath checkout --detach $pinnedSha 2>&1
                if ($LASTEXITCODE -ne 0) {
                    throw "Failed to checkout pinned_sha '$pinnedSha' in '$repoPath'. $([string]::Join("`n", @($checkoutOutput)))"
                }
            }

            $headOutput = & git -C $repoPath rev-parse HEAD 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to resolve HEAD for '$repoPath'. $([string]::Join("`n", @($headOutput)))"
            }
            $headSha = [string]$headOutput.Trim().ToLowerInvariant()
            $repoResult.head_sha = $headSha
            if ($headSha -ne $pinnedSha) {
                $repoResult.status = 'fail'
                $repoResult.issues += 'head_sha_mismatch'
            }

            $branchOutput = & git -C $repoPath symbolic-ref --quiet --short HEAD 2>$null
            if ($LASTEXITCODE -eq 0) {
                $branchName = [string]$branchOutput.Trim()
                $repoResult.branch_state = $branchName
                if (-not [string]::IsNullOrWhiteSpace($defaultBranch) -and $branchName -ne $defaultBranch) {
                    $repoResult.status = 'fail'
                    $repoResult.issues += 'branch_identity_mismatch'
                }
            } else {
                $repoResult.branch_state = 'detached'
            }

            if ($repoResult.status -eq 'pass') {
                $repoResult.message = 'Repository satisfies deterministic manifest contract.'
            } else {
                $repoResult.message = 'Repository violates deterministic manifest contract.'
            }
        } catch {
            $repoResult.status = 'fail'
            $repoResult.issues += 'exception'
            $repoResult.message = $_.Exception.Message
        }

        if ($repoResult.status -ne 'pass') {
            $errors += "$repoPath :: $($repoResult.message)"
        }

        $repositoryResults += [pscustomobject]$repoResult
    }

    $payloadFiles = @(
        @{ source = (Join-Path $payloadRoot 'AGENTS.md'); destination = (Join-Path $resolvedWorkspaceRoot 'AGENTS.md') },
        @{ source = (Join-Path $payloadRoot 'workspace-governance.json'); destination = (Join-Path $resolvedWorkspaceRoot 'workspace-governance.json') },
        @{ source = (Join-Path $payloadRoot 'scripts\Assert-WorkspaceGovernance.ps1'); destination = (Join-Path $resolvedWorkspaceRoot 'scripts\Assert-WorkspaceGovernance.ps1') },
        @{ source = (Join-Path $payloadRoot 'scripts\Test-PolicyContracts.ps1'); destination = (Join-Path $resolvedWorkspaceRoot 'scripts\Test-PolicyContracts.ps1') }
    )

    try {
        Ensure-Directory -Path (Join-Path $resolvedWorkspaceRoot 'scripts')

        foreach ($item in $payloadFiles) {
            $sourcePath = [string]$item.source
            $destinationPath = [string]$item.destination
            if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
                throw "Payload file is missing: $sourcePath"
            }
            Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Force
            $payloadSync.files += [pscustomobject]@{
                source = $sourcePath
                destination = $destinationPath
                status = 'copied'
            }
        }

        $payloadSync.status = 'success'
        $payloadSync.message = 'Workspace governance payload copied to workspace root.'
    } catch {
        $payloadSync.status = 'failed'
        $payloadSync.message = $_.Exception.Message
        $errors += "Payload sync failed. $($payloadSync.message)"
    }

    $assertScriptPath = Join-Path $resolvedWorkspaceRoot 'scripts\Assert-WorkspaceGovernance.ps1'
    $workspaceManifestPath = Join-Path $resolvedWorkspaceRoot 'workspace-governance.json'
    $auditOutputPath = [string]$governanceAudit.report_path

    if ((Test-Path -LiteralPath $assertScriptPath -PathType Leaf) -and (Test-Path -LiteralPath $workspaceManifestPath -PathType Leaf)) {
        $governanceAudit.invoked = $true
        & pwsh -NoProfile -File $assertScriptPath -WorkspaceRoot $resolvedWorkspaceRoot -ManifestPath $workspaceManifestPath -Mode Audit -OutputPath $auditOutputPath
        $governanceAudit.exit_code = $LASTEXITCODE

        if (Test-Path -LiteralPath $auditOutputPath -PathType Leaf) {
            $auditReport = Get-Content -LiteralPath $auditOutputPath -Raw | ConvertFrom-Json -ErrorAction Stop
            $failingRepos = @($auditReport.repositories | Where-Object { $_.status -eq 'fail' })
            $nonBranchFailures = @()
            $branchFailures = @()

            foreach ($failingRepo in $failingRepos) {
                $issues = @($failingRepo.issues)
                $hasNonBranchIssue = $false
                foreach ($issue in $issues) {
                    $issueValue = [string]$issue
                    if ($issueValue.StartsWith('branch_protection_')) {
                        continue
                    }
                    $hasNonBranchIssue = $true
                }

                if ($hasNonBranchIssue) {
                    $nonBranchFailures += [string]$failingRepo.path
                } else {
                    $branchFailures += [string]$failingRepo.path
                }
            }

            $governanceAudit.branch_failures = $branchFailures
            $governanceAudit.non_branch_failures = $nonBranchFailures

            if ($governanceAudit.exit_code -eq 0) {
                $governanceAudit.status = 'pass'
                $governanceAudit.message = 'Workspace governance audit passed.'
            } elseif ($nonBranchFailures.Count -eq 0 -and $branchFailures.Count -gt 0) {
                $governanceAudit.status = 'branch_only_fail'
                $governanceAudit.branch_only_failure = $true
                $governanceAudit.message = 'Workspace governance audit has branch-protection-only failures.'
                $warnings += 'Branch protection contract is not fully satisfied; install continues in audit-only mode.'
            } else {
                $governanceAudit.status = 'fail'
                $governanceAudit.message = 'Workspace governance audit failed with non-branch-protection issues.'
                $errors += $governanceAudit.message
            }
        } else {
            $governanceAudit.status = 'fail'
            $governanceAudit.message = "Governance audit report missing: $auditOutputPath"
            $errors += $governanceAudit.message
        }
    } else {
        $governanceAudit.status = 'fail'
        $governanceAudit.message = 'Governance audit prerequisites are missing (assert script or manifest).'
        $errors += $governanceAudit.message
    }
} catch {
    $errors += $_.Exception.Message
}

$status = if ($errors.Count -gt 0) { 'failed' } else { 'succeeded' }
$report = [ordered]@{
    timestamp_utc = (Get-Date).ToUniversalTime().ToString('o')
    status = $status
    mode = $Mode
    workspace_root = $resolvedWorkspaceRoot
    manifest_path = $resolvedManifestPath
    output_path = $resolvedOutputPath
    dependency_checks = $dependencyChecks
    payload_sync = $payloadSync
    repositories = $repositoryResults
    governance_audit = $governanceAudit
    warnings = $warnings
    errors = $errors
}

$report | ConvertTo-Json -Depth 14 | Set-Content -LiteralPath $resolvedOutputPath -Encoding UTF8
Write-Host "Workspace install report: $resolvedOutputPath"

if ($status -ne 'succeeded') {
    exit 1
}

exit 0
