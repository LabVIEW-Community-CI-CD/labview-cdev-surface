#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter()]
    [string]$WorkspaceRoot = 'C:\dev',

    [Parameter()]
    [switch]$FailOnWarning
)

$ErrorActionPreference = 'Stop'

function Resolve-FirstExistingPath {
    param(
        [string[]]$Candidates
    )

    foreach ($candidate in @($Candidates)) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -Path $candidate)) {
            return $candidate
        }
    }

    if (@($Candidates).Count -gt 0) {
        return $Candidates[0]
    }
    return $null
}

$manifestPath = Join-Path $WorkspaceRoot 'workspace-governance.json'
$parentAgentsPath = Join-Path $WorkspaceRoot 'AGENTS.md'
$iconEditorRepoCandidates = @(
    'C:\Users\Sergio Velderrain\repos\labview-icon-editor',
    (Join-Path $WorkspaceRoot 'labview-icon-editor')
)
$repoAgentsPath = Resolve-FirstExistingPath -Candidates @(
    (Join-Path $iconEditorRepoCandidates[0] 'AGENTS.md'),
    (Join-Path $iconEditorRepoCandidates[1] 'AGENTS.md')
)
$containersForkAgentsPath = Join-Path $WorkspaceRoot 'labview-for-containers-org\AGENTS.md'

$repoWrapperPath = Resolve-FirstExistingPath -Candidates @(
    (Join-Path $iconEditorRepoCandidates[0] '.github\scripts\Invoke-GovernanceContract.ps1'),
    (Join-Path $iconEditorRepoCandidates[1] '.github\scripts\Invoke-GovernanceContract.ps1')
)
$repoWorkflowPath = Resolve-FirstExistingPath -Candidates @(
    (Join-Path $iconEditorRepoCandidates[0] '.github\workflows\governance-contract.yml'),
    (Join-Path $iconEditorRepoCandidates[1] '.github\workflows\governance-contract.yml')
)
$containersWrapperPath = Join-Path $WorkspaceRoot 'labview-for-containers-org\.github\scripts\Invoke-GovernanceContract.ps1'
$containersWorkflowPath = Join-Path $WorkspaceRoot 'labview-for-containers-org\.github\workflows\governance-contract.yml'

$failures = @()
$warnings = @()
$checks = @()

function Add-Check {
    param(
        [string]$Scope,
        [string]$Name,
        [bool]$Passed,
        [string]$Detail,
        [ValidateSet('error', 'warning')]
        [string]$Severity = 'error'
    )

    $entry = [ordered]@{
        scope = $Scope
        check = $Name
        passed = $Passed
        severity = $Severity
        detail = $Detail
    }
    $script:checks += [pscustomobject]$entry

    if (-not $Passed) {
        if ($Severity -eq 'warning') {
            $script:warnings += "$Scope :: $Name :: $Detail"
        } else {
            $script:failures += "$Scope :: $Name :: $Detail"
        }
    }
}

if (-not (Test-Path -Path $manifestPath)) {
    throw "Manifest not found: $manifestPath"
}

$manifest = Get-Content -Path $manifestPath -Raw | ConvertFrom-Json
Add-Check -Scope 'manifest' -Name 'managed_repo_count' -Passed ($manifest.managed_repos.Count -ge 9) -Detail "managed_repos=$($manifest.managed_repos.Count)"

$installerContractProperty = $manifest.PSObject.Properties['installer_contract']
$installerContract = if ($null -ne $installerContractProperty) { $manifest.installer_contract } else { $null }
$installerContractMembers = if ($null -ne $installerContract) { @($installerContract.PSObject.Properties.Name) } else { @() }

Add-Check -Scope 'manifest' -Name 'has_installer_contract_reproducibility' -Passed ($installerContractMembers -contains 'reproducibility') -Detail 'installer_contract.reproducibility'
Add-Check -Scope 'manifest' -Name 'has_installer_contract_provenance' -Passed ($installerContractMembers -contains 'provenance') -Detail 'installer_contract.provenance'
Add-Check -Scope 'manifest' -Name 'has_installer_contract_canary' -Passed ($installerContractMembers -contains 'canary') -Detail 'installer_contract.canary'
Add-Check -Scope 'manifest' -Name 'has_installer_contract_cli_bundle' -Passed ($installerContractMembers -contains 'cli_bundle') -Detail 'installer_contract.cli_bundle'
Add-Check -Scope 'manifest' -Name 'has_installer_contract_harness' -Passed ($installerContractMembers -contains 'harness') -Detail 'installer_contract.harness'
if ($installerContractMembers -contains 'reproducibility') {
    Add-Check -Scope 'manifest' -Name 'reproducibility_required_true' -Passed ([bool]$manifest.installer_contract.reproducibility.required) -Detail "required=$($manifest.installer_contract.reproducibility.required)"
    Add-Check -Scope 'manifest' -Name 'reproducibility_strict_hash_match_true' -Passed ([bool]$manifest.installer_contract.reproducibility.strict_hash_match) -Detail "strict_hash_match=$($manifest.installer_contract.reproducibility.strict_hash_match)"
}
if ($installerContractMembers -contains 'provenance') {
    $formats = @($manifest.installer_contract.provenance.formats)
    Add-Check -Scope 'manifest' -Name 'provenance_formats_include_spdx' -Passed ($formats -contains 'SPDX-2.3-JSON') -Detail ([string]::Join(',', $formats))
    Add-Check -Scope 'manifest' -Name 'provenance_formats_include_slsa' -Passed ($formats -contains 'SLSA-v1-JSON') -Detail ([string]::Join(',', $formats))
}
if ($installerContractMembers -contains 'canary') {
    Add-Check -Scope 'manifest' -Name 'canary_has_schedule' -Passed (-not [string]::IsNullOrWhiteSpace([string]$manifest.installer_contract.canary.schedule_cron_utc)) -Detail ([string]$manifest.installer_contract.canary.schedule_cron_utc)
    Add-Check -Scope 'manifest' -Name 'canary_linux_context' -Passed ([string]$manifest.installer_contract.canary.docker_context -eq 'desktop-linux') -Detail ([string]$manifest.installer_contract.canary.docker_context)
}
if ($installerContractMembers -contains 'cli_bundle') {
    $cliBundle = $manifest.installer_contract.cli_bundle
    Add-Check -Scope 'manifest' -Name 'cli_bundle_repo' -Passed ([string]$cliBundle.repo -eq 'LabVIEW-Community-CI-CD/labview-cdev-cli') -Detail ([string]$cliBundle.repo)
    Add-Check -Scope 'manifest' -Name 'cli_bundle_asset_win' -Passed ([string]$cliBundle.asset_win -eq 'cdev-cli-win-x64.zip') -Detail ([string]$cliBundle.asset_win)
    Add-Check -Scope 'manifest' -Name 'cli_bundle_asset_linux' -Passed ([string]$cliBundle.asset_linux -eq 'cdev-cli-linux-x64.tar.gz') -Detail ([string]$cliBundle.asset_linux)
    Add-Check -Scope 'manifest' -Name 'cli_bundle_asset_win_sha256' -Passed ([regex]::IsMatch(([string]$cliBundle.asset_win_sha256).ToLowerInvariant(), '^[0-9a-f]{64}$')) -Detail ([string]$cliBundle.asset_win_sha256)
    Add-Check -Scope 'manifest' -Name 'cli_bundle_asset_linux_sha256' -Passed ([regex]::IsMatch(([string]$cliBundle.asset_linux_sha256).ToLowerInvariant(), '^[0-9a-f]{64}$')) -Detail ([string]$cliBundle.asset_linux_sha256)
    Add-Check -Scope 'manifest' -Name 'cli_bundle_entrypoint_win' -Passed ([string]$cliBundle.entrypoint_win -eq 'tools\cdev-cli\win-x64\cdev-cli\scripts\Invoke-CdevCli.ps1') -Detail ([string]$cliBundle.entrypoint_win)
    Add-Check -Scope 'manifest' -Name 'cli_bundle_entrypoint_linux' -Passed ([string]$cliBundle.entrypoint_linux -eq 'tools/cdev-cli/linux-x64/cdev-cli/scripts/Invoke-CdevCli.ps1') -Detail ([string]$cliBundle.entrypoint_linux)
}
if ($installerContractMembers -contains 'harness') {
    $harness = $manifest.installer_contract.harness
    Add-Check -Scope 'manifest' -Name 'harness_workflow_name' -Passed ([string]$harness.workflow_name -eq 'installer-harness-self-hosted.yml') -Detail ([string]$harness.workflow_name)
    Add-Check -Scope 'manifest' -Name 'harness_trigger_mode' -Passed ([string]$harness.trigger_mode -eq 'integration_branch_push_and_dispatch') -Detail ([string]$harness.trigger_mode)
    foreach ($label in @('self-hosted', 'windows', 'self-hosted-windows-lv')) {
        Add-Check -Scope 'manifest' -Name "harness_runner_label:$label" -Passed (@($harness.runner_labels) -contains $label) -Detail ([string]::Join(',', @($harness.runner_labels)))
    }
    foreach ($requiredReport in @('iteration-summary.json', 'exercise-report.json', 'C:\dev-smoke-lvie\artifacts\workspace-install-latest.json', 'lvie-cdev-workspace-installer-bundle.zip', 'harness-validation-report.json')) {
        Add-Check -Scope 'manifest' -Name "harness_required_report:$requiredReport" -Passed (@($harness.required_reports) -contains $requiredReport) -Detail ([string]::Join(',', @($harness.required_reports)))
    }
    foreach ($requiredPostaction in @('ppl_capability_checks.32', 'ppl_capability_checks.64', 'vip_package_build_check')) {
        Add-Check -Scope 'manifest' -Name "harness_required_postaction:$requiredPostaction" -Passed (@($harness.required_postactions) -contains $requiredPostaction) -Detail ([string]::Join(',', @($harness.required_postactions)))
    }
}

$requiredSchemaFields = @(
    'path',
    'repo_name',
    'mode',
    'required_remotes',
    'allowed_mutation_remotes',
    'required_gh_repo',
    'forbidden_targets',
    'default_branch',
    'branch_protection_required',
    'default_branch_mutation_policy',
    'required_status_checks',
    'strict_status_checks',
    'required_review_policy',
    'forbid_force_push',
    'forbid_deletion',
    'pinned_sha'
)

foreach ($repo in $manifest.managed_repos) {
    $scope = "manifest:$($repo.repo_name)"
    foreach ($field in $requiredSchemaFields) {
        $present = $null -ne $repo.PSObject.Properties[$field]
        Add-Check -Scope $scope -Name "has_field:$field" -Passed $present -Detail $field
    }

    if ($null -ne $repo.PSObject.Properties['required_status_checks']) {
        Add-Check -Scope $scope -Name 'required_status_checks_nonempty' -Passed (@($repo.required_status_checks).Count -gt 0) -Detail "count=$(@($repo.required_status_checks).Count)"
    }

    if ($null -ne $repo.PSObject.Properties['required_review_policy']) {
        $policy = $repo.required_review_policy
        Add-Check -Scope $scope -Name 'review_policy_has_required_pull_request_reviews' -Passed ($null -ne $policy.PSObject.Properties['required_pull_request_reviews']) -Detail 'required_pull_request_reviews'
        Add-Check -Scope $scope -Name 'review_policy_has_required_approving_review_count' -Passed ($null -ne $policy.PSObject.Properties['required_approving_review_count']) -Detail 'required_approving_review_count'
    }

    if ($null -ne $repo.PSObject.Properties['pinned_sha']) {
        $sha = [string]$repo.pinned_sha
        Add-Check -Scope $scope -Name 'pinned_sha_is_40_hex' -Passed ([regex]::IsMatch($sha, '^[0-9a-f]{40}$')) -Detail $sha
    }
}

if (-not (Test-Path -Path $parentAgentsPath)) {
    Add-Check -Scope 'parent-agents' -Name 'file_exists' -Passed $false -Detail "Missing: $parentAgentsPath"
} else {
    $parentText = Get-Content -Path $parentAgentsPath -Raw
    $parentRequired = @(
        'workspace-governance.json',
        '## Branch Protection Gate',
        'Default-branch mutation is blocked',
        'svelderrainruiz/labview-icon-editor-org:develop',
        'LabVIEW-Community-CI-CD/labview-icon-editor:develop',
        'svelderrainruiz/labview-for-containers-org:main',
        'LabVIEW-Community-CI-CD/labview-for-containers:main',
        'svelderrainruiz/labview-icon-editor-codex-skills:main',
        'LabVIEW-Community-CI-CD/labview-icon-editor-codex-skills:main',
        'svelderrainruiz/labview-cdev-surface:main',
        'LabVIEW-Community-CI-CD/labview-cdev-surface:main',
        'C:\dev\labview-icon-editor-codex-skills',
        'C:\dev\labview-icon-editor-codex-skills-upstream',
        'C:\dev\labview-cdev-surface',
        'C:\dev\labview-cdev-surface-upstream',
        '-R svelderrainruiz/labview-cdev-surface',
        '-R LabVIEW-Community-CI-CD/labview-cdev-surface',
        'Pipeline Contract',
        'Governance Contract',
        'stabilization-2026-certification-gate',
        'Workspace Installer Contract',
        'pinned_sha'
    )
    foreach ($token in $parentRequired) {
        Add-Check -Scope 'parent-agents' -Name "contains:$token" -Passed ($parentText.Contains($token)) -Detail $token
    }

    $staleIconFork = [regex]::IsMatch($parentText, 'svelderrainruiz/labview-icon-editor(?!-(org|codex-skills))')
    Add-Check -Scope 'parent-agents' -Name 'no_stale_icon_fork_target' -Passed (-not $staleIconFork) -Detail 'Must not reference old icon-editor fork target.'

    $unsafeCdevForkMutation = [regex]::IsMatch(
        $parentText,
        '\| `C:\\dev\\labview-cdev-surface` \|[^\r\n]*\(`LabVIEW-Community-CI-CD/labview-cdev-surface`\)'
    )
    Add-Check -Scope 'parent-agents' -Name 'no_unsafe_cdev_fork_mutation_target' -Passed (-not $unsafeCdevForkMutation) -Detail 'Fork cdev-surface path must not allow org mutation target.'
}

if (-not (Test-Path -Path $repoAgentsPath)) {
    Add-Check -Scope 'repo-agents' -Name 'file_exists' -Passed $false -Detail "Missing: $repoAgentsPath"
} else {
    $repoText = Get-Content -Path $repoAgentsPath -Raw
    $repoRequired = @(
        'C:\dev\AGENTS.md',
        'C:\dev\workspace-governance.json',
        'Branch-protection readiness gate',
        'feature-branch mutation + PR flow',
        'svelderrainruiz/labview-icon-editor-org',
        'LabVIEW-Community-CI-CD/labview-icon-editor',
        '-R svelderrainruiz/labview-icon-editor-org'
    )
    foreach ($token in $repoRequired) {
        Add-Check -Scope 'repo-agents' -Name "contains:$token" -Passed ($repoText.Contains($token)) -Detail $token
    }

    $staleIconForkRepo = [regex]::IsMatch($repoText, 'svelderrainruiz/labview-icon-editor(?!-(org|codex-skills))')
    Add-Check -Scope 'repo-agents' -Name 'no_stale_icon_fork_target' -Passed (-not $staleIconForkRepo) -Detail 'Must not reference old icon-editor fork target.'
}

if (-not (Test-Path -Path $containersForkAgentsPath)) {
    Add-Check -Scope 'containers-fork-agents' -Name 'file_exists' -Passed $false -Detail "Missing: $containersForkAgentsPath"
} else {
    $containersText = Get-Content -Path $containersForkAgentsPath -Raw
    $containersRequired = @(
        'C:\dev\AGENTS.md',
        'C:\dev\workspace-governance.json',
        '## Branch Protection Gate',
        'svelderrainruiz/labview-for-containers-org:main',
        'Governance Contract',
        '-R svelderrainruiz/labview-for-containers-org'
    )
    foreach ($token in $containersRequired) {
        Add-Check -Scope 'containers-fork-agents' -Name "contains:$token" -Passed ($containersText.Contains($token)) -Detail $token
    }

    $staleContainersFork = [regex]::IsMatch($containersText, 'svelderrainruiz/labview-for-containers(?!-org)')
    Add-Check -Scope 'containers-fork-agents' -Name 'no_stale_containers_fork_target' -Passed (-not $staleContainersFork) -Detail 'Must not reference old containers fork target.'
}

Add-Check -Scope 'ci-contract' -Name 'repo_wrapper_exists' -Passed (Test-Path -Path $repoWrapperPath) -Detail $repoWrapperPath
Add-Check -Scope 'ci-contract' -Name 'repo_workflow_exists' -Passed (Test-Path -Path $repoWorkflowPath) -Detail $repoWorkflowPath
Add-Check -Scope 'ci-contract' -Name 'containers_wrapper_exists' -Passed (Test-Path -Path $containersWrapperPath) -Detail $containersWrapperPath
Add-Check -Scope 'ci-contract' -Name 'containers_workflow_exists' -Passed (Test-Path -Path $containersWorkflowPath) -Detail $containersWorkflowPath

if (Test-Path -Path $repoWrapperPath) {
    $repoWrapperText = Get-Content -Path $repoWrapperPath -Raw
    Add-Check -Scope 'ci-contract' -Name 'repo_wrapper_checks_branch_protection_api' -Passed ($repoWrapperText.Contains('/protection')) -Detail '/protection'
    Add-Check -Scope 'ci-contract' -Name 'repo_wrapper_checks_required_context_pipeline_contract' -Passed ($repoWrapperText.Contains('Pipeline Contract')) -Detail 'Pipeline Contract'
    Add-Check -Scope 'ci-contract' -Name 'repo_wrapper_checks_required_context_governance_contract' -Passed ($repoWrapperText.Contains('Governance Contract')) -Detail 'Governance Contract'
}

if (Test-Path -Path $containersWrapperPath) {
    $containersWrapperText = Get-Content -Path $containersWrapperPath -Raw
    Add-Check -Scope 'ci-contract' -Name 'containers_wrapper_checks_branch_protection_api' -Passed ($containersWrapperText.Contains('/protection')) -Detail '/protection'
    Add-Check -Scope 'ci-contract' -Name 'containers_wrapper_checks_required_context_linux' -Passed ($containersWrapperText.Contains('run-labview-cli')) -Detail 'run-labview-cli'
    Add-Check -Scope 'ci-contract' -Name 'containers_wrapper_checks_required_context_windows' -Passed ($containersWrapperText.Contains('run-labview-cli-windows')) -Detail 'run-labview-cli-windows'
    Add-Check -Scope 'ci-contract' -Name 'containers_wrapper_checks_required_context_governance' -Passed ($containersWrapperText.Contains('Governance Contract')) -Detail 'Governance Contract'
}

if (Test-Path -Path $repoWorkflowPath) {
    $repoWorkflowText = Get-Content -Path $repoWorkflowPath -Raw
    Add-Check -Scope 'ci-contract' -Name 'repo_workflow_passes_gh_token' -Passed ($repoWorkflowText.Contains('GH_TOKEN: ${{ github.token }}')) -Detail 'GH_TOKEN env'
}

if (Test-Path -Path $containersWorkflowPath) {
    $containersWorkflowText = Get-Content -Path $containersWorkflowPath -Raw
    Add-Check -Scope 'ci-contract' -Name 'containers_workflow_passes_gh_token' -Passed ($containersWorkflowText.Contains('GH_TOKEN: ${{ github.token }}')) -Detail 'GH_TOKEN env'
}

$report = [ordered]@{
    timestamp_utc = (Get-Date).ToUniversalTime().ToString('o')
    workspace_root = $WorkspaceRoot
    fail_on_warning = [bool]$FailOnWarning
    summary = [ordered]@{
        checks = $checks.Count
        failures = $failures.Count
        warnings = $warnings.Count
    }
    checks = $checks
    failures = $failures
    warnings = $warnings
}

$report | ConvertTo-Json -Depth 12 | Write-Output

if ($failures.Count -gt 0) {
    exit 1
}
if ($FailOnWarning -and $warnings.Count -gt 0) {
    exit 1
}

exit 0
