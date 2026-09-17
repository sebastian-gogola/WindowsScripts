<#
.SYNOPSIS
    Stages the Iru enrollment bundle and builds the standalone Iru-Enrollment
    provisioning package (.ppkg) with the Windows Configuration Designer CLI.

.DESCRIPTION
    Runs on the technician machine (Windows 11 with Windows Configuration
    Designer installed), never on a target device. It:

      1. Copies Invoke-IruEnrollment.ps1 from this folder and the UNMODIFIED
         official mdmmigration.ps1 from the repo's Iru WindowsScripts folder
         into <OutputDirectory>\files\. Nothing in the repo is changed.
      2. Fills the customizations.xml template with the package ID, the
         absolute source paths of the two files, and the tenant values (the
         values ride in the package's single CommandLine, so the wrapper file
         itself stays generic and reusable in the OSDCloud flow).
      3. Runs ICD.exe /Build-ProvisioningPackage, or prints the exact command
         if ICD.exe cannot be located.

    The resulting .ppkg contains the enrollment code in clear text inside the
    command line. Treat the file like the code itself: do not commit it, and
    do not commit a filled-in copy of this script. Encryption
    ($EncryptPackage) protects the file at rest but makes OOBE prompt for the
    password, which defeats a zero-touch flow.

    The package ID is generated once and persisted in the output directory so
    rebuilds keep the same ID: Windows treats a package with the same ID and
    a higher version as an update of the earlier one.

.NOTES
    File     : Build-IruEnrollmentPackage.ps1
    Version  : 1.0.0 (2026-09-17)
    Repo     : github.com/sebastian-gogola/WindowsScripts
    Runs as  : elevated administrator on the technician machine (ICD.exe
               requires an elevated command window)
    PS       : Windows PowerShell 5.1

    Exit codes:
      0 = package built, or staged with the ICD command printed
      1 = ICD.exe returned a non-zero exit code
      2 = precondition failure (missing source files, incomplete tenant
          values, unwritable output directory)

    Sources: see the accompanying README.md (Sourcing notes section).
#>

# =============================================================================
# DISCLAIMER: Experimental helper script - provided as-is, without warranty or
# official Iru support. Sandbox scripts have not gone through the review and
# validation applied to the official Iru WindowsScripts. Review the code and
# validate on test hardware before any production use.
# =============================================================================

# =============================================================================
# CONFIGURATION - edit this block, nothing below it
# =============================================================================

# Iru tenant values (see Invoke-IruEnrollment.ps1 and the official
# mdmmigration.md for where each one lives in the Iru console).
$TenantName     = ''
$BlueprintId    = ''
$EnrollmentCode = ''
$TenantId       = ''
$TenantLocation = 'US'          # 'US' | 'EU'

# Wrapper mode baked into the package: 'Enroll' for the real package,
# 'Probe' for a first read-only package that only reports what the step
# would see on the prospect's hardware.
$WrapperMode = 'Enroll'

# Package metadata. Version must increase when you rebuild a package that
# was already applied to a device and you want the new one to replace it.
$PackageName    = 'Iru-Enrollment'
$PackageVersion = '1.0'

# Output. The .ppkg, the filled customizations.xml and files\ land here.
$OutputDirectory = 'C:\IruEnrollment\build'

# Optional: encrypt the package (OOBE will ask for the auto-generated
# password shown by ICD at build time). Leave $false for zero-touch.
$EncryptPackage = $false

# Optional: explicit path to ICD.exe. Leave empty to auto-detect from the
# Windows ADK (Imaging and Configuration Designer component). The Microsoft
# Store version of Windows Configuration Designer can also build packages
# through its UI; use the UI there and keep this script for the staging step.
$IcdPath = ''

# Optional: /StoreFile argument for ICD. Leave empty to let ICD load its
# default settings store, which is what the Microsoft CLI documentation does.
$StoreFile = ''

# Source of the official migration script (read-only). Default: the repo's
# Iru WindowsScripts folder, resolved relative to this file.
$MigrationScriptSource = ''

# =============================================================================
# CONSTANTS
# =============================================================================

$ScriptVersion   = '1.0.0'
$WrapperFileName = 'Invoke-IruEnrollment.ps1'
$MigrationName   = 'mdmmigration.ps1'
$TemplateName    = 'customizations.xml'
$PackageIdFile   = 'package-id.txt'

$IcdCandidates = @(
    'C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Imaging and Configuration Designer\x86\ICD.exe',
    'C:\Program Files\Windows Kits\10\Assessment and Deployment Kit\Imaging and Configuration Designer\x86\ICD.exe'
)

function Write-Step { param([string]$Message) Write-Output ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message) }
function Fail { param([string]$Message, [int]$Code) Write-Output ('ERROR: {0}' -f $Message); exit $Code }

# =============================================================================
# MAIN
# =============================================================================

Write-Step ('Build-IruEnrollmentPackage v{0}' -f $ScriptVersion)

$here     = $PSScriptRoot
$repoRoot = Split-Path (Split-Path $here -Parent) -Parent
if ([string]::IsNullOrWhiteSpace($MigrationScriptSource)) {
    $MigrationScriptSource = Join-Path $repoRoot ('Iru WindowsScripts\' + $MigrationName)
}

# ---- Preconditions -------------------------------------------------------
$missing = @()
foreach ($v in @('TenantName', 'BlueprintId', 'EnrollmentCode', 'TenantId')) {
    if ([string]::IsNullOrWhiteSpace((Get-Variable -Name $v -ValueOnly))) { $missing += $v }
}
if ($missing.Count -gt 0) { Fail ('Fill these tenant values in the CONFIGURATION block: ' + ($missing -join ', ')) 2 }
if ($TenantName.Contains('.')) { Fail "TenantName must be the URL prefix only ('contoso', not 'contoso.iru.com')." 2 }
$TenantLocation = $TenantLocation.Trim().ToUpperInvariant()
if ($TenantLocation -ne 'US' -and $TenantLocation -ne 'EU') { Fail "TenantLocation must be 'US' or 'EU'." 2 }
if ($WrapperMode -ne 'Enroll' -and $WrapperMode -ne 'Probe') { Fail "WrapperMode must be 'Enroll' or 'Probe'." 2 }
foreach ($val in @($TenantName, $BlueprintId, $EnrollmentCode, $TenantId)) {
    if ($val -match '[\s"<>&]') { Fail ("Tenant value '{0}' contains characters that cannot ride in the package command line." -f $val) 2 }
}

$wrapperSource  = Join-Path $here $WrapperFileName
$templateSource = Join-Path $here $TemplateName
foreach ($p in @($wrapperSource, $templateSource, $MigrationScriptSource)) {
    if (-not (Test-Path -Path $p)) { Fail ("Required file not found: {0}" -f $p) 2 }
}

# ---- Stage files ---------------------------------------------------------
$filesDir = Join-Path $OutputDirectory 'files'
try {
    New-Item -Path $filesDir -ItemType Directory -Force | Out-Null
} catch {
    Fail ("Cannot create output directory '{0}': {1}" -f $filesDir, $_.Exception.Message) 2
}
Copy-Item -Path $wrapperSource         -Destination (Join-Path $filesDir $WrapperFileName) -Force
Copy-Item -Path $MigrationScriptSource -Destination (Join-Path $filesDir $MigrationName)   -Force
Write-Step ('Staged {0} and {1} into {2}' -f $WrapperFileName, $MigrationName, $filesDir)

$migrationHash = (Get-FileHash -Path (Join-Path $filesDir $MigrationName) -Algorithm SHA256).Hash
Write-Step ('mdmmigration.ps1 SHA256: {0}' -f $migrationHash)

# ---- Package ID (stable across rebuilds) ----------------------------------
$idPath = Join-Path $OutputDirectory $PackageIdFile
if (Test-Path -Path $idPath) {
    $packageId = (Get-Content -Path $idPath -Raw).Trim()
} else {
    $packageId = [guid]::NewGuid().ToString()
    Set-Content -Path $idPath -Value $packageId -Encoding ASCII
}
Write-Step ('Package ID: {0}' -f $packageId)

# ---- Fill the template ---------------------------------------------------
$xml = Get-Content -Path $templateSource -Raw
$xml = $xml.Replace('__PACKAGE_ID__', $packageId)
$xml = $xml.Replace('__BUILD_DIR__', $OutputDirectory.TrimEnd('\'))
$xml = $xml.Replace('__MODE__', $WrapperMode)
$xml = $xml.Replace('__TENANT_NAME__', $TenantName)
$xml = $xml.Replace('__BLUEPRINT_ID__', $BlueprintId)
$xml = $xml.Replace('__ENROLLMENT_CODE__', $EnrollmentCode)
$xml = $xml.Replace('__TENANT_ID__', $TenantId)
$xml = $xml.Replace('__TENANT_LOCATION__', $TenantLocation)
$xml = $xml.Replace('<Name>Iru-Enrollment</Name>', ('<Name>{0}</Name>' -f $PackageName))
$xml = $xml.Replace('<Version>1.0</Version>', ('<Version>{0}</Version>' -f $PackageVersion))

$xmlOut = Join-Path $OutputDirectory 'customizations.xml'
Set-Content -Path $xmlOut -Value $xml -Encoding UTF8
Write-Step ('Wrote {0}' -f $xmlOut)

# ---- Locate ICD.exe ------------------------------------------------------
$icd = $IcdPath
if ([string]::IsNullOrWhiteSpace($icd)) {
    foreach ($c in $IcdCandidates) { if (Test-Path -Path $c) { $icd = $c; break } }
}

$ppkgOut = Join-Path $OutputDirectory ('{0}_{1}.ppkg' -f $PackageName, $PackageVersion)
$icdArgs = @(
    '/Build-ProvisioningPackage',
    ('/CustomizationXML:"{0}"' -f $xmlOut),
    ('/PackagePath:"{0}"' -f $ppkgOut),
    $(if ($EncryptPackage) { '+Encrypted' } else { '-Encrypted' }),
    '+Overwrite'
)
if (-not [string]::IsNullOrWhiteSpace($StoreFile)) { $icdArgs += ('/StoreFile:"{0}"' -f $StoreFile) }

if ([string]::IsNullOrWhiteSpace($icd)) {
    Write-Step 'ICD.exe not found. Install the Windows ADK "Imaging and Configuration Designer" component, or open the Windows Configuration Designer app, create an Advanced provisioning project, and import the customizations.xml above. To build from the command line later, run (elevated):'
    Write-Output ('  "<path to ICD.exe>" {0}' -f ($icdArgs -join ' '))
    exit 0
}

Write-Step ('Building with {0}' -f $icd)
Write-Output ('  {0} {1}' -f $icd, (($icdArgs -join ' ') -replace '-EnrollmentCode \S+', '-EnrollmentCode ***'))
$proc = Start-Process -FilePath $icd -ArgumentList $icdArgs -Wait -PassThru -NoNewWindow
if ($proc.ExitCode -ne 0) {
    Fail ("ICD.exe exited with {0}. Check icd.log next to ICD.exe or in %TEMP% for details." -f $proc.ExitCode) 1
}
if (-not (Test-Path -Path $ppkgOut)) {
    Fail 'ICD.exe reported success but no .ppkg was produced.' 1
}

Write-Step ('Package built: {0}' -f $ppkgOut)
Write-Step 'Reminder: the package carries the enrollment code. Keep it with the same care as the code itself and do not commit it.'
exit 0
