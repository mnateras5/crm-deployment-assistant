#Requires -Version 5.1
<#
.SYNOPSIS
Deploys one change-control ticket's CRM components to a target environment.

.DESCRIPTION
Reads the ticket folder
    {CRMDeployments}\{DeploymentDate}\{ChangeControlTicket}
and deploys, in this order:
    1. CRM Non-Isolated Assemblies - updates already-registered assemblies
                                     with isolation mode None
    2. CRM Solutions               - imports each unmanaged solution .zip,
                                     then publishes
    3. CRM Assemblies              - updates already-registered assemblies
                                     with isolation mode Sandbox
    4. PS Scripts                  - copies scripts to
                                     {PSTargetLocation}\<relative path>

A ticket does not need every folder; missing or empty ones are skipped.
Everything is checked before anything is changed: the solution order,
that the DLLs are signed .NET assemblies, the PS scripts target, and the
CRM connection.

A log of the run is written to {Ticket}\Logs, and PS scripts that get
overwritten are backed up to {Ticket}\Backups first.

Static settings (share root, CRM URLs, PS scripts locations, PROD clusters)
live in Settings.psd1 next to this script.

.PARAMETER Environment
Target environment: DEV, UAT or PROD.

.PARAMETER OrgName
The CRM organization, which is the client name, e.g. Fidelis.

.PARAMETER DeploymentDate
The deployment date folder, e.g. 2026-09-30.

.PARAMETER ChangeControlTicket
The change-control ticket folder, e.g. CC-3322.

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

.PARAMETER SkipPSScripts
Do not copy the ticket's PS scripts.

.PARAMETER ContinueOnError
Keep going after an item fails. By default the run stops at the first failure.

.PARAMETER Force
Skip the confirmation prompt for PROD.

.EXAMPLE
.\Deploy-CrmChange.ps1 -Environment DEV -OrgName Fidelis -DeploymentDate 2026-09-30 -ChangeControlTicket CC-3322 -WhatIf

Dry run: checks the ticket, connects to CRM and lists what would change.

.EXAMPLE
.\Deploy-CrmChange.ps1 -Environment DEV -OrgName Fidelis -DeploymentDate 2026-09-30 -ChangeControlTicket CC-3322
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateSet('DEV', 'UAT', 'PROD')]
    [string]$Environment,

    [Parameter(Mandatory)]
    [ValidatePattern('^[\w\-]+$')]
    [string]$OrgName,

    [Parameter(Mandatory)]
    [ValidatePattern('^\d{4}-\d{2}-\d{2}$')]
    [string]$DeploymentDate,

    [Parameter(Mandatory)]
    [ValidatePattern('^[\w\-]+$')]
    [string]$ChangeControlTicket,

    [ValidatePattern('^[\w\-]+$')]
    [string]$Cluster,

    [System.Management.Automation.PSCredential]$Credential,

    [string]$SettingsPath = (Join-Path $PSScriptRoot 'Settings.psd1'),

    [switch]$SkipNonIsolatedAssemblies,
    [switch]$SkipSolutions,
    [switch]$SkipAssemblies,
    [switch]$SkipPSScripts,
    [switch]$ContinueOnError,
    [switch]$Force
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

foreach ($lib in 'Common', 'Deploy-Solutions', 'Deploy-Assemblies', 'Deploy-PSScripts') {
    . (Join-Path $PSScriptRoot "lib\$lib.ps1")
}


# --- Settings and folders -----------------------------------------------------

if (-not (Test-Path -LiteralPath $SettingsPath -PathType Leaf)) {
    throw "Settings file not found: $SettingsPath"
}
$settings = Import-PowerShellDataFile -LiteralPath $SettingsPath
$target = Resolve-EnvironmentSettings -Settings $settings -Environment $Environment -OrgName $OrgName -Cluster $Cluster
$folders = $settings.FolderNames

$ticketFolder = Join-Path (Join-Path $settings.CRMDeployments $DeploymentDate) $ChangeControlTicket
if (-not (Test-Path -LiteralPath $ticketFolder -PathType Container)) {
    throw "Ticket folder not found: $ticketFolder"
}

$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$runName = "${Environment}_${OrgName}_$stamp"
if ($WhatIfPreference) { $runName += '_WhatIf' }
$logFolder = Join-Path $ticketFolder $folders.Logs
$logFile = Join-Path $logFolder "$runName.log"
$backupRoot = Join-Path (Join-Path (Join-Path $ticketFolder $folders.Backups) $runName) $folders.PSScripts

New-Item -ItemType Directory -Path $logFolder -Force -WhatIf:$false | Out-Null
Start-Transcript -LiteralPath $logFile -WhatIf:$false | Out-Null

$exitCode = 0
try {
    Write-Step 'Deployment'
    Write-Info "Ticket:      $ChangeControlTicket ($DeploymentDate)"
    Write-Info "Source:      $ticketFolder"
    Write-Info "Environment: $Environment$(if ($target.Cluster) { " (cluster $($target.Cluster))" })"
    Write-Info "CRM org:     $($target.OrgUrl)"
    Write-Info "PS scripts:  $($target.PSTargetLocation)"
    Write-Info "Run by:      $([Environment]::UserDomainName)\$([Environment]::UserName) on $([Environment]::MachineName)"
    if ($WhatIfPreference) { Write-Info 'Mode:        WhatIf (nothing will be changed)' }

    # --- Check everything before changing anything ----------------------------

    Write-Step 'Pre-deployment checks'
    $nonIsolatedAssemblies = @()
    if (-not $SkipNonIsolatedAssemblies) {
        $nonIsolatedAssemblies = @(Get-AssemblyPlan -Folder (Join-Path $ticketFolder $folders.NonIsolatedAssemblies))
    }
    $solutions = @()
    if (-not $SkipSolutions) {
        $solutions = @(Get-SolutionPlan -Folder (Join-Path $ticketFolder $folders.Solutions) -SolutionSettings $settings.Solutions)
    }
    $assemblies = @()
    if (-not $SkipAssemblies) {
        $assemblies = @(Get-AssemblyPlan -Folder (Join-Path $ticketFolder $folders.Assemblies))
    }
    $scripts = @()
    if (-not $SkipPSScripts) {
        $scripts = @(Get-PSScriptPlan -Folder (Join-Path $ticketFolder $folders.PSScripts) -TargetRoot $target.PSTargetLocation)
    }
    Write-Info "Found $($nonIsolatedAssemblies.Count) non-isolated assembly(ies), $($solutions.Count) solution(s), $($assemblies.Count) sandbox assembly(ies), $($scripts.Count) PS script(s)."

    $inBoth = @($nonIsolatedAssemblies | Where-Object { $name = $_.Name; @($assemblies | Where-Object { $_.Name -eq $name }).Count -gt 0 } | ForEach-Object { $_.File.Name })
    if ($inBoth.Count -gt 0) {
        throw "These assemblies are in both '$($folders.NonIsolatedAssemblies)' and '$($folders.Assemblies)'; keep each in one folder: $($inBoth -join ', ')"
    }

    if ($nonIsolatedAssemblies.Count + $solutions.Count + $assemblies.Count + $scripts.Count -eq 0) {
        Write-Warn 'Nothing to deploy.'
        return
    }

    if ($scripts.Count -gt 0) {
        if (-not $target.PSTargetLocation -or $target.PSTargetLocation -eq 'TODO') {
            throw "PSTargetLocation for $Environment is not set in Settings.psd1."
        }
        if (-not (Test-Path -LiteralPath $target.PSTargetLocation -PathType Container)) {
            throw "PS scripts target is not reachable: $($target.PSTargetLocation)"
        }
    }

    $conn = $null
    if ($nonIsolatedAssemblies.Count + $solutions.Count + $assemblies.Count -gt 0) {
        $conn = Connect-CrmTarget -Target $target -OrgName $OrgName -Credential $Credential
    }
    Write-Info 'Checks passed.'

    if ($Environment -eq 'PROD' -and -not $WhatIfPreference -and -not $Force) {
        $question = "Deploy $ChangeControlTicket to PROD org $OrgName ($($target.OrgUrl))?"
        if (-not $PSCmdlet.ShouldContinue($question, 'PROD deployment')) {
            Write-Warn 'Cancelled by user.'
            return
        }
    }

    # --- Deploy -------------------------------------------------------------------

    Invoke-AssemblyDeployment -Conn $conn -Assemblies $nonIsolatedAssemblies -IsolationMode None -FolderName $folders.NonIsolatedAssemblies -ContinueOnError:$ContinueOnError
    if (-not (Test-HasFailures) -or $ContinueOnError) {
        Invoke-SolutionDeployment -Conn $conn -Solutions $solutions -SolutionSettings $settings.Solutions -ContinueOnError:$ContinueOnError
    }
    if (-not (Test-HasFailures) -or $ContinueOnError) {
        Invoke-AssemblyDeployment -Conn $conn -Assemblies $assemblies -IsolationMode Sandbox -FolderName $folders.Assemblies -ContinueOnError:$ContinueOnError
    }
    if (-not (Test-HasFailures) -or $ContinueOnError) {
        Invoke-PSScriptDeployment -Scripts $scripts -BackupRoot $backupRoot -ContinueOnError:$ContinueOnError
    }
} catch {
    Write-Host ''
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    $exitCode = 1
} finally {
    $results = @(Get-DeploymentResults)
    if ($results.Count -gt 0) {
        Write-Step 'Summary'
        $results | Format-Table Stage, Status, Item, Detail -AutoSize -Wrap | Out-String -Width 200 | Write-Host
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
