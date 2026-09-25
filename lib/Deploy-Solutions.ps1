# Stage 1: import the unmanaged CRM solution .zip files of a ticket.

function Get-SolutionPlan {
    <#
    .SYNOPSIS
    Returns the solution .zip files in import order, or throws when the order
    file is inconsistent with the folder.

    .DESCRIPTION
    If the order file (Settings.Solutions.OrderFileName) exists, it decides the
    order: one file name per line, blank lines and lines starting with # are
    ignored. Every zip in the folder must be listed and every listed file must
    exist, so a solution is never silently skipped or imported out of order.
    Without the order file, zips are imported alphabetically.
    #>
    param(
        [Parameter(Mandatory)][string]$Folder,
        [Parameter(Mandatory)][hashtable]$SolutionSettings
    )
    $zips = @(Get-StageFiles -Path $Folder -Filter '*.zip')
    if ($zips.Count -eq 0) { return @() }

    $orderFile = Join-Path $Folder $SolutionSettings.OrderFileName
    if (-not (Test-Path -LiteralPath $orderFile -PathType Leaf)) {
        return $zips
    }

    $listed = @(Get-Content -LiteralPath $orderFile |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and -not $_.StartsWith('#') })

    $byName = @{}
    foreach ($zip in $zips) { $byName[$zip.Name.ToLowerInvariant()] = $zip }

    $problems = @()
    $ordered = @()
    foreach ($name in $listed) {
        $key = $name.ToLowerInvariant()
        if (-not $byName.ContainsKey($key)) {
            $problems += "'$name' is listed in $($SolutionSettings.OrderFileName) but is not in the folder"
        } else {
            $ordered += $byName[$key]
            $byName.Remove($key)
        }
    }
    foreach ($unlisted in $byName.Values) {
        $problems += "'$($unlisted.Name)' is in the folder but not listed in $($SolutionSettings.OrderFileName)"
    }
    if ($problems) {
        throw "Solution order problems in '$Folder':`n  - " + ($problems -join "`n  - ")
    }
    return $ordered
}

function Invoke-SolutionDeployment {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        $Conn,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.IO.FileInfo[]]$Solutions,
        [Parameter(Mandatory)][hashtable]$SolutionSettings,
        [switch]$ContinueOnError
    )
    $stage = 'Solutions'
    Write-Step "CRM Solutions ($($Solutions.Count))"
    if ($Solutions.Count -eq 0) {
        Write-Info 'Nothing to import.'
        return
    }

    $imported = 0
    foreach ($zip in $Solutions) {
        if (-not $PSCmdlet.ShouldProcess($zip.Name, 'Import CRM solution')) {
            Add-DeploymentResult -Stage $stage -Item $zip.Name -Status WhatIf -Detail 'Would import'
            continue
        }
        $started = Get-Date
        try {
            Write-Info "Importing $($zip.Name) ..."
            Import-CrmSolution -conn $Conn `
                -SolutionFilePath $zip.FullName `
                -OverwriteUnManagedCustomizations:([bool]$SolutionSettings.OverwriteUnmanagedCustomizations) `
                -ActivatePlugIns:([bool]$SolutionSettings.ActivatePlugIns) `
                -MaxWaitTimeInSeconds $SolutionSettings.MaxWaitTimeInSeconds `
                -ErrorAction Stop | Out-Null
            $imported++
            $elapsed = [int]((Get-Date) - $started).TotalSeconds
            Add-DeploymentResult -Stage $stage -Item $zip.Name -Status Deployed -Detail "Imported in ${elapsed}s"
        } catch {
            Add-DeploymentResult -Stage $stage -Item $zip.Name -Status Failed -Detail $_.Exception.Message
            if (-not $ContinueOnError) { break }
        }
    }

    # Publish whatever was imported, even if a later solution failed, so the
    # org is not left with unpublished customizations.
    if ($imported -gt 0 -and $SolutionSettings.PublishAfterImport) {
        try {
            Write-Info 'Publishing all customizations ...'
            Publish-CrmAllCustomization -conn $Conn -ErrorAction Stop | Out-Null
            Add-DeploymentResult -Stage $stage -Item 'Publish all customizations' -Status Deployed
        } catch {
            Add-DeploymentResult -Stage $stage -Item 'Publish all customizations' -Status Failed -Detail $_.Exception.Message
        }
    }
}
