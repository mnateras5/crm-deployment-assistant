#
# Static settings for Deploy-CrmChange.ps1.
#
# This is a PowerShell *data* file: it is read with Import-PowerShellDataFile,
# so it can only hold literals (strings, numbers, $true/$false, hashtables,
# arrays) and never runs code. Do not put credentials in here.
#
@{
    # Root of the deployment share. The script expects:
    #   {CRMDeployments}\{DeploymentDate}\{ChangeControlTicket}\CRM Solutions
    #   {CRMDeployments}\{DeploymentDate}\{ChangeControlTicket}\CRM Assemblies
    #   {CRMDeployments}\{DeploymentDate}\{ChangeControlTicket}\PS Scripts
    CRMDeployments = '\\turningpoint-healthcare.com\it\Application Development\CRM Deployments'

    # Sub-folder names inside a ticket folder. Logs and Backups are created by
    # the script, so each ticket folder keeps its own audit trail.
    FolderNames = @{
        Solutions  = 'CRM Solutions'
        Assemblies = 'CRM Assemblies'
        PSScripts  = 'PS Scripts'
        Logs       = 'Logs'
        Backups    = 'Backups'
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
            # TODO: set the PROD PowerShell scripts location. If it differs per
            # cluster, use the {Cluster} token, e.g. '\\tps-{Cluster}-xrmwf\c$\...'.
            PSTargetLocation = 'TODO'
            # Which PROD cluster (um1, um2 or um3) hosts each client's org.
            # TODO: fill in the real client-to-cluster mapping.
            OrgClusters = @{
                # Fidelis = 'um1'
            }
        }
    }
}
