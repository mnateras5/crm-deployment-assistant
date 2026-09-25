# CRM Deployment Assistant

Deploys one change-control ticket's CRM components to DEV, UAT or PROD with a
single PowerShell command.

```powershell
.\Deploy-CrmChange.ps1 -Environment DEV -OrgName Fidelis -DeploymentDate 2026-09-30 -ChangeControlTicket CC-3322 -WhatIf
.\Deploy-CrmChange.ps1 -Environment DEV -OrgName Fidelis -DeploymentDate 2026-09-30 -ChangeControlTicket CC-3322
```

Always run with `-WhatIf` first: it checks the ticket, connects to CRM and
lists what would change, without changing anything.

## Ticket folder layout

```
{CRMDeployments}\{DeploymentDate}\{ChangeControlTicket}\
    CRM Solutions\     unmanaged solution .zip files (+ optional order.txt)
    CRM Assemblies\    plugin/workflow DLLs to update
    PS Scripts\        scripts, laid out relative to PSTargetLocation
    Logs\              created by the script: one log per run
    Backups\           created by the script: PS scripts it overwrote
```

`{CRMDeployments}` is set in `Settings.psd1`. A ticket only needs the folders
it uses; missing or empty ones are skipped.

## What it does, in order

1. **Checks everything first.** Solution order, DLLs (must be strong-name
   signed .NET assemblies), PS scripts target reachable, CRM connection.
   Nothing is changed if any check fails.
2. **CRM Solutions.** Imports each `.zip` with `Import-CrmSolution`
   (overwrite unmanaged customizations, activate plug-ins), then publishes
   all customizations once. The order comes from `order.txt` (one file name
   per line, `#` for comments) if present, otherwise alphabetical, so a
   `01_`, `02_` prefix also works. With `order.txt`, every zip must be listed.
3. **CRM Assemblies.** Updates assemblies that are **already registered**:
   the DLL replaces the content of the matching `pluginassembly` record, so
   its plugin types and steps stay as they are. The DLL must have the same
   name, public key token and major.minor version as the registered one.
   A new assembly, or a major.minor version change, must be registered once
   with the Plugin Registration Tool (XrmToolbox); later updates can use
   this script.
4. **PS Scripts.** Copies each file to `{PSTargetLocation}\<relative path>`,
   e.g. `PS Scripts\Orgs\Fidelis\Foo.ps1` goes to
   `\\tps-dev-xrmwf3\c$\inetpub\poshweb\scripts-root\Orgs\Fidelis\Foo.ps1`.
   Identical files are skipped; a file about to be overwritten is first
   copied to `{Ticket}\Backups\<run>\PS Scripts\...`.

The run stops at the first failure unless `-ContinueOnError` is passed; if
some solutions were already imported, they are still published. A summary
table is printed at the end and the script exits with code 1 on any failure.

## Parameters

| Parameter | Description |
|---|---|
| `-Environment` | `DEV`, `UAT` or `PROD` |
| `-OrgName` | CRM org = client name, e.g. `Fidelis` |
| `-DeploymentDate` | Date folder, `yyyy-MM-dd` |
| `-ChangeControlTicket` | Ticket folder, e.g. `CC-3322` |
| `-Cluster` | PROD only: `um1`, `um2` or `um3`; overrides `OrgClusters` in settings |
| `-Credential` | CRM credential; default is the current Windows user (AD integrated) |
| `-WhatIf` | Dry run |
| `-SkipSolutions`, `-SkipAssemblies`, `-SkipPSScripts` | Skip a stage |
| `-ContinueOnError` | Keep going after a failed item |
| `-Force` | Skip the PROD confirmation prompt |
| `-SettingsPath` | Alternative settings file |

## Settings (`Settings.psd1`)

Static settings: the share root, sub-folder names, solution import options,
and per environment the CRM server URL and `PSTargetLocation`. PROD is spread
over three clusters (`um1`, `um2`, `um3`), so its URL uses a `{Cluster}` token
and `OrgClusters` maps each client to its cluster.

Before the first PROD run, fill in the two `TODO`s in `Settings.psd1`: the
PROD `PSTargetLocation` and the `OrgClusters` mapping.

## Requirements

- Windows PowerShell 5.1 (`powershell.exe`). The Xrm module does not run on
  PowerShell 7.
- The `Microsoft.Xrm.Data.PowerShell` module:
  `Install-Module Microsoft.Xrm.Data.PowerShell -Scope CurrentUser`
- Read access to the deployment share, write access to the ticket folder
  (for logs and backups) and to `PSTargetLocation`, and a CRM user allowed
  to import solutions and update plugin assemblies.
