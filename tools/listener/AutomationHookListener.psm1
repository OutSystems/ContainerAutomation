$ExecutionPath = $ExecutionContext.SessionState.Module.ModuleBase

Import-Module $(Join-Path -Path "$ExecutionPath" -ChildPath "../../utils/Logger.psm1") -Force
Import-Module $(Join-Path -Path "$ExecutionPath" -ChildPath "../../utils/GeneralUtils.psm1") -Force
Import-Module $(Join-Path -Path "$ExecutionPath" -ChildPath "../../modules/GlobalConstants.psm1") -Force

Function ParseRequestRawURL {
    Param (
        [Parameter(Mandatory=$true)][String]$RequestUrl
    )

    $Result = @{}

    $SplittedText = $RequestUrl.Replace("?", "/?").Split("/")

    $Result.HostingTechnology = $SplittedText[1]
    $Result.MethodName = $SplittedText[2]

    return $Result
}

Function ParseQueryString {
    Param (
        [Parameter(Mandatory=$true)][Collections.Specialized.NameValueCollection]$QueryString
    )

    $AllParameters = New-Object Collections.Specialized.NameValueCollection $QueryString

    $ParsedQueryString = @{}
    $ParsedQueryString.PlatformParameters = @{}

    foreach ($Key in $($global:PlatformParameterKeys).Keys) {
        $ParsedQueryString.PlatformParameters[$Key] = $AllParameters[$Key]

        $AllParameters.Remove($Key)
    }

    $ParsedQueryString.AdditionalParameters = @{}

    foreach ($Key in $AllParameters.AllKeys) {
        $ParsedQueryString.AdditionalParameters[$Key] = $AllParameters[$Key]
    }

    return $ParsedQueryString
}

Function CreateAsyncJob {
    Param (
        [Parameter(Mandatory=$true)][String]$RequestGUID,
        [Parameter(Mandatory=$true)][String][ValidateSet("ContainerBuild", "ContainerRun", "ContainerRemove", "UpdateConfigurations")]$MethodName,
        [Parameter(Mandatory=$true)][Hashtable]$PlatformParameters,
        [Parameter(Mandatory=$true)][Hashtable]$AdditionalParameters,
        [Parameter(Mandatory=$true)][String]$ExecutionPath,
        [Parameter(Mandatory=$true)][String]$HostingTechnology
    )

    # Script Block definition
    $DynamicMethodExecution = {
        Param (
            [Parameter(Mandatory=$true)][String]$BlockRequestGUID,
            [Parameter(Mandatory=$true)][String]$BlockMethodName,
            [Parameter(Mandatory=$true)][Hashtable]$BlockPlatformParameters,
            [Parameter(Mandatory=$true)][Hashtable]$BlockAdditionalParameters,
            [Parameter(Mandatory=$true)][String]$BlockExecutionPath,
            [Parameter(Mandatory=$true)][String]$BlockHostingTechnology,
            [Parameter(Mandatory=$true)][String]$BlockLogFile
        )

        Import-Module $(Join-Path -Path $BlockExecutionPath -ChildPath "../../utils/Logger.psm1") -Force
        Import-Module $(Join-Path -Path $BlockExecutionPath -ChildPath "../../utils/GeneralUtils.psm1") -Force

        $LogPath = Join-Path -Path $BlockExecutionPath -ChildPath "../../logs/$BlockHostingTechnology"
        $LogPrefix = "$($BlockRequestGUID)_$($BlockMethodName)"

        ConfigureLogger -LogFolder $LogPath -LogPrefix $LogPrefix

        # $global:LogFilePath was defined in ConfigureLogger
        $LocalPowerShellLogFile = $global:LogFilePath

        WriteLog -Level "INFO" -Message "[$BlockRequestGUID] > Logging [$BlockMethodName] operation to [ $LocalPowerShellLogFile ]." -LogFile $BlockLogFile

        try {
            Import-Module $(Join-Path -Path $BlockExecutionPath -ChildPath "../../modules/HostingTechnologyModuleLoader.psm1") -Force -ArgumentList $BlockHostingTechnology

            $(&"$BlockMethodName"   -PlatformParameters $BlockPlatformParameters `
                                    -AdditionalParameters $BlockAdditionalParameters)

            WriteLog -Level "INFO" -Message "[$BlockRequestGUID] > [$BlockMethodName] operation finished successfully." -LogFile $BlockLogFile
        } catch {
            WriteLog -Level "FATAL" -Message "[$BlockRequestGUID] > [$BlockMethodName] operation finished with errors: $_ : $($_.ScriptStackTrace)." -LogFile $BlockLogFile
            WriteLog -Level "FATAL" -Message "[$BlockRequestGUID] > Check log [ $LocalPowerShellLogFile ] for more info." -LogFile $BlockLogFile
        }
    }

    $JobInfo = Start-Job    -Init ([ScriptBlock]::Create("Set-Location '$pwd'")) `
                            -ScriptBlock $DynamicMethodExecution `
                            -ArgumentList $RequestGUID, $MethodName, $PlatformParameters, $AdditionalParameters, $ExecutionPath, $HostingTechnology, $global:LogFilePath

    WriteLog -Level "DEBUG" -Message "[$RequestGUID] > Started job with Id [$($JobInfo.Id)]."
}

Function SendResponse {
    Param (
        [Parameter(Mandatory=$true)]$Response,
        [Parameter(Mandatory=$true)][string]$Message
    )

    # Convert the data to UTF8 bytes
    [byte[]]$Buffer = [System.Text.Encoding]::UTF8.GetBytes($Message)

    $Response.ContentType = 'application/json';

    # Set length of response
    $Response.ContentLength64 = $Buffer.length

    # Write response out and close
    $Output = $Response.OutputStream
    $Output.Write($Buffer, 0, $Buffer.length)
    $Output.Close()
}

Function StringifyParameters {
    Param (
        [Parameter(Mandatory=$true)][Hashtable]$Parameters,
        [Parameter()][switch]$DecodeBase64=$false
    )

    $StringifiedParameters = @()

    foreach ($Key in $Parameters.Keys) {
        if ($DecodeBase64) {
            $StringifiedParameters += "$Key : $(ConvertIfFromBase64 -Text $Parameters[$Key])"
        } else {
            $StringifiedParameters += "$Key : $($Parameters[$Key])"
        }
    }

    return $($StringifiedParameters -join " | ")
}

Function AutomationHookListener {
    Param (
        [Parameter(Mandatory=$true)][int]$Port
    )

    $LogFolder = Join-Path -Path $ExecutionPath -ChildPath "../../logs/"
    ConfigureLogger -LogFolder $LogFolder -LogPrefix "listener"

    # Create a Listener on port $Port
    $Listener = New-Object System.Net.HttpListener
    $Listener.Prefixes.Add("http://+:$($Port)/") 

    try {
        $Listener.Start()
    } catch {
        WriteLog -Level "FATAL" -Message "Unable to start ContainerBundleListener: $_"
        return
    }

    WriteLog -Level "INFO" -Message "ContainerBundleListener has started on port '$Port'!"

    # Run until you send a GET Request to /end
    while ($true) {
        $Context = $Listener.GetContext() 

        # Capture the details about the Request
        $Request = $Context.Request

        # Setup a place to deliver a response
        $Response = $Context.Response
        
        $RequestGUID = [guid]::NewGuid()

        WriteLog -Level "DEBUG" -Message "[$RequestGUID] > Received: $($Request.Url.ToString())"

        # Break from loop if GET Request sent to /end
        if ($Request.Url -match '/end$') {
            $Response.StatusCode = 200

            SendResponse    -Response $Response `
                            -Message "Stopped."
            break
        } else {
            $Result = ParseRequestRawURL -RequestUrl $Request.RawUrl

            $HostingTechnology = $Result.HostingTechnology
            $MethodName = $Result.MethodName

            if ($HostingTechnology -and $MethodName) {
                $ParsedQueryString = $(ParseQueryString -QueryString $Request.QueryString)

                $StringifiedPlatformParameters = $(StringifyParameters -Parameters $ParsedQueryString.PlatformParameters -DecodeBase64)
                $StringifiedAdditionalParameters = $(StringifyParameters -Parameters $ParsedQueryString.AdditionalParameters)

                WriteLog -Level "DEBUG" -Message "[$RequestGUID] > Request '$HostingTechnology/$MethodName' has these Platform Parameters -> $StringifiedPlatformParameters and these Additional Parameters -> $StringifiedAdditionalParameters"

                if ($ParsedQueryString.PlatformParameters.Address) {
                    try {
                        $(CreateAsyncJob    -RequestGUID $RequestGUID `
                                            -MethodName $MethodName `
                                            -PlatformParameters $ParsedQueryString.PlatformParameters `
                                            -AdditionalParameters $ParsedQueryString.AdditionalParameters `
                                            -ExecutionPath $ExecutionPath `
                                            -HostingTechnology $HostingTechnology)

                        $Message = "Success"
                    } catch {
                        WriteLog -Level "WARN" -Message $_
                        $Response.StatusCode = 500
                        $Message = "Unexpected request. Format: http://_:$($Port)/<HostingTechnology>/<Operation>?[Parameters]"
                    }
                } else {
                    $Message = "Do nothing, assuming test connection."
                    WriteLog -Level "DEBUG" -Message $Message
                }
            } else {
                $Message = "Do nothing, missing <HostingTechnology> or <Operation>."
                WriteLog -Level "DEBUG" -Message $Message
            }
        }

        SendResponse    -Response $Response `
                        -Message $Message
    }

    #Terminate the listener
    $Listener.Stop()

    WriteLog "ContainerBundleListener has ended!"
}
