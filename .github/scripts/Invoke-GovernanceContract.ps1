#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter()]
    [string]$RepoSlug = 'svelderrainruiz/labview-cdev-surface',

    [Parameter()]
    [string]$Branch = 'main'
)

$ErrorActionPreference = 'Stop'

$tokenSource = ''
if (-not [string]::IsNullOrWhiteSpace($env:GH_ADMIN_TOKEN)) {
    $env:GH_TOKEN = $env:GH_ADMIN_TOKEN
    $tokenSource = 'GH_ADMIN_TOKEN'
} elseif (-not [string]::IsNullOrWhiteSpace($env:WORKFLOW_BOT_TOKEN)) {
    $env:GH_TOKEN = $env:WORKFLOW_BOT_TOKEN
    $tokenSource = 'WORKFLOW_BOT_TOKEN'
} elseif (-not [string]::IsNullOrWhiteSpace($env:GH_TOKEN)) {
    $tokenSource = 'GH_TOKEN'
} elseif (-not [string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN)) {
    $env:GH_TOKEN = $env:GITHUB_TOKEN
    $tokenSource = 'GITHUB_TOKEN'
}

if ([string]::IsNullOrWhiteSpace($RepoSlug)) {
    throw 'RepoSlug is required.'
}
if ([string]::IsNullOrWhiteSpace($Branch)) {
    throw 'Branch is required.'
}
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw 'gh CLI is required.'
}
if ([string]::IsNullOrWhiteSpace($env:GH_TOKEN)) {
    throw 'GH token is required. Set GH_ADMIN_TOKEN (preferred) or WORKFLOW_BOT_TOKEN/GH_TOKEN/GITHUB_TOKEN.'
}

$requiredContexts = @(
    'CI Pipeline',
    'Workspace Installer Contract',
    'Reproducibility Contract',
    'Provenance Contract'
)

$endpoint = "repos/$RepoSlug/branches/$([uri]::EscapeDataString($Branch))/protection"
$response = & gh api $endpoint 2>&1
if ($LASTEXITCODE -ne 0) {
    $errorText = [string]::Join([Environment]::NewLine, @($response))
    if ($errorText -match 'Resource not accessible by integration' -or $errorText -match 'HTTP 403') {
        Write-Warning "Branch protection API is not accessible with token source '$tokenSource'. Set GH_ADMIN_TOKEN secret with repository administration access to enforce this check. Skipping enforcement for this run."
        exit 0
    }

    throw "Failed to read branch protection for ${RepoSlug}:$Branch. $errorText"
}

$protection = $response | ConvertFrom-Json -ErrorAction Stop
$issues = @()

if ($null -eq $protection.required_status_checks -or -not [bool]$protection.required_status_checks.strict) {
    $issues += 'required_status_checks.strict is not enabled'
}

$actualContexts = @()
if ($null -ne $protection.required_status_checks -and $null -ne $protection.required_status_checks.contexts) {
    $actualContexts = @($protection.required_status_checks.contexts)
}

foreach ($context in $requiredContexts) {
    if ($actualContexts -notcontains $context) {
        $issues += "missing required status context: $context"
    }
}

if ($null -eq $protection.required_pull_request_reviews) {
    $issues += 'required_pull_request_reviews is not enabled'
}

if ($null -ne $protection.allow_force_pushes -and [bool]$protection.allow_force_pushes.enabled) {
    $issues += 'force pushes are allowed'
}

if ($null -ne $protection.allow_deletions -and [bool]$protection.allow_deletions.enabled) {
    $issues += 'branch deletions are allowed'
}

if ($issues.Count -gt 0) {
    $issues | ForEach-Object { Write-Error $_ }
    exit 1
}

Write-Host "Governance contract satisfied for ${RepoSlug}:$Branch"
exit 0

