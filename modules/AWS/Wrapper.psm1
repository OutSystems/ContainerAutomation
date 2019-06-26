$ExecutionPath = $ExecutionContext.SessionState.Module.ModuleBase

Import-Module $(Join-Path -Path "$ExecutionPath" -ChildPath "../../utils/Logger.psm1")
Import-Module $(Join-Path -Path "$ExecutionPath" -ChildPath "../../utils/DockerUtils.psm1") -Force

$UnzippedBundlesPath = $(Join-Path -Path $global:ArtefactsBasePath -ChildPath "$($global:UnzippedBundlesFolderName)/")
New-Item -Force -ItemType Directory -Path $UnzippedBundlesPath 2>&1>$null

Function GetRepositoryUri {
    Param (
        [Parameter(Mandatory=$true)][String]$RepositoryName
    )

    $Repository = $(Get-ECRRepository | ForEach-Object { if ($_.RepositoryName.Equals($RepositoryName)) {$_} })

    if (-not $Repository) {
        $Repository = $(New-ECRRepository -RepositoryName $RepositoryName)
    }

    return $Repository.RepositoryUri
}

Function GenerateRepositoryName {
    Param (
        [Parameter(Mandatory=$true)][String]$AppName
    )

    return $AppName.Replace(" ", "_").ToLowerInvariant()
}

Function GetVpcId {
    Param (
        [Parameter(Mandatory=$true)][String]$LoadBalancerArn
    )
    $LoadBalancer = $(Get-ELB2LoadBalancer -LoadBalancerArn $LoadBalancerArn)

    return $LoadBalancer.VpcId
}

Function GetListenerArn {
    Param (
        [Parameter(Mandatory=$true)][String]$LoadBalancerArn
    )

    return $(Get-ELB2Listener -LoadBalancerArn $LoadBalancerArn).ListenerArn
}

Function CreateRule {
    Param (
        [Parameter(Mandatory=$true)][String]$ModuleName,
        [Parameter(Mandatory=$true)][String]$ListenerARN,
        [Parameter(Mandatory=$true)][String]$TargetGroupArn
    )

    $RulesInfo = Get-ELB2Rule -ListenerArn $ListenerARN

    $ModulePattern = "/$($ModuleName)*"

    if (-not $($RulesInfo | ForEach-Object { if ($_.Conditions.Values -and $_.Conditions.Values.Contains($ModulePattern)) { $_ } })) {
        $Action = [Amazon.ElasticLoadBalancingV2.Model.Action]::new()
        $Action.Type = [Amazon.ElasticLoadBalancingV2.ActionTypeEnum]::new("Forward")
        $Action.TargetGroupArn = $TargetGroupArn

        $Condition = [Amazon.ElasticLoadBalancingV2.Model.RuleCondition]::new()
        $Condition.Field = "path-pattern"
        $Condition.Values = $ModulePattern

        New-ELB2Rule    -ListenerArn $ListenerARN `
                        -Action $Action `
                        -Condition $Condition `
                        -Priority $RulesInfo.Count
    }
}

Function GetOrCreateTargetGroup {
    Param (
        [Parameter(Mandatory=$true)][String]$ModuleName
    )

    $TargetGroupName = "tg-$($ModuleName)"
    $TargetGroupName = $TargetGroupName[0..32] -join ""

    $TargetGroupResult = $(Get-ELB2TargetGroup | ForEach-Object { if ($_.TargetGroupName.Equals($TargetGroupName) ) {$_} })

    if (-not $TargetGroupResult) {
        $LoadBalancerArn = $global:AWSLoadBalancerArn

        $VpcID = $(GetVpcId -LoadBalancerArn $LoadBalancerArn)

        $TargetGroupResult = New-ELB2TargetGroup    -HealthCheckIntervalSecond 60 `
                                                    -HealthCheckPath "/$($ModuleName)/_ping.aspx" `
                                                    -HealthCheckTimeoutSecond 30 `
                                                    -HealthyThresholdCount 5 `
                                                    -Name $TargetGroupName `
                                                    -Port 80 `
                                                    -Protocol HTTP `
                                                    -UnhealthyThresholdCount 2 `
                                                    -VpcId $VpcID
    }

    return $TargetGroupResult.TargetGroupArn
}

Function RegisterTaskDefinition {
    Param (
        [Parameter(Mandatory=$true)][String]$ApplicationKey,
        [Parameter(Mandatory=$true)][String]$RemoteRegistry
    )

    if (-not $(Get-ECSTaskDefinitions -FamilyPrefix $ApplicationKey)) {
        $ContainerDefinition = [Amazon.ECS.Model.ContainerDefinition]::new()
        $ContainerDefinition.Cpu = 1024
        $ContainerDefinition.Image = "$($RemoteRegistry):latest"

        $MountPointSecrets = [Amazon.ECS.Model.MountPoint]::new()
        $MountPointSecrets.ContainerPath = $global:ConfigsFolderInContainer
        $MountPointSecrets.SourceVolume = $global:ConfigsFolderName

        $MountPointConfigs = [Amazon.ECS.Model.MountPoint]::new()
        $MountPointConfigs.ContainerPath = $global:SecretsFolderInContainer
        $MountPointConfigs.SourceVolume = $global:SecretsFolderName

        $ContainerDefinition.MountPoints = @($MountPointSecrets, $MountPointConfigs)
        $ContainerDefinition.Name = $ApplicationKey

        $PortMapping = [Amazon.ECS.Model.PortMapping]::new()
        $PortMapping.ContainerPort = 80
        $PortMapping.HostPort = 0

        $ContainerDefinition.PortMappings = $PortMapping 

        $ConfigsVolume = [Amazon.ECS.Model.Volume ]::new()
        $ConfigsVolume.Name = $global:ConfigsFolderName

        $ConfigsPath = [Amazon.ECS.Model.HostVolumeProperties]::new()
        $ConfigsPath.SourcePath = "c:\docker\$($global:ConfigsFolderName)\$ApplicationKey"

        $ConfigsVolume.Host = $ConfigsPath

        $SecretsVolume = [Amazon.ECS.Model.Volume ]::new()
        $SecretsVolume.Name = $global:SecretsFolderName

        $SecretsPath = [Amazon.ECS.Model.HostVolumeProperties]::new()
        $SecretsPath.SourcePath = "c:\docker\$($global:SecretsFolderName)"

        $SecretsVolume.Host = $SecretsPath

        Register-ECSTaskDefinition  -ContainerDefinition $ContainerDefinition `
                                    -Family $ApplicationKey `
                                    -Memory "512"  `
                                    -Volume @($SecretsVolume, $ConfigsVolume)
    }

}

Function CreateOrUpdateService {
    Param (
        [Parameter(Mandatory=$true)][String]$ApplicationKey,
        [Parameter(Mandatory=$true)][String]$TargetGroupArn
    )

    $LaunchType = [Amazon.ECS.LaunchType]::new("EC2")
    $LoadBalancer = [Amazon.ECS.Model.LoadBalancer]::new()
    $LoadBalancer.ContainerName = $ApplicationKey
    $LoadBalancer.ContainerPort = 80
    $LoadBalancer.TargetGroupArn = $TargetGroupArn

    $ClusterName = $global:AWSClusterName

    $Service = Get-ECSService -Cluster $ClusterName -Service $ApplicationKey

    if ($Service.Failures) {
        # New Service
        New-ECSService  -Cluster $ClusterName `
                        -DesiredCount 1 `
                        -HealthCheckGracePeriodSecond 0 `
                        -LaunchType $LaunchType `
                        -LoadBalancer $LoadBalancer `
                        -DeploymentConfiguration_MaximumPercent 200 `
                        -DeploymentConfiguration_MinimumHealthyPercent 50 `
                        -ServiceName $ApplicationKey `
                        -TaskDefinition $ApplicationKey
    } else {
        # Redeploy
        Update-ECSService -Cluster $ClusterName -ForceNewDeployment $true -Service $ApplicationKey
    }

}

Function GetRegion {
    $region = (Invoke-WebRequest http://169.254.169.254/latest/meta-data/placement/availability-zone).Content
    $region = $region.Substring(0, $region.Length - 1)
    return $region
}


Function Wrapper_ContainerBuild {
    Param (
        [Parameter(Mandatory=$true)][Hashtable]$PlatformParameters,
        [Parameter(Mandatory=$true)][Hashtable]$AdditionalParameters
    )

    $AppInfo = $(GetAppInfo -ApplicationName $PlatformParameters.ApplicationName `
                            -ApplicationKey $PlatformParameters.ApplicationKey `
                            -OperationId $PlatformParameters.OperationId `
                            -ModuleNames $PlatformParameters.ModuleNames `
                            -TargetPath $PlatformParameters.TargetPath `
                            -UnzippedBundlesPath $UnzippedBundlesPath)

    $(UnzipContainerBundle  -BundleFilePath $AppInfo.BundleFilePath `
                            -UnzipFolder $AppInfo.UnzippedBundlePath)

    $RepositoryName = $(GenerateRepositoryName -AppName $PlatformParameters.ApplicationName)

    $ImageId = $(BuildDockerImageWithRetries    -RepositoryName $RepositoryName `
                                                -RepositoryTag "latest" `
                                                -Labels @{"ApplicationKey"=$PlatformParameters.ApplicationKey ; "OperationId"=$PlatformParameters.OperationId} `
                                                -DockerfilePath $AppInfo.UnzippedBundlePath `
                                                -PreserveRepositoryName)

    $RemoteRegistry = $(GetRepositoryUri -RepositoryName $RepositoryName)

    $(TagDockerImage    -ImageId $ImageId `
                        -RemoteRegistry $RemoteRegistry `
                        -Tag "latest")

    $(Invoke-Expression -Command (Get-ECRLoginCommand -Region $(GetRegion)).Command) 2>&1>$null

    $(PushDockerImage   -RemoteRegistry $RemoteRegistry `
                        -Tag "latest")
}

Function Wrapper_ContainerRun {
    Param (
        [Parameter(Mandatory=$true)][Hashtable]$PlatformParameters,
        [Parameter(Mandatory=$true)][Hashtable]$AdditionalParameters
    )

    $Result = NewWrapperResult

    try {
        $AppInfo = $(GetAppInfo -ApplicationName $PlatformParameters.ApplicationName `
                                -ApplicationKey $PlatformParameters.ApplicationKey `
                                -OperationId $PlatformParameters.OperationId `
                                -ModuleNames $PlatformParameters.ModuleNames `
                                -TargetPath $PlatformParameters.TargetPath `
                                -UnzippedBundlesPath $UnzippedBundlesPath)

        $BucketName = $global:AWSBucketName

        Write-S3Object  -BucketName $BucketName `
                        -Key "$($global:ConfigsFolderName)/$($PlatformParameters.ApplicationKey)/$($global:UnifiedConfigFile)" `
                        -File "$($PlatformParameters.ConfigPath)\$($PlatformParameters.ApplicationKey)\$($global:UnifiedConfigFile)"

        [String[]]$ModuleNames = $AppInfo.ModuleNames

        $TargetGroupArn = $(GetOrCreateTargetGroup -ModuleName $ModuleNames[0])

        $ListenerARN = $(GetListenerArn -LoadBalancerArn $global:AWSLoadBalancerArn)

        foreach ($ModuleName in $ModuleNames) {
            CreateRule -ModuleName $ModuleName -ListenerARN $ListenerARN -TargetGroupArn $TargetGroupArn 
        }

        $RemoteRegistry = $(GetRepositoryUri -RepositoryName $(GenerateRepositoryName -AppName $PlatformParameters.ApplicationName))

        RegisterTaskDefinition -ApplicationKey $PlatformParameters.ApplicationKey -RemoteRegistry $RemoteRegistry

        CreateOrUpdateService -ApplicationKey $PlatformParameters.ApplicationKey -TargetGroupArn $TargetGroupArn
    } catch {
        $Result.Error = $_
    }

    <# 
    Service will async deploy the app, the app will take about 1-2mins till it responds. 
    Skipping ping attempt, so OutSystems deploy continues gracefully
    for ping to be checked we cannot end this operation till the container is responding. 
    Check logic needs to be implemented
    #>
    $Result.SkipPing = $true
    return $Result
}

Function Wrapper_ContainerRemove {
    Param (
        [Parameter(Mandatory=$true)][Hashtable]$PlatformParameters,
        [Parameter(Mandatory=$true)][Hashtable]$AdditionalParameters
    )

    #Not implemented. necessary to remove, target group, routing rules, and service.
}

Function Wrapper_UpdateConfigurations {
    Param (
        [Parameter(Mandatory=$true)][Hashtable]$PlatformParameters,
        [Parameter(Mandatory=$true)][Hashtable]$AdditionalParameters
    )

    $BucketName = $global:AWSBucketName

    Write-S3Object  -BucketName $BucketName `
                    -Key "$($global:ConfigsFolderName)/$($PlatformParameters.ApplicationKey)/$($global:UnifiedConfigFile)" `
                    -File "$($PlatformParameters.ConfigPath)\$($PlatformParameters.ApplicationKey)\$($global:UnifiedConfigFile)"
}
