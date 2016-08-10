
# This script can be used to quickly replace an entire or partial path of all content of a SCCM site. This can be very useful in content or site migration scenarios
# Before running this script, make sure that all content has been replicated to the target location. The script only changes the path-references in SCCM, but does not touch the content itself.
# You should have the SCCM console installed, or run this script from a SCCM PS session. Also, make sure you have the permissions to modify packages and applications
[CmdletBinding()] 
param(
	# the pattern to look for in the content paths
    [string] $SearchPattern,
	# the string to replace matched paths with
    [string] $ReplaceWith,
	# the name of the target SCCM site server
    [string] $SiteServer,
	# the name of the target SCCM site
    [string] $SiteCode
)
# stop if an error occurs (try..catch is used to provide graceful error messages)
$ErrorActionPreference = "stop"

# convert the parameters to lowercase. This is to reduce the risk of bugs due to case-sensitivity. Possibly not needed, but just to make sure :)
$SearchPattern = $SearchPattern.ToLower()
$ReplaceWith = $ReplaceWith.ToLower()
try{
	# equivalent of 'option explicit' in vb: generates errors if PS variables are not defined, which helps detect fat fingers aka typos
    Set-StrictMode -Version latest
	# store the current location of the session. This is a nice-to-have function to return to the current location after having performed the processing in the SCCM PS drive.
    Push-Location
    write-host "Loading CM PS and DLL modules"

	# load the SCCM PS and DLL files. We use the DLL's to use some shortcut C# functions to simplify the processing of applications.
	# More info and respects: https://andrewdcraig.wordpress.com/2013/01/31/configmgr-2012-change-application-source-path/
    if((get-module ConfigurationManager) -eq $null){
        import-module ConfigurationManager -Force
    }
    [System.Reflection.Assembly]::LoadFrom((Join-Path (Get-Item $env:SMS_ADMIN_UI_PATH).Parent.FullName "Microsoft.ConfigurationManagement.ApplicationManagement.dll")) | Out-Null
    [System.Reflection.Assembly]::LoadFrom((Join-Path (Get-Item $env:SMS_ADMIN_UI_PATH).Parent.FullName "Microsoft.ConfigurationManagement.ApplicationManagement.Extender.dll")) | Out-Null
    [System.Reflection.Assembly]::LoadFrom((Join-Path (Get-Item $env:SMS_ADMIN_UI_PATH).Parent.FullName "Microsoft.ConfigurationManagement.ApplicationManagement.MsiInstaller.dll")) | Out-Null

    write-host "Connecting to CM server $SiteServer | $Sitecode"
    Remove-PSDrive -Name $SiteCode -Force -ErrorAction SilentlyContinue
    $null = New-PSDrive -Name $SiteCode -PSProvider "AdminUI.PS.Provider\CMSite" -Root $SiteServer
    set-location "$($SiteCode):"
	
	# get all content loaded in the session. this might take some time depending on Infra and DB quality
    write-host "Getting Drivers"
    $Drivers = Get-CMDriver
    write-host "Getting Driver Packages"
    $DriverPackages = Get-CMDriverPackage
    write-host "Getting SUP Packages"
    $UpdatePackages = Get-CMSoftwareUpdateDeploymentPackage
    write-host "Getting standard packages"
    $Packages = Get-CMPackage
    write-host "Getting Applications"
	# as we use some DLL functions, we process the applications directly through WMI instead of the PS cmdlets
    $Applications = Get-WmiObject -ComputerName $SiteServer -Namespace root\SMS\site_$SiteCode -class SMS_Application | Where-Object {$_.IsLatest -eq $True}
    write-host "Gettins OS packages"
    $OSImages = Get-CMOperatingSystemImage
	
	# the same set of steps is executed for each type of content:
	# 1) get the path
	# 2) do a search replace in the path using the parameters provided
	# 3) if the result value (NewPath) is the same as the original path, no update is performed. Else, the existence of the path is checked, and if everything is OK, the path is updated in the SCCM object
	
    try{
        write-host "Processing applications..."
        $i = 0
        $count = $Applications.Count
        foreach($Application in $Applications){
            Write-Progress -activity "Processing Applications" -PercentComplete (($i / $count) * 100) -CurrentOperation "$($Application.LocalizedDisplayName) - Analyzing" -Status "Application $i / $count"
    
            $Update = 0
            $Application = [wmi]$Application.__PATH
            $ApplicationXML = [Microsoft.ConfigurationManagement.ApplicationManagement.Serialization.SccmSerializer]::DeserializeFromString($Application.SDMPackageXML,$True)
            if($ApplicationXML.DeploymentTypes.Count -gt 0){
                foreach ($DeploymentType in $ApplicationXML.DeploymentTypes) {
                    $Installer = $DeploymentType.Installer
                    if($Installer.Contents.Count -ne 0){
                        $Contents = $Installer.Contents[0]
                        $UpdatePath = $Contents.Location.tolower().replace($SearchPattern,$ReplaceWith)
                        
                        if ($UpdatePath -ne $Contents.Location) {
                            if((get-item -literalpath "FileSystem::$UpdatePath" -ErrorAction SilentlyContinue) -eq $null){
                                throw "Target Content Path does not exist: $UpdatePath"
                            }
                            $UpdateContent = [Microsoft.ConfigurationManagement.ApplicationManagement.ContentImporter]::CreateContentFromFolder($UpdatePath)
                            $UpdateContent.FallbackToUnprotectedDP = $True
                            $UpdateContent.OnFastNetwork = [Microsoft.ConfigurationManagement.ApplicationManagement.ContentHandlingMode]::Download
                            $UpdateContent.OnSlowNetwork = [Microsoft.ConfigurationManagement.ApplicationManagement.ContentHandlingMode]::DoNothing
                            $UpdateContent.PeerCache = $False
                            $UpdateContent.PinOnClient = $False
                            $Installer.Contents[0].ID = $UpdateContent.ID
                            $Installer.Contents[0] = $UpdateContent
                            $Update = 1
                        }
                    }
                }

           }
           if($Update -eq 1){
                Write-Progress -activity "Processing Applications" -PercentComplete (($i / $count) * 100) -CurrentOperation "$($Application.LocalizedDisplayName) - Update Needed" -Status "Application $i / $count"
                $UpdatedXML = [Microsoft.ConfigurationManagement.ApplicationManagement.Serialization.SccmSerializer]::SerializeToString($ApplicationXML, $True)
                $Application.SDMPackageXML = $UpdatedXML
                $null = $Application.Put()
                Write-Host "Updated $($Application.LocalizedDisplayName)"
                Write-Progress -activity "Processing Applications" -PercentComplete (($i / $count) * 100) -CurrentOperation "$($Application.LocalizedDisplayName) - Updated" -Status "Application $i / $count"
        
           } else {
                Write-Progress -activity "Processing Applications" -PercentComplete (($i / $count) * 100) -CurrentOperation "$($Application.LocalizedDisplayName) - No Update Needed" -Status "Application $i / $count"
                Write-Verbose "Updated $($Application.LocalizedDisplayName)"
           }
           $i++
        }
    } catch {
        throw "Error while processing application $($Application.LocalizedDisplayName): $_"
    }

    try{
        write-host "Processing standard packages..."
        $i = 0
        $count = $Packages.Count
        foreach($Package in $Packages){
           Write-Progress -activity "Processing Packages" -PercentComplete (($i / $count) * 100) -CurrentOperation "$($Package.Name) - Analyzing" -Status "Package $i / $count"
            if($Package.PkgSourcePath -ne ($NewPath = $Package.PkgSourcePath.tolower().replace($SearchPattern,$ReplaceWith))){
            
                Write-Progress -activity "Processing Packages" -PercentComplete (($i / $count) * 100) -CurrentOperation "$($Package.Name) - Update Needed" -Status "Package $i / $count"
                # because we are in a custom PS provider (SCCM PS drive), we must refer to UNC paths using the FileSystem provider prefix FileSystem::...
				if((get-item -literalpath "FileSystem::$NewPath" -ErrorAction SilentlyContinue) -eq $null){
                    throw "Target Content Path does not exist: $NewPath"
                }
                Set-CMPackage -InputObject $Package -Path $NewPath
                Write-Progress -activity "Processing Packages" -PercentComplete (($i / $count) * 100) -CurrentOperation "$($Package.Name) - Updated" -Status "Package $i / $count"
                Write-Host "Updated $($Package.Name)"
            } else {
                Write-Progress -activity "Processing Packages" -PercentComplete (($i / $count) * 100) -CurrentOperation "$($Package.Name) - No Update Needed" -Status "Package $i / $count"
            }
            $i++
        }
    } catch {
        throw "Error while processing standard package $($Package.Name): $_"
    }

    try {
        write-host "Processing OS packages..."
        $i = 0
        $count = $OSImages.Count
        foreach($OSImage in $OSImages){
            Write-Progress -activity "Processing OS Packages" -PercentComplete (($i / $count) * 100) -CurrentOperation "$($OSImage.Name) - analyzing" -Status "OS Package $i / $count"
            if($OSImage.PkgSourcePath -ne ($NewPath = $OSImage.PkgSourcePath.tolower().replace($SearchPattern,$ReplaceWith))){
                Write-Progress -activity "Processing OS Packages" -PercentComplete (($i / $count) * 100) -CurrentOperation "$($OSImage.Name) - Update Needed" -Status "OS Package $i / $count"
                if((get-item -literalpath "FileSystem::$NewPath" -ErrorAction SilentlyContinue) -eq $null){
                    throw "Target Content Path does not exist: $NewPath"
                }
                Set-CMOperatingSystemImage -InputObject $OSImage -Path $NewPath
                Write-Progress -activity "Processing OS Packages" -PercentComplete (($i / $count) * 100) -CurrentOperation "$($OSImage.Name) - Updated" -Status "OS Package $i / $count"
                Write-Host "Updated $($OSImage.Name)"
            } else {

                Write-Progress -activity "Processing OS Packages" -PercentComplete (($i / $count) * 100) -CurrentOperation "$($OSImage.Name) - no update needed" -Status "OS Package $i / $count"
            }
        }
    } catch {
        throw "Error while processing OS package $($OSImage.Name): $_"
    }

    try{
        write-host "Processing drivers..."
        $i = 0
        $count = $Drivers.Count
        foreach($Driver in $Drivers){
            Write-Progress -activity "Processing Drivers" -PercentComplete (($i / $count) * 100) -CurrentOperation "$($Driver.LocalizedDisplayName) - analyzing" -Status "Driver $i / $count"
            if($Driver.ContentSourcePath -ne ($NewPath = $Driver.ContentSourcePath.tolower().replace($SearchPattern,$ReplaceWith))){
                Write-Progress -activity "Processing Drivers" -PercentComplete (($i / $count) * 100) -CurrentOperation "$($Driver.LocalizedDisplayName) - update needed" -Status "Driver $i / $count"
                if((get-item -literalpath "FileSystem::$NewPath" -ErrorAction SilentlyContinue) -eq $null){
                    throw "Target Content Path does not exist: $NewPath"
                }
                set-cmdriver -InputObject $Driver -DriverSource $NewPath
                Write-Progress -activity "Processing Drivers" -PercentComplete (($i / $count) * 100) -CurrentOperation "$($Driver.LocalizedDisplayName) - updated" -Status "Driver $i / $count"
                Write-Host "Updated $($Driver.LocalizedDisplayName)"
            } else {
                Write-Progress -activity "Processing Drivers" -PercentComplete (($i / $count) * 100) -CurrentOperation "$($Driver.LocalizedDisplayName) - no update needed" -Status "Driver $i / $count"
            }
            $i++
        }
    } catch {
        throw "Error while processing driver $($Driver.LocalizedDisplayName): $_"
    }

    try{
        write-host "Processing Driver Packages..."
        $i = 0
        $count = $DriverPackages.count
        foreach($DriverPackage in $DriverPackages){
            Write-Progress -activity "Processing Driver Packages" -PercentComplete (($i / $count) * 100) -CurrentOperation "$($DriverPackage.Name) - analyzing" -Status "Driver Package $i / $count"
            if($DriverPackage.PkgSourcePath -ne ($NewPath = $DriverPackage.PkgSourcePath.tolower().replace($SearchPattern,$ReplaceWith))){
                Write-Progress -activity "Processing Driver Packages" -PercentComplete (($i / $count) * 100) -CurrentOperation "$($DriverPackage.Name) - update needed" -Status "Driver Package $i / $count"
                if((get-item -literalpath "FileSystem::$NewPath" -ErrorAction SilentlyContinue) -eq $null){
                    throw "Target Content Path does not exist: $NewPath"
                }
                Set-CMDriverPackage -InputObject $DriverPackage -DriverPackageSource $NewPath
                Write-Progress -activity "Processing Driver Packages" -PercentComplete (($i / $count) * 100) -CurrentOperation "$($DriverPackage.Name) - updated" -Status "Driver Package $i / $count"
                Write-Host "Updated $($DriverPackage.Name)"
            } else {
                Write-Progress -activity "Processing Driver Packages" -PercentComplete (($i / $count) * 100) -CurrentOperation "$($DriverPackage.Name) - no update needed" -Status "Driver Package $i / $count"
            }
            $i++
        }
    } catch {
        throw "Error while processing driver package $($DriverPackage.Name): $_"
    }


    try{
        write-host "Processing Update Packages..."
        $i = 0
        $count = $UpdatePackages.Count
        foreach($UpdatePackage in $UpdatePackages){
            Write-Progress -activity "Processing Update Packages" -PercentComplete (($i / $count) * 100) -CurrentOperation "$($UpdatePackage.Name) - analyzing" -Status "Update Package $i / $count"
            if($UpdatePackage.PkgSourcePath -ne ($NewPath = $UpdatePackage.PkgSourcePath.tolower().replace($SearchPattern,$ReplaceWith))){
                Write-Progress -activity "Processing Update Packages" -PercentComplete (($i / $count) * 100) -CurrentOperation "$($UpdatePackage.Name) - update needed" -Status "Update Package $i / $count"
                if((get-item -literalpath "FileSystem::$NewPath" -ErrorAction SilentlyContinue) -eq $null){
                    throw "Target Content Path does not exist: $NewPath"
                }
                Set-CMSoftwareUpdateDeploymentPackage -InputObject $UpdatePackage -Path $NewPath
                Write-Progress -activity "Processing Update Packages" -PercentComplete (($i / $count) * 100) -CurrentOperation "$($UpdatePackage.Name) - updated" -Status "Update Package $i / $count"
                Write-Host "Updated $($UpdatePackage.Name)"
            } else {
                Write-Progress -activity "Processing Update Packages" -PercentComplete (($i / $count) * 100) -CurrentOperation "$($UpdatePackage.Name) - no update needed" -Status "Update Package $i / $count"
            }
            $i++
        }
    } catch {
        throw "Error while processing update package $($UpdatePackage.Name): $_"
    }
} catch {
    $_
}
finally{
	# return from the SCCM PS drive to the original location where the script was executed
   Pop-Location
}
        

    
    
