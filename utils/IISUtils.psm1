$ExecutionPath = $ExecutionContext.SessionState.Module.ModuleBase

Import-Module WebAdministration
Import-Module $(Join-Path -Path "$ExecutionPath" -ChildPath "Logger.psm1")
Import-Module $(Join-Path -Path "$ExecutionPath" -ChildPath "GeneralUtils.psm1") -Force

Function CreateSiteForWildcard {
    Param (
        [Parameter(Mandatory=$false)][String]$SiteName,
        [Parameter(Mandatory=$true)][String]$SiteFolderPath,
        [Parameter(Mandatory=$false)][String]$Domain
    )

    try {
        Import-Module IISAdministration

        $SiteName = $(EnsureSiteNameSanity -SiteName $SiteName)

        if (-not $(Get-IISSite -Name $SiteName)) {
            if (-not $Domain) {
                $Domain = (Get-WmiObject Win32_ComputerSystem).Domain
            }

            $Hostname = $($(hostname) + "." + $Domain)

            New-Item -Force -Path $SiteFolderPath -Type Directory

            Reset-IISServerManager -Confirm:$False
            $Manager = Get-IISServerManager

            $NewSite = $Manager.Sites.Add($SiteName, "http", "*:80:$SiteName.$Hostname", $SiteFolderPath)
            $NewSite.Bindings.Add("*:443:$SiteName.$Hostname", "https")

            $Manager.CommitChanges()

            if ((Get-IISSite -Name $SiteName).State -ne "Started") {
                Start-IISSite -Name $SiteName

                WriteLog -Level "DEBUG" -Message "Started '$SiteName' website (was not started after creation)."
            }

            WriteLog "Created '$SiteName' website."
        } else {
            WriteLog -Level "DEBUG" -Message "Website '$SiteName' already exists. Nothing was done."
        }
    } finally {
        Remove-Module IISAdministration
    }
}

Function AddToAllowedServerVariables {
    Param (
        [Parameter(Mandatory=$false)][String]$SiteName,
        [Parameter(Mandatory=$true)][String]$VariableName
    )

    $SiteName = $(EnsureSiteNameSanity -SiteName $SiteName)

    $Site = "iis:\sites\$SiteName"
    $FilterRoot = "/system.webServer/rewrite/allowedServerVariables"

    if ($null -eq ((Get-WebConfigurationProperty -PSPath $Site -Filter $FilterRoot -Name ".").Collection | Where-Object name -eq $VariableName)) {
        Set-WebConfiguration -Filter $FilterRoot -Location "$SiteName" -Value (@{name="$VariableName"})

        WriteLog "Added '$VariableName' allowed server variable to '$SiteName' website."
    } else {
        WriteLog -Level "DEBUG" -Message "Website '$SiteName' already has configured the '$VariableName' allowed server variable. Nothing was done."
    }
}

Function AddDefaultRewriteRule {
    Param (
        [Parameter(Mandatory=$false)][String]$SiteName,
        [Parameter(Mandatory=$true)][String]$TargetHostname
    )

    $SiteName = $(EnsureSiteNameSanity -SiteName $SiteName)

    $RuleName = "RewriteToSelf"

    $Site="iis:\sites\$SiteName"

    WriteLog -Level "DEBUG" -Message "Creating default rewrite inbound rule in '$SiteName' website to have reroute all unconfigured paths to a target host name ('$TargetHostname')."

    $FilterRewriteRules = "system.webServer/rewrite/rules"
    $FilterRoot = "$FilterRewriteRules/rule[@name='$RuleName']"

    Start-WebCommitDelay

    Clear-WebConfiguration -PSPath $Site -Filter $FilterRoot

    Stop-WebCommitDelay

    Start-WebCommitDelay

    Add-WebConfigurationProperty -PSPath $Site -Filter "$FilterRewriteRules" -Name "." -Value @{name=$RuleName; stopProcessing='True'}
    Set-WebConfigurationProperty -PSPath $Site -Filter "$FilterRoot/match" -Name "url" -Value "(.*)"
    Set-WebConfigurationProperty -PSPath $Site -Filter "$FilterRoot/action" -Name "type" -Value "Rewrite"
    Set-WebConfigurationProperty -PSPath $Site -Filter "$FilterRoot/action" -Name "url" -Value "https://$TargetHostname/{R:1}"

    Stop-WebCommitDelay
}

Function AddProxyHeaderInboundRule {
    Param (
        [Parameter(Mandatory=$false)][String]$SiteName,
        [Parameter(Mandatory=$true)][ValidateSet('Https', 'Http')][String]$Proto,
        [Parameter(Mandatory=$true)][String]$AtIndex
    )

    $SiteName = $(EnsureSiteNameSanity -SiteName $SiteName)

    $RuleName = "AddProxyHeaders" + $Proto

    $Site="iis:\sites\$SiteName"

    WriteLog -Level "DEBUG" -Message "Creating URL Rewrite Inbound Rule for '$Proto' offloading headers in '$SiteName' website."

    $FilterRewriteRules = "system.webServer/rewrite/rules"

    $FilterRoot = "$FilterRewriteRules/rule[@name='$RuleName']"

    Clear-WebConfiguration -PSPath $Site -Filter $FilterRoot

    $HttpsState = if ($Proto -eq "Https") { "ON" } else { "OFF" }
    Add-WebConfigurationProperty -PSPath $Site -Filter "$FilterRewriteRules" -Name "." -Value @{name=$RuleName; stopProcessing='False'} -AtIndex $AtIndex
    Set-WebConfigurationProperty -PSPath $Site -Filter "$FilterRoot/match" -Name "url" -Value "(.*)"
    Set-WebConfigurationProperty -PSPath $Site -Filter "$FilterRoot/action" -Name "type" -Value "None"
    Set-WebConfigurationProperty -PSPath $Site -Filter "$FilterRoot/conditions" -Name "." -Value @{logicalGrouping="MatchAll";trackAllCaptures="false"}
    Set-WebConfiguration -PSPath $Site -Filter "$FilterRoot/conditions" -Value @{input="{HTTPS}";pattern=$HttpsState}
    Set-WebConfiguration -PSPath $Site -Filter "$FilterRoot/serverVariables" -Value (@{name="HTTP_X_FORWARDED_PROTO";value=$Proto.ToLowerInvariant()})
}

Function AddURLRewriteInboundRule {
    Param (
        [Parameter(Mandatory=$false)][String]$SiteName,
        [Parameter(Mandatory=$true)][String]$TargetHostName,
        [Parameter(Mandatory=$true)][String]$Path
    )

    $SiteName = $(EnsureSiteNameSanity -SiteName $SiteName)

    $MatchString = $Path
    $RuleName = $Path

    $Site="iis:\sites\$SiteName"

    WriteLog -Level "DEBUG" -Message "Creating URL Rewrite Inbound Rule for '$MatchString' in '$SiteName' website."

    $FilterRewriteRules = "system.webServer/rewrite/rules"
    $FilterRoot = "$FilterRewriteRules/rule[@name='$RuleName']"

    Start-WebCommitDelay

    Clear-WebConfiguration -PSPath $Site -Filter $FilterRoot

    Stop-WebCommitDelay

    Start-WebCommitDelay

    Add-WebConfigurationProperty -PSPath $Site -Filter "$FilterRewriteRules" -Name "." -Value @{name=$RuleName;patternSyntax='Regular Expressions';stopProcessing='True'}
    Set-WebConfigurationProperty -PSPath $Site -Filter "$FilterRoot/match" -Name "url" -Value "^$MatchString/(.*)"
    Set-WebConfigurationProperty -PSPath $Site -Filter "$FilterRoot/conditions" -Name "logicalGrouping" -Value "MatchAny"
    Set-WebConfigurationProperty -PSPath $Site -Filter "$FilterRoot/action" -Name "type" -Value "Rewrite"
    Set-WebConfigurationProperty -PSPath $Site -Filter "$FilterRoot/action" -Name "url" -Value "http://${TargetHostName}/$Path/{R:1}"

    Stop-WebCommitDelay
}

Function RemoveURLRewriteInboundRule {
    Param (
        [Parameter(Mandatory=$false)][String]$SiteName,
        [Parameter(Mandatory=$true)][String]$RuleName
    )

    $SiteName = $(EnsureSiteNameSanity -SiteName $SiteName)

    WriteLog -Level "DEBUG" -Message "Removing URL Rewrite Inbound Rule with name '$RuleName' from '$SiteName' website."

    $Site = "iis:\sites\$SiteName"

    $FilterRoot = "system.webServer/rewrite/rules/rule[@name='$RuleName']"

    Start-WebCommitDelay

    Clear-WebConfiguration -PSPath $Site -Filter $FilterRoot

    Stop-WebCommitDelay
}

Function GetURLRewriteInboundRule {
    Param (
        [Parameter(Mandatory=$false)][String]$SiteName,
        [Parameter(Mandatory=$true)][String]$RuleName
    )

    $SiteName = $(EnsureSiteNameSanity -SiteName $SiteName)

    $Site = "iis:\sites\$SiteName"

    $FilterRoot = "system.webServer/rewrite/rules/rule[@name='$RuleName']"

    Start-WebCommitDelay

    Get-WebConfigurationProperty -PSPath $Site -Filter $FilterRoot -Name "."

    Start-WebCommitDelay
}

Function CheckIfRewriteRulesCanBeRemoved {
    Param (
        [Parameter(Mandatory=$false)][String]$SiteName,
        [Parameter(Mandatory=$true)][String]$TargetHostName,
        [Parameter(Mandatory=$true)][String[]]$Paths
    )

    $SiteName = $(EnsureSiteNameSanity -SiteName $SiteName)

    foreach ($Path in $Paths) {
        $RewriteURL = $(GetURLRewriteInboundRule -SiteName $SiteName -RuleName $Path)

        if ($RewriteURL -and $RewriteURL.action.url.Contains("http://$TargetHostName/")) {
            continue
        } else {
            return $false
        }
    }

    return $true
}

Function AddReroutingRules {
    Param (
        [Parameter(Mandatory=$false)][String]$SiteName,
        [Parameter(Mandatory=$true)][String]$TargetHostName,
        [Parameter(Mandatory=$true)][String[]]$Paths
    )

    $SiteName = $(EnsureSiteNameSanity -SiteName $SiteName)

    AddToAllowedServerVariables -SiteName $SiteName -VariableName "HTTP_X_FORWARDED_PROTO"

    AddProxyHeaderInboundRule -SiteName $SiteName -Proto "Https" -AtIndex 0
    AddProxyHeaderInboundRule -SiteName $SiteName -Proto "Http" -AtIndex 1

    foreach ($Path in $Paths) {
        AddURLRewriteInboundRule    -SiteName $SiteName `
                                    -TargetHostName $TargetHostName `
                                    -Path $Path
    }
}

Function RemoveReroutingRules {
    Param (
        [Parameter(Mandatory=$false)][String]$SiteName,
        [Parameter(Mandatory=$true)][String[]]$Paths
    )

    $SiteName = $(EnsureSiteNameSanity -SiteName $SiteName)

    RemoveURLRewriteInboundRule -SiteName $SiteName `
                                -RuleName "AddProxyHeadersHttps"

    RemoveURLRewriteInboundRule -SiteName $SiteName `
                                -RuleName "AddProxyHeadersHttp"

    foreach ($Path in $Paths) {
        $RuleName = $Path

        RemoveURLRewriteInboundRule -SiteName $SiteName `
                                    -RuleName $RuleName
    }
}

Function EnsureSiteNameSanity {
    Param (
        [Parameter(Mandatory=$false)][String]$SiteName
    )

    if (-not $SiteName) {
        $SiteName = "Default Web Site"
    }

    return $SiteName
}
