Function Get-OutSystemsModulesFromBundle {
    param(
        [Parameter(mandatory=$true)][string]$Filepath
    )

    $ZipFile = $Null

    try {
        [Reflection.Assembly]::LoadWithPartialName('System.IO.Compression.FileSystem') 2>&1>$null
        $ZipFile = [IO.Compression.ZipFile]::OpenRead($Filepath)

        $Map = @{}

        foreach ($Entry in $ZipFile.Entries) {
            if ($Entry.FullName.StartsWith("modules") -and -not $Entry.FullName.EndsWith("web.config")) {
                $Map[$Entry.FullName.Split("/")[1]] = ""
            }
        }

        return $Map.Keys
    } catch {
        throw "Something went wrong when reading the zip file '$Filepath': $_"
    } finally {
        if ($ZipFile) {
            $ZipFile.Dispose()
        }
    }
}

Function Add-CFRoutes {
    param(
        [Parameter(mandatory=$true)][string]$Filepath,
        [Parameter(mandatory=$true)][string]$AppName,
        [Parameter(mandatory=$true)][string]$PublicAddress,
        [Parameter(mandatory=$true)][string]$ZoneAddress
    )

    foreach ($module in (Get-OutSystemsModulesFromBundle $Filepath)) {
        foreach ($Address in @($PublicAddress, $ZoneAddress)) {
            Invoke-Expression "cf map-route $AppName $Address --path $module"
        }
    }
}
