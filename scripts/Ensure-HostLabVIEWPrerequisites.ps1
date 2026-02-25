#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^\d{4}$')]
    [string]$RequiredLabviewYear,

    [Parameter(Mandatory = $true)]
    [string]$ArtifactRoot,

    [string[]]$MandatoryBitnesses = @('32'),

    [string[]]$AutoInstallBitnesses = @('64'),

    [switch]$RequireViAnalyzer
)

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

function Get-ReleaseVersionForYear {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Year
    )

    switch ($Year) {
        '2020' { return '20.0' }
        '2025' { return '25.3' }
        '2026' { return '26.1' }
        default {
            throw "Unsupported LabVIEW year '$Year' for NIPM remediation."
        }
    }
}

function Get-LabVIEWExecutablePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Year,
        [Parameter(Mandatory = $true)]
        [ValidateSet('32', '64')]
        [string]$Bitness
    )

    if ($Bitness -eq '64') {
        return "C:\Program Files\National Instruments\LabVIEW $Year\LabVIEW.exe"
    }

    return "C:\Program Files (x86)\National Instruments\LabVIEW $Year\LabVIEW.exe"
}

function Normalize-Bitnesses {
    param(
        [Parameter()]
        [string[]]$Bitnesses
    )

    return @(
        @($Bitnesses |
            ForEach-Object { [string]$_ } |
            Where-Object { $_ -in @('32', '64') } |
            Select-Object -Unique |
            Sort-Object)
    )
}

function Invoke-NipkgCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$NipkgPath,
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $NipkgPath @Arguments 2>&1
        $exitCode = [int]$LASTEXITCODE
        foreach ($line in @($output | ForEach-Object { [string]$_ })) {
            if (-not [string]::IsNullOrWhiteSpace($line)) {
                Write-Host $line
            }
        }
        return $exitCode
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

function Get-NipkgFeedList {
    param(
        [Parameter(Mandatory = $true)]
        [string]$NipkgPath
    )

    $output = & $NipkgPath feed-list 2>&1
    $exitCode = [int]$LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "nipkg feed-list failed with exit code $exitCode."
    }

    return [string]::Join([Environment]::NewLine, @($output | ForEach-Object { [string]$_ }))
}

function Test-NipkgPackageInstalled {
    param(
        [Parameter(Mandatory = $true)]
        [string]$NipkgPath,
        [Parameter(Mandatory = $true)]
        [string]$PackageName
    )

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $NipkgPath list-installed $PackageName 2>&1
        $exitCode = [int]$LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($exitCode -ne 0) {
        throw "nipkg list-installed '$PackageName' failed with exit code $exitCode."
    }

    $pattern = "^\s*{0}\s" -f [regex]::Escape($PackageName)
    foreach ($line in @($output | ForEach-Object { [string]$_ })) {
        if ($line -match $pattern) {
            return $true
        }
    }

    return $false
}

function Ensure-NipkgFeed {
    param(
        [Parameter(Mandatory = $true)]
        [string]$NipkgPath,
        [Parameter(Mandatory = $true)]
        [string]$FeedName,
        [Parameter(Mandatory = $true)]
        [string]$FeedUri,
        [Parameter(Mandatory = $true)]
        [ref]$FeedListCache,
        [Parameter()]
        [System.Collections.ArrayList]$Actions
    )

    $escapedFeedName = [regex]::Escape($FeedName)
    if ($FeedListCache.Value -match ("(?m)^\s*{0}\t" -f $escapedFeedName)) {
        return $false
    }
    $escapedFeedUri = [regex]::Escape($FeedUri)
    if ($FeedListCache.Value -match ("(?m)^\s*[^\t]+\t{0}\s*$" -f $escapedFeedUri)) {
        return $false
    }

    $exitCode = Invoke-NipkgCommand -NipkgPath $NipkgPath -Arguments @('feed-add', $FeedUri, "--name=$FeedName")
    [void]$Actions.Add([ordered]@{
        action = 'feed-add'
        feed_name = $FeedName
        feed_uri = $FeedUri
        exit_code = $exitCode
    })
    if ($exitCode -ne 0) {
        throw "nipkg feed-add failed for '$FeedName' with exit code $exitCode."
    }

    $FeedListCache.Value = Get-NipkgFeedList -NipkgPath $NipkgPath
    return $true
}

function Ensure-LabVIEWInstall {
    param(
        [Parameter(Mandatory = $true)]
        [string]$NipkgPath,
        [Parameter(Mandatory = $true)]
        [string]$Year,
        [Parameter(Mandatory = $true)]
        [ValidateSet('32', '64')]
        [string]$Bitness,
        [Parameter(Mandatory = $true)]
        [string]$PackageName,
        [Parameter(Mandatory = $true)]
        [bool]$IsAdministrator,
        [Parameter()]
        [System.Collections.ArrayList]$Actions
    )

    $exePath = Get-LabVIEWExecutablePath -Year $Year -Bitness $Bitness
    $alreadyPresent = Test-Path -LiteralPath $exePath -PathType Leaf
    if ($alreadyPresent) {
        [void]$Actions.Add([ordered]@{
            action = 'labview-check'
            bitness = $Bitness
            package = $PackageName
            executable = $exePath
            status = 'present'
        })
        return $true
    }

    if (-not $IsAdministrator) {
        throw ("Administrative privileges are required to install '{0}' for {1}-bit LabVIEW {2}. Relaunch an elevated shell and rerun remediation." -f $PackageName, $Bitness, $Year)
    }

    $exitCode = Invoke-NipkgCommand -NipkgPath $NipkgPath -Arguments @('install', '--accept-eulas', '--yes', '--include-recommended', $PackageName)
    [void]$Actions.Add([ordered]@{
        action = 'labview-install'
        bitness = $Bitness
        package = $PackageName
        executable = $exePath
        exit_code = $exitCode
    })
    if ($exitCode -ne 0) {
        throw "nipkg install failed for package '$PackageName' (bitness=$Bitness) with exit code $exitCode."
    }

    if (-not (Test-Path -LiteralPath $exePath -PathType Leaf)) {
        throw "LabVIEW executable is still missing after install: $exePath"
    }

    return $true
}

$report = [ordered]@{
    status = 'pending'
    error_code = ''
    required_labview_year = $RequiredLabviewYear
    mandatory_bitnesses = @()
    auto_install_bitnesses = @()
    require_vi_analyzer = [bool]$RequireViAnalyzer
    nipkg_path = ''
    release_version = ''
    is_admin = $false
    feeds_added = @()
    actions = @()
    vi_analyzer = [ordered]@{
        status = 'not_requested'
        error_code = ''
        required_packages = @()
        installed_before = @{}
        installed_after = @{}
    }
    timestamp_utc = (Get-Date).ToUniversalTime().ToString('o')
}

$actions = New-Object System.Collections.ArrayList
$feedsAdded = New-Object System.Collections.ArrayList

try {
    Ensure-Directory -Path $ArtifactRoot

    $nipkgPath = 'C:\Program Files\National Instruments\NI Package Manager\nipkg.exe'
    if (-not (Test-Path -LiteralPath $nipkgPath -PathType Leaf)) {
        throw "NIPM executable not found: $nipkgPath"
    }
    $report.nipkg_path = $nipkgPath

    $releaseVersion = Get-ReleaseVersionForYear -Year $RequiredLabviewYear
    $report.release_version = $releaseVersion
    $releaseVersionToken = ($releaseVersion -replace '\.', '-')
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
    $isAdministrator = [bool]$currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $report.is_admin = $isAdministrator

    $mandatoryBitnesses = Normalize-Bitnesses -Bitnesses $MandatoryBitnesses
    $autoInstallBitnesses = Normalize-Bitnesses -Bitnesses $AutoInstallBitnesses
    $report.mandatory_bitnesses = @($mandatoryBitnesses)
    $report.auto_install_bitnesses = @($autoInstallBitnesses)

    $viAnalyzerPackages = @()
    $viAnalyzerMissingPackages = @()
    if ($RequireViAnalyzer) {
        $report.vi_analyzer.status = 'pending'
        $viAnalyzerPackages = @('ni-labview-vi-analyzer-toolkit-lic')
        if ($RequiredLabviewYear -eq '2020') {
            $viAnalyzerPackages += @(
                'ni-labview-2020-vi-analyzer-toolkit',
                'ni-labview-2020-vi-analyzer-toolkit-x86'
            )
        } else {
            $viAnalyzerPackages += 'ni-viawin-labview-support'
        }
        $report.vi_analyzer.required_packages = @($viAnalyzerPackages)

        # VI Analyzer remediation is install-capable only on elevated runners.
        # On non-admin lanes, pass only if all required packages are already present.
        if (-not $isAdministrator) {
            $installedBefore = [ordered]@{}
            foreach ($packageName in $viAnalyzerPackages) {
                $isInstalled = $false
                try {
                    $isInstalled = [bool](Test-NipkgPackageInstalled -NipkgPath $nipkgPath -PackageName $packageName)
                } catch {
                    [void]$actions.Add([ordered]@{
                        action = 'vi-analyzer-check'
                        package = $packageName
                        status = 'check_failed'
                        error = $_.Exception.Message
                    })
                    $isInstalled = $false
                }
                $installedBefore[$packageName] = $isInstalled
                if (-not $isInstalled) {
                    $viAnalyzerMissingPackages += $packageName
                }
            }
            $report.vi_analyzer.installed_before = $installedBefore

            if (@($viAnalyzerMissingPackages).Count -gt 0) {
                $report.error_code = 'requires_admin_for_vi_analyzer_install'
                $report.vi_analyzer.error_code = 'requires_admin_for_vi_analyzer_install'
                $report.vi_analyzer.status = 'requires_admin'
                throw ("requires_admin_for_vi_analyzer_install: Administrative privileges are required to remediate VI Analyzer packages ({0}) for LabVIEW {1}. Missing packages: {2}" -f [string]::Join(', ', @($viAnalyzerPackages)), $RequiredLabviewYear, [string]::Join(', ', @($viAnalyzerMissingPackages)))
            }

            $report.vi_analyzer.installed_after = $installedBefore
            $report.vi_analyzer.status = 'pass'
        }
    }

    $feedListCache = Get-NipkgFeedList -NipkgPath $nipkgPath

    $labviewFeedBaseX64 = "https://download.ni.com/support/nipkg/products/ni-l/ni-labview-$RequiredLabviewYear/$releaseVersion"
    $labviewFeedBaseX86 = "https://download.ni.com/support/nipkg/products/ni-l/ni-labview-$RequiredLabviewYear-x86/$releaseVersion"

    $feedSpecs = @(
        [ordered]@{
            name = "ni-labview-$RequiredLabviewYear-core-en-$releaseVersionToken-released"
            uri = "$labviewFeedBaseX64/released"
        }
        [ordered]@{
            name = "ni-labview-$RequiredLabviewYear-core-en-$releaseVersionToken-released-critical"
            uri = "$labviewFeedBaseX64/released-critical"
        }
        [ordered]@{
            name = "ni-labview-$RequiredLabviewYear-core-x86-en-$releaseVersionToken-released"
            uri = "$labviewFeedBaseX86/released"
        }
        [ordered]@{
            name = "ni-labview-$RequiredLabviewYear-core-x86-en-$releaseVersionToken-released-critical"
            uri = "$labviewFeedBaseX86/released-critical"
        }
    )

    if ($RequireViAnalyzer -and $RequiredLabviewYear -ne '2020') {
        $viaFeedBase = "https://download.ni.com/support/nipkg/products/ni-l/ni-labview-vi-analyzer-toolkit/$releaseVersion"
        $feedSpecs += [ordered]@{
            name = "ni-viawin-labview-support-$releaseVersionToken-released"
            uri = "$viaFeedBase/released"
        }
        $feedSpecs += [ordered]@{
            name = "ni-viawin-labview-support-$releaseVersionToken-released-critical"
            uri = "$viaFeedBase/released-critical"
        }
    }

    $anyFeedAdded = $false
    foreach ($feedSpec in $feedSpecs) {
        $added = Ensure-NipkgFeed `
            -NipkgPath $nipkgPath `
            -FeedName ([string]$feedSpec.name) `
            -FeedUri ([string]$feedSpec.uri) `
            -FeedListCache ([ref]$feedListCache) `
            -Actions $actions
        if ($added) {
            [void]$feedsAdded.Add([ordered]@{
                name = [string]$feedSpec.name
                uri = [string]$feedSpec.uri
            })
            $anyFeedAdded = $true
        }
    }

    if ($anyFeedAdded) {
        $updateExitCode = Invoke-NipkgCommand -NipkgPath $nipkgPath -Arguments @('update')
        [void]$actions.Add([ordered]@{
            action = 'update'
            exit_code = $updateExitCode
        })
        if ($updateExitCode -ne 0) {
            throw "nipkg update failed with exit code $updateExitCode."
        }
    }

    $packageMapByBitness = @{
        '32' = "ni-labview-$RequiredLabviewYear-core-x86-en"
        '64' = "ni-labview-$RequiredLabviewYear-core-en"
    }

    foreach ($bitness in $mandatoryBitnesses) {
        [void](Ensure-LabVIEWInstall `
            -NipkgPath $nipkgPath `
            -Year $RequiredLabviewYear `
            -Bitness $bitness `
            -PackageName ([string]$packageMapByBitness[$bitness]) `
            -IsAdministrator $isAdministrator `
            -Actions $actions)
    }

    foreach ($bitness in $autoInstallBitnesses) {
        if ($mandatoryBitnesses -contains $bitness) {
            continue
        }
        [void](Ensure-LabVIEWInstall `
            -NipkgPath $nipkgPath `
            -Year $RequiredLabviewYear `
            -Bitness $bitness `
            -PackageName ([string]$packageMapByBitness[$bitness]) `
            -IsAdministrator $isAdministrator `
            -Actions $actions)
    }

    if ($RequireViAnalyzer -and $report.vi_analyzer.status -ne 'pass') {
        $installedBefore = [ordered]@{}
        foreach ($packageName in $viAnalyzerPackages) {
            $installedBefore[$packageName] = [bool](Test-NipkgPackageInstalled -NipkgPath $nipkgPath -PackageName $packageName)
        }
        $report.vi_analyzer.installed_before = $installedBefore

        foreach ($packageName in $viAnalyzerPackages) {
            if (-not [bool]$installedBefore[$packageName]) {
                if (-not $isAdministrator) {
                    $report.error_code = 'requires_admin_for_vi_analyzer_install'
                    $report.vi_analyzer.error_code = 'requires_admin_for_vi_analyzer_install'
                    $report.vi_analyzer.status = 'requires_admin'
                    throw ("requires_admin_for_vi_analyzer_install: Administrative privileges are required to install VI Analyzer package '{0}'. Relaunch an elevated shell and rerun remediation." -f $packageName)
                }
                $installExitCode = Invoke-NipkgCommand -NipkgPath $nipkgPath -Arguments @('install', '--accept-eulas', '--yes', '--include-recommended', $packageName)
                [void]$actions.Add([ordered]@{
                    action = 'vi-analyzer-install'
                    package = $packageName
                    exit_code = $installExitCode
                })
                if ($installExitCode -ne 0) {
                    throw "nipkg install failed for VI Analyzer package '$packageName' with exit code $installExitCode."
                }
            }
        }

        $installedAfter = [ordered]@{}
        foreach ($packageName in $viAnalyzerPackages) {
            $installedAfter[$packageName] = [bool](Test-NipkgPackageInstalled -NipkgPath $nipkgPath -PackageName $packageName)
        }
        $report.vi_analyzer.installed_after = $installedAfter

        $missingAfter = @(
            $viAnalyzerPackages | Where-Object { -not [bool]$installedAfter[$_] }
        )
        if (@($missingAfter).Count -gt 0) {
            throw ("VI Analyzer remediation incomplete. Missing packages: {0}" -f ([string]::Join(', ', @($missingAfter))))
        }
        $report.vi_analyzer.status = 'pass'
    }

    $report.feeds_added = @($feedsAdded)
    $report.actions = @($actions)
    $report.status = 'pass'
} catch {
    $report.feeds_added = @($feedsAdded)
    $report.actions = @($actions)
    $report.status = 'fail'
    if ([string]::IsNullOrWhiteSpace([string]$report.error_code) -and ([string]$_.Exception.Message).StartsWith('requires_admin_for_vi_analyzer_install')) {
        $report.error_code = 'requires_admin_for_vi_analyzer_install'
    }
    $report.error = $_.Exception.Message
    throw
} finally {
    $reportPath = Join-Path $ArtifactRoot 'host-prereq-remediation-report.json'
    $report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $reportPath -Encoding utf8
    Write-Host ("Host prerequisite remediation report: {0}" -f $reportPath)
}
