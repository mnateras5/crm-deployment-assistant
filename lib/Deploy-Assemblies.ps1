# Stage 2: update already-registered plugin/workflow assemblies.
#
# Only assemblies that are already registered in the org are updated: the
# new DLL's bytes replace the pluginassembly record's content, so all
# existing plugin types and steps stay as they are. A new assembly (or one
# whose major.minor version changed, which CRM treats as a different
# assembly) must be registered with the Plugin Registration Tool first.

function Get-AssemblyPlan {
    <#
    .SYNOPSIS
    Reads the identity of each DLL in the folder, and throws if any DLL is not
    a .NET assembly or is not strong-name signed (required for Sandbox).
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
            $problems += "'$($dll.Name)' is not strong-name signed (required for Sandbox isolation)"
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
        [Parameter(Mandatory)]$Assembly
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
    return $record
}

function Invoke-AssemblyDeployment {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        $Conn,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Assemblies,
        [switch]$ContinueOnError
    )
    $stage = 'Assemblies'
    Write-Step "CRM Assemblies ($($Assemblies.Count))"
    if ($Assemblies.Count -eq 0) {
        Write-Info 'Nothing to update.'
        return
    }

    foreach ($assembly in $Assemblies) {
        $item = $assembly.File.Name
        try {
            # Runs under -WhatIf too: the lookup is read-only and shows up front
            # whether each DLL can be updated.
            $record = Find-RegisteredAssembly -Conn $Conn -Assembly $assembly
            $change = "$($record.version) -> $($assembly.Version) ($($record.isolationmode))"
            if ($record.isolationmode -and $record.isolationmode -ne 'Sandbox') {
                Write-Warn "$item is registered with isolation mode '$($record.isolationmode)', not Sandbox."
            }

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
