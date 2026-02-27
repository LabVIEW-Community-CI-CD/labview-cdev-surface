#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Release control plane decision trail contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:scriptPath = Join-Path $script:repoRoot 'scripts/Write-ReleaseControlPlaneDecisionTrail.ps1'

        if (-not (Test-Path -LiteralPath $script:scriptPath -PathType Leaf)) {
            throw "Decision trail script missing: $script:scriptPath"
        }

        $script:scriptContent = Get-Content -LiteralPath $script:scriptPath -Raw
    }

    It 'writes deterministic decision-trail evidence from control-plane report' {
        $script:scriptContent | Should -Match 'control_plane_report_missing'
        $script:scriptContent | Should -Match 'Get-FileHash'
        $script:scriptContent | Should -Match 'decision_evidence'
        $script:scriptContent | Should -Match 'state_machine'
        $script:scriptContent | Should -Match 'rollback_orchestration'
        $script:scriptContent | Should -Match 'stable_window_decision'
        $script:scriptContent | Should -Match 'signature'
        $script:scriptContent | Should -Match 'fingerprint'
        $script:scriptContent | Should -Match 'Write-WorkflowOpsReport'
    }

    It 'has parse-safe PowerShell syntax' {
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($script:scriptContent, [ref]$tokens, [ref]$errors)
        @($errors).Count | Should -Be 0
    }

    It 'handles missing optional stable-window decision fields in validate mode' {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("decision-trail-contract-" + [Guid]::NewGuid().ToString('N'))
        New-Item -Path $tempRoot -ItemType Directory -Force | Out-Null
        try {
            $reportPath = Join-Path $tempRoot 'release-control-plane-report.json'
            $trailPath = Join-Path $tempRoot 'release-control-plane-decision-trail.json'
            $report = [ordered]@{
                schema_version = '1.0'
                timestamp_utc = '2026-02-27T11:07:04.0000000Z'
                repository = 'LabVIEW-Community-CI-CD/labview-cdev-surface-fork'
                branch = 'main'
                mode = 'Validate'
                dry_run = $true
                control_plane_policy_schema_version = '2.0'
                control_plane_policy_source = 'workspace_governance'
                status = 'pass'
                reason_code = 'validate_dry_run'
                message = 'ok'
                state_machine = $null
                rollback_orchestration = $null
                stable_promotion_window = [ordered]@{
                    decision = [ordered]@{
                        status = 'skipped'
                        reason_code = 'not_full_cycle_mode'
                    }
                }
                executions = @()
            }

            $report | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $reportPath -Encoding utf8
            & pwsh -NoProfile -File $script:scriptPath -ReportPath $reportPath -OutputPath $trailPath | Out-Null

            Test-Path -LiteralPath $trailPath -PathType Leaf | Should -BeTrue
            $trail = Get-Content -LiteralPath $trailPath -Raw | ConvertFrom-Json -Depth 20
            $trail.decision_evidence.stable_window_decision.status | Should -Be 'skipped'
            $trail.decision_evidence.stable_window_decision.reason_code | Should -Be 'not_full_cycle_mode'
            $trail.decision_evidence.stable_window_decision.can_promote | Should -BeFalse
            $trail.decision_evidence.stable_window_decision.current_utc_weekday | Should -Be ''
        } finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }
}
