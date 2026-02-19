################################################################################################
# Created by Lance Crandall | support@iru.com | Iru, Inc.
################################################################################################
#
#   Created - 2025/12/11
#   Updated - 2026/01/09
#
################################################################################################
# Script Information
################################################################################################
#
# This script downloads and installs MSI and EXE applications from public URLs (OneDrive,
# Google Drive, etc.). It handles download verification, uninstallation of existing versions
# (supports multiple uninstall commands executed sequentially), and proper execution based on
# file type (MSI vs EXE). The script ensures the installer is downloaded and verified before
# executing any uninstall commands.
# The script is designed to run from an elevated context (Administrator/SYSTEM).
# It can be executed interactively or fully unattended.
#
################################################################################################
# License Information
################################################################################################
#
# Copyright 2026 Iru, Inc.
#
# Permission is hereby granted, free of charge, to any person obtaining a copy of this
# software and associated documentation files (the "Software"), to deal in the Software
# without restriction, including without limitation the rights to use, copy, modify, merge,
# publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons
# to whom the Software is furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all copies or
# substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
# INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR
# PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE
# FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
# OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
# DEALINGS IN THE SOFTWARE.
#
################################################################################################

param(
    # Multi-app install (array-only)
    [string[]]$DownloadUrls,
    [string[]]$InstallCommandLines,
    [string]$DownloadDirectory,
    [string[]]$UninstallCommandLines,
    [string[]]$ProcessNamesToKill,
    [int]$UninstallTimeoutSeconds,
    [int]$InstallationTimeoutSeconds,
    [int]$UrlTestTimeoutSeconds,
    [switch]$CleanupAfterInstall,
    [switch]$Debug
)

# Script version
$VERSION = "1.0.0"

# ---------------------------------------------------------------------------------
# Editable defaults (override by command-line parameters when provided)
# ---------------------------------------------------------------------------------
$DownloadUrlsDefault = @()               # Array of URLs
$InstallCommandLinesDefault = @()        # Array of command lines
$programDataPath = [Environment]::GetFolderPath("CommonApplicationData")
$DownloadDirectoryDefault = Join-Path $programDataPath "Iru\AppInstalls"  # Default download location (%ProgramData%\Iru\AppInstalls)
$UninstallCommandLinesDefault = @()       # Array of uninstall commands, e.g., @("msiexec /x {GUID} /qn", "app.exe /uninstall /S")
$ProcessNamesToKillDefault = @()          # Array of process names (EXE names) to kill before uninstall, e.g., @("app.exe", "service.exe")
$CleanupAfterInstallDefault = $false      # Remove downloaded file after successful installation (default: false to avoid issues if source unavailable)
$EnableDebugDefault = $false

# Download retry settings
$MaxDownloadRetries = 3                    # Number of retry attempts for failed downloads
$DownloadRetryDelaySeconds = 5             # Seconds to wait between retry attempts
$DownloadTimeoutSeconds = 300              # Timeout for download operation (5 minutes)

# Timeout settings
$UninstallTimeoutSecondsDefault = 600       # Timeout for uninstall operation in seconds (10 minutes default)
$InstallationTimeoutSecondsDefault = 600    # Timeout for installation operation in seconds (10 minutes default)
$UrlTestTimeoutSecondsDefault = 10          # Timeout for URL accessibility test in seconds (10 seconds default)

# MSI/installer exit codes that should be treated as success (not failures)
# 3010 = ERROR_SUCCESS_REBOOT_REQUIRED (reboot needed to complete install)
# 1641 = ERROR_SUCCESS_REBOOT_INITIATED (installer initiated a reboot)
# 1638 = ERROR_PRODUCT_VERSION (another version of this product is already installed)
# 1603 with certain conditions could also be added here if needed
$SuccessExitCodes = @(0, 3010, 1641, 1638)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls

$script:DebugMode = $false
$script:LogFile = $null
$script:DownloadedFilePath = $null
$script:DownloadSessionDirectory = $null
$script:OutputBuffer = New-Object System.Text.StringBuilder
$script:LastError = $null
$script:InstallExitCode = $null
$script:InstallStderr = $null
$script:DownloadSuccess = $false
$script:InstallSuccess = $false
$script:DownloadFailures = @()   # array of @{ Url = "..."; Error = "..." }
$script:InstallFailures = @()    # array of @{ CommandLine = "..."; ExitCode = <int|null>; Error = "..." }
$script:InstallSuccesses = @()   # array of install command lines that succeeded

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Level,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $timestamp = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss")
    $line = "$timestamp [$Level] $Message"
    
    # Always write to log file (wrap in try/catch so a log-write failure never crashes the script)
    if ($script:LogFile) {
        try {
            Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 -ErrorAction Stop
        } catch {
            # Log write failed (file locked, stream error, etc.) - don't let it kill the script
        }
    }
    
    # Append to output buffer for stdout (but don't write to stdout yet)
    [void]$script:OutputBuffer.AppendLine($line)
}

function Write-SummaryOutput {
    param(
        [bool]$IsError = $false
    )
    
    # Build a smart summary with the most useful information
    $summary = New-Object System.Text.StringBuilder
    
    if ($IsError) {
        [void]$summary.AppendLine("FAILED:")

        # If we have multiple install failures, show them directly (preferred for multi-app mode)
        if ($script:InstallFailures -and $script:InstallFailures.Count -gt 0) {
            foreach ($f in $script:InstallFailures) {
                $cmd = $null
                $code = $null
                $errDetail = $null
                try { $cmd = $f.CommandLine } catch { }
                try { $code = $f.ExitCode } catch { }
                try { $errDetail = $f.Error } catch { }

                if (-not [string]::IsNullOrWhiteSpace($cmd)) {
                    $codeText = "Unknown"
                    if ($null -ne $code) { $codeText = "$code" }
                    [void]$summary.AppendLine(("  {0} failed. (Error code: {1})" -f $cmd, $codeText))
                    # Include installer error message if available (e.g., stderr from the installer)
                    if (-not [string]::IsNullOrWhiteSpace($errDetail)) {
                        [void]$summary.AppendLine(("  Installer: {0}" -f $errDetail))
                    }
                }
            }
        }
        
        # Add the most recent error message (most important)
        # Clean up error message to avoid duplication (remove "Error:" prefix if already present)
        $cleanError = $null
        if ($script:LastError) {
            $cleanError = $script:LastError.Trim()
            # Remove "Error:" prefix if it exists to avoid duplication
            if ($cleanError -match "^Error:\s*(.+)") {
                $cleanError = $matches[1].Trim()
            }
            # Remove "FAILED:" prefix if it exists
            if ($cleanError -match "^FAILED:\s*(.+)") {
                $cleanError = $matches[1].Trim()
            }
            [void]$summary.AppendLine("  $cleanError")
        }
        
        # Add download failures (if any)
        if ($script:DownloadFailures -and $script:DownloadFailures.Count -gt 0) {
            foreach ($d in $script:DownloadFailures) {
                $u = $null
                try { $u = $d.Url } catch { }
                if (-not [string]::IsNullOrWhiteSpace($u)) {
                    [void]$summary.AppendLine(("  Download failed: {0}" -f $u))
                } else {
                    [void]$summary.AppendLine("  Download failed")
                }
            }
        }
        
    } else {
        # For success: one line per successful install command
        [void]$summary.AppendLine("SUCCESS:")
        if ($script:InstallSuccesses -and $script:InstallSuccesses.Count -gt 0) {
            foreach ($cmd in $script:InstallSuccesses) {
                if (-not [string]::IsNullOrWhiteSpace($cmd)) {
                    [void]$summary.AppendLine(("  {0} was successful" -f $cmd))
                }
            }
        } else {
            [void]$summary.AppendLine("  Installation completed")
        }
    }
    
    # Get the summary text (let the service handle truncation if needed)
    $summaryText = $summary.ToString().TrimEnd("`r", "`n")
    
    # Output to appropriate stream: stdout for success, stderr for errors
    if ($IsError) {
        # Write to stderr using multiple fallbacks for environments without a console (e.g., MDM agents)
        try {
            [Console]::Error.WriteLine($summaryText)
        } catch {
            try {
                $host.UI.WriteErrorLine($summaryText)
            } catch {
                # Last resort: Write-Error adds formatting but at least produces output
                Write-Error $summaryText -ErrorAction Continue
            }
        }
    } else {
        # Write to stdout for success
        Write-Output $summaryText
    }
}

function Log-Info { param([string]$Message) Write-Log -Level "INFO" -Message $Message }
function Log-Warn { param([string]$Message) Write-Log -Level "WARN" -Message $Message }
function Log-Error { param([string]$Message) Write-Log -Level "ERROR" -Message $Message }
function Log-Debug { param([string]$Message) if ($script:DebugMode) { Write-Log -Level "DEBUG" -Message $Message } }

function Initialize-Logger {
    $programData = [Environment]::GetFolderPath("CommonApplicationData")
    $root = Join-Path $programData "Iru"
    $sub = Join-Path $root "AppInstalls"
    $dir = Join-Path $sub "Logs"
    foreach ($path in @($root, $sub, $dir)) {
        if (-not (Test-Path -LiteralPath $path)) {
            New-Item -ItemType Directory -Path $path -Force | Out-Null
        }
    }

    # Include a short GUID suffix so concurrent instances never collide on the same filename
    $stamp = (Get-Date).ToString("yyyyMMdd_HHmmss")
    $shortGuid = ([System.Guid]::NewGuid().ToString().Substring(0, 8))
    $script:LogFile = Join-Path $dir "AppInstall_${stamp}_${shortGuid}.log"
    if (-not (Test-Path -LiteralPath $script:LogFile)) {
        New-Item -ItemType File -Path $script:LogFile -Force | Out-Null
    }

    Log-Info ("Log file: {0}" -f $script:LogFile)

    $envComputer = [Environment]::GetEnvironmentVariable("COMPUTERNAME")
    if ($envComputer) {
        Log-Info ("Machine: {0}" -f $envComputer)
    }

    try {
        $compName = [System.Net.Dns]::GetHostName()
        if ($compName) {
            Log-Info ("Computer: {0}" -f $compName)
        }
    } catch {
        Log-Debug ("Failed to resolve host name: {0}" -f $_.Exception.Message)
    }

    $osVersion = [Environment]::OSVersion.Version
    Log-Info ("OS: {0}.{1}.{2}" -f $osVersion.Major, $osVersion.Minor, $osVersion.Build)
    Log-Info ("Script version: {0}" -f $VERSION)
}

function Test-UrlAccessible {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $false)][int]$TimeoutSeconds
    )

    try {
        # Use script variable if parameter not provided
        if (-not $PSBoundParameters.ContainsKey('TimeoutSeconds')) {
            $TimeoutSeconds = $script:UrlTestTimeoutSeconds
        }
        
        Log-Debug ("Testing URL accessibility: {0}" -f $Url)
        $request = [System.Net.WebRequest]::Create($Url)
        $request.Method = "HEAD"
        $request.Timeout = $TimeoutSeconds * 1000  # Convert seconds to milliseconds
        $response = $request.GetResponse()
        $statusCode = [int]$response.StatusCode
        $response.Close()
        
        if ($statusCode -ge 200 -and $statusCode -lt 400) {
            Log-Debug ("URL is accessible (HTTP {0})" -f $statusCode)
            return $true
        } else {
            Log-Warn ("URL returned HTTP {0}" -f $statusCode)
            return $false
        }
    } catch {
        Log-Debug ("URL accessibility test failed: {0}" -f $_.Exception.Message)
        return $false
    }
}

function Get-FileNameFromUrl {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $false)][int]$TimeoutSeconds
    )

    # Extract filename like a browser does: check Content-Disposition header first,
    # then fall back to URL path, then use generic name as last resort
    try {
        # Use script variable if parameter not provided
        if (-not $PSBoundParameters.ContainsKey('TimeoutSeconds')) {
            $TimeoutSeconds = $script:UrlTestTimeoutSeconds
        }
        
        # First, try to get filename from Content-Disposition header (like browsers do)
        try {
            $request = [System.Net.WebRequest]::Create($Url)
            $request.Method = "HEAD"
            $request.Timeout = $TimeoutSeconds * 1000  # Convert seconds to milliseconds
            $response = $request.GetResponse()
            
            $contentDisposition = $response.Headers["Content-Disposition"]
            if ($contentDisposition) {
                # Parse Content-Disposition header: attachment; filename="setup.exe" or filename*=UTF-8''setup.exe
                if ($contentDisposition -match 'filename[^;=\n]*=(([''"])([^''"]+)\2|[^\s;]+)') {
                    $fileName = $matches[3]
                    if ([string]::IsNullOrWhiteSpace($fileName)) {
                        $fileName = $matches[1]
                    }
                    # Remove quotes if present
                    $fileName = $fileName.Trim('"', "'")
                    # Handle UTF-8 encoded filenames (filename*=UTF-8''filename.ext)
                    if ($fileName -match "^UTF-8''(.+)$") {
                        $fileName = $matches[1]
                    }
                    
                    if (-not [string]::IsNullOrWhiteSpace($fileName) -and $fileName.Contains('.')) {
                        $response.Close()
                        Log-Debug ("Using filename from Content-Disposition header: {0}" -f $fileName)
                        return $fileName
                    }
                }
            }
            $response.Close()
        } catch {
            Log-Debug ("Could not retrieve Content-Disposition header: {0}" -f $_.Exception.Message)
            # Continue to fallback methods
        }
        
        # Fallback: Extract filename from URL path
        $uri = New-Object System.Uri($Url)
        $fileName = [System.IO.Path]::GetFileName($uri.LocalPath)
        
        if (-not [string]::IsNullOrWhiteSpace($fileName) -and $fileName.Contains('.')) {
            Log-Debug ("Using filename from URL path: {0}" -f $fileName)
            return $fileName
        }
        
        # Last resort: throw so the caller's try/catch handles this properly
        throw "Could not determine filename from URL or headers: $Url"
        
    } catch {
        throw "Error extracting filename from URL '$Url': $($_.Exception.Message)"
    }
}

function Invoke-DownloadFile {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$DestinationPath
    )

    $attempt = 0
    $lastException = $null

    while ($attempt -lt $MaxDownloadRetries) {
        $attempt++
        try {
            Log-Info ("Download attempt {0} of {1}: {2}" -f $attempt, $MaxDownloadRetries, $Url)
            
            # Ensure destination directory exists
            $destDir = Split-Path -Path $DestinationPath -Parent
            if (-not (Test-Path -LiteralPath $destDir)) {
                New-Item -ItemType Directory -Path $destDir -Force | Out-Null
                Log-Debug ("Created download directory: {0}" -f $destDir)
            }
            elseif (Test-Path -LiteralPath $DestinationPath) {
                Remove-Item -LiteralPath $DestinationPath -Force
                Log-Debug ("Removed existing file: {0}" -f $DestinationPath)
            }

            # Use Invoke-WebRequest for more reliable download with progress tracking
            $uri = New-Object System.Uri($Url)
            
            Log-Debug ("Starting download from: {0}" -f $Url)
            $startTime = Get-Date
            
            # Download with timeout using Invoke-WebRequest
            try {
                Invoke-WebRequest -Uri $Url -OutFile $DestinationPath -TimeoutSec $DownloadTimeoutSeconds -UseBasicParsing | Out-Null
                
                # Verify file was created and has content
                if (-not (Test-Path -LiteralPath $DestinationPath)) {
                    throw New-Object System.IO.FileNotFoundException("Downloaded file not found at destination")
                }
                
                $fileInfo = Get-Item -LiteralPath $DestinationPath
                if ($fileInfo.Length -eq 0) {
                    throw New-Object System.IO.IOException("Downloaded file is empty")
                }
                
                $elapsed = (Get-Date) - $startTime
                Log-Info ("Download completed successfully in {0:N1} seconds: {1} ({2:N2} MB)" -f $elapsed.TotalSeconds, $DestinationPath, ($fileInfo.Length / 1MB))
                
            } catch {
                # If Invoke-WebRequest fails, fall back to WebClient with event-based completion detection
                Log-Debug ("Invoke-WebRequest failed, trying WebClient: {0}" -f $_.Exception.Message)
                
                $webClient = New-Object System.Net.WebClient
                
                # Use a hashtable to track download state (better scope handling)
                $downloadState = @{
                    Complete = $false
                    Error = $null
                }
                
                $eventHandler = Register-ObjectEvent -InputObject $webClient -EventName "DownloadFileCompleted" -Action {
                    $Event.MessageData.Complete = $true
                    if ($EventArgs.Error) {
                        $Event.MessageData.Error = $EventArgs.Error
                    }
                } -MessageData $downloadState
                
                # Start download asynchronously
                $webClient.DownloadFileAsync($uri, $DestinationPath)
                
                # Wait for download completion event with timeout (event-based, not polling)
                $downloadEvent = Wait-Event -SourceIdentifier $eventHandler.Name -Timeout $DownloadTimeoutSeconds
                
                if ($null -eq $downloadEvent) {
                    # Timeout occurred - cancel download and cleanup
                    $webClient.CancelAsync()
                    Unregister-Event -SourceIdentifier $eventHandler.Name -ErrorAction SilentlyContinue
                    $webClient.Dispose()
                    throw New-Object System.TimeoutException("Download timeout after $DownloadTimeoutSeconds seconds")
                }
                
                # Event fired - remove the event from queue and unregister
                Remove-Event -SourceIdentifier $eventHandler.Name -ErrorAction SilentlyContinue
                Unregister-Event -SourceIdentifier $eventHandler.Name -ErrorAction SilentlyContinue
                
                # Check for download errors
                if ($downloadState.Error) {
                    $webClient.Dispose()
                    throw $downloadState.Error
                }
                
                # Dispose WebClient
                $webClient.Dispose()
                
                # Verify file was downloaded and has content
                if (-not (Test-Path -LiteralPath $DestinationPath)) {
                    throw New-Object System.IO.FileNotFoundException("Downloaded file not found at destination")
                }
                
                $fileInfo = Get-Item -LiteralPath $DestinationPath
                if ($fileInfo.Length -eq 0) {
                    throw New-Object System.IO.IOException("Downloaded file is empty")
                }
                
                $elapsed = (Get-Date) - $startTime
                Log-Info ("Download completed successfully in {0:N1} seconds: {1} ({2:N2} MB)" -f $elapsed.TotalSeconds, $DestinationPath, ($fileInfo.Length / 1MB))
            }

            return $true

        } catch {
            $lastException = $_
            Log-Warn ("Download attempt {0} failed: {1}" -f $attempt, $_.Exception.Message)
            
            # Clean up partial download
            if (Test-Path -LiteralPath $DestinationPath) {
                try {
                    Remove-Item -LiteralPath $DestinationPath -Force -ErrorAction SilentlyContinue
                } catch {
                    Log-Debug ("Failed to clean up partial download: {0}" -f $_.Exception.Message)
                }
            }

            if ($attempt -lt $MaxDownloadRetries) {
                Log-Info ("Retrying download in {0} seconds..." -f $DownloadRetryDelaySeconds)
                Start-Sleep -Seconds $DownloadRetryDelaySeconds
            }
        } finally {
            # Cleanup is handled in the try block
        }
    }

    # All retries failed
    Log-Error ("Download failed after {0} attempts: {1}" -f $MaxDownloadRetries, $lastException.Exception.Message)
    throw $lastException
}

function Expand-ZipFile {
    param(
        [Parameter(Mandatory = $true)][string]$ZipFilePath,
        [Parameter(Mandatory = $true)][string]$DestinationDirectory
    )

    try {
        Log-Info ("Extracting ZIP file: {0}" -f $ZipFilePath)
        Log-Info ("Extraction destination: {0}" -f $DestinationDirectory)

        # Ensure destination directory exists
        if (-not (Test-Path -LiteralPath $DestinationDirectory)) {
            New-Item -ItemType Directory -Path $DestinationDirectory -Force | Out-Null
            Log-Debug ("Created extraction directory: {0}" -f $DestinationDirectory)
        }

        # Use .NET System.IO.Compression.ZipFile to extract
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($ZipFilePath, $DestinationDirectory)

        # Verify extraction was successful by checking if directory has content
        $extractedItems = Get-ChildItem -LiteralPath $DestinationDirectory -Force
        if ($extractedItems.Count -eq 0) {
            throw New-Object System.IO.IOException("ZIP extraction completed but destination directory is empty")
        }

        Log-Info ("ZIP file extracted successfully: {0} item(s) extracted" -f $extractedItems.Count)
        return $true

    } catch {
        Log-Error ("Failed to extract ZIP file: {0}" -f $_.Exception.Message)
        return $false
    }
}

function Invoke-Uninstall {
    param(
        [Parameter(Mandatory = $true)][string]$UninstallCommand,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory
    )

    if ([string]::IsNullOrWhiteSpace($UninstallCommand)) {
        Log-Debug ("No uninstall command provided, skipping uninstallation")
        return $true
    }

    Log-Info ("Executing uninstall command: {0}" -f $UninstallCommand)
    Log-Info ("Working directory: {0}" -f $WorkingDirectory)

    # Track whether we completed normal execution. If not, the finally block may need to kill the process.
    $completed = $false

    try {
        $processInfo = New-Object System.Diagnostics.ProcessStartInfo
        $processInfo.FileName = "cmd.exe"
        $processInfo.Arguments = "/c `"$UninstallCommand`""
        $processInfo.WorkingDirectory = $WorkingDirectory
        $processInfo.UseShellExecute = $false
        $processInfo.RedirectStandardOutput = $true
        $processInfo.RedirectStandardError = $true
        $processInfo.CreateNoWindow = $true

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $processInfo

        $process.Start() | Out-Null
        
        # Wait for process to exit with timeout
        $exited = $process.WaitForExit($script:UninstallTimeoutSeconds * 1000)  # Timeout for uninstall (converted to milliseconds)
        
        if (-not $exited) {
            # Process did not exit within timeout - kill it
            Log-Warn ("Uninstall process exceeded timeout of {0} seconds, terminating process..." -f $script:UninstallTimeoutSeconds)
            try {
                $process.Kill()
                $process.WaitForExit()  # Wait for process to fully terminate
            } catch {
                Log-Warn ("Failed to kill uninstall process: {0}" -f $_.Exception.Message)
            }
            Log-Warn ("Uninstall process was terminated due to timeout")
            
            # Close the process to release resources
            if ($process) {
                try {
                    $process.Close()
                } catch {
                    Log-Debug ("Failed to close uninstall process after timeout: {0}" -f $_.Exception.Message)
                }
            }
            
            # Don't fail on timeout for uninstall - app may not be installed or may be stuck
            $completed = $true
            return $true
        }
        
        # Process exited within timeout - call WaitForExit() again to ensure async operations complete
        $process.WaitForExit()

        $exitCode = $process.ExitCode

        # Capture stdout and stderr synchronously after process completes
        $output = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()

        if (-not [string]::IsNullOrWhiteSpace($output)) {
            Log-Debug ("Uninstall output: {0}" -f $output)
        }
        if (-not [string]::IsNullOrWhiteSpace($stderr)) {
            Log-Debug ("Uninstall errors: {0}" -f $stderr)
        }

        if ($exitCode -eq 0) {
            Log-Info ("Uninstall completed successfully (exit code: {0})" -f $exitCode)
        } else {
            Log-Warn ("Uninstall returned exit code {0} (this may be expected if application is not installed)" -f $exitCode)
            # Don't fail on non-zero exit codes for uninstall - app may not be installed
        }
        
        # Close the process to release resources
        if ($process) {
            try {
                $process.Close()
            } catch {
                Log-Debug ("Failed to close uninstall process after completion: {0}" -f $_.Exception.Message)
            }
        }
        
        $completed = $true
        return $true

    } catch {
        Log-Error ("Uninstall execution failed: {0}" -f $_.Exception.Message)
        return $false
    } finally {
        # Ensure process streams are closed
        # Only attempt kill here if we didn't reach a normal return path
        if (-not $completed -and $process -and -not $process.HasExited) {
            try {
                $process.Kill()
            } catch {
                $killMsg = $_.Exception.Message
                if ($killMsg -match "No process associated with this object") {
                    # Benign race: process exited/closed between HasExited check and Kill()
                    Log-Debug ("Skipping uninstall process kill in finally block (process already exited/closed)")
                } else {
                    Log-Debug ("Failed to kill uninstall process in finally block: {0}" -f $killMsg)
                }
            }
        }
        if ($process) {
            try {
                $process.Close()
            } catch {
                Log-Debug ("Failed to close uninstall process in finally block: {0}" -f $_.Exception.Message)
            }
            try {
                $process.Dispose()
            } catch {
                Log-Debug ("Failed to dispose uninstall process in finally block: {0}" -f $_.Exception.Message)
            }
        }
    }
}

function Invoke-Install {
    param(
        [Parameter(Mandatory = $true)][string]$CommandLine,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory
    )

    Log-Info ("Executing install command: {0}" -f $CommandLine)
    Log-Info ("Working directory: {0}" -f $WorkingDirectory)

    # Track whether we completed normal execution. If not, the finally block may need to kill the process.
    $completed = $false

    try {
        # Reset per-install state used by summaries
        $script:InstallExitCode = $null
        $script:InstallStderr = $null

        $processInfo = New-Object System.Diagnostics.ProcessStartInfo
        $processInfo.FileName = "cmd.exe"
        $processInfo.Arguments = "/c `"$CommandLine`""
        $processInfo.WorkingDirectory = $WorkingDirectory
        $processInfo.UseShellExecute = $false
        $processInfo.RedirectStandardOutput = $true
        $processInfo.RedirectStandardError = $true
        $processInfo.CreateNoWindow = $true

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $processInfo

        $process.Start() | Out-Null
        
        # Wait for process to exit with timeout
        $exited = $process.WaitForExit($script:InstallationTimeoutSeconds * 1000)  # Timeout for installation (converted to milliseconds)
        
        if (-not $exited) {
            # Process did not exit within timeout - kill it
            $errorMsg = "Installation process exceeded timeout of $script:InstallationTimeoutSeconds seconds"
            Log-Error $errorMsg
            try {
                $process.Kill()
                $process.WaitForExit()  # Wait for process to fully terminate
            } catch {
                Log-Warn ("Failed to kill installation process: {0}" -f $_.Exception.Message)
            }
            
            # Close the process to release resources
            if ($process) {
                try {
                    $process.Close()
                } catch {
                    Log-Debug ("Failed to close installation process after timeout: {0}" -f $_.Exception.Message)
                }
            }
            
            $script:LastError = $errorMsg
            $completed = $true
            return [pscustomobject]@{
                Success     = $false
                ExitCode    = $null
                Error       = $errorMsg
                CommandLine = $CommandLine
            }
        }
        
        # Process exited within timeout - call WaitForExit() again to ensure async operations complete
        $process.WaitForExit()

        $exitCode = $process.ExitCode
        $script:InstallExitCode = $exitCode

        # Capture stdout and stderr synchronously after process completes
        $output = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()

        if (-not [string]::IsNullOrWhiteSpace($output)) {
            Log-Debug ("Install output: {0}" -f $output)
        }
        if (-not [string]::IsNullOrWhiteSpace($stderr)) {
            Log-Debug ("Install errors: {0}" -f $stderr)
            # Store installer stderr for inclusion in error summary
            $script:InstallStderr = $stderr.Trim()
        }

        if ($exitCode -in $SuccessExitCodes) {
            if ($exitCode -eq 0) {
                Log-Info ("Installation completed successfully (exit code: {0})" -f $exitCode)
            } else {
                Log-Info ("Installation completed with acceptable exit code: {0} (treated as success)" -f $exitCode)
            }
            $script:InstallSuccess = $true
            
            # Close the process to release resources
            if ($process) {
                try {
                    $process.Close()
                } catch {
                    Log-Debug ("Failed to close installation process after success: {0}" -f $_.Exception.Message)
                }
            }
            
            $completed = $true
            return [pscustomobject]@{
                Success     = $true
                ExitCode    = $exitCode
                Error       = $null
                CommandLine = $CommandLine
            }
        } else {
            $errorMsg = "Installation failed with exit code: $exitCode"
            Log-Error $errorMsg
            $script:LastError = $errorMsg
            $script:InstallSuccess = $false
            
            # Close the process to release resources
            if ($process) {
                try {
                    $process.Close()
                } catch {
                    Log-Debug ("Failed to close installation process after failure: {0}" -f $_.Exception.Message)
                }
            }
            
            $completed = $true
            return [pscustomobject]@{
                Success     = $false
                ExitCode    = $exitCode
                Error       = $errorMsg
                CommandLine = $CommandLine
            }
        }

    } catch {
        $errorMsg = "Installation execution failed: $($_.Exception.Message)"
        Log-Error $errorMsg
        $script:LastError = $errorMsg
        return [pscustomobject]@{
            Success     = $false
            ExitCode    = $null
            Error       = $errorMsg
            CommandLine = $CommandLine
        }
    } finally {
        # Ensure process streams are closed
        # Only attempt kill here if we didn't reach a normal return path
        if (-not $completed -and $process -and -not $process.HasExited) {
            try {
                $process.Kill()
            } catch {
                $killMsg = $_.Exception.Message
                if ($killMsg -match "No process associated with this object") {
                    # Benign race: process exited/closed between HasExited check and Kill()
                    Log-Debug ("Skipping installation process kill in finally block (process already exited/closed)")
                } else {
                    Log-Debug ("Failed to kill installation process in finally block: {0}" -f $killMsg)
                }
            }
        }
        if ($process) {
            try {
                $process.Close()
            } catch {
                Log-Debug ("Failed to close installation process in finally block: {0}" -f $_.Exception.Message)
            }
            try {
                $process.Dispose()
            } catch {
                Log-Debug ("Failed to dispose installation process in finally block: {0}" -f $_.Exception.Message)
            }
        }
    }
}

function Test-Administrator {
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Stop-ProcessesByName {
    param(
        [Parameter(Mandatory = $true)][string[]]$ProcessNames
    )

    if (-not $ProcessNames -or $ProcessNames.Count -eq 0) {
        Log-Debug ("No process names provided to stop")
        return $true
    }

    $killedCount = 0
    $notFoundCount = 0
    $errorCount = 0

    foreach ($processName in $ProcessNames) {
        if ([string]::IsNullOrWhiteSpace($processName)) {
            Log-Debug ("Skipping empty process name")
            continue
        }

        # Remove .exe extension if present for matching
        $nameToMatch = $processName.Trim()
        if ($nameToMatch.EndsWith(".exe", [System.StringComparison]::OrdinalIgnoreCase)) {
            $nameToMatch = $nameToMatch.Substring(0, $nameToMatch.Length - 4)
        }

        try {
            # Check if process is running
            # Get-Process can return $null, a single Process object, or an array of Process objects
            # Force to array to handle all cases consistently
            $processes = @(Get-Process -Name $nameToMatch -ErrorAction SilentlyContinue)
            
            if ($processes -and $processes.Count -gt 0) {
                Log-Info ("Found {0} running instance(s) of '{1}'" -f $processes.Count, $processName)
                
                foreach ($proc in $processes) {
                    try {
                        Log-Info ("  Killing process: {0} (PID: {1})" -f $proc.ProcessName, $proc.Id)
                        Stop-Process -Id $proc.Id -Force -ErrorAction Stop
                        
                        # Wait for process to actually terminate (5 second timeout)
                        $exited = $proc.WaitForExit(5000)
                        if ($exited) {
                            Log-Debug ("  Process {0} (PID: {1}) terminated successfully" -f $proc.ProcessName, $proc.Id)
                        } else {
                            Log-Warn ("  Process {0} (PID: {1}) did not terminate within timeout, but continuing..." -f $proc.ProcessName, $proc.Id)
                        }
                        
                        $killedCount++
                    } catch {
                        Log-Warn ("  Failed to kill process {0} (PID: {1}): {2}" -f $proc.ProcessName, $proc.Id, $_.Exception.Message)
                        $errorCount++
                    }
                }
            } else {
                Log-Debug ("Process '{0}' is not running" -f $processName)
                $notFoundCount++
            }
        } catch {
            Log-Warn ("Error checking for process '{0}': {1}" -f $processName, $_.Exception.Message)
            $errorCount++
        }
    }

    if ($killedCount -gt 0) {
        Log-Info ("Process termination completed: {0} killed, {1} not found, {2} errors" -f $killedCount, $notFoundCount, $errorCount)
    } else {
        Log-Info ("No processes were running that needed to be killed")
    }

    return $true
}

# ---------------------------------------------------------------------------------
# Main Script Execution
# ---------------------------------------------------------------------------------

# Acquire a global named mutex to prevent multiple instances from running simultaneously.
# If another instance is already running (e.g., MDM agent launched duplicates), this instance
# waits up to 60 seconds for the lock, then exits cleanly with code 0 so the MDM does not retry.
$mutexName = "Global\IruAppInstallScript"
$mutex = $null
$mutexAcquired = $false
try {
    $mutex = New-Object System.Threading.Mutex($false, $mutexName)
    $mutexAcquired = $mutex.WaitOne(60000)  # Wait up to 60 seconds
} catch [System.Threading.AbandonedMutexException] {
    # Previous holder crashed - we now own the mutex
    $mutexAcquired = $true
} catch {
    # If mutex creation fails entirely, proceed anyway (best effort)
    $mutexAcquired = $true
}

if (-not $mutexAcquired) {
    # Another instance is still running after 60 seconds - exit cleanly
    # Use exit 0 so the MDM does not treat this as a failure and retry endlessly
    if ($mutex) { try { $mutex.Dispose() } catch { } }
    exit 0
}

try {
    # Determine parameter values (CLI takes precedence over defaults)
    # PowerShell automatically assigns command-line parameters, so we only need to fall back to defaults if not provided
    
    # Array parameters for multi-app installs: Use command-line value if provided, otherwise use default
    if (-not $PSBoundParameters.ContainsKey('DownloadUrls')) {
        $DownloadUrls = $DownloadUrlsDefault
    }
    
    if (-not $PSBoundParameters.ContainsKey('InstallCommandLines')) {
        $InstallCommandLines = $InstallCommandLinesDefault
    }
    
    if (-not $PSBoundParameters.ContainsKey('DownloadDirectory')) {
        if (-not [string]::IsNullOrWhiteSpace($DownloadDirectoryDefault)) {
            $DownloadDirectory = $DownloadDirectoryDefault
        } else {
            # Fallback to ProgramData if default wasn't set
            $programDataPath = [Environment]::GetFolderPath("CommonApplicationData")
            $DownloadDirectory = Join-Path $programDataPath "Iru\AppInstalls"
        }
    }
    
    # Array parameters: Use command-line value if provided, otherwise use default
    if (-not $PSBoundParameters.ContainsKey('UninstallCommandLines')) {
        $UninstallCommandLines = $UninstallCommandLinesDefault
    }
    
    if (-not $PSBoundParameters.ContainsKey('ProcessNamesToKill')) {
        $ProcessNamesToKill = $ProcessNamesToKillDefault
    }
    
    # Numeric parameters: Use command-line value if provided, otherwise use default
    if (-not $PSBoundParameters.ContainsKey('UninstallTimeoutSeconds')) {
        $script:UninstallTimeoutSeconds = $UninstallTimeoutSecondsDefault
    } else {
        $script:UninstallTimeoutSeconds = $UninstallTimeoutSeconds
    }
    
    if (-not $PSBoundParameters.ContainsKey('InstallationTimeoutSeconds')) {
        $script:InstallationTimeoutSeconds = $InstallationTimeoutSecondsDefault
    } else {
        $script:InstallationTimeoutSeconds = $InstallationTimeoutSeconds
    }
    
    if (-not $PSBoundParameters.ContainsKey('UrlTestTimeoutSeconds')) {
        $script:UrlTestTimeoutSeconds = $UrlTestTimeoutSecondsDefault
    } else {
        $script:UrlTestTimeoutSeconds = $UrlTestTimeoutSeconds
    }
    
    # Switch parameters: Use command-line value if provided, otherwise use default
    if (-not $PSBoundParameters.ContainsKey('CleanupAfterInstall')) {
        $CleanupAfterInstall = $CleanupAfterInstallDefault
    }
    
    if (-not $PSBoundParameters.ContainsKey('Debug')) {
        $script:DebugMode = $EnableDebugDefault
    } else {
        $script:DebugMode = $Debug
    }

    # Initialize logging
    Initialize-Logger

    Log-Info ("Application Installation Script v{0}" -f $VERSION)

    # Resolve multi-app inputs (array-only)
    $resolvedDownloadUrls = @($DownloadUrls | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $resolvedInstallCommandLines = @($InstallCommandLines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    # Validate required parameters
    if (-not $resolvedDownloadUrls -or $resolvedDownloadUrls.Count -eq 0) {
        $errorMsg = "DownloadUrls is required but was not provided"
        Log-Error $errorMsg
        $script:LastError = $errorMsg
        try { Write-SummaryOutput -IsError $true } catch { }
        if ($mutexAcquired -and $mutex) { try { $mutex.ReleaseMutex() } catch { } }
        if ($mutex) { try { $mutex.Dispose() } catch { } }
        exit 1
    }

    if (-not $resolvedInstallCommandLines -or $resolvedInstallCommandLines.Count -eq 0) {
        $errorMsg = "InstallCommandLines is required but was not provided"
        Log-Error $errorMsg
        $script:LastError = $errorMsg
        try { Write-SummaryOutput -IsError $true } catch { }
        if ($mutexAcquired -and $mutex) { try { $mutex.ReleaseMutex() } catch { } }
        if ($mutex) { try { $mutex.Dispose() } catch { } }
        exit 1
    }

    # Check for administrator privileges
    if (-not (Test-Administrator)) {
        $errorMsg = "This script must be run with administrator privileges"
        Log-Error $errorMsg
        $script:LastError = $errorMsg
        try { Write-SummaryOutput -IsError $true } catch { }
        if ($mutexAcquired -and $mutex) { try { $mutex.ReleaseMutex() } catch { } }
        if ($mutex) { try { $mutex.Dispose() } catch { } }
        exit 1
    }

    Log-Info ("Configuration:")
    Log-Info ("  Download URLs: {0}" -f $resolvedDownloadUrls.Count)
    for ($i = 0; $i -lt $resolvedDownloadUrls.Count; $i++) {
        Log-Info ("    [{0}] {1}" -f ($i + 1), $resolvedDownloadUrls[$i])
    }
    Log-Info ("  Install Command Lines: {0}" -f $resolvedInstallCommandLines.Count)
    for ($i = 0; $i -lt $resolvedInstallCommandLines.Count; $i++) {
        Log-Info ("    [{0}] {1}" -f ($i + 1), $resolvedInstallCommandLines[$i])
    }
    Log-Info ("  Download Directory: {0}" -f $DownloadDirectory)
    if ($ProcessNamesToKill -and $ProcessNamesToKill.Count -gt 0) {
        Log-Info ("  Process Names to Kill ({0}):" -f $ProcessNamesToKill.Count)
        for ($i = 0; $i -lt $ProcessNamesToKill.Count; $i++) {
            Log-Info ("    [{0}] {1}" -f ($i + 1), $ProcessNamesToKill[$i])
        }
    } else {
        Log-Info ("  Process Names to Kill: (none)")
    }
    if ($UninstallCommandLines -and $UninstallCommandLines.Count -gt 0) {
        Log-Info ("  Uninstall Command Lines ({0}):" -f $UninstallCommandLines.Count)
        for ($i = 0; $i -lt $UninstallCommandLines.Count; $i++) {
            Log-Info ("    [{0}] {1}" -f ($i + 1), $UninstallCommandLines[$i])
        }
    } else {
        Log-Info ("  Uninstall Command Lines: (none)")
    }
    Log-Info ("  Cleanup After Install: {0}" -f $CleanupAfterInstall)
    Log-Info ("  Debug Mode: {0}" -f $script:DebugMode)

    # Validate mapping: either 1:1 URLs->installs, or 1 URL + many installs (e.g., zip containing multiple installers)
    $installToDownloadIndex = @()
    if ($resolvedDownloadUrls.Count -eq $resolvedInstallCommandLines.Count) {
        for ($i = 0; $i -lt $resolvedInstallCommandLines.Count; $i++) {
            $installToDownloadIndex += $i
        }
    } elseif ($resolvedDownloadUrls.Count -eq 1 -and $resolvedInstallCommandLines.Count -ge 1) {
        for ($i = 0; $i -lt $resolvedInstallCommandLines.Count; $i++) {
            $installToDownloadIndex += 0
        }
    } else {
        $errorMsg = ("DownloadUrls/InstallCommandLines count mismatch. Provide matching counts, or provide 1 DownloadUrl with multiple InstallCommandLines. DownloadUrls={0}, InstallCommandLines={1}" -f $resolvedDownloadUrls.Count, $resolvedInstallCommandLines.Count)
        Log-Error $errorMsg
        $script:LastError = $errorMsg
        try { Write-SummaryOutput -IsError $true } catch { }
        if ($mutexAcquired -and $mutex) { try { $mutex.ReleaseMutex() } catch { } }
        if ($mutex) { try { $mutex.Dispose() } catch { } }
        exit 1
    }

    # Create unique GUID folder for this download session
    # This prevents overwriting existing installers when cleanup is disabled and script is rerun
    $downloadGuid = [System.Guid]::NewGuid().ToString()
    $script:DownloadSessionDirectory = Join-Path $DownloadDirectory $downloadGuid
    
    Log-Info ("Creating unique download session folder: {0}" -f $script:DownloadSessionDirectory)
    if (-not (Test-Path -LiteralPath $script:DownloadSessionDirectory)) {
        New-Item -ItemType Directory -Path $script:DownloadSessionDirectory -Force | Out-Null
        Log-Debug ("Created download session directory: {0}" -f $script:DownloadSessionDirectory)
    }

    # Step 1: Download all installers first (to avoid racing installs across MDM parallel scripts)
    Log-Info ("Step 1: Downloading installers ({0})..." -f $resolvedDownloadUrls.Count)
    $downloadItems = @()
    $script:DownloadFailures = @()

    for ($i = 0; $i -lt $resolvedDownloadUrls.Count; $i++) {
        $url = $resolvedDownloadUrls[$i]

        # For a single download URL, use the root session folder directly (common for ZIP bundles).
        # For multiple URLs, isolate each download into its own unique folder under the session folder.
        $itemDir = $script:DownloadSessionDirectory
        if ($resolvedDownloadUrls.Count -gt 1) {
            $itemDir = Join-Path $script:DownloadSessionDirectory ([System.Guid]::NewGuid().ToString())
            if (-not (Test-Path -LiteralPath $itemDir)) {
                New-Item -ItemType Directory -Path $itemDir -Force | Out-Null
            }
        }

        Log-Info ("  Download [{0}/{1}]: {2}" -f ($i + 1), $resolvedDownloadUrls.Count, $url)

        # Test URL accessibility (best-effort) for each download
        $urlAccessible = Test-UrlAccessible -Url $url -TimeoutSeconds $script:UrlTestTimeoutSeconds
        if (-not $urlAccessible) {
            Log-Warn ("  URL accessibility test failed, but proceeding with download attempt...")
        }

        $fileName = $null
        try {
            $fileName = Get-FileNameFromUrl -Url $url -TimeoutSeconds $script:UrlTestTimeoutSeconds
        } catch {
            $msg = "Failed to determine filename for URL: $url"
            Log-Error $msg
            $script:DownloadFailures += @{ Url = $url; Error = $msg }
            continue
        }

        $filePath = Join-Path $itemDir $fileName
        Log-Info ("    Target: {0}" -f $filePath)

        try {
            $null = Invoke-DownloadFile -Url $url -DestinationPath $filePath
        } catch {
            $msg = "Download failed: $($_.Exception.Message)"
            Log-Error ("    {0}" -f $msg)
            $script:DownloadFailures += @{ Url = $url; Error = $msg }
            continue
        }

        if (-not (Test-Path -LiteralPath $filePath)) {
            $msg = "Downloaded file not found at expected location: $filePath"
            Log-Error ("    {0}" -f $msg)
            $script:DownloadFailures += @{ Url = $url; Error = $msg }
            continue
        }

        $fileInfo = Get-Item -LiteralPath $filePath
        if ($fileInfo.Length -eq 0) {
            $msg = "Downloaded file is empty: $filePath"
            Log-Error ("    {0}" -f $msg)
            $script:DownloadFailures += @{ Url = $url; Error = $msg }
            continue
        }
        Log-Info ("    File verified: {0} ({1:N2} MB)" -f $fileInfo.Name, ($fileInfo.Length / 1MB))

        # ZIP handling: extract into the same folder and delete the ZIP
        $extension = [System.IO.Path]::GetExtension($filePath).ToLower()
        if ($extension -eq ".zip") {
            Log-Info ("    ZIP file detected - extracting to same folder...")
            $extractResult = Expand-ZipFile -ZipFilePath $filePath -DestinationDirectory $itemDir
            if (-not $extractResult) {
                $msg = "ZIP extraction failed"
                Log-Error ("    {0}" -f $msg)
                $script:DownloadFailures += @{ Url = $url; Error = $msg }
                continue
            }

            try {
                Remove-Item -LiteralPath $filePath -Force
                Log-Info ("    ZIP file deleted successfully")
            } catch {
                Log-Warn ("    Failed to delete ZIP file: {0}" -f $_.Exception.Message)
            }
        }

        $downloadItems += [pscustomobject]@{
            Index            = $i
            Url              = $url
            WorkingDirectory = $itemDir
            DownloadedPath   = $filePath
            Success          = $true
        }
    }

    $script:DownloadSuccess = ($script:DownloadFailures.Count -eq 0)

    # Step 2: Kill processes if specified (before uninstalls and installs)
    if ($ProcessNamesToKill -and $ProcessNamesToKill.Count -gt 0) {
        Log-Info ("Step 2: Checking for and killing specified processes...")
        $null = Stop-ProcessesByName -ProcessNames $ProcessNamesToKill
    }

    # Step 3: Execute uninstall commands if provided
    if ($UninstallCommandLines -and $UninstallCommandLines.Count -gt 0) {
        Log-Info ("Step 3: Uninstalling existing applications (if present)...")
        $uninstallSuccessCount = 0
        $uninstallFailureCount = 0
        $uninstallWorkingDirectory = $script:DownloadSessionDirectory
        
        for ($i = 0; $i -lt $UninstallCommandLines.Count; $i++) {
            $uninstallCmd = $UninstallCommandLines[$i]
            if ([string]::IsNullOrWhiteSpace($uninstallCmd)) {
                Log-Debug ("Skipping empty uninstall command at index {0}" -f $i)
                continue
            }
            
            Log-Info ("  Uninstall command [{0}/{1}]: {2}" -f ($i + 1), $UninstallCommandLines.Count, $uninstallCmd)
            $uninstallResult = Invoke-Uninstall -UninstallCommand $uninstallCmd -WorkingDirectory $uninstallWorkingDirectory
            if ($uninstallResult) {
                $uninstallSuccessCount++
            } else {
                $uninstallFailureCount++
                Log-Warn ("Uninstall command [{0}] encountered issues, but continuing..." -f ($i + 1))
            }
            
            # Brief pause between uninstall commands
            if ($i -lt ($UninstallCommandLines.Count - 1)) {
                Start-Sleep -Seconds 2
            }
        }
        
        Log-Info ("Uninstall step completed: {0} succeeded, {1} had issues" -f $uninstallSuccessCount, $uninstallFailureCount)
        Start-Sleep -Seconds 2  # Brief pause after all uninstalls
    }

    # Step 4: Install applications sequentially
    Log-Info ("Step 4: Installing applications sequentially ({0})..." -f $resolvedInstallCommandLines.Count)
    $script:InstallFailures = @()
    $script:InstallSuccesses = @()
    $installSuccessCount = 0
    $installFailureCount = 0

    for ($i = 0; $i -lt $resolvedInstallCommandLines.Count; $i++) {
        $cmd = $resolvedInstallCommandLines[$i]
        if ([string]::IsNullOrWhiteSpace($cmd)) {
            Log-Debug ("Skipping empty install command at index {0}" -f $i)
            continue
        }

        $downloadIndex = $installToDownloadIndex[$i]
        $downloadItem = $null
        if ($downloadItems -and $downloadItems.Count -gt 0) {
            $downloadItem = $downloadItems | Where-Object { $_.Index -eq $downloadIndex } | Select-Object -First 1
        }

        if (-not $downloadItem) {
            $msg = "Skipping install because corresponding download failed or was not available"
            Log-Error ("Install command [{0}/{1}] skipped: {2}" -f ($i + 1), $resolvedInstallCommandLines.Count, $cmd)
            $script:InstallFailures += @{ CommandLine = $cmd; ExitCode = $null; Error = $msg }
            $installFailureCount++
            continue
        }

        Log-Info ("  Install command [{0}/{1}]: {2}" -f ($i + 1), $resolvedInstallCommandLines.Count, $cmd)
        Log-Info ("  Working directory: {0}" -f $downloadItem.WorkingDirectory)

        $result = Invoke-Install -CommandLine $cmd -WorkingDirectory $downloadItem.WorkingDirectory
        if ($result -and $result.Success) {
            $installSuccessCount++
            $script:InstallSuccesses += $cmd
        } else {
            $installFailureCount++
            $exitCode = $null
            $errorMsg = $null
            try { $exitCode = $result.ExitCode } catch { }
            try { $errorMsg = $result.Error } catch { }
            # Also capture installer stderr if available (more useful than generic message)
            if (-not [string]::IsNullOrWhiteSpace($script:InstallStderr)) {
                $errorMsg = $script:InstallStderr
            }
            Log-Error ("Install command failed (exit code: {0}): {1}" -f $exitCode, $cmd)
            $script:InstallFailures += @{ CommandLine = $cmd; ExitCode = $exitCode; Error = $errorMsg }
        }
    }

    Log-Info ("Install step completed: {0} succeeded, {1} failed" -f $installSuccessCount, $installFailureCount)

    # Step 5: Cleanup download session folder if requested
    if ($CleanupAfterInstall) {
        Log-Info ("Step 5: Cleaning up download session folder...")
        if ($script:DownloadSessionDirectory -and (Test-Path -LiteralPath $script:DownloadSessionDirectory)) {
            try {
                Remove-Item -LiteralPath $script:DownloadSessionDirectory -Recurse -Force
                Log-Info ("Download session folder removed successfully")
            } catch {
                Log-Warn ("Failed to remove download session folder: {0}" -f $_.Exception.Message)
            }
        }
    }

    $hadFailures = (($script:DownloadFailures -and $script:DownloadFailures.Count -gt 0) -or ($script:InstallFailures -and $script:InstallFailures.Count -gt 0))
    if ($hadFailures) {
        $script:InstallSuccess = $false
        $script:LastError = "One or more downloads or installations failed"
        try { Write-SummaryOutput -IsError $true } catch { }
        if ($mutexAcquired -and $mutex) { try { $mutex.ReleaseMutex() } catch { } }
        if ($mutex) { try { $mutex.Dispose() } catch { } }
        exit 1
    }

    $script:InstallSuccess = $true
    $script:InstallExitCode = 0

    Log-Info ("Script completed successfully")
    
    # Output summary to stdout
    try { Write-SummaryOutput -IsError $false } catch { }

    if ($mutexAcquired -and $mutex) { try { $mutex.ReleaseMutex() } catch { } }
    if ($mutex) { try { $mutex.Dispose() } catch { } }
    exit 0

} catch {
    $errorMsg = "Unexpected error: $($_.Exception.Message)"
    try { Log-Error $errorMsg } catch { }
    try { Log-Error ("Stack trace: {0}" -f $_.ScriptStackTrace) } catch { }
    $script:LastError = $errorMsg
    
    # Cleanup on error if download session folder was created
    if ($CleanupAfterInstall) {
        try {
            if ($script:DownloadSessionDirectory -and (Test-Path -LiteralPath $script:DownloadSessionDirectory)) {
                Remove-Item -LiteralPath $script:DownloadSessionDirectory -Recurse -Force -ErrorAction SilentlyContinue
            }
        } catch {
            # Ignore cleanup errors during error handling
        }
    }
    
    # Output summary to stderr - wrap so exit 1 always runs
    try { Write-SummaryOutput -IsError $true } catch { }
    
    if ($mutexAcquired -and $mutex) { try { $mutex.ReleaseMutex() } catch { } }
    if ($mutex) { try { $mutex.Dispose() } catch { } }
    exit 1
}
