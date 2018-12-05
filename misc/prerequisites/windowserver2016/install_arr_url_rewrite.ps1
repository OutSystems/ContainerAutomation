Function InstallARRAndURLRewrite {
    $CurrentLocation = Get-Location
    
    $MSIName = "/WebPlatformInstaller_amd64_en-US.msi"

    $WebPlatformInstallerURL = "http://download.microsoft.com/download/C/F/F/CFF3A0B8-99D4-41A2-AE1A-496C08BEB904/$MSIName"

    $TempFolder = "$env:TEMP/InstallARRAndURLRewrite"

    $MSIFullPath = Join-Path -Path $TempFolder -ChildPath $MSIName
    $LogFullPath = Join-Path -Path $TempFolder -ChildPath "WebpiCmd.log"

    $WebPlatformInstallerPath = "C:/Program Files/Microsoft/Web Platform Installer"
    
    New-Item $TempFolder -Type Directory

    Invoke-WebRequest $WebPlatformInstallerURL -OutFile $MSIFullPath
    Start-Process $MSIFullPath '/qn' -PassThru | Wait-Process
    Set-Location $WebPlatformInstallerPath; .\WebpiCmd.exe /Install /Products:'UrlRewrite2,ARRv3_0' /AcceptEULA /Log:$LogFullPath
    
    Remove-Item -Recurse $TempFolder

    Set-Location $CurrentLocation
}

Function ActivateARR {

    Import-Module IISAdministration

    $manager = Get-IISServerManager
    $sectionGroupConfig = $manager.GetApplicationHostConfiguration()

    $sectionName = 'proxy';

    $webserver = $sectionGroupConfig.RootSectionGroup.SectionGroups['system.webServer']

    if (!$webserver.Sections[$sectionName]) {
        $proxySection = $webserver.Sections.Add($sectionName)
        $proxySection.OverrideModeDefault = "Deny"
        $proxySection.AllowDefinition="AppHostOnly"
        $manager.CommitChanges()

        Write-Host "Commited Section Group"
    }

    $manager = Get-IISServerManager
    $config = $manager.GetApplicationHostConfiguration()
    $section = $config.GetSection('system.webServer/' + $sectionName)
    $section.SetAttributeValue('enabled', 'true')
    # Required by the platform to build proper redirect URL when it is behind a proxy
    $section.SetAttributeValue('preserveHostHeader', 'true')
    # Disabling this because the platform already writes the correct location header
    $section.SetAttributeValue('reverseRewriteHostInResponseHeaders', 'false')
    $manager.CommitChanges()

    Write-Host "Commited Section"
}

InstallARRAndURLRewrite
ActivateARR
