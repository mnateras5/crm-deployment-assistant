# Update already-registered plugin/workflow assemblies. Used for two stages:
#   - "CRM Non-Isolated Assemblies" (isolation mode None), deployed first
#   - "CRM Assemblies" (isolation mode Sandbox), deployed after the solutions
#
# Only assemblies that are already registered in the org are updated: the
# new DLL's bytes replace the pluginassembly record's content, so all
# existing plugin types and steps stay as they are. A new assembly (or one
# whose major.minor version changed, which CRM treats as a different
# assembly) must be registered with the Plugin Registration Tool first.
# The registered isolation mode must match the folder the DLL is in; this
# script never changes an assembly's isolation mode.

# pluginassembly.isolationmode option values.
$script:IsolationModes = @{ 1 = 'None'; 2 = 'Sandbox'; 3 = 'External' }

function Get-RegisteredIsolationMode {
    <#
    .SYNOPSIS
    Returns the record's isolation mode as None, Sandbox or External, from the
    raw option value when available, else from the formatted label.
    #>
    param([Parameter(Mandatory)]$Record)
    # Get-CrmRecords puts the attribute's key/value pair in isolationmode_Property;
    # its value is an OptionSetValue.
    try {
        $raw = [int]$Record.isolationmode_Property.Value.Value
        if ($script:IsolationModes.ContainsKey($raw)) { return $script:IsolationModes[$raw] }
    } catch {
        # Fall back to the formatted label below.
    }
    return [string]$Record.isolationmode
}

function Get-AssemblyPlan {
    <#
    .SYNOPSIS
    Reads the identity of each DLL in the folder, and throws if any DLL is not
    a .NET assembly or is not strong-name signed (CRM requires it).
    #>
    param([Parameter(Mandatory)][string]$Folder)

    $dlls = @(Get-StageFiles -Path $Folder -Filter '*.dll')
    $plan = @()
    $problems = @()
    foreach ($dll in $dlls) {
        try {
            # Reads the manifest only; does not load the assembly.
            $identity = [System.Reflection.AssemblyName]::GetAssemblyName($dll.FullName)
        } catch {
            $problems += "'$($dll.Name)' is not a .NET assembly: $($_.Exception.Message)"
            continue
        }
        $tokenBytes = $identity.GetPublicKeyToken()
        if (-not $tokenBytes -or $tokenBytes.Length -eq 0) {
            $problems += "'$($dll.Name)' is not strong-name signed, which CRM requires"
            continue
        }
        $culture = $identity.CultureName
        if (-not $culture) { $culture = 'neutral' }
        $plan += [pscustomobject]@{
            File           = $dll
            Name           = $identity.Name
            Version        = $identity.Version
            Culture        = $culture
            PublicKeyToken = (($tokenBytes | ForEach-Object { $_.ToString('x2') }) -join '')
        }
    }
    if ($problems) {
        throw "Assembly problems in '$Folder':`n  - " + ($problems -join "`n  - ")
    }
    return $plan
}

function Find-RegisteredAssembly {
    <#
    .SYNOPSIS
    Returns the pluginassembly record the DLL should replace, or throws with
    the reason it cannot be updated in place.
    #>
    param(
        $Conn,
        [Parameter(Mandatory)]$Assembly,
        [Parameter(Mandatory)][ValidateSet('None', 'Sandbox')][string]$IsolationMode
    )
    $result = Get-CrmRecords -conn $Conn -EntityLogicalName pluginassembly `
        -FilterAttribute name -FilterOperator eq -FilterValue $Assembly.Name `
        -Fields pluginassemblyid, name, version, culture, publickeytoken, isolationmode `
        -ErrorAction Stop
    $records = @($result.CrmRecords)
    if ($records.Count -eq 0) {
        throw "Not registered in this org. Register it once with the Plugin Registration Tool, then re-run."
    }

    $sameMajorMinor = @($records | Where-Object {
        $v = [version]$_.version
        $v.Major -eq $Assembly.Version.Major -and $v.Minor -eq $Assembly.Version.Minor
    })
    if ($sameMajorMinor.Count -eq 0) {
        $registered = ($records | ForEach-Object { $_.version }) -join ', '
        throw "Registered version(s) $registered do not share major.minor with $($Assembly.Version); CRM treats that as a new assembly, so register it with the Plugin Registration Tool."
    }
    if ($sameMajorMinor.Count -gt 1) {
        throw "More than one registered assembly matches $($Assembly.Name) $($Assembly.Version.Major).$($Assembly.Version.Minor).*; resolve it manually."
    }

    $record = $sameMajorMinor[0]
    if ($record.publickeytoken -and $record.publickeytoken -ne $Assembly.PublicKeyToken) {
        throw "Public key token $($Assembly.PublicKeyToken) does not match the registered $($record.publickeytoken); the DLL was signed with a different key."
    }
    if ($record.culture -and $record.culture -ne $Assembly.Culture) {
        throw "Culture '$($Assembly.Culture)' does not match the registered '$($record.culture)'."
    }
    $registeredMode = Get-RegisteredIsolationMode -Record $record
    if ($registeredMode -ne $IsolationMode) {
        throw "Registered with isolation mode '$registeredMode', but this folder is for '$IsolationMode'. Move the DLL to the right folder, or change the registration with the Plugin Registration Tool."
    }
    return $record
}

function Invoke-AssemblyDeployment {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        $Conn,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Assemblies,
        [Parameter(Mandatory)][ValidateSet('None', 'Sandbox')][string]$IsolationMode,
        [Parameter(Mandatory)][string]$FolderName,
        [switch]$ContinueOnError
    )
    $stage = if ($IsolationMode -eq 'None') { 'Non-Isolated Assemblies' } else { 'Sandbox Assemblies' }
    Write-Step "$FolderName ($($Assemblies.Count))"
    if ($Assemblies.Count -eq 0) {
        Write-Info 'Nothing to update.'
        return
    }

    foreach ($assembly in $Assemblies) {
        $item = $assembly.File.Name
        try {
            # Runs under -WhatIf too: the lookup is read-only and shows up front
            # whether each DLL can be updated.
            $record = Find-RegisteredAssembly -Conn $Conn -Assembly $assembly -IsolationMode $IsolationMode
            $change = "$($record.version) -> $($assembly.Version) ($IsolationMode)"

            if (-not $PSCmdlet.ShouldProcess("$item $change", 'Update plugin assembly')) {
                Add-DeploymentResult -Stage $stage -Item $item -Status WhatIf -Detail "Would update $change"
                continue
            }

            $content = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($assembly.File.FullName))
            Set-CrmRecord -conn $Conn -EntityLogicalName pluginassembly -Id $record.pluginassemblyid -Fields @{
                content = $content
                version = $assembly.Version.ToString()
            } -ErrorAction Stop
            Add-DeploymentResult -Stage $stage -Item $item -Status Deployed -Detail "Updated $change"
        } catch {
            Add-DeploymentResult -Stage $stage -Item $item -Status Failed -Detail $_.Exception.Message
            if (-not $ContinueOnError) { break }
        }
    }
}
