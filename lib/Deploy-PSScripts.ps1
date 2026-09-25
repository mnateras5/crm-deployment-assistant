# Stage 3: copy the ticket's PowerShell scripts to the scripts server.
#
# Each file keeps its path relative to the "PS Scripts" folder, e.g.
#   {Ticket}\PS Scripts\Orgs\Fidelis\Foo.ps1
#   -> {PSTargetLocation}\Orgs\Fidelis\Foo.ps1
# A target file that is about to be overwritten is first copied to the
# ticket's Backups folder, so a rollback is a file copy back.

function Get-PSScriptPlan {
    param(
        [Parameter(Mandatory)][string]$Folder,
        [Parameter(Mandatory)][string]$TargetRoot
    )
    $files = @(Get-StageFiles -Path $Folder -Recurse)
    $plan = @()
    if ($files.Count -eq 0) { return $plan }
    $sourceRoot = (Resolve-Path -LiteralPath $Folder).ProviderPath
    foreach ($file in $files) {
        $relative = $file.FullName.Substring($sourceRoot.TrimEnd('\', '/').Length).TrimStart('\', '/')
        $plan += [pscustomobject]@{
            Source       = $file
            RelativePath = $relative
            Target       = Join-Path $TargetRoot $relative
        }
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
        $item = $script.RelativePath
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
                $backup = Join-Path $BackupRoot $item
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
