$ExecutionPath = $ExecutionContext.SessionState.Module.ModuleBase

Import-Module $(Join-Path -Path "$ExecutionPath" -ChildPath "..\utils\Logger.psm1")
Import-Module $(Join-Path -Path "$ExecutionPath" -ChildPath "..\utils\GeneralUtils.psm1") -Force

Function UnzipContainerBundle {
    Param (
        [Parameter(Mandatory=$true)][String]$BundleFilePath,
        [Parameter(Mandatory=$true)][String]$UnzipFolder,
        [bool]$Force
    )

    $FileName = $(Split-Path $BundleFilePath -leaf)

    try {
        if (-not (Test-Path $BundleFilePath)) {
            throw "File '$BundleFilePath' does not exist."
        }

        $Unzip = $True

        if ($(Test-Path $UnzipFolder)) {
            if (-not $BlockForce) {
                WriteLog -Level "DEBUG" -Message "'$FileName' already exists. Doing some checks..."

                if (-not $(FastCrossCheckFilesInFolderAndZip -FolderPath $UnzipFolder -ZipPath $BundleFilePath)) {
                    WriteLog -Level "DEBUG" -Message "'$FileName' zip bundle and unzipped bundle folder are not coherent. Deleting unzipped bundle folder."
                    Remove-Item -Path $UnzipFolder -Recurse -Force
                } else {
                    WriteLog -Level "DEBUG" -Message "'$FileName' Everything seems to be unchanged. Doing nothing."
                    $Unzip = $False
                }
            }
        }

        if ($Unzip) {
            WriteLog -Level "DEBUG" -Message "'$FileName' unzipped bundle folder doesn't exist. Unzipping..."

            $FolderName = $(Split-Path $UnzipFolder -Leaf)
            $TempPath = Join-Path -Path $env:Temp -ChildPath $FolderName

            Expand-Archive -Path $BundleFilePath -DestinationPath $TempPath -Force

            # The \\?\ are needed to workaround filepath size limitations. for more information check:
            # https://blogs.msdn.microsoft.com/bclteam/2007/02/13/long-paths-in-net-part-1-of-3-kim-hamilton/
            # https://docs.microsoft.com/en-us/windows/desktop/FileIO/naming-a-file
            Copy-Item -Path "\\?\$TempPath" -Destination "\\?\$UnzipFolder" -Force -Recurse

            if (Test-Path $TempPath) {
                Remove-Item -Path $TempPath -Recurse -Force 2>$null
            }

            WriteLog -Level "DEBUG" -Message "'$FileName' unzipped to '$UnzipFolder'."
        }
    } catch {
        throw "'$FileName' unzipping failed: $_"
    }
}

Function GetAppFullName {
    Param (
        [Parameter(Mandatory=$true)][String]$ApplicationKey,
        [Parameter(Mandatory=$true)][String]$OperationId
    )

    return "$($ApplicationKey)_$($OperationId)"
}

Function GetModuleNamesFromUnzippedBundle {
    Param (
        [Parameter(Mandatory=$true)][String]$ApplicationKey,
        [Parameter(Mandatory=$true)][String]$OperationId,
        [Parameter(Mandatory=$true)][String]$UnzippedBundlesPath 
    )

    $UnzippedBundlePath = Join-Path -Path $UnzippedBundlesPath -ChildPath $(GetAppFullName -ApplicationKey $ApplicationKey -OperationId $OperationId)

    if (-not $(Test-Path $UnzippedBundlePath)) {
        $UnzippedBundlePath = Get-Item "$UnzippedBundlesPath\$ApplicationKey*" | 
                                Sort-Object LastWriteTime -Descending | 
                                    Select-Object -First 1
    }

    if ($UnzippedBundlePath -and $(Test-Path $UnzippedBundlePath)) {
        $ModulesPath = $(Join-Path -Path $UnzippedBundlePath -ChildPath $global:ModulesFolderName)
    
        if ($ModulesPath -and $(Test-Path $ModulesPath)) {
            return $(GetSubFolders -Path $ModulesPath)
        } else {
            WriteLog -Level "DEBUG" -Message "The modules folder for app '$ApplicationKey' doesn't exist. Unable to calculate module names."
        }
    } else {
        WriteLog -Level "DEBUG" -Message "The unzipped bundle folder for app '$ApplicationKey' doesn't exist. Unable to calculate module names."
    }

    return @()
}

Function GetAppInfo {
    Param (
        [Parameter(Mandatory=$true)][String]$ApplicationName,
        [Parameter(Mandatory=$true)][String]$ApplicationKey,
        [Parameter(Mandatory=$true)][String]$OperationId,
        [Parameter(Mandatory=$true)][String[]][AllowEmptyCollection()]$ModuleNames,
        [Parameter(Mandatory=$true)][String]$TargetPath,
        [Parameter(Mandatory=$true)][String]$UnzippedBundlesPath 
    )

    $AppInfo = @{}

    $AppInfo.ApplicationName = $ApplicationName
    $AppInfo.ApplicationKey = $ApplicationKey
    $AppInfo.OperationId = $OperationId
    $AppInfo.FullName = $(GetAppFullName -ApplicationKey $ApplicationKey -OperationId $OperationId)
    $AppInfo.BundleFilePath = Join-Path -Path $TargetPath -ChildPath "$($AppInfo.FullName).zip"
    $AppInfo.UnzippedBundlePath = Join-Path -Path $UnzippedBundlesPath -ChildPath $AppInfo.FullName
    
    if ($ModuleNames) {
        $AppInfo.ModuleNames = $ModuleNames
    } else {
        WriteLog -Level "DEBUG" -Message "Calculating modules for app '$ApplicationKey' from unzipped bundle folder."
        $AppInfo.ModuleNames = $(GetModuleNamesFromUnzippedBundle   -ApplicationKey $ApplicationKey `
                                                                    -OperationId $OperationId `
                                                                    -UnzippedBundlesPath $UnzippedBundlesPath)
    }

    if ($AppInfo.ModuleNames) {
        WriteLog "'$($AppInfo.FullName)' has the following modules: '$($AppInfo.ModuleNames -join ", ")'."
    }

    return $AppInfo
}

Function NewWrapperResult {
    $Result = @{}
    $Result.Error = $null
    $Result.SkipPing = $False

    return $Result
}
