# all logging settins are here on top
if (-not $global:LogFolder) {
    $global:LogFolder = "."
}

if (-not $global:LogPrefix) {
    $global:LogPrefix = ""
}

if (-not $global:LogName) {
    $global:LogName = "$($global:LogPrefix)$($env:computername.ToLower())-$($pid).log"
}

if (-not $global:LogFilePath) {
    $global:LogFilePath = $(Join-Path -Path $global:LogFolder -ChildPath $global:LogName)
}

$global:LogLevel = "DEBUG" # ("DEBUG","INFO","WARN","ERROR","FATAL")
$global:LogSize = 1mb # 30kb
$global:LogCount = 10
# end of settings

Function ConfigureLogger {
    Param (
        [Parameter(Mandatory=$True)][String]$LogFolder,
        [Parameter(Mandatory=$True)][String]$LogPrefix,
        [Parameter(Mandatory=$False)][String]$LogName
    )

    $global:LogFolder = $LogFolder
    $global:LogPrefix = $LogPrefix

    if ($LogName) {
        if (-not $LogName.EndsWith(".log")) {
            $LogName += ".log"
        }

        $global:LogName = $LogName
    }

    if (-not $global:LogPrefix.EndsWith("-")) {
        $global:LogPrefix += "-"
    }

    if (-not $(Test-Path $global:LogFolder)) {
        $(New-Item -Force -Path $global:LogFolder -ItemType Directory) 2>&1>$null
    }

    $global:LogFolder = Resolve-Path $global:LogFolder

    $global:LogFilePath = $(Join-Path -Path $global:LogFolder -ChildPath "$($global:LogPrefix)$($global:LogName)")
}

Function WriteLogLine {
    Param (
        [Parameter(Mandatory=$True)][String]$Line,
        [Parameter(Mandatory=$False)][String]$LogFile
    )

    if (-not $LogFile) {
        $LogFile = $global:LogFilePath
    }

    Add-Content $LogFile -Value $Line -Encoding UTF8
    Write-Host $Line
}

# http://stackoverflow.com/a/38738942
Function WriteLog {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory=$True)][String]$Message,
        [Parameter(Mandatory=$False)][String]$Level = "INFO",
        [Parameter(Mandatory=$False)][String]$LogFile
    )

    $levels = ("DEBUG","INFO","WARN","ERROR","FATAL")
    $LogLevelPos = [array]::IndexOf($levels, $global:LogLevel)
    $levelPos = [array]::IndexOf($levels, $Level)
    #$Stamp = (Get-Date).toString("yyyy/MM/dd HH:mm:ss:fff")
    $Stamp = $(Get-Date -Format o)

    if ($LogLevelPos -lt 0) {
        WriteLogLine "$Stamp [ERROR] Wrong LogLevel configuration [$Level]"
    }

    if ($levelPos -lt 0) {
        WriteLogLine "$Stamp [ERROR] Wrong log level parameter [$Level]"
    }

    # if level parameter is wrong or configuration is wrong I still want to see the 
    # message in log
    if ($levelPos -lt $LogLevelPos -and $levelPos -ge 0 -and $LogLevelPos -ge 0){
        return
    }

    $Line = "[$Stamp] [$Level]: $Message"
    WriteLogLine $Line $LogFile
}

# https://gallery.technet.microsoft.com/scriptcenter/PowerShell-Script-to-Roll-a96ec7d4
function ResetLog {
    # function checks to see if file in question is larger than the paramater specified 
    # if it is it will roll a log and delete the oldes log if there are more than x logs. 
    Param (
        [String]$FileName, 
        [int64]$Filesize = 1mb , 
        [int] $LogCount = 5
    )

    $logRollStatus = $true

    if(test-path $FileName) {
        $file = Get-ChildItem $FileName

        # this starts the log roll
        if((($file).length) -ige $Filesize) {
            $fileDir = $file.Directory
            #this gets the name of the file we started with
            $fn = $file.name
            $files = Get-ChildItem $filedir | Where-Object { $_.name -like "$fn*" } | Sort-Object lastwritetime
            #this gets the fullname of the file we started with
            $filefullname = $file.fullname

            #$LogCount +=1 #add one to the count as the base file is one more than the count
            for ($i = ($files.count); $i -gt 0; $i--) {
                #[int]$fileNumber = ($f).name.Trim($file.name) #gets the current number of
                # the file we are on 
                $files = Get-ChildItem $filedir | Where-Object { $_.name -like "$fn*" } | Sort-Object lastwritetime
                $operatingFile = $files | Where-Object { ($_.name).trim($fn) -eq $i }

                if ($operatingfile) {
                    $operatingFilenumber = ($files | Where-Object { ($_.name).trim($fn) -eq $i }).name.trim($fn)
                } else {
                    $operatingFilenumber = $null
                }
 
                if (($null -eq $operatingFilenumber) -and ($i -ne 1) -and ($i -lt $LogCount)) {
                    $operatingFilenumber = $i
                    $newFileName = "$filefullname.$operatingFilenumber"
                    $operatingFile = $files | Where-Object { ($_.name).trim($fn) -eq ($i-1) }
                    write-host "moving to $newFileName"
                    move-item ($operatingFile.FullName) -Destination $newFileName -Force
                } elseif ($i -ge $LogCount) {
                    if ($null -eq $operatingFilenumber) {
                        $operatingFilenumber = $i - 1
                        $operatingFile = $files | Where-Object { ($_.name).trim($fn) -eq $operatingFilenumber }
                    }

                    write-host "deleting " ($operatingFile.FullName) 
                    remove-item ($operatingFile.FullName) -Force
                } elseif ($i -eq 1) {
                    $operatingFilenumber = 1
                    $newFileName = "$filefullname.$operatingFilenumber"
                    write-host "moving to $newFileName"
                    move-item $filefullname -Destination $newFileName -Force
                } else {
                    $operatingFilenumber = $i +1  
                    $newFileName = "$filefullname.$operatingFilenumber"
                    $operatingFile = $files | Where-Object { ($_.name).trim($fn) -eq ($i-1) }
                    write-host "moving to $newFileName"
                    move-item ($operatingFile.FullName) -Destination $newFileName -Force
                }
            } 
        } else {
            $logRollStatus = $false
        }
    } else {
        $logrollStatus = $false
    }

    $LogRollStatus
}

# to null to avoid output
$Null = @(
    ResetLog -FileName $global:LogFilePath -Filesize $global:LogSize -LogCount $global:LogCount
)
