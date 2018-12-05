<# 
To debug using Visual Code:
    Use Open Folder to load the project
    Set (in this file) the $HostingTechnology you want to debug
    Call the function you want to debug
    Set up breakpoints as needed
    Start Debugging! (press F5)
#>

# Select the Hosting Technology: needs to exist the implementation in /modules/{HostingTechnology}
$HostingTechnology = "DockerEEPlusIIS"

Import-Module "$PSScriptRoot/../../modules/HostingTechnologyModuleLoader.psm1" -Force -ArgumentList $HostingTechnology

# Set the parameters
$Address = ""
$ApplicationName = ""
$ApplicationKey = ""
$OperationId = ""
$TargetPath = ""
$ResultPath = ""
$ConfigPath = ""
$ModuleNames = ""

$SiteName = ""
$PlatformServerFQMN = ""
$SecretPath = ""

# Call here any of the four main operations: ContainerBuild, ContainerRun, UpdateConfigurations and ContainerRemove
ContainerBuild  -PlatformParameters @{ 
                    Address = $Address ; 
                    ApplicationName = $ApplicationName ; 
                    ApplicationKey = $ApplicationKey ; 
                    OperationId = $OperationId ; 
                    TargetPath = $TargetPath ; 
                    ResultPath = $ResultPath ; 
                    ConfigPath = $ConfigPath ;
                    ModuleNames = $ModuleNames ;
                } `
                -AdditionalParameters @{ 
                    "SiteName" = $SiteName ; 
                    "PlatformServerFQMN" = $PlatformServerFQMN ;
                    "SecretPath" = $SecretPath
                }
