node {
    psScript = """
    Import-Module C:/jenkins/modules/HostingTechnologyModuleLoader.psm1 -ArgumentList 'DockerEEPlusIIS' -Force

    if ('${params.Address}' -ne '') {
        ContainerRun            -PlatformParameters @{ 
                                    Address = '${params.Address}' ; 
                                    ApplicationName = '${params.ApplicationName}' ; 
                                    ApplicationKey = '${params.ApplicationKey}' ; 
                                    OperationId = '${params.OperationId}' ; 
                                    TargetPath = '${params.TargetPath}' ; 
                                    ResultPath = '${params.ResultPath}' ; 
                                    ConfigPath = '${params.ConfigPath}' ;
                                    ModuleNames = '${params.ModuleNames}' ;
                                } `
                                -AdditionalParameters @{ 
                                    'SecretPath'='${params.SecretPath}' ; 
                                    'PlatformServerFQMN'='${params.PlatformServerFQMN}' 
                                }
    }
    """

    powershell(returnStdout: true, script: psScript)
}
