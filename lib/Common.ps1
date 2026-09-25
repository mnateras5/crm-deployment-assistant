# Shared helpers: console/log output and the per-item result list that feeds
# the end-of-run summary. Dot-sourced by Deploy-CrmChange.ps1.

$script:DeploymentResults = New-Object System.Collections.Generic.List[object]

function Write-Step {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host ''
    Write-Host "=== $Message ===" -ForegroundColor Cyan
}

function Write-Info {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "  $Message"
}

function Write-Warn {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "  WARNING: $Message" -ForegroundColor Yellow
}

function Add-DeploymentResult {
    <#
    .SYNOPSIS
    Records the outcome of one deployed item for the summary.
    Status is one of: Deployed, Unchanged, WhatIf, Skipped, Failed.
    #>
    param(
        [Parameter(Mandatory)][string]$Stage,
        [Parameter(Mandatory)][string]$Item,
        [Parameter(Mandatory)][ValidateSet('Deployed', 'Unchanged', 'WhatIf', 'Skipped', 'Failed')][string]$Status,
        [string]$Detail = ''
    )
    $script:DeploymentResults.Add([pscustomobject]@{
        Stage  = $Stage
        Item   = $Item
        Status = $Status
        Detail = $Detail
    })
    $color = switch ($Status) {
        'Deployed'  { 'Green' }
        'Failed'    { 'Red' }
        'WhatIf'    { 'DarkCyan' }
        default     { 'Gray' }
    }
    $line = "  [$Status] $Item"
    if ($Detail) { $line += " - $Detail" }
    Write-Host $line -ForegroundColor $color
}

function Get-DeploymentResults {
    return $script:DeploymentResults.ToArray()
}

function Test-HasFailures {
    return @($script:DeploymentResults | Where-Object { $_.Status -eq 'Failed' }).Count -gt 0
}

function Get-StageFiles {
    <#
    .SYNOPSIS
    Returns the files of a stage folder matching a filter, or an empty array
    when the folder is missing (a ticket does not need every component type).
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Filter = '*',
        [switch]$Recurse
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return @()
    }
    return @(Get-ChildItem -LiteralPath $Path -Filter $Filter -File -Recurse:$Recurse | Sort-Object FullName)
}
