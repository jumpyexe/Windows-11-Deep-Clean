#Requires -RunAsAdministrator
<#
DESCRIPTION
    Creates an optional restore point, checks Windows Update, runs SFC and DISM,
    cleans common temp locations, optimizes fixed drives, checks Windows Time,
    and prints a task summary. Raw native command output is saved separately.
    DEBUG logging is hidden unless -VerboseLog is used.
#>

[CmdletBinding()]
param(
    [string]$LogRoot = 'C:\Logs\Maintenance',

    [string[]]$NtpServers = @('time.nist.gov'),

    [ValidateRange(1, 600000)]
    [int]$OffsetThresholdMs = 500,

    [switch]$SkipRestorePoint,

    [switch]$SkipWindowsUpdate,

    [switch]$SkipCleanup,

    [switch]$SkipDriveOptimization,

    [switch]$SkipTimeSync,

    [switch]$EnableRawTranscript,

    [switch]$VerboseLog,

    [int]$CleanupErrorSampleCount = 5,

    [switch]$NoRebootPrompt
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:TimeStamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
$script:LogRoot = $LogRoot
$script:RawLogRoot = Join-Path -Path $LogRoot -ChildPath "Raw-$script:TimeStamp"
$script:LogPath = Join-Path -Path $LogRoot -ChildPath "SystemHealthCheck-$script:TimeStamp.log"
$script:TaskResults = [System.Collections.Generic.List[object]]::new()
$script:RebootRequired = $false
$script:TranscriptPath = $null

function Initialize-LogFolders {
    New-Item -Path $script:LogRoot -ItemType Directory -Force | Out-Null
    New-Item -Path $script:RawLogRoot -ItemType Directory -Force | Out-Null
}

function Write-Log {
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet('INFO', 'WARN', 'ERROR', 'DEBUG')]
        [string]$Level = 'INFO'
    )

    if ($Level -eq 'DEBUG' -and -not $VerboseLog) {
        return
    }

    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8
    Write-Host $line
}

function Add-TaskResult {
    param(
        [Parameter(Mandatory)]
        [string]$Task,

        [Parameter(Mandatory)]
        [bool]$Success,

        [Parameter(Mandatory)]
        [string]$Message
    )

    $script:TaskResults.Add([pscustomobject]@{
        Task = $Task
        Success = $Success
        Message = $Message
    }) | Out-Null
}

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Format-ByteSize {
    param([Nullable[double]]$Bytes)

    if ($null -eq $Bytes) {
        return 'Unknown'
    }

    $value = [double]$Bytes
    $units = @('B', 'KB', 'MB', 'GB', 'TB')
    $index = 0

    while ([math]::Abs($value) -ge 1024 -and $index -lt ($units.Count - 1)) {
        $value = $value / 1024
        $index++
    }

    if ($index -eq 0) {
        return '{0:N0} {1}' -f $value, $units[$index]
    }

    return '{0:N2} {1}' -f $value, $units[$index]
}

function ConvertFrom-SpacedNativeText {
    param(
        [Parameter(ValueFromPipeline)]
        [AllowNull()]
        [string]$Text
    )

    process {
        if ([string]::IsNullOrWhiteSpace($Text)) {
            return $null
        }

        $trimmed = $Text.Trim()
        $tokens = $trimmed -split '\s+'
        $singleCharTokens = [regex]::Matches($trimmed, '(?<!\S)\S(?!\S)').Count

        if ($tokens.Count -ge 4 -and ($singleCharTokens / $tokens.Count) -gt 0.65) {
            return (($trimmed -replace '\s{3,}', '__GAP__') -replace '\s+', '' -replace '__GAP__', ' ').Trim()
        }

        return $trimmed
    }
}

function Convert-OperationResultCode {
    param([int]$ResultCode)

    switch ($ResultCode) {
        0 { 'Not started' }
        1 { 'In progress' }
        2 { 'Succeeded' }
        3 { 'Succeeded with errors' }
        4 { 'Failed' }
        5 { 'Aborted' }
        default { "Unknown result code $ResultCode" }
    }
}

function Get-SafeFileName {
    param([Parameter(Mandatory)][string]$Name)

    return ($Name -replace '[^a-zA-Z0-9_.-]', '_')
}

function Invoke-NativeCommandClean {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,

        [string[]]$ArgumentList = @(),

        [string]$DisplayName = (Split-Path -Path $FilePath -Leaf),

        [string]$RawOutputPath,

        [int[]]$ProgressMilestones = @(25, 50, 75, 100),

        [switch]$SuppressRoutineLines
    )

    $commandLine = "$FilePath $($ArgumentList -join ' ')".Trim()
    Write-Log "Running native command: $commandLine" 'INFO'

    $rawOutput = @()
    try {
        $rawOutput = @(& $FilePath @ArgumentList 2>&1 | ForEach-Object { $_.ToString() })
        $exitCode = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 }
    }
    catch {
        $rawOutput += $_.Exception.Message
        $exitCode = 1
    }

    if ([string]::IsNullOrWhiteSpace($RawOutputPath)) {
        $safeName = Get-SafeFileName -Name $DisplayName
        $RawOutputPath = Join-Path -Path $script:RawLogRoot -ChildPath "$safeName-$script:TimeStamp.raw.log"
    }

    try {
        $rawDir = Split-Path -Path $RawOutputPath -Parent
        if (-not [string]::IsNullOrWhiteSpace($rawDir) -and -not (Test-Path -LiteralPath $rawDir)) {
            New-Item -Path $rawDir -ItemType Directory -Force | Out-Null
        }

        $rawOutput | Set-Content -LiteralPath $RawOutputPath -Encoding UTF8 -Force
        Write-Log "$DisplayName raw output saved to: $RawOutputPath" 'DEBUG'
    }
    catch {
        Write-Log "Failed to save raw output for $DisplayName. $($_.Exception.Message)" 'WARN'
    }

    $cleanOutput = @(
        $rawOutput |
            ConvertFrom-SpacedNativeText |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { ($_ -replace '\s+', ' ').Trim() }
    )

    $seen = [System.Collections.Generic.HashSet[string]]::new()
    $reportedMilestones = [System.Collections.Generic.HashSet[int]]::new()

    foreach ($line in $cleanOutput) {
        if (-not $seen.Add($line)) {
            continue
        }

        $progressPercent = $null

        if ($line -match '^Verification\s+(\d+(?:\.\d+)?)\s*%\s+complete\.?$') {
            $progressPercent = [double]$matchess[1]
        }
        elseif ($line -match '^\[.*?(\d+(?:\.\d+)?)%.*\]$') {
            $progressPercent = [double]$matchess[1]
        }
        elseif ($line -match '^(Retrim|Defragmentation|Consolidation):?\s+(\d+(?:\.\d+)?)\s*%\s+complete') {
            $progressPercent = [double]$matchess[2]
        }

        if ($null -ne $progressPercent) {
            foreach ($milestone in $ProgressMilestones) {
                if ($progressPercent -ge $milestone -and -not $reportedMilestones.Contains($milestone)) {
                    [void]$reportedMilestones.Add($milestone)
                    Write-Log "$DisplayName progress: $milestone%" 'INFO'
                }
            }
            continue
        }

        if ($SuppressRoutineLines) {
            if ($line -match '^Beginning (system scan|verification phase)') { continue }
            if ($line -match '^Deployment Image Servicing and Management tool$') { continue }
            if ($line -match '^Version:\s+') { continue }
            if ($line -match '^Image Version:\s+') { continue }
            if ($line -match '^Performing pass \d+:$') { continue }
            if ($line -match '^Post Defragmentation Report:$') { continue }
            if ($line -match '^Volume Information:$') { continue }
            if ($line -match '^Retrim:$') { continue }
            if ($line -match '^(Volume size|Cluster size|Used space|Free space|Backed allocations|Allocations trimmed)\s*=') { continue }
            if ($line -match '^The command completed successfully\.?$') { continue }
            if ($line -match '^Sending resync command to local computer$') { continue }
            if ($line -match '^Tracking .+\[:?[^\]]+:123\]\.?$') { continue }
            if ($line -match '^Collecting \d+ samples\.?$') { continue }
            if ($line -match '^The current time is ') { continue }
        }

        Write-Log "${DisplayName}: $line" 'DEBUG'
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        RawOutput = @($rawOutput)
        CleanOutput = @($cleanOutput)
        RawOutputPath = $RawOutputPath
        Text = (($cleanOutput | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine)
    }
}

function Get-SfcSummary {
    param([Parameter(Mandatory)][string[]]$Output)

    $text = (($Output | ConvertFrom-SpacedNativeText | ForEach-Object { ($_ -replace '\s+', ' ').Trim() }) -join "`n")

    if ($text -match 'Windows Resource Protection did not find any integrity violations') {
        return 'No integrity violations found.'
    }

    if ($text -match 'Windows Resource Protection found corrupt files and successfully repaired them') {
        return 'Corruption found and repaired.'
    }

    if ($text -match 'Windows Resource Protection found corrupt files but was unable to fix some of them') {
        return 'Corruption found but not fully repaired.'
    }

    if ($text -match 'Windows Resource Protection could not perform the requested operation') {
        return 'SFC could not complete the requested operation.'
    }

    if ($text -match 'Windows Resource Protection could not perform the requested operation') {
    return 'SFC could not complete the requested operation.'
	}

	if (
    $text -match 'Verification\s+100\s*%\s+complete' -and
    $text -notmatch 'found corrupt files|could not perform|unable to fix'
	) {
    return 'SFC completed successfully. No corruption summary string detected.'
	}

return 'No standard SFC summary string detected.'
}

function Get-DismScanSummary {
    param([Parameter(Mandatory)][string[]]$Output)

    $text = ($Output | ConvertFrom-SpacedNativeText) -join "`n"

    if ($text -match 'No component store corruption detected') {
        return [pscustomobject]@{
            Summary = 'No component store corruption detected.'
            NeedsRestoreHealth = $false
        }
    }

    if ($text -match 'The component store is repairable') {
        return [pscustomobject]@{
            Summary = 'Component store corruption detected and repairable.'
            NeedsRestoreHealth = $true
        }
    }

    if ($text -match 'The component store is corrupted') {
        return [pscustomobject]@{
            Summary = 'Component store corruption detected.'
            NeedsRestoreHealth = $true
        }
    }

    if ($text -match 'The operation completed successfully') {
        return [pscustomobject]@{
            Summary = 'ScanHealth completed successfully, but no standard corruption string was detected.'
            NeedsRestoreHealth = $false
        }
    }

    return [pscustomobject]@{
        Summary = 'No standard DISM ScanHealth summary string detected.'
        NeedsRestoreHealth = $false
    }
}

function Get-DismRestoreSummary {
    param([Parameter(Mandatory)][string[]]$Output)

    $text = ($Output | ConvertFrom-SpacedNativeText) -join "`n"

    if ($text -match 'The restore operation completed successfully') {
        return 'RestoreHealth completed successfully.'
    }

    if ($text -match 'The operation completed successfully') {
        return 'RestoreHealth operation completed successfully.'
    }

    return 'No standard DISM RestoreHealth summary string detected.'
}

function Get-DirectoryStats {
    param([Parameter(Mandatory)][string]$Path)

    $fileCount = 0
    [int64]$totalBytes = 0

    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{
            Path = $Path
            Files = 0
            Bytes = 0
            Exists = $false
        }
    }

    try {
        Get-ChildItem -LiteralPath $Path -Force -Recurse -File -ErrorAction SilentlyContinue |
            ForEach-Object {
                $fileCount++
                $totalBytes += [int64]$_.Length
            }
    }
    catch {
        Write-Log "Unable to fully enumerate '$Path'. $($_.Exception.Message)" 'WARN'
    }

    return [pscustomobject]@{
        Path = $Path
        Files = $fileCount
        Bytes = $totalBytes
        Exists = $true
    }
}

function Remove-DirectoryChildren {
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$ErrorSampleCount = 5
    )

    $errors = [System.Collections.Generic.List[string]]::new()

    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{
            Attempted = $false
            ErrorCount = 0
            ErrorSamples = @()
        }
    }

    Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop
        }
        catch {
            $errors.Add($_.Exception.Message) | Out-Null
        }
    }

    return [pscustomobject]@{
        Attempted = $true
        ErrorCount = $errors.Count
        ErrorSamples = @($errors | Select-Object -First $ErrorSampleCount)
    }
}

function Get-FixedDriveFreeSpace {
    $drives = @{}

    Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType = 3' | ForEach-Object {
        $drives[$_.DeviceID] = [int64]$_.FreeSpace
    }

    return $drives
}

function Get-RebootRequiredState {
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
    )

    foreach ($path in $paths) {
        if ($path -eq 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager') {
            try {
                $value = Get-ItemProperty -Path $path -Name PendingFileRenameOperations -ErrorAction Stop
                if ($null -ne $value.PendingFileRenameOperations) {
                    return $true
                }
            }
            catch {
                continue
            }
        }
        elseif (Test-Path -Path $path) {
            return $true
        }
    }

    return $false
}

function Invoke-Step {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock
    )

    try {
        $null = & $ScriptBlock
    }
    catch {
        Write-Log "Task '$Name' failed. $($_.Exception.Message)" 'ERROR'
        Add-TaskResult -Task $Name -Success $false -Message $_.Exception.Message
    }
}

function New-MaintenanceRestorePoint {
    if ($SkipRestorePoint) {
        Write-Log 'Restore point skipped by parameter.' 'INFO'
        Add-TaskResult -Task 'Create-RestorePoint' -Success $true -Message 'Skipped by parameter.'
        return
    }

    Write-Log 'Creating restore point.' 'INFO'
    $description = "Monthly Maintenance $script:TimeStamp"
    $restoreWarnings = @()

    $checkpoint = Get-Command -Name Checkpoint-Computer -ErrorAction SilentlyContinue
    if ($checkpoint) {
        Checkpoint-Computer `
            -Description $description `
            -RestorePointType 'MODIFY_SETTINGS' `
            -WarningVariable restoreWarnings `
            -WarningAction SilentlyContinue
    }
    else {
        $encodedCommand = [Convert]::ToBase64String(
            [Text.Encoding]::Unicode.GetBytes(
                "Checkpoint-Computer -Description '$description' -RestorePointType 'MODIFY_SETTINGS' -WarningAction SilentlyContinue"
            )
        )
        $legacy = Start-Process -FilePath 'powershell.exe' `
            -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encodedCommand `
            -Wait `
            -PassThru `
            -WindowStyle Hidden

        if ($legacy.ExitCode -ne 0) {
            throw "powershell.exe restore point creation failed with exit code $($legacy.ExitCode)."
        }
    }

    if ($restoreWarnings.Count -gt 0) {
        $warningText = ($restoreWarnings | ForEach-Object { $_.Message }) -join ' '
        Write-Log "Restore point warning: $warningText" 'WARN'
        Add-TaskResult -Task 'Create-RestorePoint' -Success $true -Message 'Restore point not created because Windows frequency policy returned a warning.'
        return
    }

    Add-TaskResult -Task 'Create-RestorePoint' -Success $true -Message 'Restore point created.'
}

function Invoke-WindowsUpdateCheck {
    if ($SkipWindowsUpdate) {
        Write-Log 'Windows Update skipped by parameter.' 'INFO'
        Add-TaskResult -Task 'Perform-WindowsUpdate' -Success $true -Message 'Skipped by parameter.'
        return
    }

    Write-Log 'Checking Windows Update through COM API.' 'INFO'

    $session = New-Object -ComObject Microsoft.Update.Session
    $searcher = $session.CreateUpdateSearcher()
    $criteria = "IsInstalled=0 and Type='Software' and IsHidden=0"
    $searchResult = $searcher.Search($criteria)

    if ($searchResult.Updates.Count -eq 0) {
        Write-Log 'No applicable software updates found.' 'INFO'
        $script:RebootRequired = $script:RebootRequired -or (Get-RebootRequiredState)
        Write-Log "Reboot required by Windows Update: $script:RebootRequired" 'INFO'
        Add-TaskResult -Task 'Perform-WindowsUpdate' -Success $true -Message 'No applicable updates found. Nothing installed.'
        return
    }

    $updates = New-Object -ComObject Microsoft.Update.UpdateColl
    for ($i = 0; $i -lt $searchResult.Updates.Count; $i++) {
        $update = $searchResult.Updates.Item($i)
        Write-Log "Applicable update: $($update.Title)" 'INFO'

        if (-not $update.EulaAccepted) {
            $update.AcceptEula()
        }

        [void]$updates.Add($update)
    }

    Write-Log "Downloading $($updates.Count) update(s)." 'INFO'
    $downloader = $session.CreateUpdateDownloader()
    $downloader.Updates = $updates
    $downloadResult = $downloader.Download()
    $downloadSummary = Convert-OperationResultCode -ResultCode ([int]$downloadResult.ResultCode)
    Write-Log "Windows Update download result: $downloadSummary" 'INFO'

    if ([int]$downloadResult.ResultCode -in 4, 5) {
        throw "Windows Update download did not succeed. Result: $downloadSummary."
    }

    $installableUpdates = New-Object -ComObject Microsoft.Update.UpdateColl
    for ($i = 0; $i -lt $updates.Count; $i++) {
        $update = $updates.Item($i)
        if ($update.IsDownloaded) {
            [void]$installableUpdates.Add($update)
        }
        else {
            Write-Log "Update not downloaded, skipping install: $($update.Title)" 'WARN'
        }
    }

    if ($installableUpdates.Count -eq 0) {
        throw 'No updates were downloaded successfully.'
    }

    Write-Log "Installing $($installableUpdates.Count) update(s)." 'INFO'
    $installer = $session.CreateUpdateInstaller()
    $installer.Updates = $installableUpdates
    $installResult = $installer.Install()
    $installSummary = Convert-OperationResultCode -ResultCode ([int]$installResult.ResultCode)
    Write-Log "Windows Update install result: $installSummary" 'INFO'

    for ($i = 0; $i -lt $installableUpdates.Count; $i++) {
        $updateResult = $installResult.GetUpdateResult($i)
        $updateTitle = $installableUpdates.Item($i).Title
        $resultText = Convert-OperationResultCode -ResultCode ([int]$updateResult.ResultCode)
        Write-Log "Update result: $updateTitle : $resultText" 'INFO'
    }

    $script:RebootRequired = $script:RebootRequired -or [bool]$installResult.RebootRequired -or (Get-RebootRequiredState)
    Write-Log "Reboot required by Windows Update: $script:RebootRequired" 'INFO'

    $success = [int]$installResult.ResultCode -in 2, 3
    Add-TaskResult -Task 'Perform-WindowsUpdate' -Success $success -Message "Installed $($installableUpdates.Count) update(s). Result: $installSummary."
}

function Invoke-SystemFileChecks {
    Write-Log 'Running SFC.' 'INFO'
    $sfcRawPath = Join-Path -Path $script:RawLogRoot -ChildPath "sfc-initial-$script:TimeStamp.raw.log"
    $sfcResult = Invoke-NativeCommandClean `
        -FilePath 'sfc.exe' `
        -ArgumentList @('/scannow') `
        -DisplayName 'SFC' `
        -RawOutputPath $sfcRawPath `
        -SuppressRoutineLines

    $sfcSummary = Get-SfcSummary -Output $sfcResult.CleanOutput
    Write-Log "SFC exit code: $($sfcResult.ExitCode). Summary: $sfcSummary" 'INFO'

    Write-Log 'Running DISM ScanHealth.' 'INFO'
    $dismScanRawPath = Join-Path -Path $script:RawLogRoot -ChildPath "dism-scanhealth-$script:TimeStamp.raw.log"
    $dismScan = Invoke-NativeCommandClean `
        -FilePath 'DISM.exe' `
        -ArgumentList @('/Online', '/Cleanup-Image', '/ScanHealth') `
        -DisplayName 'DISM ScanHealth' `
        -RawOutputPath $dismScanRawPath `
        -SuppressRoutineLines

    $dismScanSummary = Get-DismScanSummary -Output $dismScan.CleanOutput
    Write-Log "DISM ScanHealth exit code: $($dismScan.ExitCode). Summary: $($dismScanSummary.Summary)" 'INFO'

    $dismFinalSummary = $dismScanSummary.Summary
    $secondSfcSummary = $null

    if ($dismScan.ExitCode -eq 0 -and $dismScanSummary.NeedsRestoreHealth) {
        Write-Log 'DISM repairable corruption detected. Running DISM RestoreHealth.' 'INFO'
        $dismRestoreRawPath = Join-Path -Path $script:RawLogRoot -ChildPath "dism-restorehealth-$script:TimeStamp.raw.log"
        $dismRestore = Invoke-NativeCommandClean `
            -FilePath 'DISM.exe' `
            -ArgumentList @('/Online', '/Cleanup-Image', '/RestoreHealth') `
            -DisplayName 'DISM RestoreHealth' `
            -RawOutputPath $dismRestoreRawPath `
            -SuppressRoutineLines

        $dismFinalSummary = Get-DismRestoreSummary -Output $dismRestore.CleanOutput
        Write-Log "DISM RestoreHealth exit code: $($dismRestore.ExitCode). Summary: $dismFinalSummary" 'INFO'

        Write-Log 'Re-running SFC after DISM repair attempt.' 'INFO'
        $secondSfcRawPath = Join-Path -Path $script:RawLogRoot -ChildPath "sfc-after-dism-$script:TimeStamp.raw.log"
        $secondSfc = Invoke-NativeCommandClean `
            -FilePath 'sfc.exe' `
            -ArgumentList @('/scannow') `
            -DisplayName 'Second SFC' `
            -RawOutputPath $secondSfcRawPath `
            -SuppressRoutineLines

        $secondSfcSummary = Get-SfcSummary -Output $secondSfc.CleanOutput
        Write-Log "Second SFC exit code: $($secondSfc.ExitCode). Summary: $secondSfcSummary" 'INFO'
    }
    elseif ($dismScan.ExitCode -eq 0 -and -not $dismScanSummary.NeedsRestoreHealth) {
        Write-Log 'DISM RestoreHealth skipped because ScanHealth did not detect component store corruption.' 'INFO'
    }
    else {
        Write-Log 'DISM RestoreHealth skipped because ScanHealth did not complete cleanly.' 'WARN'
    }

    $success = (
        $dismScan.ExitCode -eq 0 -and
        $sfcSummary -notmatch 'not fully repaired|could not complete'
    )

    $message = "SFC: $sfcSummary DISM: $dismFinalSummary"
    if ($secondSfcSummary) {
        $message = "$message Second SFC: $secondSfcSummary"
    }

    Add-TaskResult -Task 'Run-SystemFileChecks' -Success $success -Message $message
}

function Invoke-Cleanup {
    if ($SkipCleanup) {
        Write-Log 'Cleanup skipped by parameter.' 'INFO'
        Add-TaskResult -Task 'Cleanup-Files' -Success $true -Message 'Skipped by parameter.'
        return
    }

    $freeBefore = Get-FixedDriveFreeSpace
    $targets = @(
        [pscustomobject]@{ Name = 'User Temp'; Path = $env:TEMP },
        [pscustomobject]@{ Name = 'System Temp'; Path = 'C:\Windows\Temp' },
        [pscustomobject]@{ Name = 'Windows Update Cache'; Path = 'C:\Windows\SoftwareDistribution\Download' }
    )

    [int64]$estimatedRemoved = 0
    $hadErrors = $false

    foreach ($target in $targets) {
        if ([string]::IsNullOrWhiteSpace($target.Path)) {
            Write-Log "Cleanup target '$($target.Name)' skipped because path is empty." 'WARN'
            continue
        }

        try {
            $before = Get-DirectoryStats -Path $target.Path
            Write-Log "Cleanup target '$($target.Name)' before: $($before.Files) files, $(Format-ByteSize $before.Bytes)" 'INFO'

            if ($target.Name -eq 'Windows Update Cache') {
                try {
                    Stop-Service -Name wuauserv -Force -ErrorAction Stop
                    Stop-Service -Name bits -Force -ErrorAction Stop
                    Write-Log 'Stopped Windows Update services for cache cleanup.' 'INFO'
                }
                catch {
                    Write-Log "Unable to stop Windows Update services cleanly. $($_.Exception.Message)" 'WARN'
                }
            }

            $removeResult = Remove-DirectoryChildren -Path $target.Path -ErrorSampleCount $CleanupErrorSampleCount

            if ($target.Name -eq 'Windows Update Cache') {
                foreach ($service in @('bits', 'wuauserv')) {
                    try {
                        Start-Service -Name $service -ErrorAction Stop -WarningAction SilentlyContinue
                    }
                    catch {
                        Write-Log "Unable to start service '$service'. $($_.Exception.Message)" 'WARN'
                    }
                }
            }

            $after = Get-DirectoryStats -Path $target.Path
            $removed = [math]::Max(0, ([int64]$before.Bytes - [int64]$after.Bytes))
            $estimatedRemoved += $removed

            Write-Log "Cleanup target '$($target.Name)' after: $($after.Files) files, $(Format-ByteSize $after.Bytes)" 'INFO'
            Write-Log "Cleanup target '$($target.Name)' estimated removed: $(Format-ByteSize $removed)" 'INFO'

            if ($removeResult.ErrorCount -gt 0) {
                $hadErrors = $true
                Write-Log "Cleanup target '$($target.Name)' had $($removeResult.ErrorCount) removal error(s). Showing first $CleanupErrorSampleCount." 'WARN'
                foreach ($sample in $removeResult.ErrorSamples) {
                    Write-Log "Cleanup.$($target.Name).Error: $sample" 'DEBUG'
                }
            }
        }
        catch {
            $hadErrors = $true
            Write-Log "Cleanup failed for '$($target.Name)'. $($_.Exception.Message)" 'WARN'
        }
    }

    $flushDns = Invoke-NativeCommandClean `
        -FilePath 'ipconfig.exe' `
        -ArgumentList @('/flushdns') `
        -DisplayName 'ipconfig flushdns' `
        -SuppressRoutineLines

    if ($flushDns.ExitCode -eq 0) {
        Write-Log 'Flushed DNS cache.' 'INFO'
    }
    else {
        $hadErrors = $true
        Write-Log "DNS cache flush returned exit code $($flushDns.ExitCode)." 'WARN'
    }

    $freeAfter = Get-FixedDriveFreeSpace
    foreach ($drive in $freeAfter.Keys) {
        if ($freeBefore.ContainsKey($drive)) {
            $delta = [int64]$freeAfter[$drive] - [int64]$freeBefore[$drive]
            Write-Log "Cleanup observed free-space delta on $drive`: $(Format-ByteSize $delta)" 'INFO'
        }
    }

    $message = "Cleanup completed. Estimated removed: $(Format-ByteSize $estimatedRemoved)."
    if ($hadErrors) {
        $message = "Cleanup completed with errors. Estimated removed: $(Format-ByteSize $estimatedRemoved)."
    }

    Add-TaskResult -Task 'Cleanup-Files' -Success (-not $hadErrors) -Message $message
}

function Get-DefragTrimmedSpace {
    param([string[]]$Output)

    $matchess = @(
        $Output | Where-Object {
            $_ -match 'Total space trimmed\s*=\s*(.+)$' -or
            $_ -match 'Allocations trimmed\s*=\s*(.+)$'
        }
    )

    if ($matchess.Count -eq 0) {
        return 'Not reported'
    }

    $last = $matchess[-1]
    if ($last -match 'Total space trimmed\s*=\s*(.+)$') {
        return $matchess[1].Trim()
    }

    if ($last -match 'Allocations trimmed\s*=\s*(.+)$') {
        return $matchess[1].Trim()
    }

    return 'Not reported'
}

function Invoke-DriveOptimization {
    if ($SkipDriveOptimization) {
        Write-Log 'Drive optimization skipped by parameter.' 'INFO'
        Add-TaskResult -Task 'Optimize-Drives' -Success $true -Message 'Skipped by parameter.'
        return
    }

    $drives = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType = 3' | Sort-Object -Property DeviceID)
    if ($drives.Count -eq 0) {
        Write-Log 'No fixed drives found for optimization.' 'WARN'
        Add-TaskResult -Task 'Optimize-Drives' -Success $true -Message 'No fixed drives found.'
        return
    }

    $hadErrors = $false
    $messages = [System.Collections.Generic.List[string]]::new()

    foreach ($drive in $drives) {
        $deviceId = [string]$drive.DeviceID
        $driveArg = "$deviceId"
        $freeBefore = [int64]$drive.FreeSpace
        Write-Log "Drive $deviceId free before optimization: $(Format-ByteSize $freeBefore)" 'INFO'
        Write-Log "Using defrag.exe /O /U /V for $deviceId." 'INFO'

        $safeDrive = $deviceId.TrimEnd(':')
        $rawPath = Join-Path -Path $script:RawLogRoot -ChildPath "defrag-$safeDrive-$script:TimeStamp.raw.log"
        $result = Invoke-NativeCommandClean `
            -FilePath 'defrag.exe' `
            -ArgumentList @($driveArg, '/O', '/U', '/V') `
            -DisplayName "defrag $deviceId" `
            -RawOutputPath $rawPath `
            -SuppressRoutineLines

        if ($result.ExitCode -ne 0) {
            $hadErrors = $true
            Write-Log "Drive $deviceId optimization returned exit code $($result.ExitCode)." 'WARN'
        }

        $trimmed = Get-DefragTrimmedSpace -Output $result.CleanOutput
        $driveAfter = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID = '$deviceId'"
        $freeAfter = [int64]$driveAfter.FreeSpace
        $delta = $freeAfter - $freeBefore

        Write-Log "Drive $deviceId free after optimization: $(Format-ByteSize $freeAfter)" 'INFO'
        Write-Log "Drive $deviceId observed free-space delta after optimization: $(Format-ByteSize $delta)" 'INFO'
        Write-Log "Drive $deviceId total space trimmed reported by defrag: $trimmed" 'INFO'
        $messages.Add("$deviceId trimmed: $trimmed; free delta: $(Format-ByteSize $delta)") | Out-Null
    }

    Add-TaskResult `
        -Task 'Optimize-Drives' `
        -Success (-not $hadErrors) `
        -Message ("Volume optimization completed. " + ($messages -join ' '))
}

function Get-NtpOffsetSample {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Server,

        [ValidateRange(1, 50)]
        [int]$Samples = 6
    )

    $stripchart = Invoke-NativeCommandClean `
        -FilePath 'w32tm.exe' `
        -ArgumentList @('/stripchart', "/computer:$Server", '/dataonly', "/samples:$Samples") `
        -DisplayName "w32tm stripchart $Server" `
        -SuppressRoutineLines

    if ($stripchart.ExitCode -ne 0) {
        return [pscustomobject]@{
            Success = $false
            Server = $Server
            OffsetMs = $null
            AbsOffsetMs = $null
            ExitCode = $stripchart.ExitCode
            Message = "Offset sample failed for $Server. Exit code: $($stripchart.ExitCode)."
            RawOutput = $stripchart.RawOutput
        }
    }

    $offsets = foreach ($line in $stripchart.CleanOutput) {
        if ($line -match '([-+]?\d+(?:\.\d+)?)s') {
            [double]$matchess[1] * 1000.0
        }
    }

    if (-not $offsets) {
        return [pscustomobject]@{
            Success = $false
            Server = $Server
            OffsetMs = $null
            AbsOffsetMs = $null
            ExitCode = $stripchart.ExitCode
            Message = "Offset sample failed for $Server. No offset values were parsed."
            RawOutput = $stripchart.RawOutput
        }
    }

    $offsetMs = [int][Math]::Round((($offsets | Measure-Object -Average).Average))

    return [pscustomobject]@{
        Success = $true
        Server = $Server
        OffsetMs = $offsetMs
        AbsOffsetMs = [Math]::Abs($offsetMs)
        ExitCode = $stripchart.ExitCode
        Message = "Offset sample from ${Server}: $offsetMs ms."
        RawOutput = $stripchart.RawOutput
    }
}

function Invoke-TimeSync {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    if ($SkipTimeSync) {
        Write-Log 'Time sync skipped by parameter.' 'INFO'
        Add-TaskResult -Task 'Resync-Time' -Success $true -Message 'Skipped by parameter.'
        return $true
    }

    $task = 'Resync-Time'
    $peerList = (
        $NtpServers | ForEach-Object {
            if ($_ -match ',0x[0-9A-Fa-f]+$') {
                $_
            }
            else {
                "$_,0x8"
            }
        }
    ) -join ' '

    if (-not $PSCmdlet.ShouldProcess('Time sync', ("Configure peers: {0}" -f $peerList))) {
        Add-TaskResult -Task $task -Success $false -Message 'Skipped by ShouldProcess.'
        return $false
    }

    $svc = Get-Service -Name w32time -ErrorAction SilentlyContinue
    if (-not $svc) {
        Add-TaskResult -Task $task -Success $false -Message 'w32time service not found.'
        Write-Log 'Windows Time service not found.' 'WARN'
        return $false
    }

    if ($svc.Status -ne 'Running') {
        Write-Log 'Starting Windows Time service.' 'INFO'
        Start-Service -Name w32time -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    }

    Write-Log "Configuring NTP peers: $peerList" 'INFO'

    $config = Invoke-NativeCommandClean `
        -FilePath 'w32tm.exe' `
        -ArgumentList @('/config', "/manualpeerlist:$peerList", '/syncfromflags:manual', '/update') `
        -DisplayName 'w32tm config' `
        -SuppressRoutineLines

    $resync = Invoke-NativeCommandClean `
        -FilePath 'w32tm.exe' `
        -ArgumentList @('/resync') `
        -DisplayName 'w32tm resync' `
        -SuppressRoutineLines

    $source = Invoke-NativeCommandClean `
        -FilePath 'w32tm.exe' `
        -ArgumentList @('/query', '/source') `
        -DisplayName 'w32tm source' `
        -SuppressRoutineLines

    $status = Invoke-NativeCommandClean `
        -FilePath 'w32tm.exe' `
        -ArgumentList @('/query', '/status') `
        -DisplayName 'w32tm status' `
        -SuppressRoutineLines

    $sourceText = [string]($source.CleanOutput | Select-Object -Last 1)
    if ([string]::IsNullOrWhiteSpace($sourceText)) {
        $sourceText = 'Unknown'
    }

    $statusText = ($status.CleanOutput -join '; ')
    if (-not [string]::IsNullOrWhiteSpace($statusText)) {
        Write-Log "Windows Time status: $statusText" 'INFO'
    }

    $postSyncSample = $null
    foreach ($server in $NtpServers) {
        $serverName = ($server -replace ',0x[0-9A-Fa-f]+$', '')
        $sample = Get-NtpOffsetSample -Server $serverName

        if ($sample.Success) {
            $postSyncSample = $sample
            Write-Log $sample.Message 'INFO'
            break
        }

        Write-Log $sample.Message 'WARN'
    }

    if ($config.ExitCode -ne 0) {
        Add-TaskResult `
            -Task $task `
            -Success $false `
            -Message "Time config failed. Config exit: $($config.ExitCode). Source: $sourceText."
        return $false
    }

    if ($resync.ExitCode -eq 0 -and $sourceText -notmatch 'Local CMOS Clock' -and $postSyncSample) {
        if ($postSyncSample.AbsOffsetMs -gt $OffsetThresholdMs) {
            Add-TaskResult `
                -Task $task `
                -Success $false `
                -Message "Time resync completed, but offset $($postSyncSample.AbsOffsetMs) ms exceeds threshold $OffsetThresholdMs ms. Source: $sourceText."

            return $false
        }

        Add-TaskResult `
            -Task $task `
            -Success $true `
            -Message "Time resync OK. Offset $($postSyncSample.OffsetMs) ms. Source: $sourceText."

        return $true
    }

    Add-TaskResult `
        -Task $task `
        -Success $false `
        -Message "Time resync failed or source not confirmed. Resync exit: $($resync.ExitCode). Source: $sourceText."

    return $false
}

function Resync-Time {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    Invoke-TimeSync
}

function Invoke-RebootStep {
    $script:RebootRequired = $script:RebootRequired -or (Get-RebootRequiredState)

    if ($script:RebootRequired) {
        Write-Log 'Reboot is required.' 'WARN'
    }
    else {
        Write-Log 'Reboot is not required.' 'INFO'
    }

    if ($NoRebootPrompt) {
        Add-TaskResult -Task 'Reboot' -Success $true -Message "Reboot required: $script:RebootRequired. No prompt due to parameter."
        return
    }

    $answer = Read-Host 'Reboot anyway? (y/N)'
    if ($answer -match '^(y|yes)$') {
        Add-TaskResult -Task 'Reboot' -Success $true -Message 'User accepted reboot.'
        Write-Log 'Restarting computer.' 'INFO'
        Restart-Computer -Force
    }
    else {
        Add-TaskResult -Task 'Reboot' -Success $true -Message "Reboot required: $script:RebootRequired. User declined."
    }
}

function Show-TaskSummary {
    Write-Host ''
    Write-Host 'System Maintenance Completed!'
    Write-Host "Log saved to $script:LogPath"
    Write-Host "Raw command logs saved to $script:RawLogRoot"
    if ($script:TranscriptPath) {
        Write-Host "Raw PowerShell transcript saved to $script:TranscriptPath"
    }
    Write-Host ''
    Write-Host 'Task Summary'
    Write-Host ''
    $script:TaskResults | Format-Table -AutoSize
}

try {
    Initialize-LogFolders

    if ($EnableRawTranscript) {
        $script:TranscriptPath = Join-Path -Path $script:RawLogRoot -ChildPath "transcript-$script:TimeStamp.raw.txt"
        Start-Transcript -Path $script:TranscriptPath -Force | Out-Null
    }

    Write-Host 'System Maintenance Started!'
    Write-Log "Log file: $script:LogPath" 'INFO'
    Write-Log "Raw log folder: $script:RawLogRoot" 'INFO'
    Write-Log "Running elevated: $(Test-IsAdmin)" 'INFO'

    if (-not (Test-IsAdmin)) {
        throw 'This script must run elevated.'
    }

    Write-Host 'Step 1/7: Restore point'
    Invoke-Step -Name 'Create-RestorePoint' -ScriptBlock { New-MaintenanceRestorePoint }

    Write-Host 'Step 2/7: Windows Update'
    Invoke-Step -Name 'Perform-WindowsUpdate' -ScriptBlock { Invoke-WindowsUpdateCheck }

    Write-Host 'Step 3/7: SFC and DISM'
    Invoke-Step -Name 'Run-SystemFileChecks' -ScriptBlock { Invoke-SystemFileChecks }

    Write-Host 'Step 4/7: Cleanup'
    Invoke-Step -Name 'Cleanup-Files' -ScriptBlock { Invoke-Cleanup }

    Write-Host 'Step 5/7: Optimize drives'
    Invoke-Step -Name 'Optimize-Drives' -ScriptBlock { Invoke-DriveOptimization }

    Write-Host 'Step 6/7: Time sync'
    Invoke-Step -Name 'Resync-Time' -ScriptBlock { Invoke-TimeSync }

    Write-Host 'Step 7/7: Reboot optional'
    Invoke-Step -Name 'Reboot' -ScriptBlock { Invoke-RebootStep }
}
catch {
    Write-Log "Fatal script error. $($_.Exception.Message)" 'ERROR'
    Add-TaskResult -Task 'Fatal' -Success $false -Message $_.Exception.Message
}
finally {
    Show-TaskSummary

    if ($EnableRawTranscript) {
        try {
            Stop-Transcript | Out-Null
        }
        catch {
            Write-Log "Unable to stop transcript. $($_.Exception.Message)" 'WARN'
        }
    }
}