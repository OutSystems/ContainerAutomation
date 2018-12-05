Function ConvertToCanonicalName {
    Param (
        [Parameter(Mandatory=$true)][String]$Text
    )

    $StringBuilder = New-Object System.Text.StringBuilder
    [System.Security.Cryptography.HashAlgorithm]::Create("SHA1").ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text)) | ForEach-Object {
        [Void]$StringBuilder.Append($_.ToString("x2"))
    }
    return $StringBuilder.ToString().Substring(0, 8)
}

Function IsBase64String {
    Param (
        [Parameter()][String]$Text
    )

    $Text = $Text.Trim()
    return ($Text.Length % 4 -eq 0) -and ($Text -match '^[a-zA-Z0-9\+/]*={0,3}$')
}

Function FromBase64 {
    Param (
        [Parameter()][String]$Text
    )

    if (-not $Text) {
        return ""
    }

    return [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($Text)) 
}

Function ConvertIfFromBase64 {
    Param (
        [Parameter()][String]$Text
    )

    if (IsBase64String -Text $Text) {
        $Text = $(FromBase64 -Text $Text)
    }

    return $Text
}

Function SubstituteLastInstance {
    Param (
        [Parameter(Mandatory=$true)][String]$In,
        [Parameter(Mandatory=$true)][String]$Of,
        [Parameter(Mandatory=$true)][String][AllowEmptyString()]$For
    )

    return ($In -replace "(.*)$Of(.*)", "`$1$For`$2")
}

Function RemoveLastInstance {
    Param (
        [Parameter(Mandatory=$true)][String]$In,
        [Parameter(Mandatory=$true)][String]$Of
    )

    return $(SubstituteLastInstance -Of $Of -In $In -For "")
}

Function GetSubFolders {
    Param (
        [Parameter(Mandatory=$true)][String]$Path
    )

    $SubFolders = @()

    foreach ($Entry in (Get-ChildItem $Path -Directory)) {
        $SubFolders += $Entry.Name
    }

    return [String[]]$SubFolders
}

Function FastCompareContentsOfZipWithFolder([String]$zipPath, [String]$folderPath, [String]$basePath = $zipPath, $app = $(New-Object -COM 'Shell.Application'), [bool]$Result = $true) {
    foreach ($entry in $app.NameSpace($zipPath).Items()) {
        if ($entry.IsFolder) {

            $Result = $(FastCompareContentsOfZipWithFolder $entry.Path $folderPath $basePath $app $Result)

        } else {
            $fileInZipRelativePath = $($entry.Path -replace [regex]::escape($basePath), '')

            $fileInFolderPath = $(Join-Path -Path "$FolderPath" -ChildPath "$fileInZipRelativePath")

            if (-not $(Test-Path $fileInFolderPath)) {
                return $false;
            } else {
                $fileInFolder = $(Get-Item $fileInFolderPath)

                if (-not ($fileInFolder -is [System.IO.DirectoryInfo])) {
                    $fileInZip = $entry

                    if ($fileInFolder.Length -ne $fileInZip.Size) {
                        return $false
                    }
                }
            }
        }
    }

    return $Result
}

Function FastCompareContentsOfFolderWithZip([String]$folderPath, [String]$zipPath) {
    $app = New-Object -COM 'Shell.Application'

    foreach ($entry in $(Get-ChildItem $folderPath -Recurse)) {
        $fileInFolderRelativePath = $($entry.FullName -replace [regex]::escape($folderPath), '')

        $fileInZipPath = $(Join-Path -Path "$zipPath" -ChildPath "$fileInFolderRelativePath")

        try {
            $fileInZip = $app.NameSpace($fileInZipPath)
        } catch {
            # Trying to access files without an extension that are on the root of a zip file
            # [ something like $app.NameSpace('[whatever].zip\[file_without_extension]') ]
            # throws a 'The method or operation is not implemented.'
            # We do this to workaround the issue:

            $filesInRootOfZip = $app.NameSpace($zipPath).Items()

            foreach ($fileInRootOfZip in $filesInRootOfZip) {
                if ($fileInRootOfZip.Name -eq $fileInFolderRelativePath) {
                    $fileInZip = @{}
                    $fileInZip.Self = @{}

                    $fileInZip.Self.Size = $fileInRootOfZip.Size
                    $fileInZip.Self.IsFolder = $false

                    break;
                }
            }
        }

        if (-not $fileInZip) {
            return $false
        } else {
            $fileInFolder = $entry

            if (-not $fileInZip.Self.IsFolder) {
                if ($fileInFolder.Length -ne $fileInZip.Self.Size) {
                    return $false
                }
            }
        }
    }

    return $true
}

Function FastCrossCheckFilesInFolderAndZip {
    Param (
        [Parameter(Mandatory=$true)][String]$FolderPath,
        [Parameter(Mandatory=$true)][String]$ZipPath
    )

    return $(FastCompareContentsOfFolderWithZip $FolderPath $ZipPath) -and $(FastCompareContentsOfZipWithFolder $ZipPath $FolderPath)
}

Function RetryWithReturnValue {
    Param (
        [Parameter(Mandatory=$true)][Scriptblock]$Action,
        [Parameter()]$ArgumentList,
        [Parameter(Mandatory=$true)][String]$ExceptionMessage,
        [Parameter()][int16]$NRetries=5
    )

    $InnerExceptionMessage = $null

    for ($i = 0; $i -lt $NRetries; $i++) {
        try {
            $Result = $Action.Invoke($ArgumentList)

            if ($Result) {
                return $Result
            } else {
                throw "Result was null with no exception thrown. Does the ScriptBlock have a return value?"
            }
        } catch {
            If (-not $InnerExceptionMessage) {
                $InnerExceptionMessage = $_
            }
        }
    }

    if ($InnerExceptionMessage) {
        throw "$ExceptionMessage First error (of $NRetries retries): $InnerExceptionMessage."
    } else {
        throw "$ExceptionMessage"
    }
}
