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
}
