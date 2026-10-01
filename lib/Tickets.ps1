# Finds the ticket folders to deploy under a release:
#   {CRMDeployments}\{DeploymentDate}\{Release}\{Org}\{N. Ticket}
# e.g. ...\2026-09-30\R1\BCBSM\1. CC-3786
# The org folder name is the CRM organization the tickets deploy to, so it
# must match the org name exactly. Ticket folders are numbered to set the
# deployment order within their org, and sorted by that number (so 10 comes
# after 9, no zero-padding needed).

function Get-TicketFolderEntries {
    # The subfolders of an org folder, with the order number split off.
    param(
        [Parameter(Mandatory)][string]$OrgFolder,
        [Parameter(Mandatory)][string]$OrgName
    )
    return @(Get-ChildItem -LiteralPath $OrgFolder -Directory | ForEach-Object {
        $number = $null
        $ticketName = $_.Name
        if ($_.Name -match '^\s*(\d+)\s*\.\s*(.+?)\s*$') {
            $number = [int]$Matches[1]
            $ticketName = $Matches[2]
        }
        [pscustomobject]@{
            Org    = $OrgName
            Name   = $_.Name
            Label  = "$OrgName\$($_.Name)"
            Number = $number
            Ticket = $ticketName
            Path   = $_.FullName
        }
    })
}

function Get-ReleaseTickets {
    <#
    .SYNOPSIS
    Returns the ticket folders to deploy, grouped by org (orgs in
    alphabetical order) and in number order within each org.

    .DESCRIPTION
    With -Ticket, returns the folder whose full name or ticket part matches
    it (so CC-3554 finds "Fidelis\1. CC-3554"), in every org that has one:
    a ticket for several clients is deployed to each of them. -OrgName
    limits that to one org folder (matched case-insensitively). Without
    it, returns every ticket folder of every org, and throws if any is
    unnumbered or two in the same org share a number or a ticket, so
    nothing is skipped or run out of order by accident.
    #>
    param(
        [Parameter(Mandatory)][string]$ReleaseFolder,
        [string[]]$ExcludeNames = @(),
        [string]$Ticket,
        [string]$OrgName
    )
    $orgFolders = @(Get-ChildItem -LiteralPath $ReleaseFolder -Directory |
        Where-Object { $ExcludeNames -notcontains $_.Name } |
        Sort-Object Name)
    if ($orgFolders.Count -eq 0) {
        throw "No org folders in $ReleaseFolder"
    }
    if ($OrgName) {
        $orgFolders = @($orgFolders | Where-Object { $_.Name -eq $OrgName })
        if ($orgFolders.Count -eq 0) {
            throw "No org folder '$OrgName' in $ReleaseFolder"
        }
    }

    if ($Ticket) {
        $found = @(foreach ($orgFolder in $orgFolders) {
            Get-TicketFolderEntries -OrgFolder $orgFolder.FullName -OrgName $orgFolder.Name |
                Where-Object { $ExcludeNames -notcontains $_.Name -and ($_.Name -eq $Ticket -or $_.Ticket -eq $Ticket) }
        })
        if ($found.Count -eq 0) {
            $where = if ($OrgName) { "$ReleaseFolder\$($orgFolders[0].Name)" } else { "any org folder under $ReleaseFolder" }
            throw "No ticket folder '$Ticket' (or 'N. $Ticket') in $where"
        }
        foreach ($group in @($found | Group-Object Org | Where-Object { $_.Count -gt 1 })) {
            throw "More than one folder in $($group.Name) matches ticket '$Ticket': $(($group.Group | ForEach-Object { $_.Name }) -join ', ')"
        }
        return $found
    }

    $tickets = @()
    $problems = @()
    foreach ($orgFolder in $orgFolders) {
        $entries = @(Get-TicketFolderEntries -OrgFolder $orgFolder.FullName -OrgName $orgFolder.Name |
            Where-Object { $ExcludeNames -notcontains $_.Name })
        foreach ($unnumbered in @($entries | Where-Object { $null -eq $_.Number })) {
            $problems += "'$($unnumbered.Label)' has no order number; name it like '1. $($unnumbered.Name)'"
        }
        foreach ($group in @($entries | Where-Object { $null -ne $_.Number } | Group-Object Number | Where-Object { $_.Count -gt 1 })) {
            $problems += "$($orgFolder.Name): order number $($group.Name) is used by: $(($group.Group | ForEach-Object { $_.Name }) -join ', ')"
        }
        foreach ($group in @($entries | Group-Object Ticket | Where-Object { $_.Count -gt 1 })) {
            $problems += "$($orgFolder.Name): ticket $($group.Name) has more than one folder: $(($group.Group | ForEach-Object { $_.Name }) -join ', ')"
        }
        $tickets += @($entries | Sort-Object Number)
    }
    if ($problems) {
        throw "Ticket folder problems in '$ReleaseFolder':`n  - " + ($problems -join "`n  - ")
    }
    if ($tickets.Count -eq 0) {
        throw "No ticket folders in any org folder under $ReleaseFolder"
    }
    return $tickets
}

function Write-DuplicateComponentWarnings {
    <#
    .SYNOPSIS
    Warns about components that more than one ticket of the same org
    deploys. They are deployed once per ticket, in ticket order, so the last
    ticket wins. (The same component in different orgs is normal.)
    #>
    param([Parameter(Mandatory)][object[]]$Tickets)

    foreach ($orgGroup in @($Tickets | Group-Object Org)) {
        $seen = @{}
        foreach ($ticket in $orgGroup.Group) {
            $plan = $ticket.Plan
            $keys = @()
            $keys += @($plan.NonIsolatedAssemblies | ForEach-Object { "Assembly $($_.Name)" })
            $keys += @($plan.Assemblies | ForEach-Object { "Assembly $($_.Name)" })
            $keys += @($plan.Solutions | ForEach-Object { "Solution $($_.Name)" })
            $keys += @($plan.SetupRows | ForEach-Object { if ($_.Name) { "Setup $($_.Name)" } else { "Setup $($_.Id)" } })
            $keys += @($plan.Scripts | ForEach-Object { "PS script $($_.RelativePath)" })
            foreach ($key in @($keys | Select-Object -Unique)) {
                if (-not $seen.ContainsKey($key)) { $seen[$key] = @() }
                $seen[$key] += $ticket.Name
            }
        }
        foreach ($key in @($seen.Keys | Sort-Object)) {
            if ($seen[$key].Count -gt 1) {
                Write-Warn "$($orgGroup.Name): $key is in more than one ticket ($($seen[$key] -join ', ')); the last one wins."
            }
        }
    }
}
