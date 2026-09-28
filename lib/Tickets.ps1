# Finds the ticket folders to deploy under
#   {CRMDeployments}\{DeploymentDate}\{Org}\
# Ticket folders are numbered to set the deployment order:
#   1. CC-3554
#   2. CC-3560
# They are sorted by that number (so 10 comes after 9, no zero-padding
# needed).

function Get-TicketFolders {
    <#
    .SYNOPSIS
    Returns the ticket folders to deploy, in order, as objects with Name
    (folder name), Number, Ticket (the name without the number) and Path.

    .DESCRIPTION
    With -Ticket, returns the one folder whose full name or ticket part
    matches it (so CC-3554 finds "1. CC-3554"). Without it, returns every
    ticket folder, and throws if any is unnumbered or two share a number or
    a ticket, so nothing is skipped or run out of order by accident.
    #>
    param(
        [Parameter(Mandatory)][string]$OrgFolder,
        [string[]]$ExcludeNames = @(),
        [string]$Ticket
    )
    $tickets = @(Get-ChildItem -LiteralPath $OrgFolder -Directory |
        Where-Object { $ExcludeNames -notcontains $_.Name } |
        ForEach-Object {
            $number = $null
            $ticketName = $_.Name
            if ($_.Name -match '^\s*(\d+)\s*\.\s*(.+?)\s*$') {
                $number = [int]$Matches[1]
                $ticketName = $Matches[2]
            }
            [pscustomobject]@{
                Name   = $_.Name
                Number = $number
                Ticket = $ticketName
                Path   = $_.FullName
            }
        })

    if ($Ticket) {
        $found = @($tickets | Where-Object { $_.Name -eq $Ticket -or $_.Ticket -eq $Ticket })
        if ($found.Count -eq 0) {
            throw "No ticket folder '$Ticket' (or 'N. $Ticket') in $OrgFolder"
        }
        if ($found.Count -gt 1) {
            throw "More than one folder matches ticket '$Ticket' in ${OrgFolder}: $(($found | ForEach-Object { $_.Name }) -join ', ')"
        }
        return $found
    }

    if ($tickets.Count -eq 0) {
        throw "No ticket folders in $OrgFolder"
    }
    $problems = @()
    foreach ($unnumbered in @($tickets | Where-Object { $null -eq $_.Number })) {
        $problems += "'$($unnumbered.Name)' has no order number; name it like '1. $($unnumbered.Name)'"
    }
    foreach ($group in @($tickets | Where-Object { $null -ne $_.Number } | Group-Object Number | Where-Object { $_.Count -gt 1 })) {
        $problems += "Order number $($group.Name) is used by: $(($group.Group | ForEach-Object { $_.Name }) -join ', ')"
    }
    foreach ($group in @($tickets | Group-Object Ticket | Where-Object { $_.Count -gt 1 })) {
        $problems += "Ticket $($group.Name) has more than one folder: $(($group.Group | ForEach-Object { $_.Name }) -join ', ')"
    }
    if ($problems) {
        throw "Ticket folder problems in '$OrgFolder':`n  - " + ($problems -join "`n  - ")
    }
    return @($tickets | Sort-Object Number)
}

function Write-DuplicateComponentWarnings {
    <#
    .SYNOPSIS
    Warns about components that more than one ticket deploys. They are
    deployed once per ticket, in ticket order, so the last ticket wins.
    #>
    param([Parameter(Mandatory)][object[]]$Tickets)

    $seen = @{}
    foreach ($ticket in $Tickets) {
        $plan = $ticket.Plan
        $keys = @()
        $keys += @($plan.NonIsolatedAssemblies | ForEach-Object { "Assembly $($_.Name)" })
        $keys += @($plan.Assemblies | ForEach-Object { "Assembly $($_.Name)" })
        $keys += @($plan.Solutions | ForEach-Object { "Solution $($_.Name)" })
        $keys += @($plan.SetupRows | ForEach-Object { if ($_.Name) { "Setup $($_.Name)" } else { "Setup $($_.Id)" } })
        $keys += @($plan.Scripts | ForEach-Object { "PS script $($_.TargetRelativePath)" })
        foreach ($key in @($keys | Select-Object -Unique)) {
            if (-not $seen.ContainsKey($key)) { $seen[$key] = @() }
            $seen[$key] += $ticket.Name
        }
    }
    foreach ($key in @($seen.Keys | Sort-Object)) {
        if ($seen[$key].Count -gt 1) {
            Write-Warn "$key is in more than one ticket ($($seen[$key] -join ', ')); the last one wins."
        }
    }
}
