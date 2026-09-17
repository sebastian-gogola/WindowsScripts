@echo off
REM =============================================================================
REM DISCLAIMER: Experimental helper script - provided as-is, without warranty or
REM official Iru support. Sandbox scripts have not gone through the review and
REM validation applied to the official Iru WindowsScripts. Review the code and
REM validate on test hardware before any production use.
REM =============================================================================
REM
REM OSDCloud SetupComplete hook for Iru enrollment (sample).
REM
REM Where it goes:  <OSDCloud workspace or USB>\OSDCloud\Config\Scripts\SetupComplete\
REM                 together with Invoke-IruEnrollment.ps1 and mdmmigration.ps1.
REM What happens:   Invoke-OSDCloud copies that folder to C:\OSDCloud\Scripts\SetupComplete\
REM                 in the deployed image and its generated SetupComplete.ps1 runs the
REM                 file named exactly SetupComplete.cmd from there (cmd /c, SYSTEM,
REM                 first boot, no user session). The name is fixed by OSDCloud.
REM Already have a SetupComplete.cmd?  Add only the powershell.exe line below to it
REM                 and copy the two .ps1 files next to it. Nothing else is needed.
REM
REM Tenant values: fill the CONFIGURATION block in Invoke-IruEnrollment.ps1, or append
REM                 -TenantName ... -BlueprintId ... -EnrollmentCode ... -TenantId ...
REM                 -TenantLocation US|EU to the powershell.exe line.
REM
REM Exit codes are those of Invoke-IruEnrollment.ps1 (0 enrolled / already enrolled /
REM retry scheduled, 1 failed, 2 precondition). OSDCloud does not read them; they
REM are logged here so the SetupComplete transcript shows the outcome.

set "IRU_LOGDIR=%ProgramData%\IruScripts\Logs"
set "IRU_LOG=%IRU_LOGDIR%\SetupComplete-IruEnrollment.log"
if not exist "%IRU_LOGDIR%" mkdir "%IRU_LOGDIR%"

echo %DATE% %TIME% SetupComplete: starting Iru enrollment from %~dp0>> "%IRU_LOG%"

"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0Invoke-IruEnrollment.ps1" -RunSource OSDCloud

echo %DATE% %TIME% SetupComplete: Invoke-IruEnrollment.ps1 exit code %ERRORLEVEL%>> "%IRU_LOG%"
exit /b 0
