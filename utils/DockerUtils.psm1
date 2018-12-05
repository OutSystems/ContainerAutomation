$ExecutionPath = $ExecutionContext.SessionState.Module.ModuleBase

Import-Module $(Join-Path -Path "$ExecutionPath" -ChildPath "Logger.psm1")
Import-Module $(Join-Path -Path "$ExecutionPath" -ChildPath "GeneralUtils.psm1") -Force

Function CheckIfZipIsLikelyADockerBundle {
    Param (
        [Parameter(Mandatory=$true)][String]$DockerBundleFile
    )

    $status = $false

    if (Test-Path -Path $DockerBundleFile) {
        [Reflection.Assembly]::LoadWithPartialName('System.IO.Compression.FileSystem') 2>&1>$null

        $BundleFile = Get-ChildItem $DockerBundleFile

        $status = [IO.Compression.ZipFile]::OpenRead($BundleFile.FullName).Entries.Fullname -contains "Dockerfile"
    } else {
        WriteLog -Level "DEBUG" -Message "Bundle $DockerBundleFile not found. Maybe it was deleted?"
    }

    return $status
}

Function CleanUpLabel {
    Param (
        [Parameter(Mandatory=$true)][String]$Label
    )

    return $($Label -replace ' ', '').ToLowerInvariant()
}

Function CreateFilter {
    Param (
        [Parameter(Mandatory=$true)][Hashtable]$Labels
    )

    [String]$FormattedFilters = ""

    foreach ($Key in $Labels.Keys) {
        if ($Labels[$Key]) {
            $FormattedFilters += " -f `"label=$(CleanUpLabel $Key)=$(CleanUpLabel $Labels[$Key])`""
        } else {
            $FormattedFilters += " -f `"label=$(CleanUpLabel $Key)`""
        }
    }

    return $FormattedFilters
}

Function CreateLabels {
    Param (
        [Parameter(Mandatory=$true)][Hashtable]$Labels
    )

    [String]$FormattedLabels = ""

    foreach ($Key in $Labels.Keys) {
        if ($Labels[$Key]) {
            $FormattedLabels += " --label `"$(CleanUpLabel $Key)=$(CleanUpLabel $Labels[$Key])`""
        } else {
            $FormattedLabels += " --label `"$(CleanUpLabel $Key)`""
        }

    }

    return $FormattedLabels
}

Function CreateVolumeMappings {
    Param (
        [Parameter(Mandatory=$true)][Hashtable]$VolumeMappings
    )

    [String]$FormattedVolumeMappings = ""

    foreach ($Key in $VolumeMappings.Keys) {
        # Spaces in paths fed to docker need to be escaped
        $HostPath = $Key -replace " ", "`` "
        $ContainerPath = $VolumeMappings[$Key] -replace " ", "`` "

        $FormattedVolumeMappings += " -v $($HostPath):$($ContainerPath):ro"
    }

    return $FormattedVolumeMappings
}

Function ExecuteDockerCommand {
    Param (
        [Parameter(Mandatory=$true)][String[]]$ArgumentList,
        [Parameter()][switch]$CanHaveNullResult=$False,
        [Parameter()][switch]$LogOutputResult=$False,
        [Parameter()][switch]$LogCmdBeforeInvoke=$False
    )

    $DockerCmd = "& docker $ArgumentList 2>&1"

    if ($LogCmdBeforeInvoke) {
        WriteLog -Level "DEBUG" -Message "Trying to execute: $DockerCmd"
    }

    $DockerCmdInfo = Invoke-Expression $DockerCmd

    WriteLog -Level "DEBUG" -Message "Executed: $DockerCmd"

    if ($LogOutputResult) {
        WriteLog -Level "DEBUG" -Message "Output:`r`n$($DockerCmdInfo -join "`r`n")"
    }

    if ( ((-not $CanHaveNullResult) -and (-not $DockerCmdInfo)) -or $DockerCmdInfo.Exception ) {
        throw "Tried to do '$DockerCmd'. Output: '$DockerCmdInfo' | Exception: $($DockerCmdInfo.Exception)."
    } 

    return $DockerCmdInfo
}

Function RunDockerCmdOnIds {
    Param (
        [Parameter(Mandatory=$true)][String[]]$Ids,
        [Parameter(Mandatory=$true)][String]$Operation,
        [Parameter(Mandatory=$true)][String]$OperationName
    )

    $SuccessfulOps = @()
    $FailedOps = @()

    foreach ($Id in $Ids) {
        $Result = $(ExecuteDockerCommand -ArgumentList $Operation, $Id)

        if ([String]$Result -eq $Id) {
            $SuccessfulOps += $Id
        } else {
            $FailedOps += $Id
        }
    }

    if ($Ids.Count -eq 0) {
        WriteLog -Level "DEBUG" -Message "No IDs applicable to [$OperationName]!"
    } else {
        if ($SuccessfulOps.Count -gt 0) {
            WriteLog -Level "DEBUG" -Message "Successfully applied [$OperationName] to IDs: $([String]::Join(", ", $SuccessfulOps))."
        }

        if ($FailedOps.Count -gt 0) {
            WriteLog -Level "DEBUG" -Message "Failed to apply [$OperationName] to IDs: $([String]::Join(", ", $FailedOps))."
        }
    }

    return ($Ids.Count -eq $SuccessfulOps.Count)
}

Function GetDockerContainerLogs {
    Param (
        [Parameter(Mandatory=$true)][String]$ContainerId
    )

    try {
        return $(ExecuteDockerCommand "logs", "$ContainerId" -CanHaveNullResult)
    } catch {
        return $_
    }
}

Function DockerImageExists {
    Param (
        [Parameter(Mandatory=$true)][String]$RepositoryName,
        [Parameter(Mandatory=$true)][String]$RepositoryTag
    )

    try {
        return $($null -ne $(ExecuteDockerCommand "image", "inspect", "$($RepositoryName + ":" + $RepositoryTag)"))
    } catch {
        return $False
    }
}

Function BuildDockerImage {
    Param (
        [Parameter(Mandatory=$true)][Hashtable]$Labels,
        [Parameter(Mandatory=$true)][String]$RepositoryName,
        [Parameter(Mandatory=$true)][String]$RepositoryTag,
        [Parameter(Mandatory=$true)][String]$DockerfilePath
    )

    [String]$ImageId = $null

    $SetRepositoryTag = "${RepositoryName}:${RepositoryTag}"
    $SetLabels = $(CreateLabels -Labels $Labels)

    $DockerfilePath = "'$DockerfilePath'"

    $Result = $(ExecuteDockerCommand "build", "-t", $SetRepositoryTag, $SetLabels, $DockerfilePath)

    WriteLog -Level "DEBUG" -Message "docker build completed. Output:`r`n$($Result -join "`r`n")"

    $SuccessMsgPrefix = "Successfully built "

    $SuccessMsg = $Result | Where-Object { $_.StartsWith($SuccessMsgPrefix) }

    if ($SuccessMsg) {
        $ImageId = [String]$SuccessMsg.Replace($SuccessMsgPrefix, "")
    } else {
        throw "Something went wrong when building the container image '$($RepositoryName + ":" + $RepositoryTag)'!"
    }

    return $ImageId
}

Function BuildDockerImageWithRetries {
    Param (
        [Parameter(Mandatory=$true)][String]$RepositoryName,
        [Parameter(Mandatory=$true)][String]$RepositoryTag,
        [Parameter(Mandatory=$true)][Hashtable]$Labels,
        [Parameter(Mandatory=$true)][String]$DockerfilePath,
        [switch]$PreserveRepositoryName=$false
    )

    try {
        if ($(Test-Path $DockerfilePath)) {
            WriteLog -Level "DEBUG" -Message "'$RepositoryName' image is being built."

            if (-not $PreserveRepositoryName) {
                # Docker does not handle names with upper case characters or white spaces
                $RepositoryName = $(ConvertToCanonicalName -Text $RepositoryName)
            }

            return $(RetryWithReturnValue -Action {
                    Param (
                        [Parameter(Mandatory=$true)][Hashtable]$BlockLabels,
                        [Parameter(Mandatory=$true)][String]$BlockRepositoryName,
                        [Parameter(Mandatory=$true)][String]$BlockRepositoryTag,
                        [Parameter(Mandatory=$true)][String]$BlockDockerfilePath
                    )

                    [String]$BlockImageId = $(BuildDockerImage  -Labels $BlockLabels `
                                                                -RepositoryName $BlockRepositoryName `
                                                                -RepositoryTag $BlockRepositoryTag `
                                                                -DockerfilePath $BlockDockerfilePath)

                    WriteLog -Level "DEBUG" -Message "'$BlockRepositoryName' image was successfully built with ID: '$BlockImageId'."

                    return $BlockImageId
                } `
                -ArgumentList $Labels, $RepositoryName, $RepositoryTag, $DockerfilePath `
                -ExceptionMessage "Image object is null: something went terribly wrong."
            )
        } else {
            throw "'$DockerfilePath' does not exist."
        }
    } catch {
        throw "'$RepositoryName' image build failed!: $_"
    }
}

Function TagDockerImage {
    Param (
        [Parameter(Mandatory=$true)][String]$ImageId,
        [Parameter(Mandatory=$true)][String]$RemoteRegistry,
        [Parameter(Mandatory=$true)][String]$Tag
    )

    $SetRepositoryTag = "$($RemoteRegistry):$($Tag)"

    $(ExecuteDockerCommand -ArgumentList "tag", $ImageId, $SetRepositoryTag -CanHaveNullResult)

    WriteLog -Level "DEBUG" -Message "docker tag succeeded"
}

Function PushDockerImage {
    Param (
        [Parameter(Mandatory=$true)][String]$RemoteRegistry,
        [Parameter(Mandatory=$true)][String]$Tag
    )

    $SetRepositoryTag = "$($RemoteRegistry):$($Tag)"

    $Result = $(ExecuteDockerCommand -ArgumentList "push", $SetRepositoryTag)

    WriteLog -Level "DEBUG" -Message "docker push: $($Result -join "`r`n")"
}

Function GetDockerImagesWithLabels {
    Param (
        [Parameter(Mandatory=$true)][Hashtable]$Labels
    )

    $StringifiedLabels = $(ConvertTo-Json $Labels -Compress)

    [String[]]$ImageIds = @()

    $Filter = $(CreateFilter -Labels $Labels)

    $Result = $(ExecuteDockerCommand "image", "ls", $Filter)

    # $Result.GetType().Name -ne "String" checks if the return is not the empty result: "REPOSITORY TAG IMAGE ID CREATED SIZE"
    if ($Result.Length -gt 1 -and $Result.GetType().Name -ne "String") {
        foreach ($Line in ($Result | Select-Object -Skip 1)) {
            $ImageIds += ($Line -split "\s+")[2]
        }
    }

    if ($ImageIds) {
        WriteLog -Level "DEBUG" -Message "Found images with IDs [ $($ImageIds -join ', ') ] for the following labels: [ $StringifiedLabels ]"
    } else {
        WriteLog -Level "DEBUG" -Message "No images were found with labels: [ $StringifiedLabels ]"
    }  

    return $ImageIds
}

Function ForceRemoveDockerImages {
    Param (
        [Parameter(Mandatory=$true)][String[]]$ImageIds
    )

    return $(RunDockerCmdOnIds  -Ids $ImageIds `
                                -Operation "rmi -f" `
                                -OperationName "FORCE_REMOVE_IMAGE")
}

Function ForceRemoveDockerImagesWithLabels {
    Param (
        [Parameter(Mandatory=$true)][Hashtable]$Labels
    )

    [String[]]$ImageIds = $(GetDockerImagesWithLabels -Labels $Labels)

    if ($ImageIds) {
        return $(ForceRemoveDockerImages -ImageIds $ImageIds)
    }

    return -1
}

Function RunDockerContainer {
    Param (
        [Parameter(Mandatory=$true)][String]$ImageId,
        [Parameter(Mandatory=$true)][Hashtable]$Labels,
        [Parameter(Mandatory=$true)][Hashtable]$VolumeMappings,
        [Parameter(Mandatory=$false)][String[]]$ExtraRunParameters
    )

    [String]$ContainerId = $null

    $SetVolumeMappings = $(CreateVolumeMappings -VolumeMappings $VolumeMappings)
    $SetLabels = $(CreateLabels -Labels $Labels)

    $Parameters = @("run", "-dit")
    if ($ExtraRunParameters) {
        $Parameters += $ExtraRunParameters
    }
    $Parameters += @($SetVolumeMappings, $SetLabels, $ImageId)

    $ContainerId = [String]$(ExecuteDockerCommand -ArgumentList $Parameters)

    return $ContainerId
}

Function DockerContainerIsRunning {
    Param (
        [Parameter(Mandatory=$true)][String]$ContainerId
    )

    $IsRunning = $(ExecuteDockerCommand -ArgumentList "inspect", '--format="{{.State.Running}}"', $ContainerId)

    return ($IsRunning -eq "true")
}

Function StartExistingDockerContainer {
    Param (
        [Parameter(Mandatory=$true)][String]$ContainerId
    )

    $(ExecuteDockerCommand -ArgumentList "start", $ContainerId)
}

Function TryToMakeSureThatDockerContainerIsRunning {
    Param (
        [Parameter(Mandatory=$true)][String]$ContainerId
    )

    WriteLog -Level "DEBUG" -Message "Checking if everything is OK with container '$ContainerId'..."

    #Don't forget that the number of retries is multipled by the default nr of retries, as this is inside a RetryWithReturnValue
    $NumTries = 2
    $Try = 1
    $WaitTime = 2

    do {
        WriteLog -Level "DEBUG" -Message "[$($Try)/$NumTries]: Waiting $WaitTime seconds before checking on container '$ContainerId'..."

        Start-Sleep -Seconds $WaitTime

        if (-not $(DockerContainerIsRunning -ContainerId $ContainerId)) {
            WriteLog -Level "DEBUG" -Message "[$($Try)/$NumTries]: 'Container '$ContainerId' did not start! Giving it a push..."

            #  The output of this function needs to be /dev/null'ed or the id will be appended to the outer function's return value
            $(StartExistingDockerContainer -ContainerId $ContainerId) 2>&1>$null
        } else {
            $Try = $NumTries
        }

        $Try++
    } while ($Try -lt $NumTries)

    if (-not $(DockerContainerIsRunning -ContainerId $ContainerId)) {
        $ContainerLogFilePath = Join-Path -Path $global:LogFolder -ChildPath "container-$ContainerId.log"

        Start-Sleep -Seconds 10

        $DockerContainerLogs = $(GetDockerContainerLogs $ContainerId)

        if ($DockerContainerLogs) {
            $DockerContainerLogs = $($DockerContainerLogs -join "`r`n")

            Add-Content $ContainerLogFilePath -Value "`r`n$DockerContainerLogs" -Encoding UTF8

            $Info = "Check '$ContainerLogFilePath' for more info."
        } else {
            $Info = "Unable to retrieve any logs at this point in time."
        }

        throw "Container for '$ContainerId' refused to start! $Info."
    }
}

Function RunDockerContainerWithRetries {
    Param (
        [Parameter(Mandatory=$true)][String]$ImageId,
        [Parameter(Mandatory=$true)][Hashtable]$Labels,
        [Parameter(Mandatory=$true)][Hashtable]$VolumeMappings,
        [Parameter(Mandatory=$false)][String[]]$ExtraRunParameters
    )

    try {
        if ($ImageId) {
            $FullAppName = "[ $(ConvertTo-Json $Labels -Compress) ]"

            WriteLog -Level "DEBUG" -Message "'$FullAppName' is being (fidget) spinned up."

            return $(RetryWithReturnValue -Action {
                    Param ( 
                        [Parameter(Mandatory=$true)][String]$BlockImageId,
                        [Parameter(Mandatory=$true)][String]$BlockFullAppName,
                        [Parameter(Mandatory=$true)][Hashtable]$BlockLabels,
                        [Parameter(Mandatory=$true)][Hashtable]$BlockVolumeMappings,
                        [Parameter(Mandatory=$true)][String[]]$BlockExtraRunParameters
                    )

                    [String]$BlockContainerId = $(RunDockerContainer    -ImageId $BlockImageId `
                                                                        -Labels $BlockLabels `
                                                                        -VolumeMappings $BlockVolumeMappings `
                                                                        -ExtraRunParameters $BlockExtraRunParameters)

                    # We need to check if the container is actually running
                    # The container might exit as soon as it starts due to some transient state
                    $(TryToMakeSureThatDockerContainerIsRunning -ContainerId $BlockContainerId)

                    WriteLog -Level "DEBUG" -Message "Container for '$BlockFullAppName' running with ID: '$BlockContainerId'."

                    if (-not $BlockContainerId) {
                        throw -Level "FATAL" -Message "Unable to create container for '$BlockFullAppName'."
                    }

                    return [String]$BlockContainerId
                } `
                -ArgumentList $ImageId, $FullAppName, $Labels, $VolumeMappings, $ExtraRunParameters `
                -ExceptionMessage "Container object is null." `
                -NRetries 3
            )
        } else {
            throw "We can't proceed, Docker Image object was null or not a Docker image at all!"
        }
    } catch {
        throw "Failed to spin up container for '$FullAppName'!: $_"
    }
}

Function GetDockerContainerInfo {
    Param (
        [Parameter(Mandatory=$true)][String]$ContainerId
    )

    [String]$InfoJSON = $(ExecuteDockerCommand -ArgumentList "inspect", $ContainerId)

    return $(ConvertFrom-Json $InfoJSON)
}

Function GetDockerContainerInfoWithRetries {
    Param (
        [Parameter(Mandatory=$true)][String]$ContainerId
    )

    return $(RetryWithReturnValue -Action {
            Param (
                [Parameter(Mandatory=$true)][String]$BlockContainerId
            )

            if (-not $BlockContainerId) {
                throw "No Container ID"
            }

            $computer = $(hostname)

            $ContainerInfo = $(GetDockerContainerInfo -ContainerId $BlockContainerId)

            if ($ContainerInfo -eq "") {
                throw "No Container Info"
            }

            if ($computer -eq "") {
                throw "No Docker Host Hostname"
            }

            if (-not $ContainerInfo.Image -or $ContainerInfo.Image -eq "") {
                throw "No Parent Image ID"
            }

            if (-not $ContainerInfo.NetworkSettings.Networks.nat -or $ContainerInfo.NetworkSettings.Networks.nat -eq "") {
                throw "No IP"
            }

            if (-not $ContainerInfo.Config.Hostname -or $ContainerInfo.Config.Hostname -eq "") {
                throw "No Hostname"
            }

            if (-not $ContainerInfo.Name -or $ContainerInfo.Name -eq "") {
                throw "No Name"
            }

            return $ContainerInfo
        } `
        -ArgumentList $ContainerId `
        -ExceptionMessage "Could not obtain container info."
    )
}

Function GetDockerContainersWithLabels {
    Param (
        [Parameter(Mandatory=$true)][Hashtable]$Labels,
        [Parameter()][String]$Flags=" ",
        [Parameter()][String]$OperationName=""
    )

    $StringifiedLabels = $(ConvertTo-Json $Labels -Compress)

    WriteLog -Level "DEBUG" -Message "Getting [$OperationName] containers with the following labels: [ $StringifiedLabels ]"

    [String[]]$ContainerIds = @()

    $Filter = $(CreateFilter -Labels $Labels)

    $Result = $(ExecuteDockerCommand -ArgumentList "ps", $Flags, $Filter) | Select-Object -Skip 1

    foreach ($Line in $Result) {
        $ContainerId = [regex]::split($Line, "\s\s+")[0]
        $ContainerIds += $ContainerId
    }

    if ($ContainerIds) {
        WriteLog -Level "DEBUG" -Message "Found [$OperationName] containers with IDs [ $($ContainerIds -join ', ') ] for the following labels: [ $StringifiedLabels ]"
    } else {
        WriteLog -Level "DEBUG" -Message "No containers were found for [$OperationName] with labels: [ $StringifiedLabels ]"
    }

    return $ContainerIds
}

Function GetRunningDockerContainersWithLabels {
    Param (
        [Parameter(Mandatory=$true)][Hashtable]$Labels
    )

    return $(GetDockerContainersWithLabels -Labels $Labels -OperationName "RUNNING")
}

Function GetAllDockerContainersWithLabels {
    Param (
        [Parameter(Mandatory=$true)][Hashtable]$Labels
    )

    return $(GetDockerContainersWithLabels -Labels $Labels -Flags "-a" -OperationName "ALL")
}

Function StopDockerContainers {
    Param (
        [Parameter(Mandatory=$true)][String[]]$ContainerIds
    )

    return $(RunDockerCmdOnIds  -Ids $ContainerIds `
                                -Operation "stop" `
                                -OperationName "STOP_CONTAINER")
}

Function StopDockerContainersWithLabels {
    Param (
        [Parameter(Mandatory=$true)][Hashtable]$Labels
    )

    [String[]]$ContainerIds = $(GetRunningDockerContainersWithLabels -Labels $Labels)

    if ($ContainerIds) {
        return $(StopDockerContainers -ContainerIds $ContainerIds)
    }

    return -1
}

Function ForceRemoveDockerContainers {
    Param (
        [Parameter(Mandatory=$true)][String[]]$ContainerIds
    )

    return $(RunDockerCmdOnIds  -Ids $ContainerIds `
                                -Operation "rm -f" `
                                -OperationName "FORCE_REMOVE_CONTAINER")
}

Function ForceRemoveAllDockerContainersWithLabels {
    Param (
        [Parameter(Mandatory=$true)][Hashtable]$Labels
    )

    [String[]]$ContainerIds = $(GetAllDockerContainersWithLabels -Labels $Labels)

    if ($ContainerIds) {
        return $(ForceRemoveDockerContainers -ContainerIds $ContainerIds)
    }

    return -1
}

Function DockerContainerExists {
    Param (
        [Parameter(Mandatory=$true)][String]$ContainerId
    )

    $ContainerInfo = $(GetDockerContainerInfoWithRetries -ContainerId $ContainerId)

    return (-not $ContainerInfo) -and ($ContainerInfo -notcontains "Error: No such object: $ContainerId")
}
