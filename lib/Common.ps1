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

function Get-TurningPointCrmCredentials(){
	$UserName = $SecuritySettings.PSServiceAccount
	$Password =  $SecuritySettings.PSServiceAccountPassword
	New-Object System.Management.Automation.PSCredential ($UserName, $Password)
}

function Connect-CrmTarget {
    param(
        [Parameter(Mandatory)]$Target,
        [Parameter(Mandatory)][string]$OrgName,
        [System.Management.Automation.PSCredential]$Credential
    )
    if ($PSVersionTable.PSEdition -ne 'Desktop') {
        throw 'Microsoft.Xrm.Data.PowerShell needs Windows PowerShell 5.1 (powershell.exe), not PowerShell 7 (pwsh.exe).'
    }
    if (-not (Get-Module -ListAvailable -Name Microsoft.Xrm.Data.PowerShell)) {
        throw 'Module Microsoft.Xrm.Data.PowerShell is not installed. Run: Install-Module Microsoft.Xrm.Data.PowerShell -Scope CurrentUser'
    }
    Import-Module Microsoft.Xrm.Data.PowerShell -ErrorAction Stop

    Write-Info "Connecting to $($Target.OrgUrl) ..."
    if ($Credential) {
        $conn = Connect-CrmOnPremDiscovery -ServerUrl $Target.ServerUrl -OrganizationName $OrgName -Credential $Credential -ErrorAction Stop
    } else {
        #$conn = Get-CrmConnection -ConnectionString "AuthType=AD;Url=$($Target.OrgUrl)" -ErrorAction Stop
        $Credential = Get-TurningPointCrmCredentials
        $conn = Connect-CrmOnPremDiscovery -ServerUrl $Target.ServerUrl -OrganizationName $OrgName -Credential $Credential -ErrorAction Stop
    }
    if (-not $conn -or -not $conn.IsReady) {
        $reason = if ($conn) { $conn.LastCrmError } else { 'no connection returned' }
        throw "Could not connect to $($Target.OrgUrl): $reason"
    }
    Write-Info "Connected to $($conn.ConnectedOrgFriendlyName) ($($conn.ConnectedOrgVersion))."
    return $conn
}


function Resolve-EnvironmentSettings {
    <#
    .SYNOPSIS
    Returns the environment's CRM server URL, org URL and PS scripts location,
    with the {Cluster} token resolved.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Settings,
        [Parameter(Mandatory)][string]$Environment,
        [Parameter(Mandatory)][string]$OrgName,
        [string]$Cluster
    )
    $envSettings = $Settings.Environments[$Environment]
    if (-not $envSettings) {
        throw "Settings.psd1 has no '$Environment' entry under Environments."
    }
    $serverUrl = $envSettings.CrmServerUrl
    $psTarget = $envSettings.PSTargetLocation

    if ("$serverUrl$psTarget" -match '\{Cluster\}') {
        if (-not $Cluster) {
            $clusters = $envSettings['OrgClusters']
            if ($clusters -and $clusters.ContainsKey($OrgName)) {
                $Cluster = $clusters[$OrgName]
            }
        }
        if (-not $Cluster) {
            throw "No $Environment cluster is known for org '$OrgName'. Add it to OrgClusters in Settings.psd1 or pass -Cluster."
        }
        $serverUrl = $serverUrl.Replace('{Cluster}', $Cluster)
        $psTarget = $psTarget.Replace('{Cluster}', $Cluster)
    }

    return [pscustomobject]@{
        ServerUrl        = $serverUrl.TrimEnd('/')
        OrgUrl           = "$($serverUrl.TrimEnd('/'))/$OrgName"
        PSTargetLocation = $psTarget
        Cluster          = $Cluster
    }
}


