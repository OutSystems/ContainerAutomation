Param (
    [parameter(Mandatory=$true)][String]$HostingTechnology
)

$ErrorActionPreference = "Stop"

$ExecutionPath = $ExecutionContext.SessionState.Module.ModuleBase

if (-not $HostingTechnology) {
    throw "No Hosting Technology was specified!"
}

# The loader will search for the Wrapper and Settings files in the last folder of the modules folder tree
$SettingsForHostingTechnology = (Get-ChildItem "$ExecutionPath" -Recurse | Where-Object { $_.FullName.EndsWith("$HostingTechnology\Settings.psm1") }).FullName
$WrapperForHostingTechnology = (Get-ChildItem "$ExecutionPath" -Recurse | Where-Object { $_.FullName.EndsWith("$HostingTechnology\Wrapper.psm1") }).FullName

if ( (-not (Test-Path $SettingsForHostingTechnology)) -or (-not (Test-Path $WrapperForHostingTechnology)) ) {
    throw "[$HostingTechnology] not correctly configured. Check if the required files (Settings.psm1 and Wrapper.psm1) exist in path '$(Split-Path $SettingsForHostingTechnology -Parent)' and are implementing the correct method signatures."
}

Import-Module $(Join-Path -Path "$ExecutionPath" -ChildPath "GlobalSettings.psm1") -Force
Import-Module $(Join-Path -Path "$ExecutionPath" -ChildPath "GlobalConstants.psm1") -Force
Import-Module $(Join-Path -Path "$ExecutionPath" -ChildPath "DeployUtils.psm1") -Force

Import-Module $(Join-Path -Path "$ExecutionPath" -ChildPath "../utils/Logger.psm1")
Import-Module $(Join-Path -Path "$ExecutionPath" -ChildPath "../utils/GeneralUtils.psm1") -Force

# If $global:ArtefactsBasePath is not configured, default to execution path
if (-not $global:ArtefactsBasePath) {
    $ArtefactsBasePath = "$ExecutionPath/../"
} else {
    $ArtefactsBasePath = $global:ArtefactsBasePath
}

$global:ArtefactsBasePath = $(Join-Path -Path $ArtefactsBasePath -ChildPath "$($global:ArtefactsFolderName)/$HostingTechnology/")
$(New-Item -Force -Path $global:ArtefactsBasePath -ItemType Directory) 2>&1>$null
$global:ArtefactsBasePath = $(Resolve-Path $global:ArtefactsBasePath)

Import-Module $SettingsForHostingTechnology -Force
Import-Module $WrapperForHostingTechnology -Force

WriteLog -Level "DEBUG" -Message "Loaded for Settings: '$SettingsForHostingTechnology'."
WriteLog -Level "DEBUG" -Message "Loaded for Wrapper: '$WrapperForHostingTechnology'."

Function ContainerBuild {
    Param (
        [Parameter(Mandatory=$true)][Hashtable]$PlatformParameters,
        [Parameter(Mandatory=$false)][Hashtable]$AdditionalParameters
    )

    if (-not $AdditionalParameters) {
        $AdditionalParameters = @{}
    }

    ExecOperation   -OperationName "ContainerBuild" `
                    -MarkerFile "PrepareDone" `
                    -PlatformParameters $PlatformParameters `
                    -AdditionalParameters $AdditionalParameters
}

Function CreatePrepareDoneFile {
    Param (
        [Parameter(Mandatory=$true)][String]$ResultPath,
        [Parameter(Mandatory=$true)][String]$ApplicationKey,
        [Parameter(Mandatory=$true)][String]$OperationId,
        [Parameter(Mandatory=$true)][AllowNull()]$WrapperResult
    )

    CreateMarkerFile -ResultPath $ResultPath `
                     -ApplicationKey $ApplicationKey `
                     -OperationId $OperationId `
                     -MarkerFileExtension $global:PrepareDone `
                     -WrapperResult $WrapperResult
}

Function ContainerRun {
    Param (
        [Parameter(Mandatory=$true)][Hashtable]$PlatformParameters,
        [Parameter(Mandatory=$false)][Hashtable]$AdditionalParameters
    )

    if (-not $AdditionalParameters) {
        $AdditionalParameters = @{}
    }

    ExecOperation   -OperationName "ContainerRun" `
                    -MarkerFile "DeployDone" `
                    -PlatformParameters $PlatformParameters `
                    -AdditionalParameters $AdditionalParameters
}

Function CreateDeployDoneFile {
    Param (
        [Parameter(Mandatory=$true)][String]$ResultPath,
        [Parameter(Mandatory=$true)][String]$ApplicationKey,
        [Parameter(Mandatory=$true)][String]$OperationId,
        [Parameter(Mandatory=$true)][AllowNull()]$WrapperResult
    )

    CreateMarkerFile    -ResultPath $ResultPath `
                        -ApplicationKey $ApplicationKey `
                        -OperationId $OperationId `
                        -MarkerFileExtension $global:DeployDone `
                        -WrapperResult $WrapperResult
}

Function ContainerRemove {
    Param (
        [Parameter(Mandatory=$true)][Hashtable]$PlatformParameters,
        [Parameter(Mandatory=$false)][Hashtable]$AdditionalParameters
    )

    if (-not $AdditionalParameters) {
        $AdditionalParameters = @{}
    }

    ExecOperation   -OperationName "ContainerRemove" `
                    -MarkerFile "UndeployDone" `
                    -PlatformParameters $PlatformParameters `
                    -AdditionalParameters $AdditionalParameters
}

Function CreateUndeployDoneFile {
    Param (
        [Parameter(Mandatory=$true)][String]$ResultPath,
        [Parameter(Mandatory=$true)][String]$ApplicationKey,
        [Parameter(Mandatory=$true)][String]$OperationId,
        [Parameter(Mandatory=$true)][AllowNull()]$WrapperResult
    )

    CreateMarkerFile    -ResultPath $ResultPath `
                        -ApplicationKey $ApplicationKey `
                        -OperationId $OperationId `
                        -MarkerFileExtension $global:UndeployDone `
                        -WrapperResult $WrapperResult
}

Function UpdateConfigurations {
    Param (
        [Parameter(Mandatory=$true)][Hashtable]$PlatformParameters,
        [Parameter(Mandatory=$false)][Hashtable]$AdditionalParameters
    )

    if (-not $AdditionalParameters) {
        $AdditionalParameters = @{}
    }

    ExecOperation   -OperationName "UpdateConfigurations" `
                    -MarkerFile "UpdateConfigurations" `
                    -PlatformParameters $PlatformParameters `
                    -AdditionalParameters $AdditionalParameters
}

Function CreateUpdateConfigurationsFile {
    Param (
        [Parameter(Mandatory=$true)][String]$ResultPath,
        [Parameter(Mandatory=$true)][String]$ApplicationKey,
        [Parameter(Mandatory=$true)][String]$OperationId,
        [Parameter(Mandatory=$true)][AllowNull()]$WrapperResult
    )

    CreateMarkerFile    -ResultPath $ResultPath `
                        -ApplicationKey $ApplicationKey `
                        -OperationId $OperationId `
                        -MarkerFileExtension $global:ConfigsDone `
                        -WrapperResult $WrapperResult
}

Function LogResultError {
    Param (
        [Parameter(Mandatory=$true)][String]$OperationName,
        [Parameter(Mandatory=$true)]$Result
    )

    if ($Result.Error) {
        WriteLog -Level "FATAL" -Message "Something went wrong when handling '$OperationName': $($Result.Error | Out-String)"
    }
}

Function StringifyParameters {
    Param (
        [Parameter(Mandatory=$true)][Hashtable]$PlatformParameters,
        [Parameter(Mandatory=$true)][Hashtable]$AdditionalParameters
    )
    
    $StringifiedParameters = ""

    foreach ($Key in $PlatformParameters.Keys) {
        $StringifiedParameters += "-$Key '$($PlatformParameters[$Key])' `` " 
    }

    foreach ($Key in $AdditionalParameters.Keys) { 
        $StringifiedParameters += "-$Key '$($AdditionalParameters[$Key])' `` " 
    }

    return $StringifiedParameters
}


Function CreateMarkerFile {
    Param (
        [Parameter(Mandatory=$true)][String]$ResultPath,
        [Parameter(Mandatory=$true)][String]$ApplicationKey,
        [Parameter(Mandatory=$true)][String]$OperationId,
        [Parameter(Mandatory=$true)][String]$MarkerFileExtension,
        [Parameter(Mandatory=$true)][AllowNull()]$WrapperResult
    )

    $FileName = $(GetAppFullName -ApplicationKey $ApplicationKey -OperationId $OperationId)

    WriteLog -Level "DEBUG" -Message "'$FileName' creating '$MarkerFileExtension' file..."

    if (-not (Test-Path $ResultPath)) {
        $ErrorMessage = "The result path '$ResultPath' is not accessible."

        WriteLog "$ErrorMessage"
        throw $ErrorMessage
    }

    $ResultsFilePath = $(Join-Path -Path $ResultPath -ChildPath $FileName)

    # Apparently Out-File does not create subfolders, so we need to go the other way round
    $(New-Item -Force -Path $($ResultsFilePath + $MarkerFileExtension)) 2>&1>$null

    if (-not $WrapperResult) {
        $WrapperResult = $(NewWrapperResult)
    }

    $MarkerFileData = @{}

    if ($WrapperResult.Error) {
        $ErrorMessage = @{}
        $ErrorMessage.Error = @{}
        $ErrorMessage.Error.Message = "Container Automation: Check the log '$($global:LogFilePath)' for more info."
        $MarkerFileData = $ErrorMessage
    }

    if ($WrapperResult.AdditionalInfo) {
        $MarkerFileData.AdditionalInfo = $WrapperResult.AdditionalInfo
    }

    if ($WrapperResult.SkipPing) {
        $MarkerFileData.SkipPing = $True
    }

    Out-File -Force -FilePath $($ResultsFilePath + $MarkerFileExtension) -InputObject $(ConvertTo-Json $MarkerFileData)

    WriteLog "'$FileName' info is available @ '$($ResultsFilePath + $MarkerFileExtension)'."
}

Function ExecOperation {
    Param (
        [Parameter(Mandatory=$true)][String]$OperationName,
        [Parameter(Mandatory=$true)][String]$MarkerFile,
        [Parameter(Mandatory=$true)][Hashtable]$PlatformParameters,
        [Parameter(Mandatory=$true)][Hashtable]$AdditionalParameters
    )

    $Result = NewWrapperResult

    try {
        foreach ($Key in $($global:PlatformParameterKeys).Keys) {
            $PlatformParameters[$Key] = $(ConvertIfFromBase64 -Text $PlatformParameters[$Key])

            # Checks if a parameter is in JSON format
            if ($global:JsonPlatformParameters[$Key]) {
                $SetToDefault = $false

                # And converts if it has a value.
                if ($PlatformParameters[$Key]) {
                    try {
                        $PlatformParameters[$Key] = $(ConvertFrom-Json -InputObject $PlatformParameters[$Key])
                    } catch {
                        WriteLog -Level "DEBUG" -Message "Unable to parse expected JSON platform parameter. Defaulting to empty. Expected Type: '$($global:JsonPlatformParameters[$Key])' | Key: '$Key' | Value: '$($PlatformParameters[$Key])'."
                        $SetToDefault = $true
                    }
                } else {
                    WriteLog -Level "DEBUG" -Message "Expected JSON platform parameter is empty. Using retro-compatibility mode (i.e. empty representation for the corresponding type)."
                    $SetToDefault = $true
                }

                if ($SetToDefault) {
                    # This exists for retro-compatibility reasons
                    # If a new platform parameter is added and has a specific type
                    # we can default here to the "empty" representation of that type.
                    switch ($global:JsonPlatformParameters[$Key]) {
                        "Array" { $PlatformParameters[$Key] = @() }
                        "Dictionary" { $PlatformParameters[$Key] = @{} }
                        default { $PlatformParameters[$Key] = "" }
                    }
                }
            }
        }

        <# 
        Note: 
            We could shortcut by doing the following operation in the previous foreach:
               Set-Variable -Name $Key -Value $PlatformParameters[$Key]
            However, lets explicitly define the required parameters for this part of the process
        #>
        $ApplicationName = $PlatformParameters.ApplicationName
        $ApplicationKey = $PlatformParameters.ApplicationKey
        $OperationId = $PlatformParameters.OperationId
        $ResultPath = $PlatformParameters.ResultPath

        WriteLog "Starting [$OperationName] for app '$ApplicationName' ($($ApplicationKey)_$($OperationId))."

        $StringifiedParameters = $(StringifyParameters  -PlatformParameters $PlatformParameters `
                                                        -AdditionalParameters $AdditionalParameters)

        WriteLog -Level "DEBUG" -Message "Parameters: $StringifiedParameters"

        # The functions for each of the operations will be defined in a given module's Wrapper.psm1
        $OperationResult = $(&"Wrapper_$OperationName"  -PlatformParameters $PlatformParameters `
                                                        -AdditionalParameters $AdditionalParameters)

        if ($OperationResult -and ($OperationResult.Error -or $OperationResult.SkipPing)) {
            $Result = $OperationResult
        } else {
            $Result.AdditionalInfo = "Everything went well. Check [ $($global:LogFilePath) ] for more info."
        }

    } catch {
        $Result.Error = "Something went critically wrong: $_ : $($_.ScriptStackTrace)"

        throw $_
    } finally {
        if ($AdditionalParameters.SkipPing) {
            $Result.SkipPing = $true
        }

        $(&"Create$($MarkerFile)File"   -ResultPath $ResultPath `
                                        -ApplicationKey $ApplicationKey `
                                        -OperationId $OperationId `
                                        -WrapperResult $Result)

        LogResultError  -OperationName $OperationName `
                        -Result $Result

        $Message = "[$OperationName] for app '$ApplicationName' ($($ApplicationKey)_$($OperationId)) finished"

        if (-not ($Result.Error)) {
            WriteLog "$Message successfully."
        } else {
            WriteLog "$Message unsuccessfully."
        }
    }
}
