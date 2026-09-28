# Copy the ticket's PowerShell scripts to the scripts server.
#
# Each file keeps its path relative to the "PS Scripts" folder, e.g.
#   {Ticket}\PS Scripts\Orgs\Fidelis\Foo.ps1
#   -> {PSTargetLocation}\Orgs\Fidelis\Foo.ps1
# When the package was built for another org (-SourceOrgName differs from
# -TargetOrgName), a folder named after the source org is renamed to the
# target org on the way, e.g. with source Fidelis and target Centene:
#   {Ticket}\PS Scripts\Orgs\Fidelis\Foo.ps1
#   -> {PSTargetLocation}\Orgs\Centene\Foo.ps1
# A target file that is about to be overwritten is first copied to the
# ticket's Backups folder, so a rollback is a file copy back.

function Get-PSScriptPlan {
    <#
    .SYNOPSIS
    Returns each script with its target path. When the source and target
    orgs differ, throws if a script sits under Orgs\<another org>, since it
    can't be redirected to the target org.
    #>
    param(
        [Parameter(Mandatory)][string]$Folder,
        [Parameter(Mandatory)][string]$TargetRoot,
        [Parameter(Mandatory)][string]$SourceOrgName,
        [Parameter(Mandatory)][string]$TargetOrgName
    )
    $files = @(Get-StageFiles -Path $Folder -Recurse)
    $plan = @()
    if ($files.Count -eq 0) { return $plan }
    $sourceRoot = (Resolve-Path -LiteralPath $Folder).ProviderPath
    $crossOrg = $SourceOrgName -ne $TargetOrgName
    $problems = @()
    foreach ($file in $files) {
        $relative = $file.FullName.Substring($sourceRoot.TrimEnd('\', '/').Length).TrimStart('\', '/')
        $segments = @($relative -split '[\\/]')
        $targetRelative = $relative
        if ($crossOrg) {
            # Folders only; the file name itself is never renamed.
            for ($i = 0; $i -lt $segments.Count - 1; $i++) {
                if ($segments[$i] -eq 'Orgs' -and $segments[$i + 1] -ne $SourceOrgName -and $i + 1 -lt $segments.Count - 1) {
                    $problems += "'$relative' is for org '$($segments[$i + 1])', not the source org '$SourceOrgName'"
                }
                if ($segments[$i] -eq $SourceOrgName) { $segments[$i] = $TargetOrgName }
            }
            $targetRelative = $segments -join [System.IO.Path]::DirectorySeparatorChar
        }
        $plan += [pscustomobject]@{
            Source             = $file
            RelativePath       = $relative
            TargetRelativePath = $targetRelative
            Target             = Join-Path $TargetRoot $targetRelative
        }
    }
    if ($problems) {
        throw "PS script problems in '$Folder':`n  - " + ($problems -join "`n  - ")
    }
    if ($crossOrg -and -not @($plan | Where-Object { $_.RelativePath -ne $_.TargetRelativePath })) {
        Write-Warn "No PS script is in a '$SourceOrgName' folder, so none are redirected to '$TargetOrgName'."
    }
    return $plan
}

function Invoke-PSScriptDeployment {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Scripts,
        [Parameter(Mandatory)][string]$BackupRoot,
        [switch]$ContinueOnError
    )
    $stage = 'PS Scripts'
    Write-Step "PS Scripts ($($Scripts.Count))"
    if ($Scripts.Count -eq 0) {
        Write-Info 'Nothing to copy.'
        return
    }

    foreach ($script in $Scripts) {
        $item = $script.TargetRelativePath
        if ($script.RelativePath -ne $script.TargetRelativePath) {
            $item = "$($script.RelativePath) -> $($script.TargetRelativePath)"
        }
        try {
            $targetExists = Test-Path -LiteralPath $script.Target -PathType Leaf
            if ($targetExists) {
                $sourceHash = (Get-FileHash -LiteralPath $script.Source.FullName -Algorithm SHA256).Hash
                $targetHash = (Get-FileHash -LiteralPath $script.Target -Algorithm SHA256).Hash
                if ($sourceHash -eq $targetHash) {
                    Add-DeploymentResult -Stage $stage -Item $item -Status Unchanged -Detail 'Target is identical'
                    continue
                }
            }
            $action = if ($targetExists) { 'Back up and overwrite' } else { 'Copy new file' }

            if (-not $PSCmdlet.ShouldProcess($script.Target, $action)) {
                Add-DeploymentResult -Stage $stage -Item $item -Status WhatIf -Detail "Would $($action.ToLower())"
                continue
            }

            if ($targetExists) {
                $backup = Join-Path $BackupRoot $script.TargetRelativePath
                New-Item -ItemType Directory -Path (Split-Path $backup -Parent) -Force -WhatIf:$false | Out-Null
                Copy-Item -LiteralPath $script.Target -Destination $backup -Force -ErrorAction Stop -WhatIf:$false
            }
            New-Item -ItemType Directory -Path (Split-Path $script.Target -Parent) -Force -WhatIf:$false | Out-Null
            Copy-Item -LiteralPath $script.Source.FullName -Destination $script.Target -Force -ErrorAction Stop -WhatIf:$false

            $detail = if ($targetExists) { 'Overwritten (previous version backed up)' } else { 'New file' }
            Add-DeploymentResult -Stage $stage -Item $item -Status Deployed -Detail $detail
        } catch {
            Add-DeploymentResult -Stage $stage -Item $item -Status Failed -Detail $_.Exception.Message
            if (-not $ContinueOnError) { break }
        }
    }
}
