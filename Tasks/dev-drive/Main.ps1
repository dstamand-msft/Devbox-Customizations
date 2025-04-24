<#

.SYNOPSIS
    Script to create a new Dev Drive

.DESCRIPTION
    This script will create a new Dev Drive on a Windows system. For more information about Dev Drives, please see https://learn.microsoft.com/en-us/windows/dev-drive/

.PARAMETER Type of Drive to create
    This parameter defines the type of Dev Drive to create. The options are 'vhdx' or 'resize'.

.PARAMETER Drive Letter
    This parameter defines the drive letter that the Dev Drive will be mounted to.

.PARAMETER Drive Size
    This parameter defines the maximum size of the Dev Drive's dynamically sized volume.

.NOTES
Author: Dominique St-amand
Date: 2025-04-23
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true, HelpMessage = "Type of Drive to create")]
    [ValidateSet("vhdx", "resize")]
    [string]$Type,

    [Parameter(Mandatory = $true, HelpMessage = "The drive letter to mount the Dev Drive to")]
    [ValidatePattern("^[A-Z]$")]
    [string]$DriveLetter,

    [Parameter(Mandatory = $false, HelpMessage = "The size of the Dev Drive's")]
    [int]$DriveSize
)

switch ($Type) {
    "vhdx" {
        # inspired by https://gist.github.com/lawndoc/ea03e2ee0f4d64162669d1b5e997ec77
        $drivePath = Join-Path "C:\" "VHDX"
        $vhdxFilePath = Join-Path $drivePath "devdrive.vhdx"

        if (Test-Path $vhdxFilePath) {
            Write-Error "ERROR: $vhdxFilePath already exists! Aborting..."
            exit 1
        }
        if (Test-Path "$($DriveLetter):") {
            Write-Error "ERROR: Drive letter $($DriveLetter): is already in use! Aborting..."
            exit 1
        }
        
        # since this can run as localSystem or user (userTasks), we need to make sure there's a common ground
        # localSystem doesn't have a profile and thus no temp folder
        $tmpDir = Join-Path "C:\" "Temp"
        if (!Test-Path $tmpDir) {
            New-Item $tmpDir -Type Directory -Force | Out-Null
        }

        $diskPartFile = Join-Path -Path (Join-Path "C:\" "Temp") -ChildPath "diskpart_devdrive.txt"

        Write-Output "[*] Setting disk configuration settings..."
        $diskPartFileData = "create vdisk file='$vhdxFilePath' maximum=$DriveSize type=expandable`n" 
        $diskPartFileData += "select vdisk file='$vhdxFilePath'`n"
        $diskPartFileData += "attach vdisk`n"
        $diskPartFileData += "create partition primary`n"
        $diskPartFileData += "format fs=refs label='Dev Drive' quick`n"
        $diskPartFileData += "assign letter=$($DriveLetter)`n"

        $diskPartFileData | Out-File -Encoding ascii -FilePath $diskPartFile -Force
        
        Write-Output "[*] Creating Dev Drive..."
        if (!(Test-Path "$drivePath")) {
        New-Item $drivePath -Type Directory -Force | Out-Null
        }

        diskpart /s "$diskPartFile"
        Format-Volume -DriveLetter $DriveLetter -DevDrive
        
        if (!(Test-Path "$($DriveLetter):")) {
        Write-Error "ERROR: Failed to create ReFS vdisk for Dev Drive..."
        exit 1
        }
        
        Write-Output "[*] Verifying Dev Drive trust..."
        fsutil devdrv query "$($DriveLetter):"
        
        cd "$($DriveLetter):"
        label Dev Drive

        # dev drive doesn't re-mount after reboots without a scheduled task
        # see https://github.com/microsoft/devhome/issues/1903 for possible explanation
        $script = "# dev drive doesn't re-mount after reboots without a scheduled task. This is the script that is run by the scheduled task.`n"
        $script += "`$task = `"`"`n"
        $script += "`$devDriveTaskFile = Join-Path `$Env:Temp `"devdrivetask.txt`"`n"
        $script += "`$task += `"select vdisk file='$vhdxFilePath'``n`"`n"
        $script += "`$task += `"attach vdisk``n`"`n"
        $script += "`$task += `"cd $($DriveLetter):``n`"`n"
        $script += "`$task += `"label Dev Drive``n`"`n"
        $script += "`$task | Out-File -Encoding ascii -FilePath `$devDriveTaskFile -Force`n"
        $script += "Start-Process -FilePath `"diskpart.exe`" -ArgumentList `"/s `$devDriveTaskFile`" -NoNewWindow -Wait"

        $script | Out-File -Encoding ascii -FilePath (Join-Path $drivePath "devdrivetask.ps1") -Force

        $taskname = "Mount Dev Drive"
        $taskdescription = "Make sure Dev Drive is mounted after reboots"
        $taskTrigger = New-ScheduledTaskTrigger -AtStartup
        $taskAction = New-ScheduledTaskAction -Execute "PowerShell.exe" -Argument "-ExecutionPolicy Bypass .\devdrivetask.ps1" -WorkingDirectory $drivePath
        $taskSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        Register-ScheduledTask -TaskName $taskname -Description $taskdescription -Action $taskAction -Trigger $taskTrigger -Settings $taskSettings -User "System" -RunLevel Highest
          
        Write-Output "[*] Cleaning up..."
        Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
        
        Write-Output "[*] Done."
    }
    "resize" {
        # TODO: do the checks for the drive size vs the current size of the drive. Min is 50gb for resizing
        if ($DriveSize -lt 51200) {
            Write-Error "ERROR: The minimum size for a Dev Drive is 50GB. Please specify a larger size."
            exit 1
        }
        $partition = Get-Partition -DiskNumber 0 | Where-Object { $_.Type -eq "Basic" }
        $driveSizeInMB = [math]::Floor($partition.Size / (1024*1024))
        $newDriveSizeInMB = $driveSizeInMB - $DriveSize
        $newDriveSizeInBytes = $newDriveSizeInMB * 1024 * 1024
        $driveSizeInBytes = $DriveSize * 1024 * 1024
        
        Resize-Partition -DiskNumber 0 -PartitionNumber $partition.PartitionNumber -Size $newDriveSizeInBytes
        New-Partition -DiskNumber 0 -Size $driveSizeInBytes -DriveLetter $DriveLetter
        Format-Volume -DriveLetter $DriveLetter -DevDrive -NewFileSystemLabel "Dev Drive"
    }
}