# Shared helpers: console/log output and the per-item result list that feeds
# the end-of-run summary. Dot-sourced by Deploy-CrmChange.ps1.

$script:DeploymentResults = New-Object System.Collections.Generic.List[object]
# The ticket folder being deployed; stamped on each result.
$script:CurrentTicket = ''

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
        Ticket = $script:CurrentTicket
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
    # With -Ticket, only that ticket's results count.
    param([string]$Ticket)
    return @($script:DeploymentResults | Where-Object {
        $_.Status -eq 'Failed' -and (-not $Ticket -or $_.Ticket -eq $Ticket)
    }).Count -gt 0
}

# --- Archive ------------------------------------------------------------------
#
# After an item deploys, a copy goes to the ticket's archive for the
# environment, mirroring its path in the ticket folder:
#   {Org}\{N. Ticket}\CRM Solutions\Core.zip
#   -> {Org}\Archive\{Env}\{N. Ticket}\CRM Solutions\Core.zip
# A later run in that environment skips items whose archived copy is
# identical, so a re-run after a failure only deploys what is left (and a
# file that was changed since is deployed again). The originals stay in
# place for the other environments.

# Set per ticket by Deploy-CrmChange.ps1: @{ TicketPath; ArchivePath }.
$script:ArchiveContext = $null

function Get-ArchivedCopyPath {
    param([Parameter(Mandatory)][string]$Path)
    if (-not $script:ArchiveContext) { return $null }
    $ticketPath = $script:ArchiveContext.TicketPath.TrimEnd('\', '/')
    if (-not $Path.StartsWith($ticketPath, [StringComparison]::OrdinalIgnoreCase)) { return $null }
    $relative = $Path.Substring($ticketPath.Length).TrimStart('\', '/')
    return Join-Path $script:ArchiveContext.ArchivePath $relative
}

function Test-Archived {
    <#
    .SYNOPSIS
    True when the file was already deployed to this environment: its
    archived copy exists and is identical.
    #>
    param([Parameter(Mandatory)][string]$Path)
    $copy = Get-ArchivedCopyPath -Path $Path
    if (-not $copy -or -not (Test-Path -LiteralPath $copy -PathType Leaf)) { return $false }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath $copy -Algorithm SHA256).Hash
}

function Add-ToArchive {
    <#
    .SYNOPSIS
    Copies a deployed file to the environment's archive. Does nothing under
    -WhatIf; a failure to archive is a warning, not a failed deployment.
    #>
    param([Parameter(Mandatory)][string]$Path)
    if ($WhatIfPreference) { return }
    $copy = Get-ArchivedCopyPath -Path $Path
    if (-not $copy) { return }
    try {
        New-Item -ItemType Directory -Path (Split-Path $copy -Parent) -Force -WhatIf:$false | Out-Null
        Copy-Item -LiteralPath $Path -Destination $copy -Force -ErrorAction Stop -WhatIf:$false
    } catch {
        Write-Warn "Deployed, but could not archive '$Path': $($_.Exception.Message)"
    }
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

function Set-CrmRequestTimeout {
    <#
    .SYNOPSIS
    Sets how long each CRM request on this connection may take (the SDK
    default is 2 minutes), using whatever the installed module and CRM
    connector versions support. Never fails the run: warns instead.
    #>
    param(
        [Parameter(Mandatory)]$Conn,
        [Parameter(Mandatory)][TimeSpan]$Timeout
    )
    try {
        if (Get-Command Set-CrmConnectionTimeout -ErrorAction SilentlyContinue) {
            Set-CrmConnectionTimeout -conn $Conn -TimeoutInSeconds ([int]$Timeout.TotalSeconds) -ErrorAction Stop | Out-Null
            Write-Info "Request timeout: $([int]$Timeout.TotalSeconds)s."
            return
        }
        # On-premises (AD) connections go through an OrganizationServiceProxy;
        # newer connectors use an OrganizationWebProxyClient.
        $proxyProperty = $Conn.PSObject.Properties['OrganizationServiceProxy']
        if ($proxyProperty -and $proxyProperty.Value) {
            $proxyProperty.Value.Timeout = $Timeout
            Write-Info "Request timeout: $([int]$Timeout.TotalSeconds)s."
            return
        }
        $webProperty = $Conn.PSObject.Properties['OrganizationWebProxyClient']
        if ($webProperty -and $webProperty.Value) {
            $webProperty.Value.InnerChannel.OperationTimeout = $Timeout
            Write-Info "Request timeout: $([int]$Timeout.TotalSeconds)s."
            return
        }
        Write-Warn 'Could not set the CRM request timeout on this connection; the default (2 minutes) applies.'
    } catch {
        Write-Warn "Could not set the CRM request timeout: $($_.Exception.Message). The default (2 minutes) applies."
    }
}

function Connect-CrmTarget {
    param(
        [Parameter(Mandatory)]$Target,
        [Parameter(Mandatory)][string]$OrgName,
        [System.Management.Automation.PSCredential]$Credential,
        # Timeout for connecting and for each CRM request (the SDK default is 2 minutes).
        [int]$TimeoutSeconds = 180
    )
    if ($PSVersionTable.PSEdition -ne 'Desktop') {
        throw 'Microsoft.Xrm.Data.PowerShell needs Windows PowerShell 5.1 (powershell.exe), not PowerShell 7 (pwsh.exe).'
    }
    if (-not (Get-Module -ListAvailable -Name Microsoft.Xrm.Data.PowerShell)) {
        throw 'Module Microsoft.Xrm.Data.PowerShell is not installed. Run: Install-Module Microsoft.Xrm.Data.PowerShell -Scope CurrentUser'
    }
    Import-Module Microsoft.Xrm.Data.PowerShell -ErrorAction Stop

    $timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)

    # Newer versions of the CRM connector have a global timeout that also
    # covers connecting; older ones don't, so only set it when it exists.
    $clientType = 'Microsoft.Xrm.Tooling.Connector.CrmServiceClient' -as [type]
    $globalTimeout = if ($clientType) { $clientType.GetProperty('MaxConnectionTimeout', [Reflection.BindingFlags]'Public, Static') } else { $null }
    if ($globalTimeout -and $globalTimeout.CanWrite) {
        $globalTimeout.SetValue($null, $timeout)
    }

    if (-not $Credential) {
        #$conn = Get-CrmConnection -ConnectionString "AuthType=AD;Url=$($Target.OrgUrl)" -ErrorAction Stop
        $Credential = Get-TurningPointCrmCredentials
    }
    $connectArgs = @{
        ServerUrl        = $Target.ServerUrl
        OrganizationName = $OrgName
        Credential       = $Credential
        ErrorAction      = 'Stop'
    }
    # Module versions that take the timeout as a parameter.
    if ((Get-Command Connect-CrmOnPremDiscovery).Parameters.ContainsKey('ConnectionTimeoutInSeconds')) {
        $connectArgs.ConnectionTimeoutInSeconds = $TimeoutSeconds
    }

    Write-Info "Connecting to $($Target.OrgUrl) ..."
    $conn = Connect-CrmOnPremDiscovery @connectArgs
    if (-not $conn -or -not $conn.IsReady) {
        $reason = if ($conn) { $conn.LastCrmError } else { 'no connection returned' }
        throw "Could not connect to $($Target.OrgUrl): $reason"
    }
    Set-CrmRequestTimeout -Conn $conn -Timeout $timeout
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


