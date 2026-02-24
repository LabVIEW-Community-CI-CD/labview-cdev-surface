#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter()]
    [string]$WorkspaceRoot = 'C:\dev',

    [Parameter()]
    [string]$ManifestPath,

    [Parameter()]
    [ValidateSet('Audit', 'Fix')]
    [string]$Mode = 'Audit',

    [Parameter()]
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $WorkspaceRoot 'workspace-governance.json'
}
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $WorkspaceRoot 'artifacts/workspace-governance-latest.json'
}

if ([string]::IsNullOrWhiteSpace($env:GH_TOKEN) -and -not [string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN)) {
    $env:GH_TOKEN = $env:GITHUB_TOKEN
}

$script:GhAvailable = [bool](Get-Command gh -ErrorAction SilentlyContinue)

function Normalize-Url {
    param([string]$Url)
    if ([string]::IsNullOrWhiteSpace($Url)) {
        return ''
    }
    return ($Url.Trim().TrimEnd('/')).ToLowerInvariant()
}

function Get-RemoteUrl {
    param(
        [string]$RepoPath,
        [string]$RemoteName
    )

    $url = & git -C $RepoPath remote get-url $RemoteName 2>$null
    if ($LASTEXITCODE -ne 0) {
        return $null
    }
    return $url.Trim()
}

function Assert-Remote {
    param(
        [string]$RepoPath,
        [string]$RemoteName,
        [string]$ExpectedUrl,
        [string]$OperationMode
    )

    $result = [ordered]@{
        remote = $RemoteName
        expected = $ExpectedUrl
        before = $null
        after = $null
        status = 'unknown'
        message = ''
    }

    $current = Get-RemoteUrl -RepoPath $RepoPath -RemoteName $RemoteName
    $result.before = $current

    if ([string]::IsNullOrWhiteSpace($current)) {
        if ($OperationMode -eq 'Fix') {
            & git -C $RepoPath remote add $RemoteName $ExpectedUrl | Out-Null
            $after = Get-RemoteUrl -RepoPath $RepoPath -RemoteName $RemoteName
            $result.after = $after
            if ((Normalize-Url $after) -eq (Normalize-Url $ExpectedUrl)) {
                $result.status = 'fixed-added'
            } else {
                $result.status = 'failed-add'
                $result.message = 'Remote add attempted but resulting URL does not match expected value.'
            }
        } else {
            $result.status = 'missing'
            $result.message = 'Required remote is missing.'
        }
        return [pscustomobject]$result
    }

    if ((Normalize-Url $current) -eq (Normalize-Url $ExpectedUrl)) {
        $result.after = $current
        $result.status = 'ok'
        return [pscustomobject]$result
    }

    if ($OperationMode -eq 'Fix') {
        & git -C $RepoPath remote set-url $RemoteName $ExpectedUrl | Out-Null
        $after = Get-RemoteUrl -RepoPath $RepoPath -RemoteName $RemoteName
        $result.after = $after
        if ((Normalize-Url $after) -eq (Normalize-Url $ExpectedUrl)) {
            $result.status = 'fixed-updated'
        } else {
            $result.status = 'failed-update'
            $result.message = 'Remote set-url attempted but resulting URL does not match expected value.'
        }
    } else {
        $result.after = $current
        $result.status = 'mismatch'
        $result.message = 'Remote URL does not match expected value.'
    }

    return [pscustomobject]$result
}

function Invoke-GhJson {
    param([string]$Endpoint)

    if (-not $script:GhAvailable) {
        return [pscustomobject]@{
            ok = $false
            data = $null
            error = 'gh CLI not found in PATH.'
        }
    }

    $output = & gh api $Endpoint 2>&1
    if ($LASTEXITCODE -ne 0) {
        return [pscustomobject]@{
            ok = $false
            data = $null
            error = ([string]::Join("`n", @($output)))
        }
    }

    try {
        $data = $output | ConvertFrom-Json
        return [pscustomobject]@{
            ok = $true
            data = $data
            error = ''
        }
    } catch {
        return [pscustomobject]@{
            ok = $false
            data = $null
            error = "Failed to parse gh api output as JSON."
        }
    }
}

function Test-BranchProtectionContract {
    param(
        [string]$RepoSlug,
        [string]$Branch,
        $RepoContract
    )

    $result = [ordered]@{
        repo = $RepoSlug
        branch = $Branch
        status = 'unknown'
        issues = @()
        expected = [ordered]@{
            required_status_checks = @($RepoContract.required_status_checks)
            strict_status_checks = [bool]$RepoContract.strict_status_checks
            required_review_policy = $RepoContract.required_review_policy
            forbid_force_push = [bool]$RepoContract.forbid_force_push
            forbid_deletion = [bool]$RepoContract.forbid_deletion
        }
        actual = [ordered]@{
            required_status_checks = @()
            strict_status_checks = $null
            required_approving_review_count = $null
            dismiss_stale_reviews = $null
            require_code_owner_reviews = $null
            allow_force_pushes = $null
            allow_deletions = $null
        }
        message = ''
    }

    if ([string]::IsNullOrWhiteSpace($RepoSlug) -or [string]::IsNullOrWhiteSpace($Branch)) {
        $result.status = 'fail'
        $result.issues += 'missing_repo_or_branch_contract'
        $result.message = 'Manifest is missing required_gh_repo or default_branch for branch protection check.'
        return [pscustomobject]$result
    }

    $encodedBranch = [uri]::EscapeDataString($Branch)
    $endpoint = "repos/$RepoSlug/branches/$encodedBranch/protection"
    $response = Invoke-GhJson -Endpoint $endpoint

    if (-not $response.ok) {
        $result.status = 'fail'
        if ($response.error -match 'Branch not protected') {
            $result.issues += 'branch_not_protected'
        } else {
            $result.issues += 'branch_protection_api_error'
        }
        $result.message = $response.error
        return [pscustomobject]$result
    }

    $protection = $response.data
    $actualContexts = @()
    if ($null -ne $protection.required_status_checks -and $null -ne $protection.required_status_checks.contexts) {
        $actualContexts = @($protection.required_status_checks.contexts)
    }

    $result.actual.required_status_checks = $actualContexts
    $result.actual.strict_status_checks = if ($null -ne $protection.required_status_checks) { [bool]$protection.required_status_checks.strict } else { $null }

    if ([bool]$RepoContract.strict_status_checks) {
        if ($null -eq $protection.required_status_checks -or -not [bool]$protection.required_status_checks.strict) {
            $result.issues += 'strict_status_checks_not_enabled'
        }
    }

    $expectedContexts = @($RepoContract.required_status_checks)
    foreach ($ctx in $expectedContexts) {
        if ($actualContexts -notcontains $ctx) {
            $result.issues += "missing_status_check_context:$ctx"
        }
    }

    $reviewPolicy = $RepoContract.required_review_policy
    if ($null -ne $reviewPolicy -and [bool]$reviewPolicy.required_pull_request_reviews) {
        if ($null -eq $protection.required_pull_request_reviews) {
            $result.issues += 'required_pull_request_reviews_not_enabled'
        }
    }

    if ($null -ne $protection.required_pull_request_reviews) {
        $actualReviewCount = [int]$protection.required_pull_request_reviews.required_approving_review_count
        $result.actual.required_approving_review_count = $actualReviewCount
        $result.actual.dismiss_stale_reviews = [bool]$protection.required_pull_request_reviews.dismiss_stale_reviews
        $result.actual.require_code_owner_reviews = [bool]$protection.required_pull_request_reviews.require_code_owner_reviews

        if ($null -ne $reviewPolicy -and $null -ne $reviewPolicy.required_approving_review_count) {
            $expectedCount = [int]$reviewPolicy.required_approving_review_count
            if ($actualReviewCount -lt $expectedCount) {
                $result.issues += "required_approving_review_count_below_min:$expectedCount"
            }
        }

        if ($null -ne $reviewPolicy -and $null -ne $reviewPolicy.dismiss_stale_reviews) {
            if ([bool]$protection.required_pull_request_reviews.dismiss_stale_reviews -ne [bool]$reviewPolicy.dismiss_stale_reviews) {
                $result.issues += 'dismiss_stale_reviews_mismatch'
            }
        }

        if ($null -ne $reviewPolicy -and $null -ne $reviewPolicy.require_code_owner_reviews) {
            if ([bool]$protection.required_pull_request_reviews.require_code_owner_reviews -ne [bool]$reviewPolicy.require_code_owner_reviews) {
                $result.issues += 'require_code_owner_reviews_mismatch'
            }
        }
    }

    $allowForcePushesEnabled = if ($null -ne $protection.allow_force_pushes) { [bool]$protection.allow_force_pushes.enabled } else { $null }
    $allowDeletionsEnabled = if ($null -ne $protection.allow_deletions) { [bool]$protection.allow_deletions.enabled } else { $null }
    $result.actual.allow_force_pushes = $allowForcePushesEnabled
    $result.actual.allow_deletions = $allowDeletionsEnabled

    if ([bool]$RepoContract.forbid_force_push -and $allowForcePushesEnabled -ne $false) {
        $result.issues += 'force_push_not_forbidden'
    }

    if ([bool]$RepoContract.forbid_deletion -and $allowDeletionsEnabled -ne $false) {
        $result.issues += 'deletion_not_forbidden'
    }

    if ($result.issues.Count -gt 0) {
        $result.status = 'fail'
        $result.message = 'Branch protection contract mismatch.'
    } else {
        $result.status = 'ok'
        $result.message = 'Branch protection contract satisfied.'
    }

    return [pscustomobject]$result
}

if (-not (Test-Path -Path $ManifestPath)) {
    throw "Manifest not found: $ManifestPath"
}

$manifest = Get-Content -Path $ManifestPath -Raw | ConvertFrom-Json

$repoResults = @()
$errors = @()
$changesApplied = $false

$managedPaths = @($manifest.managed_repos | ForEach-Object { $_.path })

foreach ($repo in $manifest.managed_repos) {
    $repoPath = [string]$repo.path
    $repoResult = [ordered]@{
        path = $repoPath
        repo_name = [string]$repo.repo_name
        mode = [string]$repo.mode
        required_gh_repo = [string]$repo.required_gh_repo
        default_branch = [string]$repo.default_branch
        status = 'pass'
        issues = @()
        remote_checks = @()
        branch_protection_checks = @()
    }

    if (-not (Test-Path -Path $repoPath)) {
        $repoResult.status = 'fail'
        $repoResult.issues += 'path_missing'
        $repoResults += [pscustomobject]$repoResult
        $errors += "Missing repository path: $repoPath"
        continue
    }

    if (-not (Test-Path -Path (Join-Path $repoPath '.git'))) {
        $repoResult.status = 'fail'
        $repoResult.issues += 'not_git_repository'
        $repoResults += [pscustomobject]$repoResult
        $errors += "Path is not a git repository: $repoPath"
        continue
    }

    foreach ($remoteProp in $repo.required_remotes.PSObject.Properties) {
        $remoteName = [string]$remoteProp.Name
        $expectedUrl = [string]$remoteProp.Value
        if ([string]::IsNullOrWhiteSpace($expectedUrl)) {
            continue
        }

        $check = Assert-Remote -RepoPath $repoPath -RemoteName $remoteName -ExpectedUrl $expectedUrl -OperationMode $Mode
        $repoResult.remote_checks += $check

        if ($check.status -like 'fixed-*') {
            $changesApplied = $true
        }

        if ($check.status -in @('missing', 'mismatch', 'failed-add', 'failed-update')) {
            $repoResult.status = 'fail'
            $repoResult.issues += "remote_$($check.status)_$remoteName"
            $errors += "Remote check failed ($repoPath): $remoteName expected '$expectedUrl' got '$($check.after)'"
        }
    }

    if ([bool]$repo.branch_protection_required) {
        $branchCheck = Test-BranchProtectionContract -RepoSlug ([string]$repo.required_gh_repo) -Branch ([string]$repo.default_branch) -RepoContract $repo
        $repoResult.branch_protection_checks += $branchCheck

        if ($branchCheck.status -ne 'ok') {
            $repoResult.status = 'fail'
            $repoResult.issues += "branch_protection_$($branchCheck.status)"
            $errors += "Branch protection check failed ($($repo.required_gh_repo):$($repo.default_branch)): $($branchCheck.message)"
        }
    }

    $repoResults += [pscustomobject]$repoResult
}

$workspaceGitDirs = Get-ChildItem -Path $WorkspaceRoot -Directory -ErrorAction SilentlyContinue |
    Where-Object { Test-Path (Join-Path $_.FullName '.git') } |
    ForEach-Object { $_.FullName }

$unmanagedGitDirs = @($workspaceGitDirs | Where-Object { $managedPaths -notcontains $_ } | Sort-Object)

$failedCount = @($repoResults | Where-Object { $_.status -eq 'fail' }).Count
$passedCount = @($repoResults | Where-Object { $_.status -eq 'pass' }).Count
$branchProtectionFailedCount = @($repoResults | Where-Object { $_.branch_protection_checks.Count -gt 0 -and $_.branch_protection_checks[0].status -ne 'ok' }).Count

$report = [ordered]@{
    timestamp_utc = (Get-Date).ToUniversalTime().ToString('o')
    workspace_root = $WorkspaceRoot
    manifest_path = $ManifestPath
    mode = $Mode
    summary = [ordered]@{
        total_repos = $repoResults.Count
        passed = $passedCount
        failed = $failedCount
        branch_protection_failed = $branchProtectionFailedCount
        unmanaged_git_dirs = $unmanagedGitDirs.Count
        changes_applied = $changesApplied
    }
    unmanaged_git_dirs = $unmanagedGitDirs
    repositories = $repoResults
    errors = $errors
}

$outputDir = Split-Path -Path $OutputPath -Parent
if (-not (Test-Path -Path $outputDir)) {
    New-Item -Path $outputDir -ItemType Directory -Force | Out-Null
}

$report | ConvertTo-Json -Depth 12 | Out-File -FilePath $OutputPath -Encoding ascii
Write-Host "Governance report written: $OutputPath"

if ($failedCount -gt 0) {
    exit 1
}

exit 0
