#Requires -Version 5.1
<#
.SYNOPSIS
Deploys change-control tickets' CRM components to a target environment.

.DESCRIPTION
Ticket folders live under an org folder, numbered in deployment order:
    {CRMDeployments}\{DeploymentDate}\{Org}\1. CC-3554
    {CRMDeployments}\{DeploymentDate}\{Org}\2. CC-3560
{Org} is the org the packages were built for (SourceOrgName, which
defaults to TargetOrgName).

-ChangeControlTicket deploys one ticket; -DeployAll deploys every ticket
in the org folder in number order, one ticket at a time.

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
ticket folders, the solution order, that the DLLs are signed .NET
assemblies, the Setup CSVs, the PS scripts target, and the CRM connection.
The run stops at the first failure, and later tickets are not deployed.

A single-ticket run logs to {Ticket}\Logs. A -DeployAll run logs to
{Org}\Logs and also writes each ticket's part of the summary to that
ticket's Logs folder. PS scripts that get overwritten are backed up to
{Ticket}\Backups first.

Static settings (share root, CRM URLs, PS scripts locations, PROD clusters)
live in Settings.psd1 next to this script.

.PARAMETER Environment
Target environment: DEV, UAT or PROD.

.PARAMETER TargetOrgName
The CRM organization to deploy to, which is the client name, e.g. Fidelis.

.PARAMETER SourceOrgName
The org the package was built for. Defaults to TargetOrgName. Set it to
deploy a package built for one org to another: PS scripts in a folder
named after the source org (e.g. Orgs\Fidelis) go to the target org's
folder instead (Orgs\Centene), and Setup Data rows are matched by Name
when their IDs don't exist in the target org.

.PARAMETER DeploymentDate
The deployment date folder, e.g. 2026-09-30.

.PARAMETER ChangeControlTicket
The ticket to deploy, e.g. CC-3554. Matches the folder "1. CC-3554" (or a
folder named exactly CC-3554).

.PARAMETER DeployAll
Deploy every ticket folder under the org folder, in number order. Every
ticket folder must be numbered ("1. CC-3554").

.PARAMETER Cluster
PROD only: the cluster (um1, um2, um3) hosting the org. Overrides the
OrgClusters mapping in Settings.psd1.

.PARAMETER Credential
Credential for the CRM connection. Without it, the PSServiceAccount
credentials from $SecuritySettings are used (see Connect-CrmTarget in
lib\Common.ps1).

.PARAMETER SettingsPath
Path to the settings file. Defaults to Settings.psd1 next to this script.

.PARAMETER SkipNonIsolatedAssemblies
Do not update the ticket's CRM non-isolated assemblies.

.PARAMETER SkipSolutions
Do not import the ticket's CRM solutions.

.PARAMETER SkipAssemblies
Do not update the ticket's CRM (sandbox) assemblies.

.PARAMETER SkipSetupData
Do not update the ticket's Setup entity records.

.PARAMETER SkipPSScripts
Do not copy the ticket's PS scripts.

.PARAMETER ContinueOnError
Keep going after an item fails. By default the run stops at the first failure.

.PARAMETER Force
Skip the confirmation prompt for PROD.

.EXAMPLE
.\Deploy-CrmChange.ps1 -Environment DEV -TargetOrgName Fidelis -DeploymentDate 2026-09-30 -ChangeControlTicket CC-3322 -WhatIf

Dry run: checks the ticket, connects to CRM and lists what would change.

.EXAMPLE
.\Deploy-CrmChange.ps1 -Environment DEV -TargetOrgName Fidelis -DeploymentDate 2026-09-30 -ChangeControlTicket CC-3322

.EXAMPLE
.\Deploy-CrmChange.ps1 -Environment DEV -TargetOrgName Fidelis -DeploymentDate 2026-09-30 -DeployAll -WhatIf

Dry run of every Fidelis ticket for 2026-09-30.

.EXAMPLE
.\Deploy-CrmChange.ps1 -Environment DEV -SourceOrgName Fidelis -TargetOrgName Centene -DeploymentDate 2026-09-30 -ChangeControlTicket CC-3322 -WhatIf

Deploys the CC-3322 package, built for Fidelis, to the Centene org.
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Ticket')]
param(
    [Parameter(Mandatory)]
    [ValidateSet('DEV', 'UAT', 'PROD')]
    [string]$Environment,

    [Parameter(Mandatory)]
    [ValidatePattern('^[\w\-]+$')]
    [string]$TargetOrgName,

    [ValidatePattern('^[\w\-]+$')]
    [string]$SourceOrgName,

    [Parameter(Mandatory)]
    [ValidatePattern('^\d{4}-\d{2}-\d{2}$')]
    [string]$DeploymentDate,

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
    [switch]$Force
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

foreach ($lib in 'Common', 'Tickets', 'Deploy-Solutions', 'Deploy-Assemblies', 'Deploy-SetupData', 'Deploy-PSScripts') {
    . (Join-Path $PSScriptRoot "lib\$lib.ps1")
}

function Get-TicketPlan {
    <#
    .SYNOPSIS
    Reads and checks everything one ticket would deploy (honouring the
    -Skip* switches); throws on the first problem in the ticket.
    #>
    param([Parameter(Mandatory)][string]$TicketFolder)

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
        $plan.NonIsolatedAssemblies = @(Get-AssemblyPlan -Folder (Join-Path $TicketFolder $folders.NonIsolatedAssemblies))
    }
    if (-not $SkipSolutions) {
        $plan.Solutions = @(Get-SolutionPlan -Folder (Join-Path $TicketFolder $folders.Solutions) -SolutionSettings $settings.Solutions)
    }
    if (-not $SkipAssemblies) {
        $plan.Assemblies = @(Get-AssemblyPlan -Folder (Join-Path $TicketFolder $folders.Assemblies))
    }
    if (-not $SkipSetupData) {
        $plan.SetupRows = @(Get-SetupDataPlan -Folder (Join-Path $TicketFolder $folders.SetupData) -SetupSettings $settings.SetupData)
    }
    if (-not $SkipPSScripts) {
        $plan.Scripts = @(Get-PSScriptPlan -Folder (Join-Path $TicketFolder $folders.PSScripts) -TargetRoot $target.PSTargetLocation -SourceOrgName $SourceOrgName -TargetOrgName $TargetOrgName)
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
if (-not $SourceOrgName) { $SourceOrgName = $TargetOrgName }
$target = Resolve-EnvironmentSettings -Settings $settings -Environment $Environment -OrgName $TargetOrgName -Cluster $Cluster
$folders = $settings.FolderNames

$orgFolder = Join-Path (Join-Path $settings.CRMDeployments $DeploymentDate) $SourceOrgName
if (-not (Test-Path -LiteralPath $orgFolder -PathType Container)) {
    throw "Org folder not found: $orgFolder"
}
$tickets = @(Get-TicketFolders -OrgFolder $orgFolder -ExcludeNames @($folders.Logs) -Ticket $ChangeControlTicket)

$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$runName = "${Environment}_${TargetOrgName}_$stamp"
if ($WhatIfPreference) { $runName += '_WhatIf' }
# A single ticket logs into its own folder; a -DeployAll run into the org folder.
$logRoot = if ($DeployAll) { $orgFolder } else { $tickets[0].Path }
$logFolder = Join-Path $logRoot $folders.Logs
$logFile = Join-Path $logFolder "$runName.log"

New-Item -ItemType Directory -Path $logFolder -Force -WhatIf:$false | Out-Null
Start-Transcript -LiteralPath $logFile -WhatIf:$false | Out-Null

$exitCode = 0
try {
    Write-Step 'Deployment'
    Write-Info "Date:        $DeploymentDate"
    Write-Info "Source:      $orgFolder"
    Write-Info "Tickets:     $(($tickets | ForEach-Object { $_.Name }) -join ', ')"
    Write-Info "Environment: $Environment$(if ($target.Cluster) { " (cluster $($target.Cluster))" })"
    Write-Info "CRM org:     $($target.OrgUrl)"
    if ($SourceOrgName -ne $TargetOrgName) { Write-Info "Package org: $SourceOrgName (deploying to $TargetOrgName)" }
    Write-Info "PS scripts:  $($target.PSTargetLocation)"
    Write-Info "Run by:      $([Environment]::UserDomainName)\$([Environment]::UserName) on $([Environment]::MachineName)"
    if ($WhatIfPreference) { Write-Info 'Mode:        WhatIf (nothing will be changed)' }

    # --- Check every ticket before changing anything --------------------------

    Write-Step 'Pre-deployment checks'
    $problems = @()
    foreach ($ticket in $tickets) {
        try {
            $plan = Get-TicketPlan -TicketFolder $ticket.Path
            $ticket | Add-Member -NotePropertyName Plan -NotePropertyValue $plan
            Write-Info ("{0}: {1} non-isolated assembly(ies), {2} solution(s), {3} sandbox assembly(ies), {4} setup row(s), {5} PS script(s)" -f `
                $ticket.Name, $plan.NonIsolatedAssemblies.Count, $plan.Solutions.Count, $plan.Assemblies.Count, $plan.SetupRows.Count, $plan.Scripts.Count)
        } catch {
            $problems += "$($ticket.Name): $($_.Exception.Message)"
        }
    }
    if ($problems) {
        throw "Pre-deployment checks failed; nothing was deployed.`n" + ($problems -join "`n")
    }
    if ($tickets.Count -gt 1) {
        Write-DuplicateComponentWarnings -Tickets $tickets
    }

    $totalCount = ($tickets | ForEach-Object { $_.Plan.TotalCount } | Measure-Object -Sum).Sum
    $crmItemCount = ($tickets | ForEach-Object { $_.Plan.CrmItemCount } | Measure-Object -Sum).Sum
    $scriptCount = ($tickets | ForEach-Object { $_.Plan.Scripts.Count } | Measure-Object -Sum).Sum
    if ($totalCount -eq 0) {
        Write-Warn 'Nothing to deploy.'
        return
    }

    if ($scriptCount -gt 0) {
        if (-not $target.PSTargetLocation -or $target.PSTargetLocation -eq 'TODO') {
            throw "PSTargetLocation for $Environment is not set in Settings.psd1."
        }
        if (-not (Test-Path -LiteralPath $target.PSTargetLocation -PathType Container)) {
            throw "PS scripts target is not reachable: $($target.PSTargetLocation)"
        }
    }

    $conn = $null
    if ($crmItemCount -gt 0) {
        $conn = Connect-CrmTarget -Target $target -OrgName $TargetOrgName -Credential $Credential
    }
    Write-Info 'Checks passed.'

    if ($Environment -eq 'PROD' -and -not $WhatIfPreference -and -not $Force) {
        $question = "Deploy $(($tickets | ForEach-Object { $_.Name }) -join ', ') to PROD org $TargetOrgName ($($target.OrgUrl))?"
        if (-not $PSCmdlet.ShouldContinue($question, 'PROD deployment')) {
            Write-Warn 'Cancelled by user.'
            return
        }
    }

    # --- Deploy, one ticket at a time ------------------------------------------

    foreach ($ticket in $tickets) {
        $script:CurrentTicket = $ticket.Name
        if ((Test-HasFailures) -and -not $ContinueOnError) {
            Add-DeploymentResult -Stage 'Ticket' -Item $ticket.Name -Status Skipped -Detail 'Not deployed: an earlier ticket failed'
            continue
        }
        if ($tickets.Count -gt 1) {
            Write-Host ''
            Write-Host "##### Ticket $($ticket.Name) #####" -ForegroundColor Magenta
        }
        if ($ticket.Plan.TotalCount -eq 0) {
            Write-Info 'Nothing to deploy.'
            continue
        }
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
    # In a -DeployAll run, leave each ticket its own part of the summary.
    if ($DeployAll) {
        foreach ($ticket in $tickets) {
            $ticketResults = @($results | Where-Object { $_.Ticket -eq $ticket.Name })
            if ($ticketResults.Count -eq 0) { continue }
            try {
                $ticketLogFolder = Join-Path $ticket.Path $folders.Logs
                New-Item -ItemType Directory -Path $ticketLogFolder -Force -WhatIf:$false | Out-Null
                $text = "Deployed with -DeployAll ($Environment, $TargetOrgName). Full log: $logFile`r`n"
                $text += $ticketResults | Format-Table Stage, Status, Item, Detail -AutoSize -Wrap | Out-String -Width 200
                Set-Content -LiteralPath (Join-Path $ticketLogFolder "$runName.log") -Value $text -WhatIf:$false
            } catch {
                Write-Warn "Could not write the summary for $($ticket.Name): $($_.Exception.Message)"
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
