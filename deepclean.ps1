# ===============================================================================
# SETUP LOGGING
# ===============================================================================
$LogPath = "C:\Logs\Maintenance"
if (-NOT (Test-Path -Path $LogPath)) {
    New-Item -ItemType Directory -Path $LogPath | Out-Null
}
$LogFile = Join-Path -Path $LogPath -ChildPath "SystemHealthCheck-$(Get-Date -Format 'yyyy-MM-dd_HH-mm-ss').log"
Start-Transcript -Path $LogFile

# Global error behavior - treat non-terminating errors as terminating so they are caught and logged
$ErrorActionPreference = 'Stop'

Write-Host "`n================================================================================" -ForegroundColor Gray
Write-Host "          System Cleanup Started!" -ForegroundColor Cyan
Write-Host "================================================================================" -ForegroundColor Gray


Write-Warning "`nThis process can take a significant amount of time. Please be patient."

# ===============================================================================
# CREATE RESTORE POINT
# ===============================================================================

try {
    Write-Host "`n================================================================================" -ForegroundColor Gray
    Write-Host "[TASK 1/5] Creating a System Restore Point..." -ForegroundColor Cyan
    Write-Host "================================================================================" -ForegroundColor Gray
    # Add -ErrorAction Stop to ensure that even a non-terminating error will trigger the catch block.
    Checkpoint-Computer -Description "Pre-Maintenance Script $(Get-Date)" -RestorePointType "MODIFY_SETTINGS" -ErrorAction Stop
    
    # This line only runs if the command above succeeds.
    Write-Host "System Restore Point created successfully." -ForegroundColor Green
}
catch {
    Write-Error "CRITICAL: Failed to create System Restore Point. Script cannot continue safely."
    Write-Error $_.Exception.Message

    Write-Host "-> CRITICAL: Failed to create System Restore Point. Script cannot continue safely." -ForegroundColor Red
    Write-Host "   Reason: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Aborting script execution." -ForegroundColor Red

    Stop-Transcript
    exit 1 
}

# The rest of your script follows here.
# It will only be executed if the try block completed successfully.
Write-Host "`nProceeding with the rest of the maintenance script..." -ForegroundColor Yellow


#================================================================================
# SYSTEM AND DRIVER UPDATES
#================================================================================

try {
    Write-Host "`n================================================================================" -ForegroundColor Gray
    Write-Host "[TASK 2/5] Checking for and Installing Windows & Driver Updates..." -ForegroundColor Cyan
    Write-Host "================================================================================" -ForegroundColor Gray
    
    # --- Import the PSWindowsUpdate module (assumed pre-installed) ---
    if (-NOT (Get-Module -ListAvailable -Name PSWindowsUpdate)) {
        Write-Warning "`nPowerShell module 'PSWindowsUpdate' not found. Skipping Windows Update task."
    }
    else {
        Import-Module PSWindowsUpdate -Force

        Write-Host "`nSearching for available updates (this may take a moment)..." -ForegroundColor Yellow
        Get-WindowsUpdate -Install -AcceptAll
        
        Write-Host "Windows Update check and installation process completed." -ForegroundColor Green
    }
}
catch {
    Write-Error "`-> An error occurred during the Windows Update process."
    Write-Error $_.Exception.Message
}


#================================================================================
# SYSTEM FILE INTEGRITY CHECKS
#================================================================================

try {
    # --- Run System File Checker (SFC) ---
    Write-Host "`n================================================================================" -ForegroundColor Gray
    Write-Host "[TASK 3/5] Starting System File Integrity Checks..." -ForegroundColor Cyan
    Write-Host "================================================================================" -ForegroundColor Gray
	Write-Host "`nThis will scan for and attempt to repair corrupt system files. This may take a while." -ForegroundColor Yellow
    sfc /scannow
    Write-Host "SFC scan completed." -ForegroundColor Green

    # --- Run DISM (Deployment Imaging Servicing and Management) ---
    Write-Host "`nStarting DISM Component Store Scan..." -ForegroundColor Yellow
    Write-Host "This will perform a deeper health scan of the Windows Component Store. This is a multi-step process and can be slow." -ForegroundColor Yellow

    [string[]]$checkResult = & DISM.exe /Online /Cleanup-Image /ScanHealth 2>&1

    # Check the exit code of the last command. 0 means success.
    if ($LASTEXITCODE -ne 0) {
        Write-Host "DISM /ScanHealth command failed to run. See output below." -ForegroundColor Red
        $checkResult # Display the captured output which contains the error
        Write-Host "Cannot proceed with DISM checks. Skipping to next part of script." -ForegroundColor Red
        # You might want to exit here or handle the failure appropriately
        # exit 1
    } 
    else {
        # The command ran successfully, now check the output text.
        # The '-match' operator uses regex, but for this simple string search it is effective.
        if ($checkResult -match "No component store corruption detected") {
            Write-Host "Result: Component Store is healthy. No repair needed." -ForegroundColor Green
            Write-Host "Skipping DISM /RestoreHealth." -ForegroundColor Green
        } 
        else {
            Write-Host "Result: Component Store corruption detected or scan was inconclusive." -ForegroundColor Yellow
            Write-Host "Proceeding to repair with DISM /RestoreHealth. This may take some time..." -ForegroundColor Yellow
            
            & DISM.exe /Online /Cleanup-Image /RestoreHealth
            
            # Verify the outcome of the RestoreHealth operation
            if ($LASTEXITCODE -eq 0) {
                Write-Host "DISM /RestoreHealth completed successfully." -ForegroundColor Green
            } else {
                Write-Host "DISM /RestoreHealth failed. Manual review required." -ForegroundColor Red
            }
        }
    }
}
catch {
    Write-Error "An error occurred during the System File Checker or DISM operations."
    Write-Error $_.Exception.Message
}


#================================================================================
# 4. SYSTEM CLEANUP
#================================================================================

try {
    # Define locations to check
    $TempLocations = @{
        "User Temp"                  = "$env:TEMP";
        "System Temp"                = "$env:windir\Temp";
        "Windows Update Cache"       = "$env:windir\SoftwareDistribution\Download";
        "Windows Logs (CBS)"         = "$env:windir\Logs\CBS";
        "Minidump"                   = "$env:windir\Minidump";
        "WER Temp"                   = "$env:ProgramData\Microsoft\Windows\WER\Temp";
        "WER ReportQueue"            = "$env:ProgramData\Microsoft\Windows\WER\ReportQueue";
        "Delivery Optimization"      = "$env:ProgramData\Microsoft\Network\Downloader";
    }

    Write-Host "`ncalculating size of files to clean..." -ForegroundColor Yellow

    # Calculate Size
    $totalSize = 0
    $locationsToClean = @()

    foreach ($location in $TempLocations.GetEnumerator()) {
        $locationName = $location.Name
        $path = $location.Value

        if (Test-Path -Path $path) {
            $size = Get-ChildItem -Path $path -Recurse -Force -ErrorAction SilentlyContinue | 
                    Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue
            
            if ($size.Sum -gt 0) {
                $sizeInMB = $size.Sum / 1MB
                $totalSize += $size.Sum
                Write-Host ("{0,-25} {1,15:N2} MB  at {2}" -f $locationName, $sizeInMB, $path)
                # Add this location to our list of things to clean
                $locationsToClean += [PSCustomObject]@{
                    Name = $locationName
                    Path = $path
                }
            } else {
                # Do not print folders that are empty
            }
        }
        else {
            Write-Host ("{0,-25} {1,15}     at {2}" -f $locationName, "Path not found", $path) -ForegroundColor Gray
        }
    }

    # Clean
    Write-Host "`n================================================================================" -ForegroundColor Gray
    Write-Host "[TASK 4/5] Starting file cleanup..." -ForegroundColor Cyan
    Write-Host "================================================================================" -ForegroundColor Gray
	
    $totalSizeInMB = $totalSize / 1MB
    Write-Host ("`nTotal potential space to be cleaned: {0:N2} MB" -f $totalSizeInMB) -ForegroundColor Green
	
    # Loop through the $locationsToClean array 
    foreach ($location in $locationsToClean) {
        if (Test-Path $location.Path) {
            Write-Host "Cleaning '$($location.Name)'..." -ForegroundColor Yellow
            Get-ChildItem -Path $location.Path -Recurse -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    Write-Host "Flushing DNS..." -ForegroundColor Yellow
	ipconfig /flushdns
}
catch {
    Write-Error "An unexpected error occurred during the cleanup process."
    Write-Error $_.Exception.Message
}

try {
    Write-Host "Cleaning component store..." -ForegroundColor Yellow

    & Dism.exe /online /Cleanup-Image /StartComponentCleanup /ResetBase
    
    if ($LASTEXITCODE -ne 0) {
        throw "DISM command failed with exit code $LASTEXITCODE."
    }
}
catch {
    Write-Host "-> ERROR: The Component Store cleanup operation failed." -ForegroundColor Red
    Write-Host "   Reason: $($_.Exception.Message)" -ForegroundColor Red
    Write-Error "Component Store cleanup operation failed. $($_.Exception.Message)"
}

Write-Host "`nFile cleanup completed." -ForegroundColor Green


#================================================================================
# 5. DRIVE OPTIMIZATION
#================================================================================

Write-Host "`n================================================================================" -ForegroundColor Gray
Write-Host "[TASK 5/5] Optimizing drives..." -ForegroundColor Cyan
Write-Host "================================================================================" -ForegroundColor Gray

try {
    # Enumerate fixed drives using CIM (no Storage module required)
    $fixedDrives = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType = 3"

    if (-not $fixedDrives) {
        Write-Host "No fixed drives found to optimize." -ForegroundColor Yellow
    }
    else {
        Write-Host "`nFound $($fixedDrives.Count) fixed drives to optimize: $($fixedDrives.DeviceID -join ', ')" -ForegroundColor Yellow

        foreach ($drive in $fixedDrives) {
            $driveId = $drive.DeviceID   # e.g. 'C:'

            Write-Host "Optimizing ${driveId} using defrag.exe /O (let Windows choose best method)..." -ForegroundColor Yellow

            # Run defrag and capture all output
            $defragOutput = & defrag.exe $driveId /O 2>&1
            $exitCode     = $LASTEXITCODE

            if ($exitCode -eq 0) {
                Write-Host "Drive ${driveId} optimization completed successfully." -ForegroundColor Green
            }
            else {
                Write-Warning "defrag.exe reported a problem on $driveId. Exit code: $exitCode"
                # Log detailed output into the transcript
                Write-Host "defrag.exe output for ${driveId}:" -ForegroundColor Yellow
                $defragOutput
            }
        }
    }
}
catch {
    Write-Warning "Drive optimization step skipped or failed unexpectedly."
    Write-Warning "Drive optimization error detail: $($_.Exception.Message)"
}


#================================================================================
# SCRIPT COMPLETION
#================================================================================

Write-Host "`n================================================================================" -ForegroundColor Gray
Write-Host "`nSystem Health Check Completed!" -ForegroundColor Cyan
Write-Host "`nA detailed log has been saved to: $LogFile" -ForegroundColor Green
Write-Host "`nSystem will reboot now to complete maintenance and apply any pending updates." -ForegroundColor Yellow
Write-Host "`n================================================================================" -ForegroundColor Gray

Stop-Transcript

Restart-Computer -Force