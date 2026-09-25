#
# Static settings for Deploy-CrmChange.ps1.
#
# This is a PowerShell *data* file: it is read with Import-PowerShellDataFile,
# so it can only hold literals (strings, numbers, $true/$false, hashtables,
# arrays) and never runs code. Do not put credentials in here.
#
@{
    # Root of the deployment share. The script expects:
    #   {CRMDeployments}\{DeploymentDate}\{ChangeControlTicket}\CRM Non-Isolated Assemblies
    #   {CRMDeployments}\{DeploymentDate}\{ChangeControlTicket}\CRM Solutions
    #   {CRMDeployments}\{DeploymentDate}\{ChangeControlTicket}\CRM Assemblies
    #   {CRMDeployments}\{DeploymentDate}\{ChangeControlTicket}\Setup Data
    #   {CRMDeployments}\{DeploymentDate}\{ChangeControlTicket}\PS Scripts
    CRMDeployments = '\\turningpoint-healthcare.com\it\Application Development\CRM Deployments'

    # Sub-folder names inside a ticket folder. Logs and Backups are created by
    # the script, so each ticket folder keeps its own audit trail.
    FolderNames = @{
        NonIsolatedAssemblies = 'CRM Non-Isolated Assemblies'
        Solutions             = 'CRM Solutions'
        Assemblies            = 'CRM Assemblies'
        SetupData             = 'Setup Data'
        PSScripts             = 'PS Scripts'
        Logs                  = 'Logs'
        Backups               = 'Backups'
    }

    Solutions = @{
        # Optional file inside "CRM Solutions" listing the .zip files (one per
        # line) in the order they must be imported. Without it, the zips are
        # imported in alphabetical order, so a 01_, 02_ prefix also works.
        OrderFileName                    = 'order.txt'
        OverwriteUnmanagedCustomizations = $true
        ActivatePlugIns                  = $true
        # How long to wait for one solution import to finish.
        MaxWaitTimeInSeconds             = 1800
        # Publish all customizations once, after the last solution is imported.
        PublishAfterImport               = $true
    }

    # The Setup entity updated from the "Setup Data" CSV files (columns ID,
    # Name, Value). A row is matched on IdAttribute, else on NameAttribute,
    # and only ValueAttribute is updated.
    SetupData = @{
        EntityLogicalName = 'mm360_setup'
        IdAttribute       = 'mm360_setupid'
        NameAttribute     = 'mm360_name'
        ValueAttribute    = 'mm360_value'
    }

    # One entry per target environment (the -Environment parameter).
    #
    # CrmServerUrl is the server part of the CRM URL; the org name (the client,
    # the -OrgName parameter) is appended to it, e.g.
    #   http://tpsdevdynfe101.turningpoint-healthcare.com/Fidelis
    #
    # A "{Cluster}" token in CrmServerUrl or PSTargetLocation is replaced with
    # the org's cluster from OrgClusters (or the -Cluster parameter).
    Environments = @{
        DEV = @{
            CrmServerUrl     = 'http://tpsdevdynfe101.turningpoint-healthcare.com'
            PSTargetLocation = '\\tps-dev-xrmwf3\c$\inetpub\poshweb\scripts-root'
        }
        UAT = @{
            CrmServerUrl     = 'http://um1-uat.turningpoint-healthcare.com'
            PSTargetLocation = '\\tps-uat-xrmwf2\c$\inetpub\poshweb\scripts-root'
        }
        PROD = @{
            CrmServerUrl     = 'http://{Cluster}.turningpoint-healthcare.com'
            # One scripts server for all PROD clusters.
            PSTargetLocation = '\\tps-prd-xrmwf1\c$\inetpub\poshweb\scripts-root'
            # Which PROD cluster (um1, um2 or um3) hosts each client's org.
            # Org names are matched case-insensitively.
            OrgClusters = @{
                BCBSKC     = 'um1'
                BCBSM      = 'um3'
                BCBSTN     = 'um3'
                CapitalPA  = 'um2'
                CareSource = 'um1'
                Centene    = 'um2'
                Fidelis    = 'um2'
                HAP        = 'um1'
                HorizonNJ  = 'um2'
                Priority   = 'um1'
                WellCare   = 'um2'
            }
        }
    }
}
