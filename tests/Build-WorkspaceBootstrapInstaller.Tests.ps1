#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Build-WorkspaceBootstrapInstaller script' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:scriptPath = Join-Path $script:repoRoot 'scripts/Build-WorkspaceBootstrapInstaller.ps1'
        if (-not (Test-Path -Path $script:scriptPath -PathType Leaf)) {
            throw "Script not found: $script:scriptPath"
        }
    }

    It 'fails fast when NSIS root is missing' {
        $payloadRoot = Join-Path $TestDrive 'payload'
        New-Item -Path (Join-Path $payloadRoot 'scripts') -ItemType Directory -Force | Out-Null
        New-Item -Path (Join-Path $payloadRoot 'workspace-governance') -ItemType Directory -Force | Out-Null
        Set-Content -Path (Join-Path $payloadRoot 'scripts/Install-WorkspaceFromManifest.ps1') -Value 'Write-Host test' -Encoding utf8
        Set-Content -Path (Join-Path $payloadRoot 'workspace-governance/workspace-governance.json') -Value '{"workspace_root":"C:\\dev","managed_repos":[]}' -Encoding utf8

        $outputPath = Join-Path $TestDrive 'workspace-bootstrap-installer.exe'
        {
            & $script:scriptPath -PayloadRoot $payloadRoot -OutputPath $outputPath -NsisRoot 'C:\__missing__\NSIS'
        } | Should -Throw '*Required NSIS binary not found*'
    }

    It 'builds installer when NSIS root is valid' -Skip:(-not (Test-Path 'C:\Program Files (x86)\NSIS\makensis.exe')) {
        $payloadRoot = Join-Path $TestDrive 'payload-valid'
        New-Item -Path (Join-Path $payloadRoot 'scripts') -ItemType Directory -Force | Out-Null
        New-Item -Path (Join-Path $payloadRoot 'workspace-governance') -ItemType Directory -Force | Out-Null
        Set-Content -Path (Join-Path $payloadRoot 'scripts/Install-WorkspaceFromManifest.ps1') -Value 'Write-Host test' -Encoding utf8
        Set-Content -Path (Join-Path $payloadRoot 'workspace-governance/workspace-governance.json') -Value '{"workspace_root":"C:\\dev","managed_repos":[]}' -Encoding utf8

        $outputPath = Join-Path $TestDrive 'workspace-bootstrap-installer-valid.exe'
        $result = & $script:scriptPath -PayloadRoot $payloadRoot -OutputPath $outputPath -NsisRoot 'C:\Program Files (x86)\NSIS'

        (Test-Path -Path $outputPath -PathType Leaf) | Should -BeTrue
        ([string]($result | Out-String)) | Should -Match ([regex]::Escape($outputPath))
    }

    It 'supports deterministic compare mode parameters' {
        $scriptContent = Get-Content -Path $script:scriptPath -Raw
        $scriptContent | Should -Match '\[bool\]\$Deterministic = \$true'
        $scriptContent | Should -Match '\[long\]\$SourceDateEpoch'
        $scriptContent | Should -Match '\[switch\]\$VerifyDeterminism'
        $scriptContent | Should -Match 'Normalize-PeTimestamp'
        $scriptContent | Should -Match 'DeterminismReportPath'
    }
}
