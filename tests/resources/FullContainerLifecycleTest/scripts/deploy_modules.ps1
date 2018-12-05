foreach ($AppDir in (Get-ChildItem -Directory "$PSScriptRoot/../modules")) { 
    $AppName = $AppDir.Name; 
    $AppPath = $AppDir.FullName;

    Write-Output "Deploying $AppName..."

    New-WebApplication -Site "Default Web Site" -Name $AppName -PhysicalPath $AppPath;

    Write-Output "Deployed $AppName."
}

Write-Output "Deployment complete."
