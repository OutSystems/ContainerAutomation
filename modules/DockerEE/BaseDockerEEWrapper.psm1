$ExecutionPath = $ExecutionContext.SessionState.Module.ModuleBase

Import-Module $(Join-Path -Path "$ExecutionPath" -ChildPath "../../utils/Logger.psm1")
Import-Module $(Join-Path -Path "$ExecutionPath" -ChildPath "../../utils/DockerUtils.psm1") -Force
Import-Module $(Join-Path -Path "$ExecutionPath" -ChildPath "../../utils/IISUtils.psm1") -Force

# When extending this module, implement in your module's Wrapper.psm1 the following commented 
# functions:
#       GetExtraContainerRunParameters
#       CreateRewriteRulesOnContainerRun
#       RemoveRewriteRulesOnContainerRemove
#  Make sure that signatures match!

# This function allows the definition of any parameters that need to be passed to docker run.
# You do not need to implement any special logic, but you will need to have the function header 
# in your Wrapper.psm1
# Note that, by default, '-dit' are already being used.
<#
Function GetExtraContainerRunParameters {
    # for instance, lets say we want to publish all ports to any available host ports...
    return @("-P")
}
#>

# This function should handle creating rewrite rules. It will only be called if there are valid Module Names.
# This is called during the ContainerRun stage, after stopping previous versions of the application
# running in containers, obtaining the Image ID of the current one and starting a container with any 
# Extra Parameters as defined in GetExtraContainerRunParameters.
<#
Function CreateRewriteRulesOnContainerRun {
    Param (
        [Parameter(Mandatory=$true)][Object]$ContainerInfo,
        [Parameter(Mandatory=$true)][Hashtable]$OpInfo,
        [Parameter(Mandatory=$true)][Hashtable]$AdditionalParameters
    )
    
    # do stuff
}
#>


# This function should handle removing rewrite rules. It will only be called if there are valid Module Names.
# It's called after all the images and containers that match the labels of the current operation
# are deleted.
<#
Function RemoveRewriteRulesOnContainerRemove {
    Param (
        [Parameter(Mandatory=$true)][Hashtable]$OpInfo
    )
}
#>




# From here on, be careful with what you modify!

Function TryToConvertHostPathUsedForVolumeFromNetworkShare {
    Param (
        [Parameter(Mandatory=$true)][String]$Path
    )

    # checks if path is a network share
    if ([bool]([System.Uri]$Path).IsUnc) {
        # split the network share by the \s
        # e.g. \\share.com\potato\cabbage to [ share.com , potato , cabbage]
        $SplittedPath = $($Path -replace '\\\\','' -split '\\')
        
        # windows represents internally the share by a name 
        # this name maps to the first element of the path. e.g. 'potato'
        $SmbShareName = $SplittedPath[1]

        try {
            # we try to get the samba share object by the name we calculated
            # if no samba share exists for the name an exception is thrown
            $SmbShare = $(Get-SmbShare -name $SmbShareName)

            # we replace the domain part of the share plus the share name for the 'physical' path of the share
            # hopefully
            $InferredPath = $($Path -replace "\\\\$($SplittedPath[0])\\$($SplittedPath[1])", "$($SmbShare.Path)")

            WriteLog -Level "DEBUG" -Message "Inferred that [$Path] is actually [$InferredPath]."
        } catch {
            # lets set an invalid path to ensure it will fail next
            $InferredPath = ""
        }

        <# 
            lets check if we have a valid path
            if not, throw a informative message
            this could have some additional logic, though:
            if the network share is located a different computer copy the file to a local folder
        #>
        if (-not $InferredPath) {
            throw "Unable to infer local path for network share ('$Path'). Docker does not map volumes to network shares. Additional transformations to the path are required."
        }

        if (-not (Test-Path $InferredPath)) {
            WriteLog -Level "WARN" "The path ('$Path') does not yet exist! Moving on nonetheless."
        }
    } else {
        $InferredPath = $Path
    }

    return $InferredPath
}

Function GetFilePaths {
    Param (
        [Parameter(Mandatory=$true)][String]$SiteName,
        [Parameter(Mandatory=$true)][String]$ApplicationKey,
        [Parameter(Mandatory=$true)][String]$ArtefactsBasePath,
        [Parameter(Mandatory=$true)][String]$BaseConfigPath,
        [Parameter(Mandatory=$false)][String]$SecretPath
    )

    $BaseConfigPath = TryToConvertHostPathUsedForVolumeFromNetworkShare -Path $BaseConfigPath
    
    $FilePaths = @{}

    $FilePaths.UnzippedBundlesPath = $(Join-Path -Path "$ArtefactsBasePath" -ChildPath "$SiteName/$($global:UnzippedBundlesFolderName)")
    $FilePaths.SiteFolderPath = $(Join-Path -Path "$ArtefactsBasePath" -ChildPath "$SiteName/site")
    $FilePaths.AppConfigPath = $(Join-Path -Path $BaseConfigPath -ChildPath $ApplicationKey)
    $FilePaths.SecretPath = $SecretPath

    if (-not $FilePaths.SecretPath) {
        $FilePaths.SecretPath = $(Join-Path -Path "$ArtefactsBasePath" -ChildPath "$SiteName/$($global:SecretsFolderName)")
    } else {
        $FilePaths.SecretPath = $(TryToConvertHostPathUsedForVolumeFromNetworkShare -Path $FilePaths.SecretPath)
    }

    foreach ($PathName in @("UnzippedBundlesPath", "SiteFolderPath", "AppConfigPath", "SecretPath")) {
        $Path = $FilePaths[$PathName]

        # forcing folder creation to ensure that the folders exists
        $(New-Item -Force -Path $Path -ItemType Directory) 2>&1>$null

        # forcing the paths to be fully absolute (e,g with no /../ )
        # in particular, IIS does not support a path with those characteristics for the physical path
        $FilePaths[$PathName] = $(Resolve-Path $Path)
    }

    return $FilePaths
}

Function GetAppVolumeFolders {
    Param (
        [Parameter(Mandatory=$true)][String]$ConfigsFolderInHost,
        [Parameter(Mandatory=$true)][String]$ConfigsFolderInContainer,
        [Parameter(Mandatory=$true)][String]$SecretsFolderInHost,
        [Parameter(Mandatory=$true)][String]$SecretsFolderInContainer
    )

    $AppVolumeFolders = @{}
    $AppVolumeFolders.ConfigsFolderInHost = $ConfigsFolderInHost
    $AppVolumeFolders.ConfigsFolderInContainer = $ConfigsFolderInContainer
    $AppVolumeFolders.SecretsFolderInHost = $SecretsFolderInHost
    $AppVolumeFolders.SecretsFolderInContainer = $SecretsFolderInContainer

    if (-not $(Test-Path $AppVolumeFolders.ConfigsFolderInHost)) {
        $(New-item -Force $AppVolumeFolders.ConfigsFolderInHost -ItemType directory) 2>&1>$null
    }

    if (-not $(Test-Path $AppVolumeFolders.SecretsFolderInHost)) {
        $(New-item -Force $AppVolumeFolders.SecretsFolderInHost -ItemType directory) 2>&1>$null
    }

    $AppVolumeFolders.Mappings = @{}
    $AppVolumeFolders.Mappings[$AppVolumeFolders.ConfigsFolderInHost] = $AppVolumeFolders.ConfigsFolderInContainer
    $AppVolumeFolders.Mappings[$AppVolumeFolders.SecretsFolderInHost] = $AppVolumeFolders.SecretsFolderInContainer

    return $AppVolumeFolders
}

Function GetOpInfo {
    Param (
        [Parameter(Mandatory=$true)][Hashtable]$PlatformParameters,
        [Parameter(Mandatory=$true)][Hashtable]$AdditionalParameters
    )

    $OpInfo = @{}

    $ApplicationName = $PlatformParameters.ApplicationName
    $ApplicationKey = $PlatformParameters.ApplicationKey
    $OperationId = $PlatformParameters.OperationId
    $ModuleNames = $PlatformParameters.ModuleNames
    $TargetPath = $PlatformParameters.TargetPath
    $BaseConfigPath = $PlatformParameters.ConfigPath

    # Handling the SiteName. 
    # Removes spaces.
    # If empty set it to "default"
    $OpInfo.SiteName = $AdditionalParameters.SiteName -replace " ", ""

    if (-not $OpInfo.SiteName) {
        $OpInfo.SiteName = "default"
    }

    $FilePaths = $(GetFilePaths -SiteName $OpInfo.SiteName `
                                -ApplicationKey $ApplicationKey `
                                -ArtefactsBasePath $global:ArtefactsBasePath `
                                -BaseConfigPath $BaseConfigPath `
                                -SecretPath $AdditionalParameters.SecretPath)

    $AppInfo = $(GetAppInfo -ApplicationName $ApplicationName `
                            -ApplicationKey $ApplicationKey `
                            -OperationId $OperationId `
                            -ModuleNames $ModuleNames `
                            -TargetPath $TargetPath `
                            -UnzippedBundlesPath $FilePaths.UnzippedBundlesPath)

    $AppVolumeFolders = $(GetAppVolumeFolders   -ConfigsFolderInHost $FilePaths.AppConfigPath `
                                                -ConfigsFolderInContainer $global:ConfigsFolderInContainer `
                                                -SecretsFolderInHost $FilePaths.SecretPath `
                                                -SecretsFolderInContainer $global:SecretsFolderInContainer)

    $OpInfo.FilePaths = $FilePaths
    $OpInfo.AppInfo = $AppInfo
    $OpInfo.AppVolumeFolders = $AppVolumeFolders

    return $OpInfo
}

Function GetLabels {
    Param (
        [Parameter()][String]$ApplicationKey,
        [Parameter()][String]$OperationId,
        [Parameter()][String]$SiteName
    )

    $Labels = @{}

    if ($ApplicationKey) {
        $Labels.ApplicationKey = $(CleanUpLabel $ApplicationKey)
    }

    if ($OperationId) {
        $Labels.OperationId = $(CleanUpLabel $OperationId)
    }

    if ($SiteName) {
        $Labels.SiteName = $(CleanUpLabel $SiteName)
    }

    return $Labels
}

Function CleanUpContainerArtefacts {
    Param (
        [Parameter(Mandatory=$true)][String]$TargetPath,
        [Parameter(Mandatory=$true)][String]$UnzippedBundlePath,
        [Parameter(Mandatory=$true)][String]$ApplicationKey,
        [Parameter()][String]$OperationIdToKeep
    )

    foreach ($Path in @($TargetPath, $UnzippedBundlePath)) {
        if (-not (Test-Path $Path)) {
            WriteLog "The path '$Path' doesn't seem to exist. Ignoring."
            continue
        }

        foreach ($Artefact in $(Get-ChildItem $Path -Filter "*$ApplicationKey*")) {
            try {
                if ($OperationIdToKeep -and ($(Split-Path -Path $Artefact.FullName -Leaf) -like "*$OperationIdToKeep*")) {
                    continue
                }

                if ($Artefact.Attributes -eq "Directory") {
                    $(Remove-Item -LiteralPath $Artefact.FullName -Force -Recurse) 2>$FileDeleteError
                } else {
                    $(Remove-Item -LiteralPath $Artefact.FullName -Force) 2>$FileDeleteError
                }

                if ($FileDeleteError) {
                    WriteLog -Level "DEBUG" -Message "Unable to delete '$Artefact.FullName'. Moving on..."
                    # WriteLog -Level "DEBUG" -Message "More info: $FileDeleteError"
                }

                WriteLog "Deleted '$($Artefact.FullName)'."
            } catch {
                WriteLog -Level "WARN" -Message "Unable to delete '$($Artefact.FullName)'. Moving on..."
                # WriteLog -Level "DEBUG" -Message "More info: $_"
            }
        }
    }
}

Function RunJustBeforeDeployDone {
    Param (
        [Parameter(Mandatory=$true)][String]$ScriptsPath,
        [Parameter(Mandatory=$true)][String]$ApplicationKey,
        [Parameter(Mandatory=$true)][String]$OperationId,
        [Parameter(Mandatory=$true)][String]$SiteName,
        [Parameter(Mandatory=$true)][object]$ContainerInfo
    )

    if ($ScriptsPath) {
        $GlobalScriptPath = $(Join-Path -Path $ScriptsPath -ChildPath "global.ps1")
        $AppSpecificScriptPath = $(Join-Path -Path $ScriptsPath -ChildPath "$ApplicationKey.ps1")

        foreach ($ScriptPath in @($GlobalScriptPath, $AppSpecificScriptPath)) {
            if (Test-Path $ScriptPath) {
                try {
                    WriteLog -Level "DEBUG" -Message "Found script ($ScriptPath). Executing..."

                    &$ScriptPath $ApplicationKey $OperationId $SiteName $ContainerInfo

                    WriteLog "Executed $ScriptPath"
                } catch {
                    WriteLog -Level "WARN" -Message "Something went wrong when executing '$ScriptPath': $_ ($($Error[0].ScriptStackTrace)). Ignoring..."
                }
            }
        }
    }
}

Function Wrapper_ContainerBuild {
    Param (
        [Parameter(Mandatory=$true)][Hashtable]$PlatformParameters,
        [Parameter(Mandatory=$true)][Hashtable]$AdditionalParameters
    )

    $OpInfo = $(GetOpInfo   -PlatformParameters $PlatformParameters `
                            -AdditionalParameters $AdditionalParameters)

    if (-not (Test-Path $OpInfo.AppInfo.BundleFilePath)) {
        throw "No bundle found with path '$($OpInfo.AppInfo.BundleFilePath)'. Aborting."
    }

    if (-not $(CheckIfZipIsLikelyADockerBundle -DockerBundleFile $OpInfo.AppInfo.BundleFilePath)) {
        throw "No Dockerfile found in root of '$($OpInfo.AppInfo.BundleFilePath)'. Aborting."
    }

    $Labels = $(GetLabels   -ApplicationKey $PlatformParameters.ApplicationKey `
                            -OperationId $PlatformParameters.OperationId `
                            -SiteName $OpInfo.SiteName)

    $ContainerIds = $(GetRunningDockerContainersWithLabels -Labels $Labels)

    if (($AdditionalParameters.Force) -or (-not $ContainerIds)) {
        $(UnzipContainerBundle  -BundleFilePath $OpInfo.AppInfo.BundleFilePath `
                                -UnzipFolder $OpInfo.AppInfo.UnzippedBundlePath)

        $(BuildDockerImageWithRetries   -RepositoryName $OpInfo.AppInfo.FullName `
                                        -RepositoryTag "latest" `
                                        -Labels $Labels `
                                        -DockerfilePath $OpInfo.AppInfo.UnzippedBundlePath) | Out-Null
    } else {
        WriteLog "A container is already running for '$($OpInfo.AppInfo.FullName)'. Doing nothing."
    }
}

Function Wrapper_ContainerRun {
    Param (
        [Parameter(Mandatory=$true)][Hashtable]$PlatformParameters,
        [Parameter(Mandatory=$true)][Hashtable]$AdditionalParameters
    )

    $OpInfo = $(GetOpInfo   -PlatformParameters $PlatformParameters `
                            -AdditionalParameters $AdditionalParameters)

    $LabelsForThisAppVersion = $(GetLabels  -ApplicationKey $PlatformParameters.ApplicationKey `
                                            -OperationId $PlatformParameters.OperationId `
                                            -SiteName $OpInfo.SiteName)

    $LabelsForAllAppVersions = $(GetLabels  -ApplicationKey $PlatformParameters.ApplicationKey `
                                            -SiteName $OpInfo.SiteName)

    # We need to force the 'cast' to String Array:
    # PowerShell will interpret a single item array as a string
    $ImageIds = [String[]]$(GetDockerImagesWithLabels -Labels $LabelsForThisAppVersion)
    If ($ImageIds) {
        $ImageId = $ImageIds[0]
    }

    if (-not $ImageId) {
        throw "Check if the ContainerBuild operation ran successfully. No image was found for the labels."
    }

    if (-not $AdditionalParameters.KeepDockerContainers) {
        $(ForceRemoveAllDockerContainersWithLabels -Labels $LabelsForAllAppVersions) | Out-Null
    }

    $ExtraRunParameters = $(GetExtraContainerRunParameters)

    [String]$ContainerId = $(RunDockerContainerWithRetries  -ImageId $ImageId `
                                                            -Labels $LabelsForThisAppVersion `
                                                            -VolumeMappings $OpInfo.AppVolumeFolders.Mappings`
                                                            -ExtraRunParameters $ExtraRunParameters)

    $ContainerInfo = $(GetDockerContainerInfoWithRetries -ContainerId $ContainerId)

    $AppFullName = $OpInfo.AppInfo.FullName

    WriteLog "Trying to add Rewrite Rules for '$AppFullName'..."

    if ($OpInfo.AppInfo.ModuleNames) {
        $(CreateRewriteRulesOnContainerRun  -ContainerInfo $ContainerInfo `
                                            -OpInfo $OpInfo `
                                            -AdditionalParameters $AdditionalParameters)
    } else {
        WriteLog "No module names for '$AppFullName'. No Rewrite Rules were added."
    }

    if ($ContainerInfo) {
        $(RunJustBeforeDeployDone   -ScriptsPath $OpInfo.FilePaths.SiteFolderPath `
                                    -ApplicationKey $PlatformParameters.ApplicationKey `
                                    -OperationId $PlatformParameters.OperationId `
                                    -SiteName $OpInfo.SiteName `
                                    -ContainerInfo $ContainerInfo)
    }

    $(CleanUpContainerArtefacts -TargetPath $PlatformParameters.TargetPath `
                                -UnzippedBundlePath $OpInfo.FilePaths.UnzippedBundlesPath `
                                -ApplicationKey $PlatformParameters.ApplicationKey `
                                -OperationIdToKeep $PlatformParameters.OperationId)
}

Function Wrapper_ContainerRemove {
    Param (
        [Parameter(Mandatory=$true)][Hashtable]$PlatformParameters,
        [Parameter(Mandatory=$true)][Hashtable]$AdditionalParameters
    )

    $OpInfo = $(GetOpInfo   -PlatformParameters $PlatformParameters `
                            -AdditionalParameters $AdditionalParameters)

    $LabelsForAllAppVersions = $(GetLabels  -ApplicationKey $PlatformParameters.ApplicationKey `
                                            -SiteName $OpInfo.SiteName)

    if (-not $AdditionalParameters.KeepDockerContainers) {
        $(ForceRemoveAllDockerContainersWithLabels -Labels $LabelsForAllAppVersions) | Out-Null
    }

    if (-not $AdditionalParameters.KeepDockerImages) {
        $(ForceRemoveDockerImagesWithLabels -Labels $LabelsForAllAppVersions) | Out-Null
    }

    $AppFullName = $OpInfo.AppInfo.FullName

    WriteLog "Trying to remove Rewrite Rules for '$AppFullName'..."

    if ($OpInfo.AppInfo.ModuleNames) {
        $(RemoveRewriteRulesOnContainerRemove -OpInfo $OpInfo)
    } else {
        WriteLog "No module names for '$AppFullName'. No Rewrite Rules were removed."
    }

    $(CleanUpContainerArtefacts -TargetPath $PlatformParameters.TargetPath `
                                -UnzippedBundlePath $OpInfo.FilePaths.UnzippedBundlesPath `
                                -ApplicationKey $PlatformParameters.ApplicationKey)

    #Remove-Item $ApplicationConfigsFolder -Recurse
    #WriteLog "'$AppFullName' config folder was deleted."
}

Function Wrapper_UpdateConfigurations {
    Param (
        [Parameter(Mandatory=$true)][Hashtable]$PlatformParameters,
        [Parameter(Mandatory=$true)][Hashtable]$AdditionalParameters
    )

    # Nothing to do
}
