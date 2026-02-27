#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'VS Code tasks contract for portable workflow ops' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:tasksPath = Join-Path $script:repoRoot '.vscode/tasks.json'
        if (-not (Test-Path -LiteralPath $script:tasksPath -PathType Leaf)) {
            throw "Tasks missing: $script:tasksPath"
        }
        $script:tasksDoc = Get-Content -LiteralPath $script:tasksPath -Raw | ConvertFrom-Json -ErrorAction Stop
        $script:labels = @($script:tasksDoc.tasks | ForEach-Object { [string]$_.label })
    }

    It 'defines dispatch/cancel/watch/queue portable tasks' {
        $script:labels | Should -Contain 'ops: dispatch at remote head (portable)'
        $script:labels | Should -Contain 'ops: cancel stale runs (portable)'
        $script:labels | Should -Contain 'ops: watch run (portable)'
        $script:labels | Should -Contain 'ops: runner queue snapshot (portable)'
        $script:labels | Should -Contain 'ops: release control plane local (docker)'
    }

    It 'routes tasks through Invoke-PortableOps wrapper' {
        $raw = Get-Content -LiteralPath $script:tasksPath -Raw
        $raw | Should -Match 'Invoke-PortableOps\.ps1'
        $raw | Should -Match 'Dispatch-WorkflowAtRemoteHead\.ps1'
        $raw | Should -Match 'Cancel-StaleWorkflowRuns\.ps1'
        $raw | Should -Match 'Watch-WorkflowRun\.ps1'
        $raw | Should -Match 'Get-RunnerQueueSnapshot\.ps1'
        $raw | Should -Match 'Invoke-ReleaseControlPlaneLocalDocker\.ps1'
    }
}
