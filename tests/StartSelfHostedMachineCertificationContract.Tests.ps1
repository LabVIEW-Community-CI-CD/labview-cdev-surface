#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Start self-hosted machine certification dispatch contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:startScriptPath = Join-Path $script:repoRoot 'scripts/Start-SelfHostedMachineCertification.ps1'
        if (-not (Test-Path -LiteralPath $script:startScriptPath -PathType Leaf)) {
            throw "Dispatcher script not found: $script:startScriptPath"
        }
        $script:startScriptContent = Get-Content -LiteralPath $script:startScriptPath -Raw
    }

    It 'validates execution bitness from setup profile' {
        $script:startScriptContent | Should -Match 'function Get-SetupExecutionBitness'
        $script:startScriptContent | Should -Match 'execution_bitness_invalid'
        $script:startScriptContent | Should -Match 'Allowed values: auto, 32, 64'
    }

    It 'passes execution bitness and secondary-32 policy into workflow dispatch inputs' {
        $script:startScriptContent | Should -Match 'executionBitness = Get-SetupExecutionBitness'
        $script:startScriptContent | Should -Match 'requireSecondary32 = \(Get-SetupBoolean -Setup \$setup -PropertyName ''require_secondary_32'''
        $script:startScriptContent | Should -Match '''-f'', \("execution_bitness=\{0\}" -f \$executionBitness\)'
        $script:startScriptContent | Should -Match '''-f'', \("require_secondary_32=\{0\}" -f \$requireSecondary32\)'
    }

    It 'records execution bitness and secondary-32 policy in dispatch report' {
        $script:startScriptContent | Should -Match 'execution_bitness = \$executionBitness'
        $script:startScriptContent | Should -Match 'require_secondary_32 = \$requireSecondary32'
    }
    It 'auto-attaches missing upstream actor labels when base routing matches' {
        $script:startScriptContent | Should -Match 'function Get-RunnerInventory'
        $script:startScriptContent | Should -Match 'requiredActorLabels = @\(\$requiredLabels \| Where-Object \{ \$_ -like ''cert-actor-\*'' \}'
        $script:startScriptContent | Should -Match 'runner_actor_label_autofix'
        $script:startScriptContent | Should -Match 'actions/runners/\{0\}/labels'
        $script:startScriptContent | Should -Match 'labels\[\]='
    }

    It 'enforces setup/actor routing contract before dispatch' {
        $script:startScriptContent | Should -Match 'function Get-SetupExpectedLabviewYear'
        $script:startScriptContent | Should -Match 'function Test-SetupRequiresActorLabel'
        $script:startScriptContent | Should -Match 'function Assert-DispatchRoutingContract'
        $script:startScriptContent | Should -Match 'dispatch_routing_setup_label_missing'
        $script:startScriptContent | Should -Match 'dispatch_routing_actor_label_missing'
        $script:startScriptContent | Should -Match 'dispatch_routing_actor_label_mismatch'
        $script:startScriptContent | Should -Match '\$routingContract = Assert-DispatchRoutingContract'
        $script:startScriptContent | Should -Match 'routing_contract_requires_actor_label = \[bool\]\$routingContract\.requires_actor_label'
    }
}

