<# 
 
.SYNOPSIS 
 
This script is used to add a native (based on the custom ZOL installation framework) or virtual (App-v) application package to SCCM and deploy it.
The script must be executed on a machine with the SCCM console installed, or in a virtual environment where the SCCM console is also installed.
 
 
 
.DESCRIPTION 
 
The script can be started as followed:

Add-cCMApp -Application -CollectionStructure -Deploy -ADGroup <Name of AD Group> -Name <Application Name> -ApplicationVersion <Application Version> (-Native or -Virtual) -Path <Path to application rootfolder or appv-file) (-DistributionPointName <DPName> or -DistributionGroupName <DPGroupName>)

The script contains several automations that are compliant with the ZOL Application Management Process. Depending on the parameters passed to the script, it performs one or more of the several actions:

Application
-----------

When the -application switch is provided, a SCCM application is created together with a Deployment Type that is either a script installer type or an App-V 5 type. The native SCCM cmdlets are used to create these objects.

If a native application is created, the detection method of the SCCM application is populated with a dummy PowerShell detection method. This needs to be modified manually after the script has run.

The name of the application is created in the format <ApplicationName><ApplicationVersion>.<PackageVersion>, conform the ZOL process. The deployment type is either named 'virtual' or 'native' depending on the application type.

For a native deployment type, the install and uninstall commands are respectively set to 'framework.ps1 -action install' and 'framework.ps1 -action uninstall', which are the commands needed to instruct the ZOL Application Framework to perform operations.

CollectionStructure
-------------------

when the -CollectionStructure is provided, a set of SCCM collections is created:

[SD] <Application Name> (Device) - Install -> Collection to deploy the application to devices

[SD] <Application Name> (User) - Install -> Collection to deploy the application to users

[SD] <Application Name> (Device) - UnInstall  -> Collection to remove the application from devices

[SD] <Application Name> (User) - UnInstall -> Collection to remove the application from users

All install collections are configured to synchronize the memberships from AD groups. By default this are the GG-S-C-<ApplicationName> (for device-based deployments) and GG-S-U-<ApplicationName> (for user-based deployments).
Using the -ADGroup parameter, one can specify another value for the <ApplicationName> part of the AD group.

All uninstall collections are set to contain all devices/users that have the targetted application installed, except for the objects specified in the install collections.
If the install/uninstall deployments are setup, this causes devices/users that are not a member of the AD groups (and thus install collections) to receive the uninstall deployment.
This will effectively cause the application to be removed.

The following folder-structures are created as well:

Site\
     SW Distribution\
                     SW Install\
                                (Install Collections)
                     SW Uninstall\
                                  (UnInstall Collections)

Deploy
------

When the -deploy is provided, the application is deployed to the collections, and the content is distributed to the provided distribution point or group.

4 deployments are created:

2 install deployments, 1 on the user and 1 on the device collection
2 uninstall deployments, 1 on the user and 1 on the device collection

The deployments are created with the following settings:
- Deploy as-soon-as-possible
- Required
- whether or not the user is logged-on





The script can be executed multiple time for a single application, with different steps. The order should be Application -> CollectionStructure -> Deploy for predictable results
 
 
.EXAMPLE 

Add an app-v application to SCCM

Add-cCMApp.ps1 -Application -Name MyApp -ApplicationVersion 1432 -PackageVersion 2 -Virtual -Path \\myapprepo\myapp\1432\2\virtual\MyApp.appv -SiteServer MySiteServer -SiteCode MSC
 
.EXAMPLE 

Add a native application to SCCM

Add-cCMApp.ps1 -Application -Name MyApp -ApplicationVersion 1432 -PackageVersion 2 -Native -Path \\myapprepo\myapp\1432\2\native -SiteServer MySiteServer -SiteCode MSC

.EXAMPLE 

Create a collection structure for the application

Add-cCMApp.ps1 -CollectionStructure -Name MyApp -ADGroup MyApp -SiteServer MySiteServer -SiteCode MSC

.EXAMPLE 

Create a deployment for the application

Add-cCMApp.ps1 -Deploy -Name MyApp -ApplicationVersion 1432 -PackageVersion 2 -DistributionPointGroup MyDPGroup -SiteServer MySiteServer -SiteCode MSC

.EXAMPLE 

Do all actions in one go

Add-cCMApp.ps1 -Application -CollectionGroup -Deploy -Name MyApp -ApplicationVersion 1432 -PackageVersion 2 -DistributionPointGroup MyDPGroup -Virtual -Path \\myapprepo\myapp\1432\2\virtual\MyApp.appv -SiteServer MySiteServer -SiteCode MSC
 

.LINK

ChangeLog
---------

04-08-2016: initial documented version
 
#>
param(
    # Whether to create the application, when modifying an existing application, the parameter should be left out
    [switch] $Application,
    # Whether to create the associated collections, can be omitted if they are already created
    [switch] $CollectionStructure,
    # Whether to create the deployments towards the collections, can be omitted if already present
    [switch] $Deploy,
    # The base name of the application. Eg SCCMConsole
    [string] $Name,
    # The version of the application. Eg 1606
    [string] $AppVersion,
    # The version of the package. Eg 1
    [string] $PackageVersion,
    # If the application is virtual, the full UNC path to the .appv file, in case of a native application, the UNC path to the location of the framework.ps1 file
    [string] $Path,
    # the name of the AD group to be used for deployment/uninstallations (this group is not created in AD by the script)
    [string] $ADGroup = $Name,
    # indicates that a virtual application is added
    [switch] $Virtual,
    # indicates that a native application is added
    [switch] $Native,
    # the hostname of the SCCM site server
    [string] $SiteServer,
    # the sitecode of the SCCM site to add the application to
    [string] $SiteCode,
    # the distribution point to distirbute the application contents to
    [string] $DistributionPointName,
    # the distribution point group to distirbute the application contents to
    [string] $DistributionPointGroupName
)


$ErrorActionPreference='stop'
Set-PSDebug -Strict

import-module ConfigurationManager
Remove-PSDrive -Name $SiteCode -Force -ErrorAction SilentlyContinue
New-PSDrive -Name $SiteCode -PSProvider "AdminUI.PS.Provider\CMSite" -Root $SiteServer
set-location "$($SiteCode):"

$app = $null
$appname = "$Name$AppVersion.$PackageVersion"
$devcolnamei = "[SD] $Name (Device) - Install"
$devcolnameu = "[SD] $Name (Device) - UnInstall"
$usrcolnamei = "[SD] $Name (User) - Install"
$usrcolnameu = "[SD] $Name (User) - UnInstall"
if($Application){
    $app = New-CMApplication -Name $appname -SoftwareVersion "$SoftwareVersion.$PackageVersion" -AutoInstall $true
    if($Virtual){
        $dt = Add-CMDeploymentType -AppV5xInstaller -DeploymentTypeName virtual -AutoIdentifyFromInstallationFile -ContentLocation $Path -ApplicationName ($app.LocalizedDisplayName) -ForceForUnknownPublisher $true
    }
    if($Native){
        $dt= Add-CMDeploymentType -ScriptInstaller -DeploymentTypeName native -ContentLocation $Path -ApplicationName ($app.LocalizedDisplayName) -InstallationBehaviorType InstallForSystem -InstallationProgram "framework.ps1 -action install" -UninstallProgram "framework.ps1 -action uninstall" -DetectDeploymentTypeByCustomScript -ScriptType PowerShell -ScriptContent "throw 'Please Define A Detection Type'" -LogonRequirementType WhetherOrNotUserLoggedOn
    }
}

if($CollectionStructure){
    New-Item -Name 'SW Distribution' -Path "$($SiteCode):\DeviceCollection" -ErrorAction SilentlyContinue
    New-Item -Name 'SW Distribution' -Path "$($SiteCode):\UserCollection" -ErrorAction SilentlyContinue

    New-Item -Name 'SW Install' -Path "$($SiteCode):\DeviceCollection\SW Distribution" -ErrorAction SilentlyContinue
    New-Item -Name 'SW Install' -Path "$($SiteCode):\UserCollection\SW Distribution" -ErrorAction SilentlyContinue

    New-Item -Name 'SW Uninstall' -Path "$($SiteCode):\DeviceCollection\SW Distribution" -ErrorAction SilentlyContinue
    New-Item -Name 'SW UnInstall' -Path "$($SiteCode):\UserCollection\SW Distribution" -ErrorAction SilentlyContinue



    $devinstallcol = New-CMDeviceCollection -LimitingCollectionName "All Systems" -RefreshType Continuous -Name $devcolnamei
    Add-CMDeviceCollectionQueryMembershipRule -CollectionName $devinstallcol.name -QueryExpression "select SMS_R_SYSTEM.ResourceID,SMS_R_SYSTEM.ResourceType,SMS_R_SYSTEM.Name,SMS_R_SYSTEM.SMSUniqueIdentifier,SMS_R_SYSTEM.ResourceDomainORWorkgroup,SMS_R_SYSTEM.Client from SMS_R_System where SMS_R_System.SecurityGroupName like 'DOMAIN\\c$ADGroup%'" -RuleName "[Q] AD: GG-S-C-$AdGroup"
    Move-CMObject -InputObject $devinstallcol -FolderPath "$($SiteCode):\DeviceCollection\SW Distribution\SW Install"

    $devuninstallcol = New-CMDeviceCollection -LimitingCollectionName "All Systems" -RefreshType Continuous -Name $devcolnameu
    Add-CMDeviceCollectionQueryMembershipRule -CollectionName $devuninstallcol.name -QueryExpression "select SMS_R_SYSTEM.ResourceID,SMS_R_SYSTEM.ResourceType,SMS_R_SYSTEM.Name,SMS_R_SYSTEM.SMSUniqueIdentifier,SMS_R_SYSTEM.ResourceDomainORWorkgroup,SMS_R_SYSTEM.Client from SMS_R_System inner join SMS_G_System_AppClientState on SMS_G_System_AppClientState.MachineName = SMS_R_System.Name where SMS_G_System_AppClientState.ComplianceState = 1 and SMS_G_System_AppClientState.AppName like '$Name%'" -RuleName "[Q] CM: $Name"
    Add-CMDeviceCollectionExcludeMembershipRule -CollectionName $devuninstallcol.name -ExcludeCollectionName $devinstallcol.name
    Move-CMObject -InputObject $devuninstallcol -FolderPath "$($SiteCode):\DeviceCollection\SW Distribution\SW UnInstall"

    $userinstallcol = New-CMUserCollection -LimitingCollectionName "All Users" -RefreshType Continuous -Name $usrcolnamei
    Add-CMUserCollectionQueryMembershipRule -CollectionName $userinstallcol.name -QueryExpression "select SMS_R_USER.ResourceID,SMS_R_USER.ResourceType,SMS_R_USER.Name,SMS_R_USER.UniqueUserName,SMS_R_USER.WindowsNTDomain from SMS_R_User where SMS_R_User.SecurityGroupName like 'DOMAIN\\u$ADGroup%'" -RuleName "[Q] AD: GG-S-U-$ADGroup"
    Move-CMObject -InputObject $userinstallcol -FolderPath "$($SiteCode):\UserCollection\SW Distribution\SW Install"

    $useruninstallcol = New-CMUserCollection -LimitingCollectionName "All Users" -RefreshType Continuous -Name $usrcolnameu
    Add-CMUserCollectionQueryMembershipRule -CollectionName $useruninstallcol.name -QueryExpression "select SMS_R_USER.ResourceID,SMS_R_USER.ResourceType,SMS_R_USER.Name,SMS_R_USER.UniqueUserName,SMS_R_USER.WindowsNTDomain from SMS_R_User inner join SMS_G_System_AppClientState on SMS_R_USER.UniqueUserName = SMS_G_System_AppClientState.UserName    where SMS_G_System_AppClientState.AppName like '$Name%' and SMS_G_System_AppClientState.ComplianceState = 1" -RuleName "[Q] CM: $Name"
    Add-CMUserCollectionExcludeMembershipRule -CollectionName $useruninstallcol.name -ExcludeCollectionName $userinstallcol.name
    Move-CMObject -InputObject $useruninstallcol -FolderPath "$($SiteCode):\UserCollection\SW Distribution\SW UnInstall"
}

if($Deploy){
    if($app -eq $null){
        $app = Get-CMApplication -Name $appname
    }
    if($DisttributionPointGroupName){
        Start-CMContentDistribution -Application $app -DistributionPointGroupName $DistributionPointGroupName
    }
    if($DisttributionPointName){
        Start-CMContentDistribution -Application $app -DistributionPointName $DistributionPointName
    }

    Start-CMApplicationDeployment -Name $app.LocalizedDisplayName -DeployAction Install -CollectionName $devcolnamei -DeployPurpose Required
    Start-CMApplicationDeployment -Name $app.LocalizedDisplayName -DeployAction Install -CollectionName $usrcolnamei -DeployPurpose Required
    Start-CMApplicationDeployment -Name $app.LocalizedDisplayName -DeployAction UnInstall -CollectionName $devcolnameu
    Start-CMApplicationDeployment -Name $app.LocalizedDisplayName -DeployAction UnInstall -CollectionName $usrcolnameu
    #Move-CMObject -InputObject $app -FolderPath "$($SiteCode):\Application\W10"
}
