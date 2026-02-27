#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Windows container NSIS self-test contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:selfTestScriptPath = Join-Path $script:repoRoot 'scripts/Invoke-WindowsContainerNsisSelfTest.ps1'
        $script:dockerfilePath = Join-Path $script:repoRoot 'tools/nsis-selftest-windows/Dockerfile'

        if (-not (Test-Path -LiteralPath $script:selfTestScriptPath -PathType Leaf)) {
            throw "Windows container self-test script missing: $script:selfTestScriptPath"
        }
        if (-not (Test-Path -LiteralPath $script:dockerfilePath -PathType Leaf)) {
            throw "Windows self-test Dockerfile missing: $script:dockerfilePath"
        }

        $script:selfTestScriptContent = Get-Content -LiteralPath $script:selfTestScriptPath -Raw
        $script:dockerfileContent = Get-Content -LiteralPath $script:dockerfilePath -Raw
    }

    It 'builds and runs a Windows containerized NSIS smoke install flow' {
        $script:selfTestScriptContent | Should -Match '''build'', ''-f'''
        $script:selfTestScriptContent | Should -Match '''run'''
        $script:selfTestScriptContent | Should -Match '& docker @runArgs'
        $script:selfTestScriptContent | Should -Match '''--format'', ''\{\{\.OSType\}\}'''
        $script:selfTestScriptContent | Should -Match 'windows_container_mode_required'
        $script:selfTestScriptContent | Should -Match 'Build-RunnerCliBundleFromManifest\.ps1'
        $script:selfTestScriptContent | Should -Match 'Build-WorkspaceBootstrapInstaller\.ps1'
        $script:selfTestScriptContent | Should -Match 'Convert-ManifestToWorkspace\.ps1'
        $script:selfTestScriptContent | Should -Match 'cdev-cli-win-x64\.zip'
        $script:selfTestScriptContent | Should -Match 'Invoke-CdevCli\.ps1'
        $script:selfTestScriptContent | Should -Match 'installer install'
        $script:selfTestScriptContent | Should -Match '\$cliCommandArgs = @\('
        $script:selfTestScriptContent | Should -Match '-CommandArgs \$cliCommandArgs'
        $script:selfTestScriptContent | Should -Match '''--installer-path'', \$installerPath'
        $script:selfTestScriptContent | Should -Match '''--report-path'', \$installReportPath'
        $script:selfTestScriptContent | Should -Match 'cdev-cli-installer-run-report\.json'
        $script:selfTestScriptContent | Should -Match '-InstallerExecutionContext ''ContainerSmoke'''
        $script:selfTestScriptContent | Should -Match '-Deterministic \$true'
        $script:selfTestScriptContent | Should -Match 'workspace-install-latest\.json'
        $script:selfTestScriptContent | Should -Match 'container-report\.json'
        $script:selfTestScriptContent | Should -Match 'windows-container-nsis-selftest-report\.json'
    }

    It 'supports deterministic troubleshooting controls for container lifecycle' {
        $script:selfTestScriptContent | Should -Match '\[switch\]\$BuildLocalImage'
        $script:selfTestScriptContent | Should -Match '\[switch\]\$KeepContainerScript'
        $script:selfTestScriptContent | Should -Match '\[switch\]\$KeepContainerOnFailure'
        $script:selfTestScriptContent | Should -Match '\$ContainerNamePrefix'
        $script:selfTestScriptContent | Should -Match '\$DockerContext'
    }

    It 'pins a Windows base image aligned to 2026q1 with minimal runtime surface' {
        $script:dockerfileContent | Should -Match 'nationalinstruments/labview:2026q1-windows'
        $script:dockerfileContent | Should -Match 'SHELL \["powershell"'
        $script:dockerfileContent | Should -Match 'WORKDIR C:\\workspace'
        $script:dockerfileContent | Should -Not -Match 'dotnet-install\.ps1'
        $script:dockerfileContent | Should -Not -Match 'MinGit-'
        $script:dockerfileContent | Should -Not -Match 'nsis-'
    }

    It 'has parse-safe PowerShell syntax' {
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($script:selfTestScriptContent, [ref]$tokens, [ref]$errors)
        @($errors).Count | Should -Be 0
    }
}
