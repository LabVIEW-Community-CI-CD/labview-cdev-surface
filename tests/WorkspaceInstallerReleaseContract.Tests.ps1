#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Workspace installer release workflow contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:wrapperWorkflowPath = Join-Path $script:repoRoot '.github/workflows/release-workspace-installer.yml'
        $script:coreWorkflowPath = Join-Path $script:repoRoot '.github/workflows/_release-workspace-installer-core.yml'
        $script:runnerPreflightActionPath = Join-Path $script:repoRoot '.github/actions/runner-preflight/action.yml'
        if (-not (Test-Path -LiteralPath $script:wrapperWorkflowPath -PathType Leaf)) {
            throw "Release wrapper workflow not found: $script:wrapperWorkflowPath"
        }
        if (-not (Test-Path -LiteralPath $script:coreWorkflowPath -PathType Leaf)) {
            throw "Release core workflow not found: $script:coreWorkflowPath"
        }
        if (-not (Test-Path -LiteralPath $script:runnerPreflightActionPath -PathType Leaf)) {
            throw "Runner preflight action not found: $script:runnerPreflightActionPath"
        }
        $script:wrapperWorkflowContent = Get-Content -LiteralPath $script:wrapperWorkflowPath -Raw
        $script:coreWorkflowContent = Get-Content -LiteralPath $script:coreWorkflowPath -Raw
        $script:runnerPreflightActionContent = Get-Content -LiteralPath $script:runnerPreflightActionPath -Raw
    }

    It 'keeps dispatch-only wrapper and forwards to release core workflow' {
        $script:wrapperWorkflowContent | Should -Match 'workflow_dispatch:'
        $script:wrapperWorkflowContent | Should -Not -Match '(?m)^\s*push:'
        $script:wrapperWorkflowContent | Should -Not -Match '(?m)^\s*pull_request:'
        $script:wrapperWorkflowContent | Should -Not -Match '(?m)^\s*schedule:'
        $script:wrapperWorkflowContent | Should -Match 'release_tag:'
        $script:wrapperWorkflowContent | Should -Match 'required:\s*true'
        $script:wrapperWorkflowContent | Should -Match 'type:\s*string'
        $script:wrapperWorkflowContent | Should -Match 'prerelease:'
        $script:wrapperWorkflowContent | Should -Match 'release_channel:'
        $script:wrapperWorkflowContent | Should -Match 'type:\s*boolean'
        $script:wrapperWorkflowContent | Should -Match 'allow_existing_tag:'
        $script:wrapperWorkflowContent | Should -Match 'Allow updating an existing release tag'
        $script:wrapperWorkflowContent | Should -Match 'uses:\s*\./\.github/workflows/_release-workspace-installer-core\.yml'
    }

    It 'defines reusable release-core workflow-call inputs' {
        $script:coreWorkflowContent | Should -Match 'workflow_call:'
        $script:coreWorkflowContent | Should -Match 'release_tag:'
        $script:coreWorkflowContent | Should -Match 'allow_existing_tag:'
        $script:coreWorkflowContent | Should -Match 'prerelease:'
        $script:coreWorkflowContent | Should -Match 'release_channel:'
        $script:coreWorkflowContent | Should -Match 'override_applied:'
        $script:coreWorkflowContent | Should -Match 'override_reason:'
        $script:coreWorkflowContent | Should -Match 'override_incident_url:'
    }

    It 'defines package and publish jobs with release asset upload' {
        $script:coreWorkflowContent | Should -Match 'name:\s*Release Ops Health Preflight'
        $script:coreWorkflowContent | Should -Match 'Enforce ops health preflight'
        $script:coreWorkflowContent | Should -Match 'Invoke-OpsMonitoringSnapshot\.ps1'
        $script:coreWorkflowContent | Should -Match 'RequiredRunnerLabelsCsv ''self-hosted,windows,self-hosted-windows-lv'''
        $script:coreWorkflowContent | Should -Match 'reason_code=ops_unhealthy'
        $script:coreWorkflowContent | Should -Match '\[ops_unhealthy\]'
        $script:coreWorkflowContent | Should -Match 'release-ops-health-preflight-\$\{\{\s*github\.run_id\s*\}\}'
        $script:coreWorkflowContent | Should -Match 'name:\s*Release Runner Availability Preflight'
        $script:coreWorkflowContent | Should -Match 'Validate eligible self-hosted release runner availability'
        $script:coreWorkflowContent | Should -Match '(?s)runner_preflight:.*?-\s*name:\s*Checkout.*?actions/checkout@v4.*?-\s*id:\s*check'
        $script:coreWorkflowContent | Should -Match 'uses:\s*\./\.github/actions/runner-preflight'
        $script:coreWorkflowContent | Should -Match 'required_labels_csv:\s*self-hosted,windows,self-hosted-windows-lv'
        $script:runnerPreflightActionContent | Should -Match 'repos/\$repo/actions/runners\?per_page=100'
        $script:runnerPreflightActionContent | Should -Match 'reason_code'
        $script:runnerPreflightActionContent | Should -Match 'runner_unavailable'
        $script:runnerPreflightActionContent | Should -Match 'runner_visibility_unavailable'
        $script:runnerPreflightActionContent | Should -Match 'runner_visibility'
        $script:runnerPreflightActionContent | Should -Match '\[runner_unavailable\]'
        $script:runnerPreflightActionContent | Should -Match '\[runner_visibility_unavailable\]'
        $script:coreWorkflowContent | Should -Match 'release-runner-availability-preflight-\$\{\{\s*github\.run_id\s*\}\}'
        $script:coreWorkflowContent | Should -Match 'name:\s*Package Workspace Installer'
        $script:coreWorkflowContent | Should -Match 'needs:\s*\[ops_health_preflight,\s*runner_preflight\]'
        $script:coreWorkflowContent | Should -Match 'name:\s*Publish GitHub Release Asset'
        $script:coreWorkflowContent | Should -Match 'Release preflight - verify icon-editor upstream pin freshness'
        $script:coreWorkflowContent | Should -Match 'repos/LabVIEW-Community-CI-CD/labview-icon-editor/branches/develop'
        $script:coreWorkflowContent | Should -Match 'Manifest pin is stale'
        $script:coreWorkflowContent | Should -Match 'Build-RunnerCliBundleFromManifest\.ps1'
        $script:coreWorkflowContent | Should -Match 'Test-RunnerCliBundleDeterminism\.ps1'
        $script:coreWorkflowContent | Should -Match 'Test-WorkspaceInstallerDeterminism\.ps1'
        $script:coreWorkflowContent | Should -Match 'Write-ReleaseProvenance\.ps1'
        $script:coreWorkflowContent | Should -Match 'Write-ReleaseManifest\.ps1'
        $script:coreWorkflowContent | Should -Match 'Test-ProvenanceContracts\.ps1'
        $script:coreWorkflowContent | Should -Match 'Set-AuthenticodeSignature'
        $script:coreWorkflowContent | Should -Match 'Get-AuthenticodeSignature'
        $script:coreWorkflowContent | Should -Match 'WORKSPACE_INSTALLER_CODESIGN_PFX_B64'
        $script:coreWorkflowContent | Should -Match 'WORKSPACE_INSTALLER_CODESIGN_PFX_PASSWORD'
        $script:coreWorkflowContent | Should -Match 'signatureDualModeStartUtc'
        $script:coreWorkflowContent | Should -Match 'signatureCanaryEnforceUtc'
        $script:coreWorkflowContent | Should -Match 'signatureGraceEndUtc'
        $script:coreWorkflowContent | Should -Match '\[signature_required\]'
        $script:coreWorkflowContent | Should -Match '\[signature_warning\]'
        $script:coreWorkflowContent | Should -Match 'release-manifest\.json'
        $script:coreWorkflowContent | Should -Match 'release and parity artifact roots are identical'
        $script:coreWorkflowContent | Should -Match 'must not point to parity path'
        $script:coreWorkflowContent | Should -Match 'Parity artifact path was selected for release publish input'
        $script:coreWorkflowContent | Should -Match 'workspace-installer-release-\$\{\{\s*github\.run_id\s*\}\}'
        $script:coreWorkflowContent | Should -Match '(gh release create|''release'',\s*''create'')'
        $script:coreWorkflowContent | Should -Match '\$releaseAssets = @\(\$assetPath, \$shaPath, \$reproPath, \$spdxPath, \$slsaPath, \$releaseManifestPath\)'
        $script:coreWorkflowContent | Should -Match '--target \$releaseTargetSha'
        $script:coreWorkflowContent | Should -Match 'RELEASE_TARGET_SHA:\s*\$\{\{\s*github\.sha\s*\}\}'
        $script:coreWorkflowContent | Should -Match 'already exists'
        $script:coreWorkflowContent | Should -Match 'allow_existing_tag=true'
        $script:coreWorkflowContent | Should -Match 'gh release upload'
        $script:coreWorkflowContent | Should -Match '--clobber'
        $script:coreWorkflowContent | Should -Match '\[release_immutable\]'
    }

    It 'enforces release notes, tag validation, and override disclosure support' {
        $script:coreWorkflowContent | Should -Match '\^v\[0-9\]\+\\\.\[0-9\]\+\\\.\[0-9\]\+\$'
        $script:coreWorkflowContent | Should -Match 'SHA256'
        $script:coreWorkflowContent | Should -Match 'Release target commit'
        $script:coreWorkflowContent | Should -Match 'lvie-cdev-workspace-installer\.exe /S'
        $script:coreWorkflowContent | Should -Match 'workspace-installer\.spdx\.json'
        $script:coreWorkflowContent | Should -Match 'workspace-installer\.slsa\.json'
        $script:coreWorkflowContent | Should -Match 'reproducibility-report\.json'
        $script:coreWorkflowContent | Should -Match 'Release channel'
        $script:coreWorkflowContent | Should -Match 'release_channel'
        $script:coreWorkflowContent | Should -Match 'release-manifest\.json'
        $script:coreWorkflowContent | Should -Match 'Override Disclosure'
        $script:coreWorkflowContent | Should -Match 'OVERRIDE_APPLIED'
    }
}
