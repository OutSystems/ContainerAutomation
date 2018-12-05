Import-Module "$PSScriptRoot/utils/TestUtils.psm1" -Force

Import-Module "$PSScriptRoot/../utils/Logger.psm1" -Force
Import-Module "$PSScriptRoot/../utils/DockerUtils.psm1" -Force

$ErrorActionPreference = "Stop"

ConfigureLogger -LogFolder "$PSScriptRoot\generated" -LogPrefix "FullContainerLifecycleTest"

$ContainerAutomationMachine = "localhost"
$TestPort = 20000

StartListener -TestPort $TestPort

 $HostingTechnology = "DockerEEPlusIIS"

# Only working for DockerEEPlusIIS
$CheckPing = $True

$SiteName = ""

$DeploymentZoneAddress = "localhost"

$BasePath = "$PSScriptRoot\generated\$HostingTechnology\$SiteName"
$TargetPath = "$BasePath\bundles"
$ResultPath = "$BasePath\results"
$ConfigPath = "$BasePath\configs"
$SecretPath = "$BasePath\secrets"

foreach ($Path in @($TargetPath, $ResultPath, $ConfigPath, $SecretPath)) {
    $(New-Item -Force -Path $Path -ItemType Directory) 2>&1>$null
}

$BundleInfo = $(GenerateTestBundle  -OriginPath "$PSScriptRoot\resources\FullContainerLifecycleTest\*" `
                                    -TargetPath $TargetPath)

try {
    Start-Sleep 3

    $Success = $True

    foreach ($Operation in (GetOperationsInfo)) {
        $Start = Get-Date
        
        $OperationId = $BundleInfo.OperationId

        if ($Operation.Name -eq "ContainerRemove") {
            $OperationId = [guid]::NewGuid()
        }

        $(CallHook  -ContainerAutomationMachine $ContainerAutomationMachine `
                    -Port $TestPort `
                    -HostingTechnology $HostingTechnology `
                    -OperationName $Operation.Name `
                    -DeploymentZoneAddress $DeploymentZoneAddress `
                    -PlatformServerFQMN "localhost" `
                    -ApplicationName $BundleInfo.ApplicationName `
                    -ApplicationKey $BundleInfo.ApplicationKey `
                    -OperationId $OperationId `
                    -SiteName $SiteName `
                    -TargetPath $TargetPath `
                    -ResultPath $ResultPath `
                    -ConfigPath $ConfigPath `
                    -SecretPath $SecretPath)

        $(WaitForFile   -ResultPath $ResultPath `
                        -ApplicationKey $BundleInfo.ApplicationKey `
                        -OperationId $OperationId `
                        -FileExt $Operation.FileExt)

        if ( $CheckPing -and ($Operation.Name -eq "ContainerRun") ) {

            $ModuleNamesAndStatuses = @{}
            $ModuleNamesAndStatuses.m1 = $true
            $ModuleNamesAndStatuses.m2 = $true
            $ModuleNamesAndStatuses.m3 = $false
            
            $(CheckPing -DeploymentZoneAddress $DeploymentZoneAddress `
                        -ModuleNamesAndStatuses $ModuleNamesAndStatuses)
        }

        $End = Get-Date

        WriteLog "[$($Operation.Name)] took: $($($End-$Start).TotalSeconds) seconds.`n"
    }
} catch {
    $Success = $false
    WriteLog -Level "FATAL" -Message "Something went wrong: $_ : $($_.ScriptStackTrace)"
} finally {
    if (-not $KeepArtefacts) {
        $LabelsForAllAppVersions = @{}
        $LabelsForAllAppVersions.ApplicationName = $BundleInfo.ApplicationName
        $LabelsForAllAppVersions.ApplicationKey = $BundleInfo.ApplicationKey
        $LabelsForAllAppVersions.OperationId = $BundleInfo.OperationId

        $(ForceRemoveAllDockerContainersWithLabels -Labels $LabelsForAllAppVersions) | Out-Null
        $(ForceRemoveDockerImagesWithLabels -Labels $LabelsForAllAppVersions) | Out-Null

        foreach ($Path in @($TargetPath, $ResultPath, $ConfigPath, $SecretPath, $BasePath)) {
            try {
                if (Test-Path $Path) {
                    Remove-Item $Path -Recurse -Force
                }
            } catch {
                WriteLog "Unable do delete '$Path'. Moving on."
            }
        }

        WriteLog "Cleaned up generated folder '$BasePath/*'."
    }

    StopListener -TestPort $TestPort
}

if ($Success) {
    WriteLog "All tests completed successfully."
} else {
    WriteLog "Failure."
}
