$ExecutionPath = $ExecutionContext.SessionState.Module.ModuleBase

Import-Module $(Join-Path -Path "$ExecutionPath" -ChildPath "../BaseDockerEEWrapper.psm1") -Force


Function GetExtraContainerRunParameters {
    return @("-P")
}

Function CreateRewriteRulesOnContainerRun {
    Param (
        [Parameter(Mandatory=$true)][Object]$ContainerInfo,
        [Parameter(Mandatory=$true)][Hashtable]$OpInfo,
        [Parameter(Mandatory=$true)][Hashtable]$AdditionalParameters
    )

    $PublishedPort = $ContainerInfo.NetworkSettings.Ports.'80/tcp'.HostPort

    WriteLog "Publishing port '80' to '$PublishedPort'."

    foreach($ModuleName in $OpInfo.AppInfo.ModuleNames) {
        $Location = $(GetNGiNXLocation  -ModuleName $ModuleName `
                                        -PublishedPort $PublishedPort)

        $FilePath = Join-Path -Path "$($env:Temp)" -ChildPath "$($ModuleName).location"

        try {
            New-Item -Path $FilePath -ItemType "file" -Value $Location -Force

            $(DoNGiNXConfigCopy -FilePath $FilePath)
        } catch {
            throw $_
        } finally {
            try {
                Remove-Item -Force $FilePath
            } catch {
                WriteLog -Level "WARN" -Message "Unable to delete file '$FilePath'."
            }
        }
    }

    $(DoNGiNXConfigReload)
}

Function RemoveRewriteRulesOnContainerRemove {
    Param (
        [Parameter(Mandatory=$true)][Hashtable]$OpInfo
    )

    foreach($ModuleName in $OpInfo.AppInfo.ModuleNames) {
        $(DoNGiNXConfigDelete -ModuleName $ModuleName)
    }

    $(DoNGiNXConfigReload)
}

Function GetNGiNXLocation {
    Param (
        [Parameter(Mandatory=$true)][String]$ModuleName,
        [Parameter(Mandatory=$true)][Int]$PublishedPort
    )

    $Domain = (Get-WmiObject Win32_ComputerSystem).Domain
    $Hostname = $($(hostname) + "." + $Domain)

    return "location /$ModuleName/ {
            proxy_pass http://$($Hostname):$PublishedPort/$ModuleName/;
            proxy_set_header HOST `$host;
            proxy_set_header X-Forwarded-Proto `$scheme;
        }"
}

Function DoNGiNXConfigCopy {
    Param (
        [Parameter(Mandatory=$true)][String]$FilePath
    )

    $CopyCommand = "cmd.exe /C $($global:PuTTYPath)\pscp -hostkey $($global:NGiNXHostKey) -pw $($global:NGiNXPassword) $FilePath $($global:NGiNXUser)@$($global:NGiNXFQMN):/etc/nginx/conf.d"
    Invoke-Expression -Command:$CopyCommand
    WriteLog -Level "DEBUG" -Message "Copied location file '$(Split-Path $FilePath -Leaf)' to ($global:NGiNXFQMN)."
}

Function DoNGiNXConfigDelete {
    Param (
        [Parameter(Mandatory=$true)][String]$ModuleName
    )

    $FilePath = "/etc/nginx/conf.d/$ModuleName.location"
    $DeleteCommand = "cmd.exe /C $($global:PuTTYPath)\plink -hostkey $($global:NGiNXHostKey) -ssh $($global:NGiNXUser)@$($global:NGiNXFQMN) -pw $($global:NGiNXPassword) rm -f $FilePath"
    Invoke-Expression -Command:$DeleteCommand
    WriteLog -Level "DEBUG" -Message "Deleted file '$FilePath' from ($global:NGiNXFQMN)."
}

Function DoNGiNXConfigReload {
    $ReloadCommand = "cmd.exe /C $($global:PuTTYPath)\plink -hostkey $($global:NGiNXHostKey) -ssh $($global:NGiNXUser)@$($global:NGiNXFQMN) -pw $($global:NGiNXPassword) sudo /etc/init.d/nginx reload"
    Invoke-Expression -Command:$ReloadCommand
    WriteLog -Level "DEBUG" -Message "NGiNX configuration reloaded!"
}
