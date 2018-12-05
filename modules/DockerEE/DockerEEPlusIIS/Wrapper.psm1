$ExecutionPath = $ExecutionContext.SessionState.Module.ModuleBase

Import-Module $(Join-Path -Path "$ExecutionPath" -ChildPath "../BaseDockerEEWrapper.psm1") -Force


Function GetExtraContainerRunParameters {}

Function CreateRewriteRulesOnContainerRun {
    Param (
        [Parameter(Mandatory=$true)][Object]$ContainerInfo,
        [Parameter(Mandatory=$true)][Hashtable]$OpInfo,
        [Parameter(Mandatory=$true)][Hashtable]$AdditionalParameters
    )

    $SiteName = $(DetermineSiteName -SiteName $OpInfo.SiteName)

    $(CreateSiteForWildcard -SiteName $SiteName `
                            -SiteFolderPath $OpInfo.FilePaths.SiteFolderPath)

    # $ContainerInfo.Config.Hostname is not working on Windows Server Core, using IPAddress
    $ContainerHostname = $ContainerInfo.NetworkSettings.Networks.nat.IPAddress

    $(AddReroutingRules -SiteName $SiteName `
                        -TargetHostName $ContainerHostname `
                        -Paths $OpInfo.AppInfo.ModuleNames)

    $CreatedDefaultRewriteRule = $false

    if ($AdditionalParameters.PlatformServerFQMN) {
        $ResolveDnsInfo = $(Resolve-DnsName $AdditionalParameters.PlatformServerFQMN) 2>$null

        if ($ResolveDnsInfo) {
            AddDefaultRewriteRule   -SiteName $SiteName `
                                    -TargetHostName $AdditionalParameters.PlatformServerFQMN

            $CreatedDefaultRewriteRule = $true
        } else {
            $ErrorMessage = "Could not resolve '$($AdditionalParameters.PlatformServerFQMN)'!"
        }
    } else {
        $ErrorMessage = "PlatformServerFQMN is empty!"
    }

    if (-not $CreatedDefaultRewriteRule) {
        WriteLog -Level "WARN" -Message "$ErrorMessage No URL Rewrite Inbound Rule to add rerouting back to target host name was created! Any references your app has to modules living in Classical VMs will be broken!"
    }
}

Function RemoveRewriteRulesOnContainerRemove {
    Param (
        [Parameter(Mandatory=$true)][Hashtable]$OpInfo
    )

    $SiteName = $(DetermineSiteName -SiteName $OpInfo.SiteName)

    $(RemoveReroutingRules  -SiteName $(DetermineSiteName $SiteName) `
                            -Paths $OpInfo.AppInfo.ModuleNames)
    
    WriteLog "Rewrite Rules for '$($OpInfo.AppInfo.ApplicationName)' were removed."
}

Function DetermineSiteName {
    Param (
        [Parameter(Mandatory=$false)][String]$SiteName
    )

    # if nothing or default, it's the "Default Web Site"
    if ( (-not $SiteName) -or ($SiteName -eq "default") ) {
        $SiteName = ""
    }

    return $SiteName
}
