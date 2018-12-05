Function GenerateTestBundle {
    Param (
        [Parameter(Mandatory=$true)][String]$OriginPath,
        [Parameter(Mandatory=$true)][String]$TargetPath
    )

    $ApplicationKey = [guid]::NewGuid()
    $OperationId = [guid]::NewGuid()

    $BundleInfo = @{}
    $BundleInfo.ApplicationName = "TestApp"
    $BundleInfo.ApplicationKey = $ApplicationKey
    $BundleInfo.OperationId = $OperationId
    $BundleInfo.FullName = "$($ApplicationKey)_$($OperationId)"
    $NewBundlePath = $(Join-Path -Path $TargetPath -ChildPath "$($BundleInfo.FullName).zip")

    Compress-Archive -Path $OriginPath -CompressionLevel Fastest -DestinationPath $NewBundlePath

    return $BundleInfo
}

Function CallHook {
    Param (
        [Parameter(Mandatory=$true)][String]$ContainerAutomationMachine,
        [Parameter(Mandatory=$true)][int]$Port,
        [Parameter(Mandatory=$true)][String]$HostingTechnology,
        [Parameter(Mandatory=$true)][String]$OperationName,
        [Parameter(Mandatory=$False)][String]$SiteName,
        [Parameter(Mandatory=$true)][String]$DeploymentZoneAddress,
        [Parameter(Mandatory=$true)][String]$PlatformServerFQMN,
        [Parameter(Mandatory=$true)][String]$ApplicationName,
        [Parameter(Mandatory=$true)][String]$ApplicationKey,
        [Parameter(Mandatory=$true)][String]$OperationId,
        [Parameter(Mandatory=$true)][String]$TargetPath,
        [Parameter(Mandatory=$true)][String]$ResultPath,
        [Parameter(Mandatory=$true)][String]$ConfigPath,
        [Parameter(Mandatory=$true)][String]$SecretPath
    )

    $baseURL = "http://$($ContainerAutomationMachine):$($Port)/$HostingTechnology/$OperationName/"
    $url += "$($baseURL)?Address=$DeploymentZoneAddress"
    $url += "&ApplicationName=$ApplicationName"
    $url += "&ApplicationKey=$ApplicationKey"
    $url += "&OperationId=$OperationId"
    $url += "&TargetPath=$TargetPath"
    $url += "&ResultPath=$ResultPath"
    $url += "&ConfigPath=$ConfigPath"
    $url += "&SecretPath=$SecretPath"
    $url += "&SiteName=$SiteName"
    $url += "&PlatformServerFQMN=$PlatformServerFQMN"

    WriteLog "Calling: [ $url ] ..."

    $StatusCode = $(Invoke-WebRequest $url -UseBasicParsing -TimeoutSec 10).StatusCode

    if (($StatusCode -ge 200) -and ($StatusCode -le 299)) {
        WriteLog "Calling [$OperationName] gave us an OK code ($StatusCode)."
    } else {
        throw "Calling [$OperationName] gave us a non 2xx code ($StatusCode)."
    }
}

Function CheckPing {
    Param (
        [Parameter(Mandatory=$true)][String]$DeploymentZoneAddress,
        [Parameter(Mandatory=$False)][String]$SiteName,
        [Parameter(Mandatory=$true)][Hashtable]$ModuleNamesAndStatuses
    )

    $TimeoutInSeconds = 30

    foreach ($Key in $ModuleNamesAndStatuses.Keys) {
        $ModuleName = $Key
        $ExpectedStatus = $ModuleNamesAndStatuses[$Key]

        if ($ExpectedStatus) {
            WriteLog "[PING] Expecting a 2xx code on [$ModuleName]."
        } else {
            WriteLog "[PING] Expecting a non 2xx code on [$ModuleName]."
        }

        $url = "http://$($DeploymentZoneAddress)/$ModuleName/_ping.html"
    
        $Passed = $True

        WriteLog "Calling [ $url ] with $TimeoutInSeconds seconds timeout..."
        try {
            $StatusCode = $(Invoke-WebRequest $url -UseBasicParsing -TimeoutSec $TimeoutInSeconds).StatusCode

            if ( ($StatusCode -ge 200) -and ($StatusCode -le 299) ) {
                $Passed = $True
            } else {
                $Passed = $False
            }
        } catch {
            $Passed = $False      
        }
        
        if ( $ExpectedStatus -eq $Passed ) {
            WriteLog "[PING] for [$ModuleName] gave us an OK code."
        } else {
            throw "[PING] for [$ModuleName] gave us a non OK code."
        }
    }
}

Function WaitForFile {
    Param (
        [Parameter(Mandatory=$true)][String]$ResultPath,
        [Parameter(Mandatory=$true)][String]$ApplicationKey,
        [Parameter(Mandatory=$true)][String]$OperationId,
        [Parameter(Mandatory=$true)][String]$FileExt,
        [Parameter(Mandatory=$false)][int]$TimeoutInSeconds=120
    )
    
    $FileName = "$($ApplicationKey)_$($OperationId).$FileExt"

    $MarkerFilePath = Join-Path -Path $ResultPath -ChildPath $FileName

    WriteLog "Will wait $TimeoutInSeconds seconds for marker file '$FileName' (expected in '$ResultPath')..."

    $Start = Get-Date

    do {
        Start-Sleep 2

        if (Test-Path $MarkerFilePath) {
            $MarkerFileData = $(ConvertFrom-Json $([String]$(Get-Content $MarkerFilePath)))

            Remove-Item $MarkerFilePath -Force

            WriteLog "Marker file '$FileName' loaded and deleted."

            if ($MarkerFileData.Error) {
                throw "$($MarkerFileData.Error.Message)"
            } else {
                if ($MarkerFileData.AdditionalInfo) {
                    WriteLog "Success: $($MarkerFileData.AdditionalInfo)"
                } else {
                    WriteLog "Success!"
                }
            }

            return
        }
    } while ( ($(Get-Date)-$Start).TotalSeconds -lt $TimeoutInSeconds)

    throw "Marker file '$FileName' never appeared."
}

Function GetOperationsInfo {
    $ContainerBuild = @{}
    $ContainerBuild.Name = "ContainerBuild"
    $ContainerBuild.FileExt = "preparedone"

    $ContainerRun = @{}
    $ContainerRun.Name = "ContainerRun"
    $ContainerRun.FileExt = "deploydone"

    $UpdateConfigurations = @{}
    $UpdateConfigurations.Name = "UpdateConfigurations"
    $UpdateConfigurations.FileExt = "configsdone"

    $ContainerRemove = @{}
    $ContainerRemove.Name = "ContainerRemove"
    $ContainerRemove.FileExt = "undeploydone"

    return @($ContainerBuild , $ContainerRun, $UpdateConfigurations, $ContainerRemove)
}

Function StartListener {
    Param (
        [Parameter(Mandatory=$true)][int]$TestPort
    )

    $RunListenerPath = "$PSScriptRoot\..\..\tools\listener\RunListener.ps1"

    Start-Process "powershell.exe" -ArgumentList "-windowstyle hidden ", "-File $RunListenerPath", "-Port $TestPort"

    WriteLog "Started (minimized) Listener on port '$TestPort'."
}

Function StopListener {
    Param (
        [Parameter(Mandatory=$true)][int]$TestPort
    )

    $(Invoke-WebRequest "http://localhost:$TestPort/end" -UseBasicParsing -TimeoutSec 5) | Out-Null
}
