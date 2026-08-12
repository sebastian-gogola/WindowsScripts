<#
================================================================================
 EXPERIMENTAL DISCLAIMER - SANDBOX TIER
 This script is experimental and has not completed validation for the official
 Iru WindowsScripts tier. It is provided as-is, without warranty of any kind.
 Test thoroughly in an isolated environment before deploying to any production
 device. The author assumes no liability for damage resulting from its use.
 [ NOTE: Replace this block with the canonical byte-identical Sandbox
   disclaimer block before committing. ]
================================================================================

.SYNOPSIS
    Manage-CisHardening - Audits and enforces CIS Windows 11 benchmark controls
    via HardeningKitty, deployed as an Iru Custom Script Library Item.

.DESCRIPTION
    Wraps the HardeningKitty PowerShell module (scipag/HardeningKitty, MIT) in
    the standard Iru Audit/Remediation pattern. The same file is deployed to
    both Library Item slots; only the $Mode value differs:

        Iru Audit slot        -> $Mode = 'Audit'
        Iru Remediation slot  -> $Mode = 'Enforce'

    Modes:
        Audit    - Read-only compliance check against the pruned finding list.
                   Exit 0 if pass rate >= threshold, exit 1 otherwise.
        Enforce  - HardeningKitty Config backup, then HailMary apply.
        Discover - Dump current configuration (HardeningKitty Config mode)
                   without comparison or change. Always exits 0 on success.

    Revert is intentionally NOT supported. HardeningKitty backups are
    best-effort registry restores, not snapshots. Rollback strategy is
    device backup / re-provision. See README.md.

    Payload staging: HardeningKitty is a module + CSV, but Iru deploys a
    single script. This wrapper stages the payload to %ProgramData% from a
    pinned URL and verifies SHA256 hashes before importing anything. A hash
    mismatch or download failure is a hard stop (exit 2) - this script will
    not execute unverified code as SYSTEM.

.NOTES
    Execution : NT AUTHORITY\SYSTEM via Iru Custom Script Library Item
    PowerShell: Windows PowerShell 5.1 (not PowerShell 7)
    OS        : Windows 11 (build 22000+), English language
    Encoding  : Pure ASCII
    Exit codes: 0 = compliant / success
                1 = non-compliant (Audit) / runtime failure
                2 = precondition or staging failure (wrong OS, hash mismatch,
                    download failure, module import failure)
    Log       : %ProgramData%\IruScripts\Logs\Manage-CisHardening.log
    State     : HKLM:\SOFTWARE\IruScripts\ManageCisHardening
#>

# =============================================================================
# CONFIG BLOCK - edit here, no parameters
# =============================================================================

# 'Audit' in the Iru Audit slot | 'Enforce' in the Iru Remediation slot
$Mode = 'Audit'

# Audit passes when (Passed findings / total findings) * 100 >= this value.
# Deliberately below 100: a small number of controls flap (pending reboots,
# overlapping profile writers). Raise per customer requirement.
$PassRateThreshold = 95

# Pinned payload sources. Module files are pinned to the upstream release tag
# v.0.9.4 (verified byte-identical between the tag archive and raw URLs).
# The pruned finding list is served from OUR repo - replace PINNED-COMMIT with
# the commit SHA after committing payload/, and recompute its hash if the CSV
# is ever edited: Get-FileHash -Algorithm SHA256 <file>
$PayloadFiles = @(
    @{
        Name   = 'HardeningKitty.psm1'
        Url    = 'https://raw.githubusercontent.com/scipag/HardeningKitty/refs/tags/v.0.9.4/HardeningKitty.psm1'
        Sha256 = '01EBA5F0F4F11FA21616946BD9EA7ECCD56079ABB9CAFDC7B8E7C60C75F63AEE'
    },
    @{
        Name   = 'HardeningKitty.psd1'
        Url    = 'https://raw.githubusercontent.com/scipag/HardeningKitty/refs/tags/v.0.9.4/HardeningKitty.psd1'
        Sha256 = '9789FF549F0E9D4FFF0D1DD31620459B9AF3BB47968D202A83C24B0EA5641BDE'
    },
    @{
        Name   = 'finding_list_iru_cis_win11_machine.csv'
        Url    = 'https://raw.githubusercontent.com/sebastian-gogola/WindowsScripts/PINNED-COMMIT/Sandbox/Manage-CisHardening/payload/finding_list_iru_cis_win11_machine.csv'
        Sha256 = '88FEB973A6DDAE84D0AA5A0AF0B090B3649E446B185CD2D621FEB19240D5C478'
    }
)

# Paths and state (repo conventions)
$PayloadRoot  = Join-Path $env:ProgramData 'IruScripts\HardeningKitty'
$LogDir       = Join-Path $env:ProgramData 'IruScripts\Logs'
$LogFile      = Join-Path $LogDir 'Manage-CisHardening.log'
$ReportDir    = Join-Path $PayloadRoot 'Reports'
$StateKeyPath = 'HKLM:\SOFTWARE\IruScripts\ManageCisHardening'

# Cap for FailedControlIds registry value (REG_SZ practicality, not a hard OS
# limit). Full detail is always in the report CSV and log.
$MaxFailedIdsLength = 2048

# =============================================================================
# LOGGING
# =============================================================================

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )
    $line = ('{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message)
    Write-Output $line
    try {
        Add-Content -Path $LogFile -Value $line -Encoding ASCII -ErrorAction Stop
    } catch {
        # stdout still captured by Iru; never fail the run over logging
    }
}

function Set-StateValue {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)]$Value
    )
    try {
        if (-not (Test-Path $StateKeyPath)) {
            New-Item -Path $StateKeyPath -Force | Out-Null
        }
        New-ItemProperty -Path $StateKeyPath -Name $Name -Value $Value -Force | Out-Null
    } catch {
        Write-Log ('Failed to write state value {0}: {1}' -f $Name, $_.Exception.Message) 'WARN'
    }
}

function Exit-Script {
    param([Parameter(Mandatory = $true)][int]$Code)
    Set-StateValue -Name 'LastRunMode' -Value $Mode
    Set-StateValue -Name 'LastExitCode' -Value $Code
    Set-StateValue -Name 'LastRunTime' -Value (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    Write-Log ('Exiting with code {0}' -f $Code)
    exit $Code
}

# =============================================================================
# PRECONDITIONS
# =============================================================================

foreach ($dir in @($LogDir, $PayloadRoot, $ReportDir)) {
    if (-not (Test-Path $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }
}

Write-Log ('=== Manage-CisHardening starting | Mode={0} ===' -f $Mode)

if ($PSVersionTable.PSVersion.Major -ne 5) {
    Write-Log ('Requires Windows PowerShell 5.1, found {0}' -f $PSVersionTable.PSVersion) 'ERROR'
    Exit-Script 2
}

$osBuild = [int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuildNumber
if ($osBuild -lt 22000) {
    Write-Log ('Requires Windows 11 (build 22000+), found build {0}' -f $osBuild) 'ERROR'
    Exit-Script 2
}
Write-Log ('OS build {0} - OK' -f $osBuild)

if (@('Audit', 'Enforce', 'Discover') -notcontains $Mode) {
    Write-Log ('Invalid Mode value: {0}' -f $Mode) 'ERROR'
    Exit-Script 2
}

# HardeningKitty parses secedit output; documented for English systems only.
$uiLang = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\Language' -ErrorAction SilentlyContinue).InstallLanguage
if ($uiLang -and $uiLang -ne '0409') {
    Write-Log ('OS install language {0} is not en-US (0409). HardeningKitty results may be inaccurate for secedit / User Rights controls.' -f $uiLang) 'WARN'
}

# =============================================================================
# PAYLOAD STAGING - verify or fetch, fail closed
# =============================================================================

function Test-PayloadFile {
    param([hashtable]$File)
    $path = Join-Path $PayloadRoot $File.Name
    if (-not (Test-Path $path)) { return $false }
    $actual = (Get-FileHash -Path $path -Algorithm SHA256).Hash
    return ($actual -eq $File.Sha256.ToUpper())
}

[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

foreach ($file in $PayloadFiles) {
    if ($file.Sha256 -like 'REPLACE*' -or $file.Url -like '*REPLACE-ME*' -or $file.Url -like '*PINNED-COMMIT*') {
        Write-Log ('Config incomplete: pinned URL/hash not set for {0}' -f $file.Name) 'ERROR'
        Exit-Script 2
    }

    if (Test-PayloadFile -File $file) {
        Write-Log ('Payload verified: {0}' -f $file.Name)
        continue
    }

    $dest = Join-Path $PayloadRoot $file.Name
    Write-Log ('Staging {0} from pinned source' -f $file.Name)
    try {
        Invoke-WebRequest -Uri $file.Url -OutFile $dest -UseBasicParsing -ErrorAction Stop
    } catch {
        Write-Log ('Download failed for {0}: {1}' -f $file.Name, $_.Exception.Message) 'ERROR'
        Exit-Script 2
    }

    if (-not (Test-PayloadFile -File $file)) {
        Write-Log ('SHA256 MISMATCH for {0} after download. Refusing to execute unverified payload as SYSTEM.' -f $file.Name) 'ERROR'
        Remove-Item -Path $dest -Force -ErrorAction SilentlyContinue
        Exit-Script 2
    }
    Write-Log ('Staged and verified: {0}' -f $file.Name)
}

$modulePath      = Join-Path $PayloadRoot 'HardeningKitty.psm1'
$findingListPath = Join-Path $PayloadRoot 'finding_list_iru_cis_win11_machine.csv'
Set-StateValue -Name 'PayloadHash' -Value ((Get-FileHash -Path $modulePath -Algorithm SHA256).Hash)
Set-StateValue -Name 'FindingListHash' -Value ((Get-FileHash -Path $findingListPath -Algorithm SHA256).Hash)

try {
    Import-Module $modulePath -Force -ErrorAction Stop
    Write-Log 'HardeningKitty module imported'
} catch {
    Write-Log ('Module import failed: {0}' -f $_.Exception.Message) 'ERROR'
    Exit-Script 2
}

# =============================================================================
# MODE DISPATCH
# =============================================================================

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'

switch ($Mode) {

    # -------------------------------------------------------------------------
    'Audit' {
        $reportFile = Join-Path $ReportDir ('audit_{0}.csv' -f $timestamp)
        Write-Log ('Running HardeningKitty Audit | report: {0}' -f $reportFile)

        try {
            Invoke-HardeningKitty -Mode Audit -Report -ReportFile $reportFile `
                -FileFindingList $findingListPath *>&1 |
                ForEach-Object { Add-Content -Path $LogFile -Value ('    HK: ' + $_) -Encoding ASCII -ErrorAction SilentlyContinue }
        } catch {
            Write-Log ('HardeningKitty Audit failed: {0}' -f $_.Exception.Message) 'ERROR'
            Exit-Script 1
        }

        if (-not (Test-Path $reportFile)) {
            Write-Log 'Audit completed but report file was not created' 'ERROR'
            Exit-Script 1
        }

        $results = Import-Csv -Path $reportFile
        if (-not $results -or $results.Count -eq 0) {
            Write-Log 'Report file is empty' 'ERROR'
            Exit-Script 1
        }

        # Defensive: locate the severity column rather than assuming schema.
        # HardeningKitty report rows carry Passed / Low / Medium / High.
        $severityCol = ($results[0].PSObject.Properties.Name |
            Where-Object { $_ -match 'Severity' } | Select-Object -First 1)
        if (-not $severityCol) {
            Write-Log ('Could not locate Severity column in report. Columns: {0}' -f (($results[0].PSObject.Properties.Name) -join ', ')) 'ERROR'
            Exit-Script 1
        }

        $total  = $results.Count
        $passed = @($results | Where-Object { $_.$severityCol -eq 'Passed' }).Count
        $low    = @($results | Where-Object { $_.$severityCol -eq 'Low' }).Count
        $medium = @($results | Where-Object { $_.$severityCol -eq 'Medium' }).Count
        $high   = @($results | Where-Object { $_.$severityCol -eq 'High' }).Count

        $passRate = [math]::Round(($passed / $total) * 100, 2)

        # HardeningKitty score formula: (points / max points) * 5 + 1
        # Passed = 4, Low = 2, Medium = 1, High = 0
        $points   = ($passed * 4) + ($low * 2) + ($medium * 1)
        $hkScore  = [math]::Round((($points / ($total * 4)) * 5) + 1, 2)

        $idCol = ($results[0].PSObject.Properties.Name |
            Where-Object { $_ -match '^ID$' } | Select-Object -First 1)
        $failedIds = ''
        if ($idCol) {
            $failedIds = (@($results | Where-Object { $_.$severityCol -ne 'Passed' } |
                ForEach-Object { $_.$idCol }) -join ',')
            if ($failedIds.Length -gt $MaxFailedIdsLength) {
                $failedIds = $failedIds.Substring(0, $MaxFailedIdsLength) + ',...TRUNCATED'
            }
        }

        Write-Log ('Audit results: Total={0} Passed={1} Low={2} Medium={3} High={4}' -f $total, $passed, $low, $medium, $high)
        Write-Log ('Pass rate: {0}% (threshold {1}%) | HardeningKitty score: {2}/6' -f $passRate, $PassRateThreshold, $hkScore)

        Set-StateValue -Name 'LastAuditTime' -Value (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        Set-StateValue -Name 'LastAuditScore' -Value ([string]$hkScore)
        Set-StateValue -Name 'LastAuditPassRate' -Value ([string]$passRate)
        Set-StateValue -Name 'LastAuditReport' -Value $reportFile
        Set-StateValue -Name 'FailedControlIds' -Value $failedIds

        if ($passRate -ge $PassRateThreshold) {
            Write-Log 'COMPLIANT'
            Exit-Script 0
        } else {
            Write-Log 'NON-COMPLIANT - remediation required'
            Exit-Script 1
        }
    }

    # -------------------------------------------------------------------------
    'Enforce' {
        $backupFile = Join-Path $ReportDir ('backup_{0}.csv' -f $timestamp)
        Write-Log ('Taking HardeningKitty Config backup: {0}' -f $backupFile)
        Write-Log 'NOTE: HK backup is best-effort registry restore data, NOT a snapshot.' 'WARN'

        try {
            Invoke-HardeningKitty -Mode Config -Backup -BackupFile $backupFile `
                -FileFindingList $findingListPath *>&1 |
                ForEach-Object { Add-Content -Path $LogFile -Value ('    HK: ' + $_) -Encoding ASCII -ErrorAction SilentlyContinue }
        } catch {
            Write-Log ('Config backup failed: {0} - continuing (backup is best-effort)' -f $_.Exception.Message) 'WARN'
        }

        Write-Log 'Running HardeningKitty HailMary (applying finding list)'
        try {
            Invoke-HardeningKitty -Mode HailMary -SkipRestorePoint `
                -FileFindingList $findingListPath *>&1 |
                ForEach-Object { Add-Content -Path $LogFile -Value ('    HK: ' + $_) -Encoding ASCII -ErrorAction SilentlyContinue }
        } catch {
            Write-Log ('HailMary failed: {0}' -f $_.Exception.Message) 'ERROR'
            Exit-Script 1
        }

        Set-StateValue -Name 'LastRemediationTime' -Value (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        Set-StateValue -Name 'LastBackupFile' -Value $backupFile
        Write-Log 'Enforcement complete. Some controls require a reboot; the next Audit cycle confirms convergence.'
        Exit-Script 0
    }

    # -------------------------------------------------------------------------
    'Discover' {
        $configFile = Join-Path $ReportDir ('discover_{0}.csv' -f $timestamp)
        Write-Log ('Running HardeningKitty Config (read-only dump): {0}' -f $configFile)

        try {
            Invoke-HardeningKitty -Mode Config -Backup -BackupFile $configFile `
                -FileFindingList $findingListPath *>&1 |
                ForEach-Object { Add-Content -Path $LogFile -Value ('    HK: ' + $_) -Encoding ASCII -ErrorAction SilentlyContinue }
        } catch {
            Write-Log ('Discover failed: {0}' -f $_.Exception.Message) 'ERROR'
            Exit-Script 1
        }

        Set-StateValue -Name 'LastDiscoverTime' -Value (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        Set-StateValue -Name 'LastDiscoverFile' -Value $configFile
        Write-Log 'Discover complete'
        Exit-Script 0
    }
}
