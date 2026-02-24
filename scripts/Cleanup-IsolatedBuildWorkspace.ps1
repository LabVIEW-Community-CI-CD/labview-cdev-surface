[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Path,

    [Parameter()]
    [switch]$BestEffort,

    [Parameter()]
    [switch]$RequireExists
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-NormalizedPath {
    param([Parameter(Mandatory = $true)][string]$InputPath)

    $full = [System.IO.Path]::GetFullPath($InputPath)
    if ($full.Length -gt 3 -and $full.EndsWith('\\')) {
        $full = $full.TrimEnd('\\')
    }
    return $full
}

$resolvedPath = ConvertTo-NormalizedPath -InputPath $Path
if (-not (Test-Path -LiteralPath $resolvedPath -PathType Container)) {
    if ($RequireExists) {
        throw "Cleanup path does not exist: $resolvedPath"
    }

    [pscustomobject]@{
        path = $resolvedPath
        status = 'skipped'
        message = 'Path does not exist.'
        timestamp_utc = (Get-Date).ToUniversalTime().ToString('o')
    }
    exit 0
}

try {
    Remove-Item -LiteralPath $resolvedPath -Recurse -Force
    [pscustomobject]@{
        path = $resolvedPath
        status = 'deleted'
        message = 'Isolated workspace root removed.'
        timestamp_utc = (Get-Date).ToUniversalTime().ToString('o')
    }
} catch {
    if ($BestEffort) {
        Write-Warning ("Best-effort cleanup failed for '{0}'. {1}" -f $resolvedPath, $_.Exception.Message)
        [pscustomobject]@{
            path = $resolvedPath
            status = 'warning'
            message = $_.Exception.Message
            timestamp_utc = (Get-Date).ToUniversalTime().ToString('o')
        }
    } else {
        throw
    }
}
