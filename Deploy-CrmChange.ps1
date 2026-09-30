#Requires -Version 5.1
<#
.SYNOPSIS
Deploys change-control tickets' CRM components to a target environment.

.DESCRIPTION
Ticket folders live under a release and an org folder, numbered in
deployment order:
    {CRMDeployments}\{DeploymentDate}\{Release}\{Org}\1. CC-3554
    {CRMDeployments}\{DeploymentDate}\{Release}\{Org}\2. CC-3560
{Release} separates releases on the same day (e.g. R1 by day, R2 at night).
{Org} is the CRM organization the tickets deploy to, so the folder name
must match the org name exactly.

-ChangeControlTicket deploys one ticket (found in whichever org folder has
it); -DeployAll deploys every ticket of every org in the release: orgs in
alphabetical order, each org's tickets in number order, one ticket at a
time.

Each ticket's components are deployed in this order:
    1. CRM Non-Isolated Assemblies - updates already-registered assemblies
                                     with isolation mode None
    2. CRM Solutions               - imports each unmanaged solution .zip,
                                     then publishes
    3. CRM Assemblies              - updates already-registered assemblies
                                     with isolation mode Sandbox
    4. Setup Data                  - updates Value on existing Setup records
                                     from the folder's CSV files
    5. PS Scripts                  - copies scripts to
                                     {PSTargetLocation}\<relative path>

A ticket does not need every folder; missing or empty ones are skipped.
Everything, for every ticket, is checked before anything is changed: the
ticket folders, each org's CRM URL and connection, the solution order,
that the DLLs are signed .NET assemblies, the Setup CSVs and the PS
scripts target. The run stops at the first failure, and later tickets are
not deployed.

A run of one ticket logs to {Ticket}\Logs. A run of several tickets
(-DeployAll, or a ticket found in several orgs) logs to {Release}\Logs and
also writes each ticket's part of the summary to that ticket's Logs folder. PS scripts that get overwritten are backed up to
{Ticket}\Backups first.

Static settings (share root, CRM URLs, PS scripts locations, PROD clusters)
live in Settings.psd1 next to this script.

.PARAMETER Environment
Target environment: DEV, UAT or PROD.

.PARAMETER DeploymentDate
The deployment date folder, e.g. 2026-09-30.

.PARAMETER Release
The release folder under the date, e.g. R1 or R2.

.PARAMETER ChangeControlTicket
The ticket to deploy, e.g. CC-3554. Matches the folder "1. CC-3554" (or a
folder named exactly CC-3554) in any org folder of the release; if several
orgs have that ticket, it is deployed to each of them.

.PARAMETER DeployAll
Deploy every ticket of every org in the release. Every ticket folder must
be numbered ("1. CC-3554").

.PARAMETER Cluster
PROD only: the cluster (um1, um2, um3) hosting the org. Overrides the
OrgClusters mapping in Settings.psd1. Only allowed when the run deploys to
a single org.

.PARAMETER Credential
Credential for the CRM connection. Without it, the PSServiceAccount
credentials from $SecuritySettings are used (see Connect-CrmTarget in
lib\Common.ps1).

.PARAMETER SettingsPath
Path to the settings file. Defaults to Settings.psd1 next to this script.

.PARAMETER SkipNonIsolatedAssemblies
Do not update the tickets' CRM non-isolated assemblies.

.PARAMETER SkipSolutions
Do not import the tickets' CRM solutions.

.PARAMETER SkipAssemblies
Do not update the tickets' CRM (sandbox) assemblies.

.PARAMETER SkipSetupData
Do not update the tickets' Setup entity records.

.PARAMETER SkipPSScripts
Do not copy the tickets' PS scripts.

.PARAMETER ContinueOnError
Keep going after an item fails. By default the run stops at the first failure.

.PARAMETER Force
Skip the confirmation prompt for PROD.

.PARAMETER TargetOrgName
No longer supported: the org comes from the org folder. Passing it stops
the run.

.PARAMETER SourceOrgName
No longer supported: the org comes from the org folder. Passing it stops
the run.

.EXAMPLE
.\Deploy-CrmChange.ps1 -Environment DEV -DeploymentDate 2026-09-30 -Release R1 -DeployAll -WhatIf

Dry run: checks every ticket of every org in R1, connects to each org and
lists what would change.

.EXAMPLE
.\Deploy-CrmChange.ps1 -Environment DEV -DeploymentDate 2026-09-30 -Release R1 -DeployAll

.EXAMPLE
.\Deploy-CrmChange.ps1 -Environment DEV -DeploymentDate 2026-09-30 -Release R2 -ChangeControlTicket CC-3554
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Ticket')]
param(
    [Parameter(Mandatory)]
    [ValidateSet('DEV', 'UAT', 'PROD')]
    [string]$Environment,

    [Parameter(Mandatory)]
    [ValidatePattern('^\d{4}-\d{2}-\d{2}$')]
    [string]$DeploymentDate,

    [Parameter(Mandatory)]
    [ValidatePattern('^[\w\-]+$')]
    [string]$Release,

    [Parameter(Mandatory, ParameterSetName = 'Ticket')]
    [ValidatePattern('^[\w\-. ]+$')]
    [string]$ChangeControlTicket,

    [Parameter(Mandatory, ParameterSetName = 'All')]
    [switch]$DeployAll,

    [ValidatePattern('^[\w\-]+$')]
    [string]$Cluster,

    [System.Management.Automation.PSCredential]$Credential,

    [string]$SettingsPath = (Join-Path $PSScriptRoot 'Settings.psd1'),

    [switch]$SkipNonIsolatedAssemblies,
    [switch]$SkipSolutions,
    [switch]$SkipAssemblies,
    [switch]$SkipSetupData,
    [switch]$SkipPSScripts,
    [switch]$ContinueOnError,
    [switch]$Force,

    # Deprecated: the org comes from the org folder under the release.
    [Parameter(DontShow)][string]$TargetOrgName,
    [Parameter(DontShow)][string]$SourceOrgName
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ($PSBoundParameters.ContainsKey('TargetOrgName') -or $PSBoundParameters.ContainsKey('SourceOrgName')) {
    throw ("-TargetOrgName and -SourceOrgName are no longer supported. The org now comes from the org folder: " +
        "{CRMDeployments}\{DeploymentDate}\{Release}\{Org}\{N. Ticket}. Remove them and run again " +
        "(-DeployAll deploys every org in the release).")
}

foreach ($lib in 'Common', 'Tickets', 'Deploy-Solutions', 'Deploy-Assemblies', 'Deploy-SetupData', 'Deploy-PSScripts') {
    . (Join-Path $PSScriptRoot "lib\$lib.ps1")
}

function Get-TicketPlan {
    <#
    .SYNOPSIS
    Reads and checks everything one ticket would deploy (honouring the
    -Skip* switches); throws on the first problem in the ticket.
    #>
    param([Parameter(Mandatory)]$Ticket)

    $folder = $Ticket.Path
    $plan = [pscustomobject]@{
        NonIsolatedAssemblies = @()
        Solutions             = @()
        Assemblies            = @()
        SetupRows             = @()
        Scripts               = @()
        CrmItemCount          = 0
        TotalCount            = 0
    }
    if (-not $SkipNonIsolatedAssemblies) {
        $plan.NonIsolatedAssemblies = @(Get-AssemblyPlan -Folder (Join-Path $folder $folders.NonIsolatedAssemblies))
    }
    if (-not $SkipSolutions) {
        $plan.Solutions = @(Get-SolutionPlan -Folder (Join-Path $folder $folders.Solutions) -SolutionSettings $settings.Solutions)
    }
    if (-not $SkipAssemblies) {
        $plan.Assemblies = @(Get-AssemblyPlan -Folder (Join-Path $folder $folders.Assemblies))
    }
    if (-not $SkipSetupData) {
        $plan.SetupRows = @(Get-SetupDataPlan -Folder (Join-Path $folder $folders.SetupData) -SetupSettings $settings.SetupData)
    }
    if (-not $SkipPSScripts) {
        $plan.Scripts = @(Get-PSScriptPlan -Folder (Join-Path $folder $folders.PSScripts) -TargetRoot $orgTargets[$Ticket.Org].PSTargetLocation -OrgName $Ticket.Org)
    }

    $nonIsolatedNames = @($plan.NonIsolatedAssemblies | ForEach-Object { $_.Name })
    $inBoth = @($plan.Assemblies | Where-Object { $nonIsolatedNames -contains $_.Name } | ForEach-Object { $_.File.Name })
    if ($inBoth.Count -gt 0) {
        throw "These assemblies are in both '$($folders.NonIsolatedAssemblies)' and '$($folders.Assemblies)'; keep each in one folder: $($inBoth -join ', ')"
    }

    $plan.CrmItemCount = $plan.NonIsolatedAssemblies.Count + $plan.Solutions.Count + $plan.Assemblies.Count + $plan.SetupRows.Count
    $plan.TotalCount = $plan.CrmItemCount + $plan.Scripts.Count
    return $plan
}

function Invoke-TicketDeployment {
    <#
    .SYNOPSIS
    Deploys one ticket's stages in order, stopping after a failed stage
    unless -ContinueOnError.
    #>
    param(
        [Parameter(Mandatory)]$Ticket,
        $Conn
    )
    $plan = $Ticket.Plan
    $backupRoot = Join-Path (Join-Path (Join-Path $Ticket.Path $folders.Backups) $runName) $folders.PSScripts

    Invoke-AssemblyDeployment -Conn $Conn -Assemblies $plan.NonIsolatedAssemblies -IsolationMode None -FolderName $folders.NonIsolatedAssemblies -ContinueOnError:$ContinueOnError
    if (-not (Test-HasFailures) -or $ContinueOnError) {
        Invoke-SolutionDeployment -Conn $Conn -Solutions $plan.Solutions -SolutionSettings $settings.Solutions -ContinueOnError:$ContinueOnError
    }
    if (-not (Test-HasFailures) -or $ContinueOnError) {
        Invoke-AssemblyDeployment -Conn $Conn -Assemblies $plan.Assemblies -IsolationMode Sandbox -FolderName $folders.Assemblies -ContinueOnError:$ContinueOnError
    }
    if (-not (Test-HasFailures) -or $ContinueOnError) {
        Invoke-SetupDataDeployment -Conn $Conn -Rows $plan.SetupRows -SetupSettings $settings.SetupData -FolderName $folders.SetupData -ContinueOnError:$ContinueOnError
    }
    if (-not (Test-HasFailures) -or $ContinueOnError) {
        Invoke-PSScriptDeployment -Scripts $plan.Scripts -BackupRoot $backupRoot -ContinueOnError:$ContinueOnError
    }
}

# --- Settings and folders -----------------------------------------------------

if (-not (Test-Path -LiteralPath $SettingsPath -PathType Leaf)) {
    throw "Settings file not found: $SettingsPath"
}
$settings = Import-PowerShellDataFile -LiteralPath $SettingsPath
$folders = $settings.FolderNames

$releaseFolder = Join-Path (Join-Path $settings.CRMDeployments $DeploymentDate) $Release
if (-not (Test-Path -LiteralPath $releaseFolder -PathType Container)) {
    throw "Release folder not found: $releaseFolder"
}
$tickets = @(Get-ReleaseTickets -ReleaseFolder $releaseFolder -ExcludeNames @($folders.Logs) -Ticket $ChangeControlTicket)
$orgs = @($tickets | ForEach-Object { $_.Org } | Select-Object -Unique)

$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$runName = "${Environment}_${Release}_$stamp"
if ($WhatIfPreference) { $runName += '_WhatIf' }
# A single ticket logs into its own folder; a run of several tickets into the
# release folder.
$logRoot = if ($tickets.Count -gt 1) { $releaseFolder } else { $tickets[0].Path }
$logFolder = Join-Path $logRoot $folders.Logs
$logFile = Join-Path $logFolder "$runName.log"

New-Item -ItemType Directory -Path $logFolder -Force -WhatIf:$false | Out-Null
Start-Transcript -LiteralPath $logFile -WhatIf:$false | Out-Null

$exitCode = 0
try {
    Write-Step 'Deployment'
    Write-Info "Release:     $DeploymentDate $Release"
    Write-Info "Source:      $releaseFolder"
    Write-Info "Tickets:     $(($tickets | ForEach-Object { $_.Label }) -join ', ')"
    Write-Info "Environment: $Environment"
    Write-Info "Run by:      $([Environment]::UserDomainName)\$([Environment]::UserName) on $([Environment]::MachineName)"
    if ($WhatIfPreference) { Write-Info 'Mode:        WhatIf (nothing will be changed)' }

    # --- Check everything before changing anything ----------------------------

    Write-Step 'Pre-deployment checks'
    if ($Cluster -and $orgs.Count -gt 1) {
        throw "-Cluster can only be used when deploying to one org; this run covers $($orgs -join ', '). Add the orgs to OrgClusters in Settings.psd1 instead."
    }

    # Each org folder is a CRM org: resolve its URL and scripts location.
    $orgTargets = @{}
    $problems = @()
    foreach ($org in $orgs) {
        try {
            $orgTargets[$org] = Resolve-EnvironmentSettings -Settings $settings -Environment $Environment -OrgName $org -Cluster $Cluster
            Write-Info "${org}: $($orgTargets[$org].OrgUrl)$(if ($orgTargets[$org].Cluster) { " (cluster $($orgTargets[$org].Cluster))" })"
        } catch {
            $problems += "${org}: $($_.Exception.Message)"
        }
    }
    if ($problems) {
        throw "Pre-deployment checks failed; nothing was deployed.`n" + ($problems -join "`n")
    }

    foreach ($ticket in $tickets) {
        try {
            $plan = Get-TicketPlan -Ticket $ticket
            $ticket | Add-Member -NotePropertyName Plan -NotePropertyValue $plan
            Write-Info ("{0}: {1} non-isolated assembly(ies), {2} solution(s), {3} sandbox assembly(ies), {4} setup row(s), {5} PS script(s)" -f `
                $ticket.Label, $plan.NonIsolatedAssemblies.Count, $plan.Solutions.Count, $plan.Assemblies.Count, $plan.SetupRows.Count, $plan.Scripts.Count)
        } catch {
            $problems += "$($ticket.Label): $($_.Exception.Message)"
        }
    }
    if ($problems) {
        throw "Pre-deployment checks failed; nothing was deployed.`n" + ($problems -join "`n")
    }
    if ($tickets.Count -gt 1) {
        Write-DuplicateComponentWarnings -Tickets $tickets
    }

    if (($tickets | ForEach-Object { $_.Plan.TotalCount } | Measure-Object -Sum).Sum -eq 0) {
        Write-Warn 'Nothing to deploy.'
        return
    }

    # Check each org's PS scripts target, and connect to each org that has
    # CRM components, before deploying anything.
    $connections = @{}
    foreach ($org in $orgs) {
        $orgTickets = @($tickets | Where-Object { $_.Org -eq $org })
        $orgTarget = $orgTargets[$org]
        if (($orgTickets | ForEach-Object { $_.Plan.Scripts.Count } | Measure-Object -Sum).Sum -gt 0) {
            if (-not $orgTarget.PSTargetLocation -or $orgTarget.PSTargetLocation -eq 'TODO') {
                throw "PSTargetLocation for $Environment is not set in Settings.psd1."
            }
            if (-not (Test-Path -LiteralPath $orgTarget.PSTargetLocation -PathType Container)) {
                throw "PS scripts target for $org is not reachable: $($orgTarget.PSTargetLocation)"
            }
        }
        if (($orgTickets | ForEach-Object { $_.Plan.CrmItemCount } | Measure-Object -Sum).Sum -gt 0) {
            $connections[$org] = Connect-CrmTarget -Target $orgTarget -OrgName $org -Credential $Credential
        }
    }
    Write-Info 'Checks passed.'

    if ($Environment -eq 'PROD' -and -not $WhatIfPreference -and -not $Force) {
        $question = "Deploy to PROD: $(($tickets | ForEach-Object { $_.Label }) -join ', ')?"
        if (-not $PSCmdlet.ShouldContinue($question, 'PROD deployment')) {
            Write-Warn 'Cancelled by user.'
            return
        }
    }

    # --- Deploy, one ticket at a time ------------------------------------------

    foreach ($ticket in $tickets) {
        $script:CurrentTicket = $ticket.Label
        if ((Test-HasFailures) -and -not $ContinueOnError) {
            Add-DeploymentResult -Stage 'Ticket' -Item $ticket.Label -Status Skipped -Detail 'Not deployed: an earlier ticket failed'
            continue
        }
        if ($tickets.Count -gt 1) {
            Write-Host ''
            Write-Host "##### Ticket $($ticket.Label) -> $($orgTargets[$ticket.Org].OrgUrl) #####" -ForegroundColor Magenta
        }
        if ($ticket.Plan.TotalCount -eq 0) {
            Write-Info 'Nothing to deploy.'
            continue
        }
        $conn = if ($connections.ContainsKey($ticket.Org)) { $connections[$ticket.Org] } else { $null }
        Invoke-TicketDeployment -Ticket $ticket -Conn $conn
    }
} catch {
    Write-Host ''
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    $exitCode = 1
} finally {
    $results = @(Get-DeploymentResults)
    $columns = if ($tickets.Count -gt 1) { 'Ticket', 'Stage', 'Status', 'Item', 'Detail' } else { 'Stage', 'Status', 'Item', 'Detail' }
    if ($results.Count -gt 0) {
        Write-Step 'Summary'
        $results | Format-Table $columns -AutoSize -Wrap | Out-String -Width 200 | Write-Host
    }
    # In a run of several tickets, leave each ticket its own part of the summary.
    if ($tickets.Count -gt 1) {
        foreach ($ticket in $tickets) {
            $ticketResults = @($results | Where-Object { $_.Ticket -eq $ticket.Label })
            if ($ticketResults.Count -eq 0) { continue }
            try {
                $ticketLogFolder = Join-Path $ticket.Path $folders.Logs
                New-Item -ItemType Directory -Path $ticketLogFolder -Force -WhatIf:$false | Out-Null
                $text = "Deployed together with other tickets ($Environment, $DeploymentDate $Release). Full log: $logFile`r`n"
                $text += $ticketResults | Format-Table Stage, Status, Item, Detail -AutoSize -Wrap | Out-String -Width 200
                Set-Content -LiteralPath (Join-Path $ticketLogFolder "$runName.log") -Value $text -WhatIf:$false
            } catch {
                Write-Warn "Could not write the summary for $($ticket.Label): $($_.Exception.Message)"
            }
        }
    }
    if (Test-HasFailures) { $exitCode = 1 }
    if ($exitCode -eq 0) {
        Write-Host 'Deployment finished successfully.' -ForegroundColor Green
    } else {
        Write-Host 'Deployment finished with errors.' -ForegroundColor Red
    }
    Write-Host "Log: $logFile"
    Stop-Transcript | Out-Null
}
exit $exitCode
