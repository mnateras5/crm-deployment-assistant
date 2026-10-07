# CRM Deployment Assistant

Deploys change-control tickets' CRM components to DEV, UAT or PROD with a
single PowerShell command: one ticket, or every ticket of a release.

```powershell
# Every ticket of every org in release R1 of 2026-09-30
.\Deploy-CrmChange.ps1 -Environment DEV -DeploymentDate 2026-09-30 -Release R1 -DeployAll -WhatIf
.\Deploy-CrmChange.ps1 -Environment DEV -DeploymentDate 2026-09-30 -Release R1 -DeployAll

# One ticket (to every org that has it)
.\Deploy-CrmChange.ps1 -Environment DEV -DeploymentDate 2026-09-30 -Release R2 -ChangeControlTicket CC-3554

# One ticket to one org only
.\Deploy-CrmChange.ps1 -Environment DEV -DeploymentDate 2026-09-30 -Release R1 -ChangeControlTicket CC-3786 -TargetOrgName BCBSM
```

Always run with `-WhatIf` first: it checks the tickets, connects to CRM and
lists what would change, without changing anything.

## Folder layout

```
{CRMDeployments}\{DeploymentDate}\
    R1\                  first release of the day
        BCBSM\           org folder = CRM organization name, exactly
            1. CC-3786\  ticket folders, numbered in deployment order
            2. CC-3790\
            Archive\     created by the script: copies of what was deployed
                DEV\1. CC-3786\...    per environment, mirroring the ticket
                UAT\1. CC-3786\...
        Fidelis\
            1. CC-3554\
        Logs\            created by runs of several tickets: one log per run
    R2\                  second release of the day
        Fidelis\
            1. CC-3600\
```

The **org folder decides where tickets deploy**: tickets under `Fidelis\`
go to the Fidelis CRM org (in PROD, on Fidelis's cluster from
`OrgClusters`) and their PS scripts to that environment's
`PSTargetLocation`. So the folder name must match the CRM org name exactly.

- `-DeployAll` deploys every org in the release (orgs alphabetically), each
  org's tickets in number order, one ticket at a time. `10.` comes after
  `9.` without zero-padding. Every ticket folder must be numbered, and no
  number or ticket may appear twice in an org; otherwise the run stops
  before changing anything.
- `-ChangeControlTicket CC-3554` finds `1. CC-3554` in whichever org folder
  has it. If several orgs have that ticket, it is deployed to each of them,
  unless `-TargetOrgName` names the one org to deploy it to.

## Archive: re-running after a failure

Every item that deploys successfully (a solution, an assembly, a Setup CSV
once all its rows are done, a PS script) is copied to
`{Org}\Archive\{Environment}\{N. Ticket}\`, at the same path it has in the
ticket folder. The originals stay where they are, so the same release can
still be deployed to the next environment.

The next run in the same environment skips items whose archived copy is
identical ("Already deployed to DEV (archive)"), so after fixing a failure
you just run the same command again and only what is left is deployed. A
file that was changed since it was archived is deployed again. Each
environment has its own archive, so a UAT run is not affected by DEV's.
`-IgnoreArchive` deploys everything regardless.

Inside each ticket folder:

```
{N. Ticket}\
    CRM Non-Isolated Assemblies\  DLLs registered with isolation mode None
    CRM Solutions\                unmanaged solution .zip files (+ optional order.txt)
    CRM Assemblies\               DLLs registered with isolation mode Sandbox
    Setup Data\                   CSV files (ID, Name, Value) for the Setup entity
    PS Scripts\                   scripts, laid out relative to PSTargetLocation
    Logs\                         created by the script: one log per run
    Backups\                      created by the script: PS scripts it overwrote
```

`{CRMDeployments}` is set in `Settings.psd1`. A ticket only needs the folders
it uses; missing or empty ones are skipped.

## What it does, in order

1. **Checks everything first, for every ticket in the run.** Ticket
   folders, solution order, DLLs (must be strong-name signed .NET
   assemblies), Setup CSVs, each org's CRM URL (in PROD, its cluster),
   PS scripts target reachable, a CRM connection to each org. Nothing is
   changed if any check fails. It also warns about components that more
   than one ticket of the same org deploys (the later ticket wins), and
   about PS scripts under another org's `Orgs\` folder.

Then, one ticket at a time, org by org, in number order:

2. **CRM Non-Isolated Assemblies.** Updates assemblies registered with
   isolation mode **None**, the same way as step 4. They go first, before
   the solutions.
3. **CRM Solutions.** Imports each `.zip` with `Import-CrmSolution`
   (overwrite unmanaged customizations, activate plug-ins), then publishes
   all customizations once. The order comes from `order.txt` (one file name
   per line, `#` for comments) if present, otherwise alphabetical, so a
   `01_`, `02_` prefix also works. With `order.txt`, every zip must be listed.
4. **CRM Assemblies.** Updates **Sandbox** assemblies that are **already registered**:
   the DLL replaces the content of the matching `pluginassembly` record, so
   its plugin types and steps stay as they are. The DLL must have the same
   name, public key token and major.minor version as the registered one.
   A new assembly, or a major.minor version change, must be registered once
   with the Plugin Registration Tool (XrmToolbox); later updates can use
   this script. The registered isolation mode must match the folder the DLL
   is in (None or Sandbox); the script never changes it. A DLL can't be in
   both assembly folders.
5. **Setup Data.** For each row of each `.csv` (columns `ID`, `Name`,
   `Value`, e.g. an Advanced Find export of Setup saved as CSV), finds the
   Setup record by `ID`, or by `Name` when no record has that ID (IDs usually
   differ between environments), and updates its value. If both are given
   and point at different records, the row fails. When no record matches,
   it is **created** with the row's Name and Value, and with the row's ID
   when it has one (so the record keeps the same ID in every environment);
   a row with no Name can't be created and fails. A value that differs only in upper/lower case (`true` vs `TRUE`
   after an Excel round trip) counts as unchanged. The Setup entity's
   schema names are under `SetupData` in `Settings.psd1`.
6. **PS Scripts.** Copies each file to `{PSTargetLocation}\<relative path>`,
   e.g. `PS Scripts\Orgs\Fidelis\Foo.ps1` goes to
   `\\tps-dev-xrmwf3\c$\inetpub\wwwroot\poshweb\scripts-root\Orgs\Fidelis\Foo.ps1`.
   Identical files are skipped; a file about to be overwritten is first
   copied to `{Ticket}\Backups\<run>\PS Scripts\...`.

When an item fails, the rest of **that ticket** is not deployed (unless
`-ContinueOnError` is passed); if some of its solutions were already
imported, they are still published. The run then **carries on with the
next ticket**. Keep in mind that a later ticket of the same org that
depends on the failed one will still be deployed. A summary table is
printed at the end, followed by an OK/FAILED line per ticket, and the
script exits with code 1 on any failure. Fix the failure and run the same
command again: the archive makes it deploy only what is left.

A run of one ticket logs to `{Ticket}\Logs`. A run of several tickets logs
to `{Release}\Logs`, and each ticket's part of the summary is also written
to that ticket's `Logs` folder.

## Parameters

| Parameter | Description |
|---|---|
| `-Environment` | `DEV`, `UAT` or `PROD` |
| `-DeploymentDate` | Date folder, `yyyy-MM-dd` |
| `-Release` | Release folder under the date, e.g. `R1`, `R2` |
| `-ChangeControlTicket` | One ticket, e.g. `CC-3554` (finds `1. CC-3554` in any org folder) |
| `-TargetOrgName` | With `-ChangeControlTicket` only: deploy the ticket to this org only |
| `-DeployAll` | Every ticket of every org in the release. Use instead of `-ChangeControlTicket` |
| `-Cluster` | PROD only: `um1`, `um2` or `um3`; overrides `OrgClusters` in settings. Only when the run covers one org |
| `-Credential` | CRM credential; default is the `PSServiceAccount` from `$SecuritySettings` |
| `-PromptCredentials` | Ask for the CRM credentials (Windows credential prompt) instead of using the service account; asked once per run |
| `-WhatIf` | Dry run |
| `-SkipNonIsolatedAssemblies`, `-SkipSolutions`, `-SkipAssemblies`, `-SkipSetupData`, `-SkipPSScripts` | Skip a stage (`-SkipAssemblies` is the Sandbox one) |
| `-ContinueOnError` | Keep going within a ticket after a failed item |
| `-IgnoreArchive` | Deploy everything, including items already deployed to this environment |
| `-Force` | Skip the PROD confirmation prompt |
| `-SettingsPath` | Alternative settings file |

`-SourceOrgName` is no longer supported: the org comes from the org folder.
Passing it stops the run with an error.

## Settings (`Settings.psd1`)

Static settings: the share root, sub-folder names, the CRM connection
timeout (`ConnectionTimeoutInSeconds`, 180 seconds), solution import
options, the Setup entity's schema names, and per environment the CRM server URL and `PSTargetLocation`. PROD is spread
over three clusters (`um1`, `um2`, `um3`), so its URL uses a `{Cluster}` token
and `OrgClusters` maps each client to its cluster.

When a new client is onboarded in PROD, add it to `OrgClusters`; a PROD run
with an org folder that isn't listed there (e.g. a misspelled folder name)
stops before changing anything.

## Requirements

- Windows PowerShell 5.1 (`powershell.exe`). The Xrm module does not run on
  PowerShell 7.
- The `Microsoft.Xrm.Data.PowerShell` module:
  `Install-Module Microsoft.Xrm.Data.PowerShell -Scope CurrentUser`
- Read access to the deployment share, write access to the ticket folder
  (for logs and backups) and to `PSTargetLocation`, and a CRM user allowed
  to import solutions and update plugin assemblies. Updating a non-isolated
  (isolation mode None) assembly also needs that user to be a CRM
  **Deployment Administrator**.
