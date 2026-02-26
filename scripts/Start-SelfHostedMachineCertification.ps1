#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter()]
    [string]$Repository = 'LabVIEW-Community-CI-CD/labview-cdev-surface',

    [Parameter()]
    [string]$WorkflowFile = 'self-hosted-machine-certification.yml',

    [Parameter()]
    [string]$Ref = 'main',

    [Parameter()]
    [string[]]$SetupName = @(),

    [Parameter()]
    [string]$ProfilesPath = '',

    [Parameter()]
    [switch]$Watch,

    [Parameter()]
    [int]$DispatchPauseSeconds = 4,

    [Parameter()]
    [string]$ActorMachineName = '',

    [Parameter()]
    [ValidateSet('machine+setup')]
    [string]$ActorKeyStrategy = 'machine+setup',

    [Parameter()]
    [string]$OutputPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-ProfilesPath {
    param([string]$InputPath)
    if (-not [string]::IsNullOrWhiteSpace($InputPath)) {
        return [System.IO.Path]::GetFullPath($InputPath)
    }
    $repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
    return (Join-Path $repoRoot 'tools\machine-certification\setup-profiles.json')
}

function Invoke-Gh {
    param([string[]]$Arguments)
    & gh @Arguments
    $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
    if ($exitCode -ne 0) {
        throw "gh command failed with exit code ${exitCode}: gh $($Arguments -join ' ')"
    }
}

function Get-ScalarString {
    param([object]$Value)
    if ($null -eq $Value) {
        return ''
    }
    if ($Value -is [System.Array]) {
        $first = @($Value | Select-Object -First 1)
        if (@($first).Count -eq 0) { return '' }
        return [string]$first[0]
    }
    return [string]$Value
}

function Split-LabelCsv {
    param([Parameter(Mandatory = $true)][string]$Csv)
    return @(
        $Csv -split ',' |
        ForEach-Object { ([string]$_).Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
}

function Join-LabelsCsv {
    param([Parameter(Mandatory = $true)][string[]]$Labels)
    return (@($Labels | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ',')
}

function Get-RepositoryOwner {
    param([Parameter(Mandatory = $true)][string]$Repository)
    return ([string]$Repository -split '/')[0]
}

function Get-CollisionGuardLabel {
    param([Parameter(Mandatory = $true)][object]$Setup)
    return (Get-ScalarString -Value $Setup.collision_guard_label)
}

function Get-SetupRouteLabel {
    param([Parameter(Mandatory = $true)][object]$Setup)

    $routeLabel = (Get-ScalarString -Value $Setup.setup_route_label).Trim()
    if ([string]::IsNullOrWhiteSpace($routeLabel)) {
        throw "setup_route_label_missing: setup '$([string]$Setup.name)' must define setup_route_label."
    }

    $normalized = Normalize-ActorLabelToken -Value $routeLabel
    if (-not [string]::Equals($routeLabel, $normalized, [System.StringComparison]::Ordinal)) {
        throw ("setup_route_label_invalid: setup '{0}' has non-canonical setup_route_label '{1}'. Use '{2}'." -f [string]$Setup.name, $routeLabel, $normalized)
    }

    return $routeLabel
}

function Get-SetupExpectedLabviewYear {
    param([Parameter(Mandatory = $true)][object]$Setup)

    $year = (Get-ScalarString -Value $Setup.expected_labview_year).Trim()
    if ([string]::IsNullOrWhiteSpace($year)) {
        throw "expected_labview_year_missing: setup '$([string]$Setup.name)' must define expected_labview_year."
    }
    if ($year -notmatch '^[0-9]{4}$') {
        throw ("expected_labview_year_invalid: setup '{0}' has invalid expected_labview_year '{1}'." -f [string]$Setup.name, $year)
    }
    return $year
}

function Test-SetupRequiresActorLabel {
    param([Parameter(Mandatory = $true)][string]$ExpectedLabviewYear)

    return @('2025', '2026') -contains ([string]$ExpectedLabviewYear)
}

function Assert-DispatchRoutingContract {
    param(
        [Parameter(Mandatory = $true)][string]$Repository,
        [Parameter(Mandatory = $true)][object]$Setup,
        [Parameter(Mandatory = $true)][string]$RunnerLabelsCsv,
        [Parameter(Mandatory = $true)][string]$ActorRunnerLabel
    )

    $labels = @(
        Split-LabelCsv -Csv $RunnerLabelsCsv |
        ForEach-Object { ([string]$_).Trim().ToLowerInvariant() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -Unique
    )
    if (@($labels).Count -eq 0) {
        throw ("dispatch_routing_labels_empty: setup '{0}' resolved empty runner labels." -f [string]$Setup.name)
    }

    $requiredSetupLabel = Get-SetupRouteLabel -Setup $Setup
    $setupLabels = @($labels | Where-Object { [string]$_ -like 'cert-setup-*' } | Select-Object -Unique)
    $setupLabelCount = @($setupLabels).Count
    if ($setupLabelCount -ne 1) {
        throw ("dispatch_routing_setup_label_count_invalid: setup '{0}' requires exactly one setup route label '{1}', found count={2} labels='{3}'." -f [string]$Setup.name, $requiredSetupLabel, $setupLabelCount, ($setupLabels -join ','))
    }
    if (-not [string]::Equals([string]$setupLabels[0], $requiredSetupLabel, [System.StringComparison]::Ordinal)) {
        throw ("dispatch_routing_setup_label_mismatch: setup '{0}' requires setup label '{1}' but resolved '{2}'." -f [string]$Setup.name, $requiredSetupLabel, [string]$setupLabels[0])
    }

    $expectedLabviewYear = Get-SetupExpectedLabviewYear -Setup $Setup
    $requiresActorLabelByYear = Test-SetupRequiresActorLabel -ExpectedLabviewYear $expectedLabviewYear
    $owner = Get-RepositoryOwner -Repository $Repository
    $requiresActorLabel = $requiresActorLabelByYear -and [string]::Equals($owner, 'LabVIEW-Community-CI-CD', [System.StringComparison]::OrdinalIgnoreCase)

    $expectedActorLabel = ([string]$ActorRunnerLabel).Trim().ToLowerInvariant()
    $actorLabels = @($labels | Where-Object { [string]$_ -like 'cert-actor-*' } | Select-Object -Unique)
    $actorLabelCount = @($actorLabels).Count
    $actorLabelPresent = $actorLabelCount -gt 0
    if ($requiresActorLabel -and -not $actorLabelPresent) {
        throw ("dispatch_routing_actor_label_missing: setup '{0}' (LabVIEW {1}) requires actor label for upstream dispatch; labels='{2}'." -f [string]$Setup.name, $expectedLabviewYear, ($labels -join ','))
    }
    if ($requiresActorLabel -and $actorLabelCount -ne 1) {
        throw ("dispatch_routing_actor_label_count_invalid: setup '{0}' expected exactly one actor label '{1}', found count={2} labels='{3}'." -f [string]$Setup.name, $expectedActorLabel, $actorLabelCount, ($actorLabels -join ','))
    }
    if ($requiresActorLabel -and $actorLabelCount -gt 0 -and $actorLabels[0] -notmatch '^cert-actor-[a-z0-9-]+-[a-z0-9-]+$') {
        throw ("dispatch_routing_actor_label_format_invalid: setup '{0}' resolved actor label '{1}' with invalid format." -f [string]$Setup.name, [string]$actorLabels[0])
    }
    if ($requiresActorLabel -and $actorLabelCount -eq 1 -and -not [string]::Equals([string]$actorLabels[0], $expectedActorLabel, [System.StringComparison]::Ordinal)) {
        throw ("dispatch_routing_actor_label_mismatch: setup '{0}' expected actor label '{1}' but resolved '{2}'." -f [string]$Setup.name, $expectedActorLabel, [string]$actorLabels[0])
    }

    return [pscustomobject]@{
        pass = $true
        expected_labview_year = $expectedLabviewYear
        required_setup_label = $requiredSetupLabel
        setup_label_count = $setupLabelCount
        setup_labels_csv = ($setupLabels -join ',')
        requires_actor_label = $requiresActorLabel
        required_actor_label = $expectedActorLabel
        actor_label_count = $actorLabelCount
        actor_label_present = $actorLabelPresent
        actor_labels_csv = ($actorLabels -join ',')
        resolved_labels_csv = ($labels -join ',')
    }
}
function Get-ActorMachineName {
    param([string]$PreferredName)

    if (-not [string]::IsNullOrWhiteSpace($PreferredName)) {
        return [string]$PreferredName
    }
    return [System.Environment]::MachineName
}

function Normalize-ActorLabelToken {
    param([Parameter(Mandatory = $true)][string]$Value)

    $token = ([string]$Value).Trim().ToLowerInvariant()
    $token = [Regex]::Replace($token, '[^a-z0-9\-]', '-')
    $token = [Regex]::Replace($token, '-{2,}', '-')
    $token = $token.Trim('-')
    if ([string]::IsNullOrWhiteSpace($token)) {
        return 'unknown'
    }
    return $token
}

function Get-ActorKey {
    param(
        [Parameter(Mandatory = $true)][string]$MachineName,
        [Parameter(Mandatory = $true)][string]$SetupName,
        [Parameter(Mandatory = $true)][string]$Strategy
    )

    if ($Strategy -eq 'machine+setup') {
        return ("{0}::{1}" -f [string]$MachineName, [string]$SetupName)
    }
    throw "Unsupported actor key strategy '$Strategy'."
}

function Get-ActorRunnerLabel {
    param(
        [Parameter(Mandatory = $true)][string]$MachineName,
        [Parameter(Mandatory = $true)][string]$SetupName
    )

    $machineToken = Normalize-ActorLabelToken -Value $MachineName
    $setupToken = Normalize-ActorLabelToken -Value $SetupName
    $label = ("cert-actor-{0}-{1}" -f $machineToken, $setupToken)
    if ($label.Length -gt 63) {
        $label = $label.Substring(0, 63).TrimEnd('-')
    }
    return $label
}

function Get-SetupBoolean {
    param(
        [Parameter(Mandatory = $true)][object]$Setup,
        [Parameter(Mandatory = $true)][string]$PropertyName,
        [Parameter(Mandatory = $true)][bool]$Default
    )

    $property = $Setup.PSObject.Properties[$PropertyName]
    if ($null -eq $property -or $null -eq $property.Value) {
        return $Default
    }

    $raw = [string]$property.Value
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $Default
    }

    try {
        return [System.Convert]::ToBoolean($property.Value)
    } catch {
        throw ("setup_boolean_invalid: setup '{0}' has invalid boolean value for '{1}': '{2}'." -f [string]$Setup.name, $PropertyName, $raw)
    }
}

function Get-SetupExecutionBitness {
    param(
        [Parameter(Mandatory = $true)][object]$Setup,
        [Parameter()][string]$Default = 'auto'
    )

    $property = $Setup.PSObject.Properties['execution_bitness']
    if ($null -eq $property -or $null -eq $property.Value) {
        return $Default
    }

    $raw = ([string]$property.Value).Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $Default
    }

    if ($raw -notin @('auto', '32', '64')) {
        throw ("setup_execution_bitness_invalid: setup '{0}' has invalid execution_bitness '{1}'. Allowed values: auto, 32, 64." -f [string]$Setup.name, [string]$property.Value)
    }

    return $raw
}

function Get-SetupAllowedMachineNames {
    param([Parameter(Mandatory = $true)][object]$Setup)

    $property = $Setup.PSObject.Properties['allowed_machine_names']
    if ($null -eq $property -or $null -eq $property.Value) {
        throw "allowed_machine_names_missing: setup '$([string]$Setup.name)' must define allowed_machine_names."
    }

    $names = @()
    foreach ($raw in @($property.Value)) {
        $name = ([string]$raw).Trim()
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        $names += $name.ToUpperInvariant()
    }

    if (@($names).Count -eq 0) {
        throw "allowed_machine_names_empty: setup '$([string]$Setup.name)' must define at least one allowed machine name."
    }

    return @($names | Select-Object -Unique)
}

function Resolve-RunnerLabelsCsv {
    param([Parameter(Mandatory = $true)][object]$Setup)

    $labels = @()
    $csvValue = Get-ScalarString -Value $Setup.runner_labels_csv
    if (-not [string]::IsNullOrWhiteSpace($csvValue)) {
        $labels = Split-LabelCsv -Csv $csvValue
    } else {
        $jsonValue = Get-ScalarString -Value $Setup.runner_labels_json
        if (-not [string]::IsNullOrWhiteSpace($jsonValue)) {
            try {
                $labels = @(
                    $jsonValue | ConvertFrom-Json -ErrorAction Stop |
                    ForEach-Object { ([string]$_).Trim() } |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
                )
            } catch {
                # fall through to explicit error below
            }
        }
    }

    if (@($labels).Count -eq 0) {
        throw "Setup '$([string]$Setup.name)' is missing runner labels (runner_labels_csv or valid runner_labels_json)."
    }

    $setupRouteLabel = Get-SetupRouteLabel -Setup $Setup
    if ($labels -notcontains $setupRouteLabel) {
        $labels += $setupRouteLabel
    }

    return (Join-LabelsCsv -Labels $labels)
}

function Resolve-UpstreamRunnerLabelsCsv {
    param(
        [Parameter(Mandatory = $true)][string]$Repository,
        [Parameter(Mandatory = $true)][object]$Setup,
        [Parameter(Mandatory = $true)][string]$ActorMachine
    )

    $baseCsv = Resolve-RunnerLabelsCsv -Setup $Setup
    $owner = Get-RepositoryOwner -Repository $Repository
    if (-not [string]::Equals($owner, 'LabVIEW-Community-CI-CD', [System.StringComparison]::OrdinalIgnoreCase)) {
        return $baseCsv
    }

    $guardLabel = Get-CollisionGuardLabel -Setup $Setup
    if ([string]::IsNullOrWhiteSpace($guardLabel)) {
        throw "runner_collision_guard_label_missing: setup '$([string]$Setup.name)' must define collision_guard_label for upstream dispatch."
    }

    $labels = Split-LabelCsv -Csv $baseCsv
    if ($labels -notcontains $guardLabel) {
        $labels += $guardLabel
    }

    $actorLabel = Get-ActorRunnerLabel -MachineName $ActorMachine -SetupName ([string]$Setup.name)
    if ($labels -notcontains $actorLabel) {
        $labels += $actorLabel
    }

    return (Join-LabelsCsv -Labels $labels)
}

function Get-RunnerInventory {
    param([Parameter(Mandatory = $true)][string]$Repository)

    $runnerLines = & gh api "repos/$Repository/actions/runners" --paginate --jq '.runners[] | @json'
    if ($LASTEXITCODE -ne 0) {
        throw "runner_inventory_query_failed: unable to query runner inventory for '$Repository'."
    }

    $runners = @()
    foreach ($line in @($runnerLines)) {
        if ([string]::IsNullOrWhiteSpace([string]$line)) { continue }
        $runners += @(([string]$line | ConvertFrom-Json -ErrorAction Stop))
    }

    return @($runners)
}

function Test-RunnerAllowedMachine {
    param(
        [Parameter(Mandatory = $true)][object]$Runner,
        [Parameter()][string[]]$AllowedMachineNames = @()
    )

    if (@($AllowedMachineNames).Count -eq 0) {
        return $true
    }

    $runnerName = [string]$Runner.name
    foreach ($allowedMachine in $AllowedMachineNames) {
        if ($runnerName.Equals($allowedMachine, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
        if ($runnerName.StartsWith(($allowedMachine + '-'), [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}

function Get-EligibleOnlineRunners {
    param(
        [Parameter(Mandatory = $true)][object[]]$Runners,
        [Parameter(Mandatory = $true)][string[]]$RequiredLabels,
        [Parameter()][string[]]$AllowedMachineNames = @()
    )

    return @(
        $Runners | Where-Object {
            [string]$_.status -eq 'online'
        } | Where-Object {
            $runnerLabels = @($_.labels | ForEach-Object { [string]$_.name })
            @($RequiredLabels | Where-Object { $runnerLabels -notcontains $_ }).Count -eq 0
        } | Where-Object {
            Test-RunnerAllowedMachine -Runner $_ -AllowedMachineNames $AllowedMachineNames
        }
    )
}

function Assert-UpstreamRunnerCapacity {
    param(
        [Parameter(Mandatory = $true)][string]$Repository,
        [Parameter(Mandatory = $true)][string]$RunnerLabelsCsv,
        [Parameter(Mandatory = $true)][string]$SetupName,
        [Parameter()][string]$AllowedMachineNamesCsv = ''
    )

    $requiredLabels = Split-LabelCsv -Csv $RunnerLabelsCsv
    if (@($requiredLabels).Count -eq 0) {
        throw "runner_labels_empty: setup '$SetupName' resolved to no runner labels."
    }

    $allowedMachineNames = @()
    if (-not [string]::IsNullOrWhiteSpace($AllowedMachineNamesCsv)) {
        $allowedMachineNames = @(
            $AllowedMachineNamesCsv -split ',' |
            ForEach-Object { ([string]$_.Trim()).ToUpperInvariant() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Unique
        )
    }

    $runners = Get-RunnerInventory -Repository $Repository
    $eligibleOnline = Get-EligibleOnlineRunners -Runners $runners -RequiredLabels $requiredLabels -AllowedMachineNames $allowedMachineNames

    $owner = Get-RepositoryOwner -Repository $Repository
    $requiredActorLabels = @($requiredLabels | Where-Object { $_ -like 'cert-actor-*' } | Select-Object -Unique)
    if (
        @($eligibleOnline).Count -eq 0 -and
        @($requiredActorLabels).Count -gt 0 -and
        [string]::Equals($owner, 'LabVIEW-Community-CI-CD', [System.StringComparison]::OrdinalIgnoreCase)
    ) {
        $requiredNonActorLabels = @($requiredLabels | Where-Object { $_ -notlike 'cert-actor-*' } | Select-Object -Unique)
        $eligibleWithoutActor = Get-EligibleOnlineRunners -Runners $runners -RequiredLabels $requiredNonActorLabels -AllowedMachineNames $allowedMachineNames
        $labelsAttached = $false

        foreach ($runner in $eligibleWithoutActor) {
            $runnerLabels = @($runner.labels | ForEach-Object { [string]$_.name })
            $missingActorLabels = @($requiredActorLabels | Where-Object { $runnerLabels -notcontains $_ })
            if (@($missingActorLabels).Count -eq 0) {
                continue
            }

            $labelArgs = @()
            foreach ($label in $missingActorLabels) {
                $labelArgs += @('-f', ("labels[]={0}" -f $label))
            }

            Invoke-Gh -Arguments (@(
                'api',
                '--method',
                'POST',
                ("repos/$Repository/actions/runners/{0}/labels" -f [string]$runner.id)
            ) + $labelArgs)
            Write-Warning ("runner_actor_label_autofix: added labels '{0}' to runner '{1}' for setup '{2}'." -f ($missingActorLabels -join ','), [string]$runner.name, $SetupName)
            $labelsAttached = $true
        }

        if ($labelsAttached) {
            Start-Sleep -Seconds 2
            $runners = Get-RunnerInventory -Repository $Repository
            $eligibleOnline = Get-EligibleOnlineRunners -Runners $runners -RequiredLabels $requiredLabels -AllowedMachineNames $allowedMachineNames
        }
    }

    $eligibleAvailable = @($eligibleOnline | Where-Object { -not [bool]$_.busy })

    if (@($eligibleOnline).Count -eq 0) {
        throw ("runner_route_unconfigured: no online runner matches setup '{0}' labels '{1}' and allowed machines '{2}' in repository '{3}'." -f $SetupName, $RunnerLabelsCsv, $AllowedMachineNamesCsv, $Repository)
    }
    if (@($eligibleAvailable).Count -eq 0) {
        Write-Warning ("runner_route_busy: online runners for setup '{0}' labels '{1}' and allowed machines '{2}' are currently busy; dispatch will queue." -f $SetupName, $RunnerLabelsCsv, $AllowedMachineNamesCsv)
    }
}

$resolvedProfilesPath = Resolve-ProfilesPath -InputPath $ProfilesPath
if (-not (Test-Path -LiteralPath $resolvedProfilesPath -PathType Leaf)) {
    throw "Setup profiles file not found: $resolvedProfilesPath"
}

$profilesDoc = Get-Content -LiteralPath $resolvedProfilesPath -Raw | ConvertFrom-Json -ErrorAction Stop
$allSetups = @($profilesDoc.setups)
if (@($allSetups).Count -eq 0) {
    throw "No setup profiles found in $resolvedProfilesPath"
}

$selectedSetups = @()
if (@($SetupName).Count -gt 0) {
    foreach ($name in $SetupName) {
        $candidate = @($allSetups | Where-Object { [string]$_.name -eq [string]$name }) | Select-Object -First 1
        if ($null -eq $candidate) {
            throw "Unknown setup profile '$name' in $resolvedProfilesPath"
        }
        $selectedSetups += $candidate
    }
} else {
    $selectedSetups = @($allSetups | Where-Object { $_.active -eq $true })
}

if (@($selectedSetups).Count -eq 0) {
    throw "No active setup profiles selected."
}

$dispatchRecords = @()
$claimedRunIds = @{}
$resolvedActorMachineName = Get-ActorMachineName -PreferredName $ActorMachineName
foreach ($setup in $selectedSetups) {
    $setupNameToken = [string]$setup.name
    $setupAllowedMachineNames = Get-SetupAllowedMachineNames -Setup $setup
    $allowedMachineNamesCsv = (@($setupAllowedMachineNames) -join ',')
    $actorKey = Get-ActorKey -MachineName $resolvedActorMachineName -SetupName $setupNameToken -Strategy $ActorKeyStrategy
    $actorRunnerLabel = Get-ActorRunnerLabel -MachineName $resolvedActorMachineName -SetupName $setupNameToken
    $runnerLabelsCsv = Resolve-UpstreamRunnerLabelsCsv -Repository $Repository -Setup $setup -ActorMachine $resolvedActorMachineName
    $routingContract = Assert-DispatchRoutingContract -Repository $Repository -Setup $setup -RunnerLabelsCsv $runnerLabelsCsv -ActorRunnerLabel $actorRunnerLabel
    $switchDockerContext = (Get-SetupBoolean -Setup $setup -PropertyName 'switch_docker_context' -Default $true).ToString().ToLowerInvariant()
    $startDockerDesktop = (Get-SetupBoolean -Setup $setup -PropertyName 'start_docker_desktop_if_needed' -Default $true).ToString().ToLowerInvariant()
    $executionBitness = Get-SetupExecutionBitness -Setup $setup -Default 'auto'
    $requireSecondary32 = (Get-SetupBoolean -Setup $setup -PropertyName 'require_secondary_32' -Default $false).ToString().ToLowerInvariant()
    Assert-UpstreamRunnerCapacity `
        -Repository $Repository `
        -RunnerLabelsCsv $runnerLabelsCsv `
        -SetupName $setupNameToken `
        -AllowedMachineNamesCsv $allowedMachineNamesCsv
    Write-Host ("Dispatching setup: {0}" -f $setupNameToken)
    $dispatchStartUtc = (Get-Date).ToUniversalTime()

    $dispatchArgs = @(
        'workflow', 'run', $WorkflowFile,
        '-R', $Repository,
        '--ref', $Ref,
        '-f', ("setup_name={0}" -f $setupNameToken),
        '-f', ("runner_labels_csv={0}" -f $runnerLabelsCsv),
        '-f', ("expected_labview_year={0}" -f ([string]$setup.expected_labview_year)),
        '-f', ("docker_context={0}" -f ([string]$setup.docker_context)),
        '-f', ("execution_bitness={0}" -f $executionBitness),
        '-f', ("require_secondary_32={0}" -f $requireSecondary32),
        '-f', ("switch_docker_context={0}" -f $switchDockerContext),
        '-f', ("start_docker_desktop_if_needed={0}" -f $startDockerDesktop),
        '-f', ("allowed_machine_names_csv={0}" -f $allowedMachineNamesCsv),
        '-f', ("skip_host_ini_mutation={0}" -f ([string]$setup.skip_host_ini_mutation).ToLowerInvariant()),
        '-f', ("skip_override_phase={0}" -f ([string]$setup.skip_override_phase).ToLowerInvariant())
    )
    Invoke-Gh -Arguments $dispatchArgs

    Start-Sleep -Seconds $DispatchPauseSeconds

    $runJson = gh run list -R $Repository --workflow $WorkflowFile --branch $Ref --event workflow_dispatch --limit 50 --json databaseId,status,conclusion,url,displayTitle,createdAt
    $runListRaw = @($runJson | ConvertFrom-Json -ErrorAction Stop)
    $runList = @(
        $runListRaw | ForEach-Object {
            [pscustomobject]@{
                databaseId = Get-ScalarString -Value $_.databaseId
                status = Get-ScalarString -Value $_.status
                conclusion = Get-ScalarString -Value $_.conclusion
                url = Get-ScalarString -Value $_.url
                displayTitle = Get-ScalarString -Value $_.displayTitle
                createdAt = Get-ScalarString -Value $_.createdAt
            }
        }
    )
    $candidateRuns = @(
        $runList |
        Where-Object {
            $runId = Get-ScalarString -Value $_.databaseId
            if ([string]::IsNullOrWhiteSpace($runId)) { return $false }
            if ($claimedRunIds.ContainsKey($runId)) { return $false }
            $createdAt = [DateTimeOffset]::MinValue
            if (-not [DateTimeOffset]::TryParse((Get-ScalarString -Value $_.createdAt), [ref]$createdAt)) { return $false }
            return ($createdAt.UtcDateTime -ge $dispatchStartUtc.AddMinutes(-2))
        } |
        Sort-Object -Property createdAt -Descending
    )
    $run = $candidateRuns | Select-Object -First 1
    if ($null -eq $run -and @($runList).Count -gt 0) {
        $run = @(
            $runList |
            Where-Object { -not $claimedRunIds.ContainsKey((Get-ScalarString -Value $_.databaseId)) } |
            Sort-Object -Property createdAt -Descending
        ) | Select-Object -First 1
    }
    if ($null -ne $run -and -not [string]::IsNullOrWhiteSpace((Get-ScalarString -Value $run.databaseId))) {
        $claimedRunIds[(Get-ScalarString -Value $run.databaseId)] = $true
    }

    $record = [ordered]@{
        setup_name = $setupNameToken
        machine_name = $resolvedActorMachineName
        actor_key = $actorKey
        actor_runner_label = $actorRunnerLabel
        actor_key_strategy = $ActorKeyStrategy
        runner_labels_csv = $runnerLabelsCsv
        routing_contract_pass = [bool]$routingContract.pass
        routing_contract_expected_labview_year = [string]$routingContract.expected_labview_year
        routing_contract_required_setup_label = [string]$routingContract.required_setup_label
        routing_contract_setup_labels_csv = [string]$routingContract.setup_labels_csv
        routing_contract_requires_actor_label = [bool]$routingContract.requires_actor_label
        routing_contract_required_actor_label = [string]$routingContract.required_actor_label
        routing_contract_actor_label_present = [bool]$routingContract.actor_label_present
        routing_contract_actor_labels_csv = [string]$routingContract.actor_labels_csv
        allowed_machine_names_csv = $allowedMachineNamesCsv
        execution_bitness = $executionBitness
        require_secondary_32 = $requireSecondary32
        start_docker_desktop_if_needed = $startDockerDesktop
        switch_docker_context = $switchDockerContext
        run_id = if ($null -ne $run) { (Get-ScalarString -Value $run.databaseId) } else { '' }
        run_url = if ($null -ne $run) { (Get-ScalarString -Value $run.url) } else { '' }
        run_created_at = if ($null -ne $run) { (Get-ScalarString -Value $run.createdAt) } else { '' }
        status = if ($null -ne $run) { (Get-ScalarString -Value $run.status) } else { 'unknown' }
        conclusion = if ($null -ne $run) { (Get-ScalarString -Value $run.conclusion) } else { '' }
    }
    $dispatchRecords += [pscustomobject]$record

    if ($Watch -and $null -ne $run -and -not [string]::IsNullOrWhiteSpace([string]$run.databaseId)) {
        Invoke-Gh -Arguments @('run', 'watch', [string]$run.databaseId, '-R', $Repository)
    }
}

$report = [ordered]@{
    timestamp_utc = (Get-Date).ToUniversalTime().ToString('o')
    repository = $Repository
    workflow = $WorkflowFile
    ref = $Ref
    actor_machine_name = $resolvedActorMachineName
    actor_key_strategy = $ActorKeyStrategy
    profiles_path = $resolvedProfilesPath
    dispatched_setups = @($selectedSetups | ForEach-Object { [string]$_.name })
    runs = @($dispatchRecords)
}

if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $resolvedOutputPath = [System.IO.Path]::GetFullPath($OutputPath)
    $parent = Split-Path -Path $resolvedOutputPath -Parent
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -Path $parent -ItemType Directory -Force | Out-Null
    }
    $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resolvedOutputPath -Encoding utf8
    Write-Host ("Dispatch report written: {0}" -f $resolvedOutputPath)
}

$report | ConvertTo-Json -Depth 8 | Write-Output

