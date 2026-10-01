# Create or update Setup entity records from the ticket's "Setup Data" CSV
# files.
#
# Each CSV has the columns ID, Name, Value (an Advanced Find export of the
# Setup entity, saved as CSV). A row is matched to its record by ID first
# and, when no record has that ID (IDs usually differ between environments),
# by Name, and the record's Value is updated. When neither matches, the
# record is created with the row's Name and Value, and with the row's ID
# when it has one, so the record keeps the same ID in every environment.
# The Setup entity's schema names are in Settings.psd1 (SetupData).

function Get-SetupDataPlan {
    <#
    .SYNOPSIS
    Reads every .csv in the folder and returns one entry per row, or throws
    if a file lacks the ID/Name/Value columns, a row has no key, an ID is
    not a GUID, a name or value is too long, or the same key appears twice.
    #>
    param(
        [Parameter(Mandatory)][string]$Folder,
        [Parameter(Mandatory)][hashtable]$SetupSettings
    )

    $files = @(Get-StageFiles -Path $Folder -Filter '*.csv')
    $plan = @()
    $problems = @()
    $seenIds = @{}
    $seenNames = @{}
    foreach ($file in $files) {
        $rows = @(Import-Csv -LiteralPath $file.FullName)
        if ($rows.Count -eq 0) { continue }
        $columns = @($rows[0].PSObject.Properties | ForEach-Object { $_.Name })
        $missing = @('ID', 'Name', 'Value' | Where-Object { $columns -notcontains $_ })
        if ($missing.Count -gt 0) {
            $problems += "'$($file.Name)' is missing column(s): $($missing -join ', ')"
            continue
        }

        $line = 1
        foreach ($row in $rows) {
            $line++
            $where = "'$($file.Name)' line $line"
            $idText = "$($row.ID)".Trim()
            $name = "$($row.Name)".Trim()
            $value = "$($row.Value)"
            if (-not $idText -and -not $name) {
                # Blank lines at the end of an export.
                if (-not $value.Trim()) { continue }
                $problems += "${where}: has a Value but no ID or Name"
                continue
            }
            $id = [guid]::Empty
            if ($idText -and -not [guid]::TryParse($idText, [ref]$id)) {
                $problems += "${where}: ID '$idText' is not a GUID"
                continue
            }
            if ($name.Length -gt $SetupSettings.NameMaxLength) {
                $problems += "${where}: Name is $($name.Length) characters; $($SetupSettings.NameAttribute) holds at most $($SetupSettings.NameMaxLength)"
            }
            if ($value.Length -gt $SetupSettings.ValueMaxLength) {
                $problems += "${where}: Value is $($value.Length) characters; $($SetupSettings.ValueAttribute) holds at most $($SetupSettings.ValueMaxLength)"
            }
            if ($idText) {
                if ($seenIds.ContainsKey($id)) { $problems += "${where}: ID $id is also on $($seenIds[$id])" }
                $seenIds[$id] = $where
            }
            if ($name) {
                if ($seenNames.ContainsKey($name)) { $problems += "${where}: Name '$name' is also on $($seenNames[$name])" }
                $seenNames[$name] = $where
            }
            $plan += [pscustomobject]@{
                File   = $file.FullName
                Source = $where
                Id     = if ($idText) { $id } else { $null }
                Name   = $name
                Value  = $value
            }
        }
    }
    if ($problems) {
        throw "Setup data problems in '$Folder':`n  - " + ($problems -join "`n  - ")
    }
    return $plan
}

function Get-RecordAttribute {
    # Get-CrmRecords leaves out attributes that are empty, so read them
    # without tripping StrictMode.
    param([Parameter(Mandatory)]$Record, [Parameter(Mandatory)][string]$Attribute)
    $property = $Record.PSObject.Properties[$Attribute]
    if ($property) { return $property.Value }
    return $null
}

function Find-SetupRecord {
    <#
    .SYNOPSIS
    Returns the Setup record a row refers to, $null when there is none, or
    throws when there is more than one or the ID and Name point at
    different records.
    #>
    param(
        [Parameter(Mandatory)]$Conn,
        [Parameter(Mandatory)]$Row,
        [Parameter(Mandatory)][hashtable]$SetupSettings
    )
    $entity = $SetupSettings.EntityLogicalName
    $fields = @($SetupSettings.IdAttribute, $SetupSettings.NameAttribute, $SetupSettings.ValueAttribute)

    if ($Row.Id) {
        $byId = @((Get-CrmRecords -conn $Conn -EntityLogicalName $entity `
            -FilterAttribute $SetupSettings.IdAttribute -FilterOperator eq -FilterValue $Row.Id `
            -Fields $fields -ErrorAction Stop).CrmRecords)
        if ($byId.Count -eq 1) {
            $record = $byId[0]
            $recordName = Get-RecordAttribute -Record $record -Attribute $SetupSettings.NameAttribute
            if ($Row.Name -and $recordName -ne $Row.Name) {
                throw "ID $($Row.Id) is the record named '$recordName', not '$($Row.Name)'."
            }
            return $record
        }
        if (-not $Row.Name) { return $null }
    }

    $byName = @((Get-CrmRecords -conn $Conn -EntityLogicalName $entity `
        -FilterAttribute $SetupSettings.NameAttribute -FilterOperator eq -FilterValue $Row.Name `
        -Fields $fields -ErrorAction Stop).CrmRecords)
    if ($byName.Count -eq 0) { return $null }
    if ($byName.Count -gt 1) {
        throw "$($byName.Count) $entity records are named '$($Row.Name)'; add the ID to pick one."
    }
    return $byName[0]
}

function Invoke-SetupDataDeployment {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        $Conn,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rows,
        [Parameter(Mandatory)][hashtable]$SetupSettings,
        [Parameter(Mandatory)][string]$FolderName,
        [switch]$ContinueOnError
    )
    $stage = 'Setup Data'
    Write-Step "$FolderName ($($Rows.Count))"
    if ($Rows.Count -eq 0) {
        Write-Info 'Nothing to update.'
        return
    }

    # A CSV is archived once every one of its rows is done.
    $pendingRows = @{}
    foreach ($row in $Rows) { $pendingRows[$row.File] = 1 + [int]$pendingRows[$row.File] }

    foreach ($row in $Rows) {
        $item = if ($row.Name) { $row.Name } else { "$($row.Id)" }
        try {
            # Runs under -WhatIf too: the lookup is read-only.
            $record = Find-SetupRecord -Conn $Conn -Row $row -SetupSettings $SetupSettings
            if (-not $record) {
                if (-not $row.Name) {
                    throw "No $($SetupSettings.EntityLogicalName) record has ID $($row.Id), and the row has no Name to create it with."
                }
                $newRecord = "'$($row.Name)' = '$($row.Value)'"
                if (-not $PSCmdlet.ShouldProcess($newRecord, 'Create Setup record')) {
                    Add-DeploymentResult -Stage $stage -Item $item -Status WhatIf -Detail "Would create with '$($row.Value)'"
                    continue
                }
                $fields = @{
                    $SetupSettings.NameAttribute  = $row.Name
                    $SetupSettings.ValueAttribute = $row.Value
                }
                if ($row.Id) { $fields[$SetupSettings.IdAttribute] = $row.Id }
                New-CrmRecord -conn $Conn -EntityLogicalName $SetupSettings.EntityLogicalName -Fields $fields -ErrorAction Stop | Out-Null
                Add-DeploymentResult -Stage $stage -Item $item -Status Deployed -Detail "Created with '$($row.Value)'"
                $pendingRows[$row.File]--
                continue
            }
            $current = "$(Get-RecordAttribute -Record $record -Attribute $SetupSettings.ValueAttribute)"
            # Case-insensitive so an Excel round trip (true -> TRUE) is not a change.
            if ([string]::Equals($current, $row.Value, [StringComparison]::OrdinalIgnoreCase)) {
                Add-DeploymentResult -Stage $stage -Item $item -Status Unchanged -Detail "Already '$current'"
                $pendingRows[$row.File]--
                continue
            }
            $change = "'$current' -> '$($row.Value)'"

            if (-not $PSCmdlet.ShouldProcess("$item $change", 'Update Setup value')) {
                Add-DeploymentResult -Stage $stage -Item $item -Status WhatIf -Detail "Would change $change"
                continue
            }
            $recordId = Get-RecordAttribute -Record $record -Attribute $SetupSettings.IdAttribute
            Set-CrmRecord -conn $Conn -EntityLogicalName $SetupSettings.EntityLogicalName -Id $recordId -Fields @{
                $SetupSettings.ValueAttribute = $row.Value
            } -ErrorAction Stop
            Add-DeploymentResult -Stage $stage -Item $item -Status Deployed -Detail "Changed $change"
            $pendingRows[$row.File]--
        } catch {
            Add-DeploymentResult -Stage $stage -Item $item -Status Failed -Detail "$($row.Source): $($_.Exception.Message)"
            if (-not $ContinueOnError) { break }
        }
    }

    foreach ($file in @($pendingRows.Keys)) {
        if ($pendingRows[$file] -eq 0) { Add-ToArchive -Path $file }
    }
}
