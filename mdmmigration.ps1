################################################################################################
# Created by Lance Crandall | support@iru.com | Iru, Inc.
################################################################################################
#
#   Created - 2025/11/08
#   Updated - 2026/01/05
#
################################################################################################
# Script Information
################################################################################################
#
# This script automates the process of unenrolling Windows devices from their current management
# provider and enrolling them into Kandji. 
# It gathers enrollment parameters from your IRU gateway, removes existing MDM enrollments 
# (when present), and registers the device with Kandji.
# The script is designed to run from an elevated context (Administrator/SYSTEM). 
# It can be executed interactively or fully unattended via the `-Silent` switch. 
# Because it leverages native Windows APIs, it is safe to deploy to devices via your existing 
#MDM solution or other remote execution tools.
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

# Script version
# VERSION="1.0.2"


param(
    [string]$TenantName,
    [string]$BlueprintId,
    [string]$EnrollmentCode,
    [string]$TenantID,
    [string]$TenantLocation,
    [string[]]$UninstallApp,
    [switch]$Debug,
    [switch]$Silent
)

# ---------------------------------------------------------------------------------
# Editable defaults (override by command-line parameters when provided)
# ---------------------------------------------------------------------------------
$TenantNameDefault       = $null  # Tenant URL prefix. If your sign-in URL is https://contoso.iru.com, TenantName is "contoso".
$BlueprintIdDefault      = $null  # Blueprint GUID. Iru Console -> Blueprints -> open the target blueprint; copy the GUID from the URL.
                               # Example URL: https://contoso.iru.com/blueprints/maps/447c8874-73f5-4b7a-9d55-18c58e673597/assignments
                               # BlueprintId:  447c8874-73f5-4b7a-9d55-18c58e673597
$EnrollmentCodeDefault   = $null  # Manual enrollment code. Iru Console -> Enrollment -> Manual Enrollment -> use the code for the target blueprint.
$TenantIdDefault         = $null  # Device Domain prefix. Iru Console -> Organization -> Device Domains.
                               # Example Device Domain: 8134cc6c.web-api.kandji.io  => TenantID: 8134cc6c
$TenantLocationDefault   = $null  # Example: "US" or "EU"
$UninstallAppDefault     = @()    # Example: @("msiexec /x {GUID} /qn /norestart", '"C:\Program Files\agent\Uninstall Agent.exe" /allusers /S')
$EnableDebugDefault      = $false
$EnableSilentDefault     = $true

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls

$script:DebugMode = $false
$script:LogFile = $null
$script:mdmModuleHandle = [IntPtr]::Zero

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Level,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $timestamp = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss")
    $line = "$timestamp [$Level] $Message"
    Write-Host $line
    if ($script:LogFile) {
        Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8
    }
}

function Log-Info { param([string]$Message) Write-Log -Level "INFO" -Message $Message }
function Log-Warn { param([string]$Message) Write-Log -Level "WARN" -Message $Message }
function Log-Error { param([string]$Message) Write-Log -Level "ERROR" -Message $Message }
function Log-Debug { param([string]$Message) if ($script:DebugMode) { Write-Log -Level "DEBUG" -Message $Message } }

function Initialize-Logger {
    $programData = [Environment]::GetFolderPath("CommonApplicationData")
    $root = Join-Path $programData "Iru"
    $sub = Join-Path $root "MDMMigration"
    $dir = Join-Path $sub "Logs"
    foreach ($path in @($root, $sub, $dir)) {
        if (-not (Test-Path -LiteralPath $path)) {
            New-Item -ItemType Directory -Path $path -Force | Out-Null
        }
    }

    $stamp = (Get-Date).ToString("yyyyMMdd_HHmmss")
    $script:LogFile = Join-Path $dir "MDM-Unenroll_$stamp.log"
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
}

$interopSource = @"
using System;
using System.Runtime.InteropServices;
using System.Runtime.ExceptionServices;
using System.Security;
using System.Threading;

namespace Interop {
    public static class Kernel32 {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern IntPtr LoadLibrary(string lpFileName);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool FreeLibrary(IntPtr hModule);

        [DllImport("kernel32.dll", CharSet = CharSet.Ansi, SetLastError = true)]
        public static extern IntPtr GetProcAddress(IntPtr hModule, string procName);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern uint GetModuleFileName(IntPtr hModule, System.Text.StringBuilder lpFilename, uint nSize);

        [DllImport("kernel32.dll")]
        public static extern uint GetLastError();
    }

    public static class MdmHelpers {
        private const int RPC_E_CHANGED_MODE = unchecked((int)0x80010106);
        private const int THREAD_JOIN_TIMEOUT_MS = 30000; // 30 second timeout

        private struct SafeUnregisterResult {
            public int Result;
            public int CoInitHr;
            public uint ExceptionCode;
        }

        public static uint LastUnregisterExceptionCode { get; private set; }
        public static int LastUnregisterCoInitHr { get; private set; }
        public static string LastUnregisterStage { get; private set; }
        public static string LastUnregisterMessage { get; private set; }
        public static bool LastUnregisterThreadTimedOut { get; private set; }
        public static bool LastUnregisterAnyThreadTimedOut { get; private set; }

        public delegate void LogCallback(string message);
        private static LogCallback _logCallback = null;

        public static void SetLogCallback(LogCallback callback) {
            _logCallback = callback;
        }

        private static void Log(string message) {
            if (_logCallback != null) {
                try {
                    _logCallback(message);
                } catch {
                    // Silently ignore logging exceptions to prevent them from crashing the script
                    // Logging failures shouldn't stop the unregister process
                }
            }
        }

        static MdmHelpers() {
            ResetUnregisterState();
        }

        public static void ResetUnregisterState() {
            LastUnregisterExceptionCode = 0;
            LastUnregisterCoInitHr = 0;
            LastUnregisterStage = "primary";
            LastUnregisterMessage = "";
            LastUnregisterThreadTimedOut = false;
            LastUnregisterAnyThreadTimedOut = false;
        }

        public static int TryUnregisterWithApartmentFallback(string enrollmentId) {
            ResetUnregisterState();
            Log(string.Format("[TryUnregisterWithApartmentFallback] Starting unregister for enrollment ID: {0}", enrollmentId));

            Log("[TryUnregisterWithApartmentFallback] Attempting primary (default COM) unregister...");
            SafeUnregisterResult primary = CallUnregisterInternal(enrollmentId, null, "primary");
            Log(string.Format("[TryUnregisterWithApartmentFallback] Primary result: Result=0x{0:X8}, ExceptionCode=0x{1:X8}, CoInitHr=0x{2:X8}", 
                (uint)primary.Result, primary.ExceptionCode, (uint)primary.CoInitHr));
            
            if (primary.ExceptionCode != 0) {
                Log(string.Format("[TryUnregisterWithApartmentFallback] Primary failed with exception code 0x{0:X8}", primary.ExceptionCode));
                return int.MinValue;
            }

            int rc = primary.Result;
            if (rc == 0) {
                Log("[TryUnregisterWithApartmentFallback] Primary unregister succeeded (rc=0)");
                return 0;
            }

            if (rc == RPC_E_CHANGED_MODE) {
                Log(string.Format("[TryUnregisterWithApartmentFallback] Primary returned RPC_E_CHANGED_MODE (0x{0:X8}), trying MTA...", (uint)rc));
                SafeUnregisterResult mta = CallUnregisterInternal(enrollmentId, ApartmentState.MTA, "MTA");
                Log(string.Format("[TryUnregisterWithApartmentFallback] MTA result: Result=0x{0:X8}, ExceptionCode=0x{1:X8}, CoInitHr=0x{2:X8}, ThreadTimedOut={3}", 
                    (uint)mta.Result, mta.ExceptionCode, (uint)mta.CoInitHr, LastUnregisterThreadTimedOut));

                if (mta.ExceptionCode == 0 && mta.Result == 0) {
                    Log("[TryUnregisterWithApartmentFallback] MTA unregister succeeded (rc=0)");
                    return 0;
                }

                // Continue to STA even if MTA failed (unless there was an exception)               
                Log(string.Format("[TryUnregisterWithApartmentFallback] MTA failed and returned 0x{0:X8} with exception code 0x{0:X8}, will still try STA before returning", (uint)mta.Result, mta.ExceptionCode));
              
                SafeUnregisterResult sta = CallUnregisterInternal(enrollmentId, ApartmentState.STA, "STA");
                Log(string.Format("[TryUnregisterWithApartmentFallback] STA result: Result=0x{0:X8}, ExceptionCode=0x{1:X8}, CoInitHr=0x{2:X8}, ThreadTimedOut={3}", 
                    (uint)sta.Result, sta.ExceptionCode, (uint)sta.CoInitHr, LastUnregisterThreadTimedOut));

                if (sta.ExceptionCode == 0 && sta.Result == 0) {
                    Log("[TryUnregisterWithApartmentFallback] STA unregister succeeded (rc=0)");
                    return 0;
                }

                // Both MTA and STA failed - return the best result available
                // Prefer results without exceptions, then prefer non-MinValue results
                if (sta.ExceptionCode == 0 && sta.Result != int.MinValue) {
                    Log(string.Format("[TryUnregisterWithApartmentFallback] Returning STA result (no exception): 0x{0:X8}", (uint)sta.Result));
                    return sta.Result;
                }

                if (mta.ExceptionCode == 0 && mta.Result != int.MinValue) {
                    Log(string.Format("[TryUnregisterWithApartmentFallback] Returning MTA result (no exception): 0x{0:X8}", (uint)mta.Result));
                    return mta.Result;
                }

                if (sta.Result != int.MinValue) {
                    Log(string.Format("[TryUnregisterWithApartmentFallback] Returning STA result (had exception but has result): 0x{0:X8}", (uint)sta.Result));
                    return sta.Result;
                }

                if (mta.Result != int.MinValue) {
                    Log(string.Format("[TryUnregisterWithApartmentFallback] Returning MTA result (had exception but has result): 0x{0:X8}", (uint)mta.Result));
                    return mta.Result;
                }
                // Both had exceptions and no valid results
                Log(string.Format("[TryUnregisterWithApartmentFallback] Both MTA and STA failed. MTA: ExceptionCode=0x{0:X8}, Result=0x{1:X8}; STA: ExceptionCode=0x{2:X8}, Result=0x{3:X8}", 
                    mta.ExceptionCode, (uint)mta.Result, sta.ExceptionCode, (uint)sta.Result));
                return int.MinValue;
            }

            Log(string.Format("[TryUnregisterWithApartmentFallback] Returning primary result: 0x{0:X8}", (uint)rc));
            return rc;
        }

        private static SafeUnregisterResult CallUnregisterInternal(string enrollmentId, ApartmentState? state, string stage) {
            SafeUnregisterResult result = new SafeUnregisterResult { Result = int.MinValue, CoInitHr = 0, ExceptionCode = 0 };
            LastUnregisterStage = stage;
            LastUnregisterThreadTimedOut = false;
            Log(string.Format("[CallUnregisterInternal] Stage={0}, EnrollmentId={1}, HasState={2}", stage, enrollmentId, state.HasValue));

            if (!state.HasValue) {
                Log(string.Format("[CallUnregisterInternal] Stage={0}: Calling InvokeUnregisterSafe (no apartment state)...", stage));
                uint exceptionCode;
                int rc = InvokeUnregisterSafe(enrollmentId, out exceptionCode);
                result.Result = rc;
                result.ExceptionCode = exceptionCode;
                LastUnregisterExceptionCode = exceptionCode;
                LastUnregisterCoInitHr = 0;
                Log(string.Format("[CallUnregisterInternal] Stage={0}: InvokeUnregisterSafe returned: Result=0x{1:X8}, ExceptionCode=0x{2:X8}", 
                    stage, (uint)rc, exceptionCode));
                return result;
            }

            ApartmentState targetState = state.Value;
            Exception threadEx = null;
            SafeUnregisterResult threadResult = result;

            Log(string.Format("[CallUnregisterInternal] Stage={0}: Creating thread with apartment state {1}...", stage, targetState));
            Thread thread = new Thread(() =>
            {
                Log(string.Format("[CallUnregisterInternal] Stage={0}: Thread started, ThreadID={1}", stage, Thread.CurrentThread.ManagedThreadId));
                bool needUninitLocal = false;
                SafeUnregisterResult local = new SafeUnregisterResult { Result = int.MinValue, CoInitHr = 0, ExceptionCode = 0 };
                try {
                    uint coInit = targetState == ApartmentState.MTA ? 0x0u : 0x2u;
                    Log(string.Format("[CallUnregisterInternal] Stage={0}: Calling CoInitializeEx with flag 0x{1:X8}...", stage, coInit));
                    int hr = Ole32.CoInitializeEx(IntPtr.Zero, coInit);
                    local.CoInitHr = hr;
                    Log(string.Format("[CallUnregisterInternal] Stage={0}: CoInitializeEx returned: 0x{1:X8}", stage, (uint)hr));

                    if (hr == 0 || hr == 1) {
                        needUninitLocal = true;
                        Log(string.Format("[CallUnregisterInternal] Stage={0}: CoInitializeEx succeeded, will need CoUninitialize", stage));
                    } else if (hr == RPC_E_CHANGED_MODE) {
                        Log(string.Format("[CallUnregisterInternal] Stage={0}: CoInitializeEx returned RPC_E_CHANGED_MODE, proceeding anyway", stage));
                        // Already initialized in another apartment; proceed.
                    } else if (hr < 0) {
                        Log(string.Format("[CallUnregisterInternal] Stage={0}: CoInitializeEx failed with HR 0x{1:X8}, aborting", stage, (uint)hr));
                        local.Result = hr;
                        threadResult = local;
                        return;
                    }

                    Log(string.Format("[CallUnregisterInternal] Stage={0}: Calling InvokeUnregisterSafe...", stage));
                    uint exceptionCode;
                    int rc = InvokeUnregisterSafe(enrollmentId, out exceptionCode);
                    local.Result = rc;
                    local.ExceptionCode = exceptionCode;
                    Log(string.Format("[CallUnregisterInternal] Stage={0}: InvokeUnregisterSafe returned: Result=0x{1:X8}, ExceptionCode=0x{2:X8}", 
                        stage, (uint)rc, exceptionCode));
                } catch (Exception ex) {
                    threadEx = ex;
                    Log(string.Format("[CallUnregisterInternal] Stage={0}: Exception in thread: {1}", stage, ex.ToString()));
                } finally {
                    if (needUninitLocal) {
                        Log(string.Format("[CallUnregisterInternal] Stage={0}: Calling CoUninitialize...", stage));
                        Ole32.CoUninitialize();
                        Log(string.Format("[CallUnregisterInternal] Stage={0}: CoUninitialize completed", stage));
                    }
                    if (local.Result != int.MinValue || local.ExceptionCode != 0 || local.CoInitHr != 0) {
                        threadResult = local;
                    }
                    Log(string.Format("[CallUnregisterInternal] Stage={0}: Thread completed, ThreadID={1}", stage, Thread.CurrentThread.ManagedThreadId));
                }
            });

            thread.IsBackground = true;
            thread.SetApartmentState(targetState);
            Log(string.Format("[CallUnregisterInternal] Stage={0}: Starting thread...", stage));
            thread.Start();

            Log(string.Format("[CallUnregisterInternal] Stage={0}: Waiting for thread to complete (timeout={1}ms)...", stage, THREAD_JOIN_TIMEOUT_MS));
            bool joined = false;
            try {
                joined = thread.Join(THREAD_JOIN_TIMEOUT_MS);
                Log(string.Format("[CallUnregisterInternal] Stage={0}: thread.Join() returned: {1}", stage, joined));
            } catch (Exception joinEx) {
                Log(string.Format("[CallUnregisterInternal] Stage={0}: EXCEPTION in thread.Join(): {1}", stage, joinEx.ToString()));
                LastUnregisterThreadTimedOut = true;
                LastUnregisterMessage = string.Format("Exception in thread.Join(): {0}", joinEx.Message);
                // Continue anyway - check if thread completed
                joined = false;
            }

            // Memory barrier to ensure we see updates from the thread
            System.Threading.Thread.MemoryBarrier();
            
            // Check if thread actually completed even if join timed out
            // If thread is not alive, it completed (even if join timed out due to timing)
            bool threadActuallyCompleted = !thread.IsAlive;

            if (!joined) {
                // Give a small moment for memory visibility if thread just completed
                if (!threadActuallyCompleted) {
                    System.Threading.Thread.Sleep(100);
                    System.Threading.Thread.MemoryBarrier();
                    threadActuallyCompleted = !thread.IsAlive;
                }

                if (threadActuallyCompleted) {
                    Log(string.Format("[CallUnregisterInternal] Stage={0}: Thread join timed out but thread actually completed (IsAlive=false) - using result", stage));
                    // Thread completed, clear timeout flag since it's not really a timeout
                    LastUnregisterThreadTimedOut = false;
                } else {
                    LastUnregisterThreadTimedOut = true;
                    LastUnregisterAnyThreadTimedOut = true;  // Track that ANY timeout occurred during this attempt
                    LastUnregisterMessage = string.Format("Thread join timed out after {0}ms and thread is still alive", THREAD_JOIN_TIMEOUT_MS);
                    Log(string.Format("[CallUnregisterInternal] Stage={0}: WARNING - Thread join timed out after {1}ms and thread is still alive! Thread may be hung.", stage, THREAD_JOIN_TIMEOUT_MS));
                    Log(string.Format("[CallUnregisterInternal] Stage={0}: WARNING - Continuing anyway - will try next apartment state if available", stage));
                }
                Log(string.Format("[CallUnregisterInternal] Stage={0}: Thread state: IsAlive={1}, ThreadState={2}, ActuallyCompleted={3}", 
                    stage, thread.IsAlive, thread.ThreadState, threadActuallyCompleted));
            } else {
                Log(string.Format("[CallUnregisterInternal] Stage={0}: Thread join completed successfully", stage));
                threadActuallyCompleted = true;
            }

            if (threadEx != null) {
                Log(string.Format("[CallUnregisterInternal] Stage={0}: Thread exception detected: {1}", stage, threadEx.ToString()));
                threadResult.Result = Marshal.GetHRForException(threadEx);
                threadResult.ExceptionCode = 0xFFFFFFFFu;
            }

            // Check if threadResult was updated (indicates thread completed)
            // If threadResult.Result is still int.MinValue and thread didn't complete, result is incomplete
            if (threadResult.Result == int.MinValue && threadResult.ExceptionCode == 0 && threadResult.CoInitHr == 0 && !threadActuallyCompleted) {
                Log(string.Format("[CallUnregisterInternal] Stage={0}: WARNING - Thread did not complete and result is still at initial value - result may be incomplete", stage));
            } else if (threadResult.Result != int.MinValue || threadResult.ExceptionCode != 0 || threadResult.CoInitHr != 0) {
                Log(string.Format("[CallUnregisterInternal] Stage={0}: Thread result was updated: Result=0x{1:X8}, ExceptionCode=0x{2:X8}, CoInitHr=0x{3:X8}", 
                    stage, (uint)threadResult.Result, threadResult.ExceptionCode, (uint)threadResult.CoInitHr));
            }

            LastUnregisterExceptionCode = threadResult.ExceptionCode;
            LastUnregisterCoInitHr = threadResult.CoInitHr;
            Log(string.Format("[CallUnregisterInternal] Stage={0}: Returning result: Result=0x{1:X8}, ExceptionCode=0x{2:X8}, CoInitHr=0x{3:X8}, ThreadTimedOut={4}", 
                stage, (uint)threadResult.Result, threadResult.ExceptionCode, (uint)threadResult.CoInitHr, LastUnregisterThreadTimedOut));
            return threadResult;
        }

        [HandleProcessCorruptedStateExceptions]
        [SecurityCritical]
        private static int InvokeUnregisterSafe(string enrollmentId, out uint exceptionCode) {
            exceptionCode = 0;
            Log(string.Format("[InvokeUnregisterSafe] Starting unregister for enrollment ID: {0}", enrollmentId));
            try {
                Log(string.Format("[InvokeUnregisterSafe] Calling MdmRegistration.UnregisterDevice..."));
                int result = MdmRegistration.UnregisterDevice(enrollmentId);
                Log(string.Format("[InvokeUnregisterSafe] MdmRegistration.UnregisterDevice returned: 0x{0:X8}", (uint)result));
                return result;
            } catch (AccessViolationException ex) {
                exceptionCode = 0xC0000005u;
                Log(string.Format("[InvokeUnregisterSafe] AccessViolationException caught: {0}", ex.ToString()));
                return int.MinValue;
            } catch (Exception ex) {
                exceptionCode = 0xFFFFFFFFu;
                Log(string.Format("[InvokeUnregisterSafe] Exception caught: {0}", ex.ToString()));
                return int.MinValue;
            }
        }
    }

    public static class Ole32 {
        [DllImport("ole32.dll")]
        public static extern int CoInitializeEx(IntPtr pvReserved, uint coInit);

        [DllImport("ole32.dll")]
        public static extern void CoUninitialize();
    }

    public static class MdmRegistration {
        [UnmanagedFunctionPointer(CallingConvention.Winapi, CharSet = CharSet.Unicode)]
        private delegate int RegisterDelegate(string upn, string serverAddress, string accessToken);

        [UnmanagedFunctionPointer(CallingConvention.Winapi, CharSet = CharSet.Unicode)]
        private delegate int UnregisterDelegate(string enrollmentId);

        [UnmanagedFunctionPointer(CallingConvention.Winapi, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private delegate bool IsRegisteredDelegate();

        private const int RPC_E_CHANGED_MODE = unchecked((int)0x80010106);

        private static RegisterDelegate registerFunction;
        private static UnregisterDelegate unregisterFunction;
        private static IsRegisteredDelegate isRegisteredFunction;
        private static IntPtr registerAddress = IntPtr.Zero;
        private static IntPtr unregisterAddress = IntPtr.Zero;
        private static IntPtr isRegisteredAddress = IntPtr.Zero;
        private static IntPtr cachedModule = IntPtr.Zero;
        private static string lastRegisterSource = "default";

        public static void EnsureInitialized(IntPtr moduleHandle) {
            if (moduleHandle == IntPtr.Zero) {
                throw new ArgumentException("Module handle cannot be zero.", "moduleHandle");
            }

            if (moduleHandle == cachedModule &&
                registerFunction != null &&
                unregisterFunction != null &&
                isRegisteredFunction != null) {
                return;
            }

            registerAddress = GetProc(moduleHandle, "RegisterDeviceWithManagement", out registerFunction);
            unregisterAddress = GetProc(moduleHandle, "UnregisterDeviceWithManagement", out unregisterFunction);
            isRegisteredAddress = GetProc(moduleHandle, "IsDeviceRegisteredWithManagement", out isRegisteredFunction);
            cachedModule = moduleHandle;
        }

        public static int RegisterDeviceWithFallback(string upn, string serverAddress, string accessToken) {
            EnsureDelegates();
            lastRegisterSource = "default";

            int rc = registerFunction(upn, serverAddress, accessToken);
            if (rc != RPC_E_CHANGED_MODE) {
                return rc;
            }

            int mta = CallRegisterOnThread(ApartmentState.MTA, upn, serverAddress, accessToken, registerFunction);
            if (mta != RPC_E_CHANGED_MODE && mta != int.MinValue) {
                lastRegisterSource = "MTA";
                return mta;
            }

            int sta = CallRegisterOnThread(ApartmentState.STA, upn, serverAddress, accessToken, registerFunction);
            if (sta != int.MinValue) {
                lastRegisterSource = "STA";
                return sta;
            }

            return rc;
        }

        public static int UnregisterDevice(string enrollmentId) {
            EnsureDelegates();
            return unregisterFunction(enrollmentId);
        }       

        public static string GetLastRegisterSource() {
            return lastRegisterSource;
        }

        private static void EnsureDelegates() {
            if (cachedModule == IntPtr.Zero ||
                registerFunction == null ||
                unregisterFunction == null ||
                isRegisteredFunction == null) {
                throw new InvalidOperationException("MDMRegistration delegates are not initialized.");
            }
        }

        private static IntPtr GetProc<T>(IntPtr moduleHandle, string exportName, out T del) where T : class {
            IntPtr proc = Kernel32.GetProcAddress(moduleHandle, exportName);
            if (proc == IntPtr.Zero) {
                throw new InvalidOperationException(string.Format("Export '{0}' not found in MDMRegistration.dll.", exportName));
            }

            del = (T)(object)Marshal.GetDelegateForFunctionPointer(proc, typeof(T));
            return proc;
        }

        public static string GetModulePath() {
            EnsureDelegates();
            var sb = new System.Text.StringBuilder(260);
            uint len = Kernel32.GetModuleFileName(cachedModule, sb, (uint)sb.Capacity);
            if (len == 0) {
                return "<unknown>";
            }
            return sb.ToString();
        }

         private static int CallRegisterOnThread(ApartmentState state, string upn, string serverAddress, string accessToken, RegisterDelegate registerDelegate) {
            int result = int.MinValue;
            Exception threadEx = null;

            Thread thread = new Thread(() =>
            {
                bool needUninit = false;
                try {
                    uint coInit = state == ApartmentState.MTA ? 0x0u : 0x2u;
                    int hr = Ole32.CoInitializeEx(IntPtr.Zero, coInit);
                    if (hr == 0 || hr == 1) {
                        needUninit = true;
                    } else if (hr == RPC_E_CHANGED_MODE) {
                        // Already initialized in another apartment; proceed without changing it.
                    } else if (hr < 0) {
                        result = hr;
                        return;
                    }
                    result = registerDelegate(upn, serverAddress, accessToken);
                } catch (Exception ex) {
                    threadEx = ex;
                } finally {
                    if (needUninit) {
                        Ole32.CoUninitialize();
                    }
                }
            });

            thread.IsBackground = true;
            thread.SetApartmentState(state);
            thread.Start();
            thread.Join();

            if (threadEx != null) {
                result = Marshal.GetHRForException(threadEx);
            }

            return result;
        }
    }
}
"@

function Initialize-MdmRegistration {
    if (-not ("Interop.MdmHelpers" -as [type])) {
        Add-Type -TypeDefinition $script:interopSource -Language CSharp
    }

    if ($script:mdmModuleHandle -ne [IntPtr]::Zero) {
        return $true
    }

    $handle = [Interop.Kernel32]::LoadLibrary("MDMRegistration.dll")
    if ($handle -eq [IntPtr]::Zero) {
        $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
        Log-Error ("Failed to load MDMRegistration.dll. Error: 0x{0:X8}" -f $err)
        Log-Error "This usually means either:"
        Log-Error "1. The Windows MDM feature is not enabled"
        Log-Error "2. The system is not running Windows 10/11 Enterprise/Pro"
        Log-Error "3. Required Windows updates are missing"
        return $false
    }

    $script:mdmModuleHandle = $handle
    try {
        [Interop.MdmRegistration]::EnsureInitialized($script:mdmModuleHandle)
        try {
            $modulePath = [Interop.MdmRegistration]::GetModulePath()
            Log-Debug ("Loaded MDMRegistration.dll from: {0}" -f $modulePath)
        } catch {
            Log-Debug ("Failed to resolve MDMRegistration.dll path: {0}" -f $_.Exception.Message)
        }
    } catch {
        Log-Error ("Failed to initialize MDMRegistration delegates: {0}" -f $_.Exception.Message)
        return $false
    }
    return $true
}

function Cleanup-MdmRegistration {
    if ($script:mdmModuleHandle -ne [IntPtr]::Zero) {
        [Interop.Kernel32]::FreeLibrary($script:mdmModuleHandle) | Out-Null
        $script:mdmModuleHandle = [IntPtr]::Zero
    }
}

function Test-IsElevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]$identity
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-InteractiveUserUpn {
    # This function gets the UPN of the interactively logged-on user
    # Works for: Entra/AzureAD, Domain-joined, Local accounts (returns account name)
    # Works when running as SYSTEM, admin, or interactive user
    # Uses Windows registry to get logged-on user SID, then finds UPN in IdentityStore
    # For local accounts (no UPN found), returns the local account name instead of null

    # Strategy: First collect all SessionData entries, then prioritize Azure AD accounts
    # This ensures we check all entries before falling back to local accounts

    # Helper function to get UPN from IdentityCache (checks both direct and nested paths)
    function Get-UpnFromIdentityCache {
        param(
            [string]$Sid,
            [string]$SessionKey
        )
        
        $identityStorePath = "HKLM:\SOFTWARE\Microsoft\IdentityStore\Cache"
        
        # Method 1: Check direct path: Cache\<SID>\IdentityCache\<SID>
        $directCachePath = Join-Path $identityStorePath "$Sid\IdentityCache\$Sid"
        if (Test-Path $directCachePath -ErrorAction SilentlyContinue) {
            try {
                $usernameValue = (Get-ItemProperty -Path $directCachePath -Name "UserName" -ErrorAction SilentlyContinue).UserName
                if (-not [string]::IsNullOrEmpty($usernameValue) -and $usernameValue.Contains('@')) {
                    Log-Debug ("Found UPN in direct IdentityCache path for SessionData {0}: {1}" -f $SessionKey, $usernameValue)
                    return $usernameValue
                }
            } catch {
                Log-Debug ("Failed to read Username from direct IdentityCache path: {0}" -f $_.Exception.Message)
            }
        }
        
        # Method 2: Check nested paths under system SIDs (S-1-5-18, S-1-5-19, S-1-5-20, etc.)
        $systemSids = @("S-1-5-18", "S-1-5-19", "S-1-5-20", "S-1-5-90-0-2")
        foreach ($systemSid in $systemSids) {
            $nestedCachePath = Join-Path $identityStorePath "$systemSid\IdentityCache\$Sid"
            if (Test-Path $nestedCachePath -ErrorAction SilentlyContinue) {
                try {
                    $usernameValue = (Get-ItemProperty -Path $nestedCachePath -Name "UserName" -ErrorAction SilentlyContinue).UserName
                    if (-not [string]::IsNullOrEmpty($usernameValue) -and $usernameValue.Contains('@')) {
                        Log-Debug ("Found UPN in nested IdentityCache path ({0}) for SessionData {1}: {2}" -f $systemSid, $SessionKey, $usernameValue)
                        return $usernameValue
                    }
                } catch {
                    Log-Debug ("Failed to read Username from nested IdentityCache path ({0}): {1}" -f $systemSid, $_.Exception.Message)
                }
            }
        }
        
        return $null
    }
    
    # Helper function to get UPN from LogonCache
    function Get-UpnFromLogonCache {
        param(
            [string]$Sid,
            [string]$SessionKey
        )
        
        try {
            $logonCachePath = "HKLM:\SOFTWARE\Microsoft\IdentityStore\LogonCache"
            if (-not (Test-Path $logonCachePath -ErrorAction SilentlyContinue)) {
                return $null
            }
            
            $cacheKeys = Get-ChildItem -Path $logonCachePath -ErrorAction SilentlyContinue
            foreach ($key in $cacheKeys) {
                $keySid = $key.GetValue("Sid", $null)
                if ($keySid -eq $Sid) {
                    $upnValue = $key.GetValue("UserPrincipalName", $null)
                    if ([string]::IsNullOrEmpty($upnValue)) {
                        $upnValue = $key.GetValue("UPN", $null)
                    }
                    if ([string]::IsNullOrEmpty($upnValue)) {
                        $upnValue = $key.GetValue("Email", $null)
                    }
                    
                    if (-not [string]::IsNullOrEmpty($upnValue) -and $upnValue.Contains('@')) {
                        Log-Info ("Retrieved UPN from LogonCache (SessionData {0} SID {1}): {2}" -f $SessionKey, $Sid, $upnValue)
                        return $upnValue
                    }
                }
            }
        } catch {
            Log-Debug ("Failed to check LogonCache for SessionData {0}: {1}" -f $SessionKey, $_.Exception.Message)
        }
        
        return $null
    }

    $sessionDataEntries = @()
    $materializedUpn = $null

    # Step 1: Collect all SessionData entries first
    try {
        $logonUIPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI\SessionData"
        if (Test-Path $logonUIPath -ErrorAction SilentlyContinue) {
            $sessionKeys = Get-ChildItem -Path $logonUIPath -ErrorAction SilentlyContinue | Sort-Object PSChildName -Descending
            
            foreach ($sessionKey in $sessionKeys) {
                try {
                    $sidValue = (Get-ItemProperty -Path $sessionKey.PSPath -Name "LoggedOnUserSID" -ErrorAction SilentlyContinue).LoggedOnUserSID
                    $loggedOnUser = (Get-ItemProperty -Path $sessionKey.PSPath -Name "LoggedOnUser" -ErrorAction SilentlyContinue).LoggedOnUser
                    $loggedOnSAMUser = (Get-ItemProperty -Path $sessionKey.PSPath -Name "LoggedOnSAMUser" -ErrorAction SilentlyContinue).LoggedOnSAMUser
                    
                    if (-not [string]::IsNullOrEmpty($sidValue)) {
                        # Skip SYSTEM and service accounts
                        if ($sidValue -ne "S-1-5-18" -and $sidValue -ne "S-1-5-19" -and $sidValue -ne "S-1-5-20") {
                            $isAzureAD = $false
                            if (-not [string]::IsNullOrEmpty($loggedOnUser) -and $loggedOnUser -match '^AzureAD\\(.+)$') {
                                $isAzureAD = $true
                            }

                            $sessionDataEntries += [pscustomobject]@{
                                SessionKey = $sessionKey.PSChildName
                                SID = $sidValue
                                LoggedOnUser = $loggedOnUser
                                LoggedOnSAMUser = $loggedOnSAMUser
                                IsAzureAD = $isAzureAD
                            }

                            Log-Debug ("Collected SessionData {0}: SID={1}, User={2}, IsAzureAD={3}" -f $sessionKey.PSChildName, $sidValue, $loggedOnUser, $isAzureAD)
                        }
                    }
                } catch {
                    Log-Debug ("Failed to collect SessionData key {0}: {1}" -f $sessionKey.PSChildName, $_.Exception.Message)
                }
            }
        }
    } catch {
        Log-Debug ("Failed to query LogonUI registry: {0}" -f $_.Exception.Message)
    }

    # Step 2: Prioritize Azure AD accounts - check all Azure AD entries first for UPNs
    $azureADEntries = @($sessionDataEntries | Where-Object { $_.IsAzureAD -eq $true })
    $nonAzureADEntries = @($sessionDataEntries | Where-Object { $_.IsAzureAD -eq $false })

    if ($azureADEntries.Count -gt 0) {
        Log-Debug ("Found {0} Azure AD SessionData entries, checking for UPNs..." -f $azureADEntries.Count)

        foreach ($entry in $azureADEntries) {
            try {
                $sidValue = $entry.SID
                Log-Debug ("Checking SessionData {0} with SID {1} for fully materialized identity..." -f $entry.SessionKey, $sidValue)

                # Try to find the UPN in IdentityStore Cache
                $foundUpn = Get-UpnFromIdentityCache -Sid $sidValue -SessionKey $entry.SessionKey
                
                if (-not [string]::IsNullOrEmpty($foundUpn)) {
                    Log-Info ("Found fully materialized Entra identity in SessionData {0} (SID: {1}): {2}" -f $entry.SessionKey, $sidValue, $foundUpn)
                    return $foundUpn
                } else {
                    Log-Debug ("SessionData {0} SID {1} has Azure AD user but no UPN found in IdentityCache" -f $entry.SessionKey, $sidValue)
                }
            } catch {
                Log-Debug ("Failed to process Azure AD SessionData entry {0}: {1}" -f $entry.SessionKey, $_.Exception.Message)
            }
        }
    }

    # Step 3: Check non-Azure AD entries for IdentityCache with UPNs (domain accounts, etc.)
    foreach ($entry in $nonAzureADEntries) {
        try {
            $sidValue = $entry.SID
            $foundUpn = Get-UpnFromIdentityCache -Sid $sidValue -SessionKey $entry.SessionKey

            if (-not [string]::IsNullOrEmpty($foundUpn)) {
                $materializedUpn = $foundUpn
                Log-Info ("Found fully materialized identity in SessionData {0} (SID: {1}): {2}" -f $entry.SessionKey, $sidValue, $foundUpn)
                return $foundUpn
            }
        } catch {
            Log-Debug ("Failed to process non-Azure AD SessionData entry {0}: {1}" -f $entry.SessionKey, $_.Exception.Message)
        }
    }

    # Step 2.5: If no fully materialized identity found, check LogonCache as fallback
    # This handles cases where IdentityCache might not be present but UPN is in LogonCache
    # Prioritize Azure AD entries first
    try {
        # First check Azure AD entries
        foreach ($entry in $azureADEntries) {
            $foundUpn = Get-UpnFromLogonCache -Sid $entry.SID -SessionKey $entry.SessionKey
            if (-not [string]::IsNullOrEmpty($foundUpn)) {
                return $foundUpn
            }
        }

        # Then check non-Azure AD entries
        foreach ($entry in $nonAzureADEntries) {
            $foundUpn = Get-UpnFromLogonCache -Sid $entry.SID -SessionKey $entry.SessionKey
            if (-not [string]::IsNullOrEmpty($foundUpn)) {
                return $foundUpn
            }
        }
    } catch {
        Log-Debug ("LogonCache fallback lookup failed: {0}" -f $_.Exception.Message)
    }

    # Step 4: Fallback for local/domain accounts - try to get account name from collected SessionData
    # For local accounts, extract the account name from LoggedOnUser or LoggedOnSAMUser
    # Only do this if we haven't found any Azure AD UPNs
    if ($sessionDataEntries.Count -gt 0) {
        foreach ($entry in $sessionDataEntries) {
            try {
                # For local accounts, try to extract account name
                # Prefer LoggedOnUser, fallback to LoggedOnSAMUser
                $accountName = $null
                if (-not [string]::IsNullOrEmpty($entry.LoggedOnUser)) {
                    # Extract username from formats like "COMPUTER\username" or just "username"
                    if ($entry.LoggedOnUser -match '^[^\\]+\\(.+)$') {
                        $accountName = $matches[1]
                    } elseif ($entry.LoggedOnUser -notmatch '^AzureAD\\') {
                        # Not Azure AD, use as-is (could be local account name)
                        $accountName = $entry.LoggedOnUser
                    }
                }

                if ([string]::IsNullOrEmpty($accountName) -and -not [string]::IsNullOrEmpty($entry.LoggedOnSAMUser)) {
                    # Extract username from formats like "COMPUTER\username" or just "username"
                    if ($entry.LoggedOnSAMUser -match '^[^\\]+\\(.+)$') {
                        $accountName = $matches[1]
                    } else {
                        $accountName = $entry.LoggedOnSAMUser
                    }
                }

                if (-not [string]::IsNullOrEmpty($accountName)) {
                    Log-Info ("No UPN found - using local account name from SessionData {0}: {1}" -f $entry.SessionKey, $accountName)
                    return $accountName
                }
            } catch {
                Log-Debug ("Failed to extract account name from SessionData entry {0}: {1}" -f $entry.SessionKey, $_.Exception.Message)
            }
        }
    }

    # Step 4: Final fallback - use whoami /user to get the SID directly
    try {
        $whoamiOutput = whoami /user 2>&1
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($whoamiOutput)) {
            # Parse SID from whoami output
            # whoami /user output format:
            # USER INFORMATION
            # ----------------
            # User Name           SID
            # =================== ============================================
            # domain\username     S-1-5-21-...
            $sidPattern = 'S-1-5-\d+(-\d+)+'
            $sidMatch = [regex]::Match($whoamiOutput, $sidPattern)
            
            if ($sidMatch.Success) {
                $parsedSid = $sidMatch.Value
                
                # Skip SYSTEM and service accounts
                if ($parsedSid -ne "S-1-5-18" -and $parsedSid -ne "S-1-5-19" -and $parsedSid -ne "S-1-5-20") {
                    Log-Info ("No UPN or account name found - using SID from whoami /user: {0}" -f $parsedSid)
                    return $parsedSid
                } else {
                    Log-Debug ("whoami /user returned SYSTEM or service account SID, skipping")
                }
            } else {
                Log-Debug ("Failed to parse SID from whoami /user output")
            }
        }
    } catch {
        Log-Debug ("whoami /user fallback failed: {0}" -f $_.Exception.Message)
    }

    Log-Debug "No UPN or SID found"
    return $null
}

function Get-UrlParam {
    param([string]$Content, [string]$Name)

    if ([string]::IsNullOrEmpty($Content)) { return "" }

    $pattern = "(^|[?&]){0}=([^&]*)" -f [regex]::Escape($Name)
    $match = [regex]::Match($Content, $pattern)
    if ($match.Success) {
        return [Uri]::UnescapeDataString($match.Groups[2].Value)
    }
    return ""
}

function Get-JsonValue {
    param([string]$Content, [string]$Key)

    if ([string]::IsNullOrEmpty($Content)) { return "" }

    try {
        $obj = $Content | ConvertFrom-Json -ErrorAction Stop
        $value = $obj.$Key
        if ($null -ne $value) {
            return [string]$value
        }
    } catch {
        # ignore
    }

    $pattern = '"' + [regex]::Escape($Key) + '"\s*:\s*"([^"]*)"'
    $match = [regex]::Match($Content, $pattern)
    if ($match.Success) {
        return $match.Groups[1].Value
    }
    return ""
}

function Get-MdmEnrollmentParams {
    param([string]$EnrollmentUrl)

    Log-Info "Retrieving enrollment parameters from IRU gateway..."
    Log-Debug ("HTTP request URL: {0}" -f $EnrollmentUrl)

    $result = [pscustomobject]@{
        Token = ""
        ManagementUrl = ""
    }

    try {
        $response = Invoke-WebRequest -Uri $EnrollmentUrl -UseBasicParsing -ErrorAction Stop -TimeoutSec 60
        Log-Debug "Invoke-WebRequest completed successfully."
    } catch {
        Log-Error ("Failed to retrieve enrollment parameters: {0}" -f $_.Exception.Message)
        if ($_.Exception.InnerException) {
            Log-Debug ("Inner exception: {0}" -f $_.Exception.InnerException.Message)
        }
        return $result
    }

    if ($response.PSObject.Properties.Match("StatusCode").Count -gt 0) {
        $statusCode = [int]$response.StatusCode
        Log-Debug ("HTTP status code: {0}" -f $statusCode)
    }

    $content = $null
    if ($response.PSObject.Properties.Match("Content").Count -gt 0 -and $null -ne $response.Content) {
        $content = [string]$response.Content
    } elseif ($response.PSObject.Properties.Match("RawContent").Count -gt 0 -and $null -ne $response.RawContent) {
        $content = [string]$response.RawContent
    }

    if ($null -ne $content) {
        Log-Debug ("HTTP response length (chars): {0}" -f ($content.Length))
    }

    if ([string]::IsNullOrEmpty($content)) {
        Log-Error "No response data received"
        return $result
    }

    $token = Get-UrlParam -Content $content -Name "accesstoken"
    if ([string]::IsNullOrEmpty($token)) {
        $token = Get-JsonValue -Content $content -Key "accesstoken"
    }
    if ([string]::IsNullOrEmpty($token)) {
        $token = Get-JsonValue -Content $content -Key "access_token"
    }

    if ([string]::IsNullOrEmpty($token)) {
        Log-Error "No access token found in response"
        Log-Debug ("Raw response from server: {0}" -f $content)
        return $result
    }

    $result.Token = $token
    Log-Info "Successfully retrieved enrollment token"

    if ($script:DebugMode -and $token.Length -gt 10) {
        Log-Debug ("Token starts with: {0}..., ends with: ...{1}" -f $token.Substring(0, 5), $token.Substring($token.Length - 5))
        Log-Debug ("Token length: {0}" -f $token.Length)
    }

    return $result
}

function Register-WithMdm {
    param(
        [string]$ManagementUrl,
        [string]$Token,
        [string]$Upn,
        [ref]$FailureCode
    )

    if ($null -eq $FailureCode) {
        throw "FailureCode reference parameter cannot be null."
    }
    $FailureCode.Value = 0

    if ([string]::IsNullOrEmpty($ManagementUrl)) {
        Log-Error "Cannot register: Management URL is empty"
        $FailureCode.Value = 1
        return $false
    }

    if ([string]::IsNullOrEmpty($Token)) {
        Log-Error "Cannot register: Access token is empty"
        $FailureCode.Value = 1
        return $false
    }

    Log-Info ("Attempting MDM registration with management URL: {0}" -f $ManagementUrl)

    if ($script:DebugMode) {
        Log-Debug "Registration parameters:"
        if ([string]::IsNullOrEmpty($Upn)) {
            Log-Debug ("  UPN: NULL")
        } else {
            Log-Debug ("  UPN: {0}" -f $Upn)
        }
        Log-Debug ("  ManagementUrl: {0}" -f $ManagementUrl)
        if ($Token.Length -gt 10) {
            Log-Debug ("  Token (first/last 5 chars): {0}...{1}" -f $Token.Substring(0, 5), $Token.Substring($Token.Length - 5))
            Log-Debug ("  Token length: {0}" -f $Token.Length)
        }

        try {
            $uri = [System.Uri]$ManagementUrl
            Log-Debug ("  Scheme: {0}" -f $uri.Scheme)
            Log-Debug ("  Host: {0}" -f $uri.Host)
            Log-Debug ("  Path: {0}" -f $uri.AbsolutePath)
            Log-Debug ("  Port: {0}" -f $uri.Port)
        } catch {
            Log-Debug ("Management URL parsing failed. Error: {0}" -f $_.Exception.Message)
        }
    }

    $registerSource = "default"
    try {
        $hr = [Interop.MdmRegistration]::RegisterDeviceWithFallback($Upn, $ManagementUrl, $Token)
        $registerSource = [Interop.MdmRegistration]::GetLastRegisterSource()
        Log-Debug ("RegisterDeviceWithManagement invoked via {0} context." -f $registerSource)
    } catch {
        Log-Error ("MDM registration threw exception: {0}" -f $_.Exception.Message)
        $FailureCode.Value = 0xFFFFFFFF
        return $false
    }

    if ($hr -eq 0) {
        Log-Info "MDM registration successful"
        return $true
    }

    Log-Error ("MDM registration failed with HRESULT 0x{0:X8} (context={1})" -f ($hr -band 0xFFFFFFFF), $registerSource)
    $FailureCode.Value = ($hr -band 0xFFFFFFFF)
    return $false
}


function Remove-EnrollmentScheduledTasks {
    param(
        [Parameter(Mandatory=$true)]
        [string]$EnrollmentId
    )

    Log-Debug ("Checking for scheduled tasks under \\Microsoft\\Windows\\EnterpriseMgmt\\* matching enrollment ID '{0}'..." -f $EnrollmentId)

    try {
        $taskPath = "\Microsoft\Windows\EnterpriseMgmt"

        # Get all tasks recursively under the EnterpriseMgmt path
        # We need to search all tasks and filter by path
        # Wrap in @() to ensure it's always an array, even if Where-Object returns null or a single object
        $allTasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
            $_.TaskPath -like "$taskPath*"
        })
        
        if ($null -eq $allTasks -or $allTasks.Count -eq 0) {
            Log-Debug ("No scheduled tasks found under '{0}'." -f $taskPath)
            return 0
        }

        $removedCount = 0
        foreach ($task in $allTasks) {
            $taskName = $task.TaskName
            $taskPathValue = $task.TaskPath
            $fullTaskPath = $taskPathValue + $taskName
            
            # Check if task name or path contains the enrollment ID
            if ($taskName -like "*$EnrollmentId*" -or $taskPathValue -like "*$EnrollmentId*" -or $fullTaskPath -like "*$EnrollmentId*") {
                try {
                    Log-Debug ("Removing scheduled task: {0}" -f $fullTaskPath)
                    Unregister-ScheduledTask -TaskName $taskName -TaskPath $taskPathValue -Confirm:$false -ErrorAction Stop
                    Log-Info ("Successfully removed scheduled task '{0}' for enrollment ID '{1}'." -f $fullTaskPath, $EnrollmentId)
                    $removedCount++
                } catch {
                    Log-Warn ("Failed to remove scheduled task '{0}': {1}" -f $fullTaskPath, $_.Exception.Message)
                }
            }
        }

        Log-Info ("Removed {0} scheduled task(s) for enrollment ID '{1}'." -f $removedCount, $EnrollmentId)

        return $removedCount
    } catch {
        Log-Warn ("Error checking for scheduled tasks: {0}" -f $_.Exception.Message)
        return 0
    }
}

function Remove-EnrollmentRegistryKeys {
    param(
        [Parameter(Mandatory=$true)]
        [string]$EnrollmentId
    )

    Log-Debug ("Starting registry cleanup for enrollment ID '{0}'..." -f $EnrollmentId)
    
    $regPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Enrollments\Status\$EnrollmentId",
        "HKLM:\SOFTWARE\Microsoft\EnterpriseResourceManager\Tracked\$EnrollmentId",
        "HKLM:\SOFTWARE\Microsoft\PolicyManager\AdmxInstalled\$EnrollmentId",
        "HKLM:\SOFTWARE\Microsoft\PolicyManager\Providers\$EnrollmentId",
        "HKLM:\SOFTWARE\Microsoft\Provisioning\OMADM\Accounts\$EnrollmentId",
        "HKLM:\SOFTWARE\Microsoft\Provisioning\OMADM\Logger\$EnrollmentId",
        "HKLM:\SOFTWARE\Microsoft\Provisioning\OMADM\Sessions\$EnrollmentId",
        "HKLM:\SOFTWARE\Microsoft\Enrollments\$EnrollmentId"
    )

    $removedCount = 0
    $skippedCount = 0
    $failedCount = 0

    foreach ($regPath in $regPaths) {
        try {
            if (Test-Path -Path $regPath) {
                Log-Debug ("Removing registry key: {0}" -f $regPath)
                Remove-Item -Path $regPath -Recurse -Force -ErrorAction Stop
                Log-Info ("Successfully removed registry key: {0}" -f $regPath)
                $removedCount++
            } else {
                Log-Debug ("Registry key does not exist (skipping): {0}" -f $regPath)
                $skippedCount++
            }
        } catch {
            Log-Warn ("Failed to remove registry key '{0}': {1}" -f $regPath, $_.Exception.Message)
            $failedCount++
        }
    }

    Log-Info ("Registry cleanup complete for enrollment ID '{0}': {1} removed, {2} skipped, {3} failed." -f $EnrollmentId, $removedCount, $skippedCount, $failedCount)

    return @{
        Removed = $removedCount
        Skipped = $skippedCount
        Failed = $failedCount
    }
}

function Remove-EnrollmentArtifacts {
    param(
        [Parameter(Mandatory=$true)]
        [string]$EnrollmentId
    )

    Log-Info ("Starting cleanup of enrollment artifacts for ID '{0}'..." -f $EnrollmentId)

    # Remove scheduled tasks
    $taskCount = Remove-EnrollmentScheduledTasks -EnrollmentId $EnrollmentId

    # Remove registry keys
    $regResult = Remove-EnrollmentRegistryKeys -EnrollmentId $EnrollmentId

    Log-Info ("Cleanup complete for enrollment ID '{0}': {1} scheduled task(s) removed, {2} registry key(s) removed." -f $EnrollmentId, $taskCount, $regResult.Removed)

    return @{
        TasksRemoved = $taskCount
        RegistryKeysRemoved = $regResult.Removed
        RegistryKeysSkipped = $regResult.Skipped
        RegistryKeysFailed = $regResult.Failed
    }
}

function Invoke-ApplicationUninstalls {
    param(
        [string[]]$UninstallCommands
    )

    if ($null -eq $UninstallCommands -or $UninstallCommands.Count -eq 0) {
        Log-Debug "No uninstall commands provided, skipping application uninstall step."
        return
    }

    # Filter out null/empty commands
    $validCommands = @($UninstallCommands | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    if ($validCommands.Count -eq 0) {
        Log-Debug "No valid uninstall commands provided, skipping application uninstall step."
        return
    }

    Log-Info ("Starting application uninstall process: {0} command(s) to execute." -f $validCommands.Count)

    $successCount = 0
    $failureCount = 0

    for ($i = 0; $i -lt $validCommands.Count; $i++) {
        $commandIndex = $i + 1
        $command = $validCommands[$i].Trim()

        if ([string]::IsNullOrWhiteSpace($command)) {
            Log-Debug ("Skipping uninstall command {0} (empty or whitespace)." -f $commandIndex)
            continue
        }

        Log-Info ("Executing uninstall command {0} of {1}: {2}" -f $commandIndex, $validCommands.Count, $command)

        try {
            # Use cmd.exe /c to execute the full command line - this handles all quoting and escaping properly
            # This approach works for msiexec, setup.exe, and any other command line
            $processStartInfo = New-Object System.Diagnostics.ProcessStartInfo
            $processStartInfo.FileName = "cmd.exe"
            $processStartInfo.Arguments = "/c `"$command`""
            $processStartInfo.UseShellExecute = $false
            $processStartInfo.RedirectStandardOutput = $true
            $processStartInfo.RedirectStandardError = $true
            $processStartInfo.CreateNoWindow = $true

            Log-Debug ("Uninstall command {0}: Starting process via cmd.exe..." -f $commandIndex)
            $process = [System.Diagnostics.Process]::Start($processStartInfo)

            # Wait for the process to complete with a timeout (30 minutes max)
            $timeoutMinutes = 30
            $processCompleted = $process.WaitForExit($timeoutMinutes * 60 * 1000)

            if (-not $processCompleted) {
                Log-Warn ("Uninstall command {0}: Process timed out after {1} minutes, terminating..." -f $commandIndex, $timeoutMinutes)
                $process.Kill()
                $process.WaitForExit(10000)  # Wait up to 10 seconds for termination
                $failureCount++
                continue
            }

            $exitCode = $process.ExitCode
            $stdout = $process.StandardOutput.ReadToEnd()
            $stderr = $process.StandardError.ReadToEnd()

            if ($exitCode -eq 0) {
                $successCount++
                Log-Info ("Uninstall command {0} completed successfully (exit code: {1})." -f $commandIndex, $exitCode)
                if (-not [string]::IsNullOrWhiteSpace($stdout)) {
                    Log-Debug ("Uninstall command {0} stdout: {1}" -f $commandIndex, $stdout)
                }
            } else {
                $failureCount++
                Log-Warn ("Uninstall command {0} failed with exit code {1}." -f $commandIndex, $exitCode)
                if (-not [string]::IsNullOrWhiteSpace($stdout)) {
                    Log-Debug ("Uninstall command {0} stdout: {1}" -f $commandIndex, $stdout)
                }
                if (-not [string]::IsNullOrWhiteSpace($stderr)) {
                    Log-Debug ("Uninstall command {0} stderr: {1}" -f $commandIndex, $stderr)
                }
            }

            $process.Dispose()

        } catch {
            $failureCount++
            Log-Warn ("Uninstall command {0} threw an exception: {1}" -f $commandIndex, $_.Exception.Message)
            Log-Debug ("Exception details: {0}" -f $_.Exception.ToString())
        }
    }

    Log-Info ("Application uninstall process complete: {0} succeeded, {1} failed out of {2} total command(s)." -f $successCount, $failureCount, $validCommands.Count)
}

function Get-EnrollmentCandidates {
    $list = @()
    $root = $null

    try {
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
        $root = $base.OpenSubKey("SOFTWARE\\Microsoft\\Enrollments")
    } catch {
        Log-Error ("Failed to open enrollment registry key: {0}" -f $_.Exception.Message)
    }

    if (-not $root) {
        Log-Info ("No enrollments found at HKLM\\{0}." -f "SOFTWARE\Microsoft\Enrollments")
        return $list
    }

    $exclude = @("Local Authority", "Cloud Authority", "Deploy Authority")

    foreach ($name in $root.GetSubKeyNames()) {
        if ($name -ieq "Status") { continue }

        $sub = $root.OpenSubKey($name)
        if (-not $sub) { continue }

        try {
            $provider = $sub.GetValue("ProviderID", $null)
            $upn = $sub.GetValue("UPN", "")

            if ([string]::IsNullOrEmpty($provider)) {
                Log-Debug ("Skipping {0} (no ProviderID)." -f $name)
                continue
            }

            $skip = $false
            foreach ($item in $exclude) {
                if ($item.Equals($provider, [System.StringComparison]::InvariantCultureIgnoreCase)) {
                    $skip = $true
                    break
                }
            }

            if ($skip) {
                Log-Debug ("Excluding {0} (ProviderID='{1}')." -f $name, $provider)
                continue
            }

            # Secondary check: verify DMPCertThumbprint exists and isn't empty
            $dmpCertThumbprint = $sub.GetValue("DMPCertThumbprint", $null)
            if ([string]::IsNullOrEmpty($dmpCertThumbprint)) {
                Log-Debug ("Skipping {0} (DMPCertThumbprint is missing or empty)." -f $name)
                continue
            }

            $list += [pscustomobject]@{
                Id         = $name
                ProviderId = $provider
                Upn        = $upn
            }
        } finally {
            $sub.Close()
        }
    }

    $root.Close()
    $base.Close()
    return $list
}

function Try-UnregisterWithFallback {
    param([string]$EnrollmentId)

    # Set up logging callback to forward C# log messages to PowerShell
    $logCallback = [Interop.MdmHelpers+LogCallback] {
        param([string]$message)
        Log-Debug $message
    }
    [Interop.MdmHelpers]::SetLogCallback($logCallback)

    Log-Debug ("Attempting unregister with default COM settings for enrollment ID: {0}" -f $EnrollmentId)
    Log-Debug ("Current thread: ManagedThreadId={0}, IsThreadPoolThread={1}" -f [System.Threading.Thread]::CurrentThread.ManagedThreadId, [System.Threading.Thread]::CurrentThread.IsThreadPoolThread)

    # Log execution context to help diagnose threading issues
    try {
        $currentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $currentPrincipal = [System.Security.Principal.WindowsPrincipal]$currentIdentity
        $isAdmin = $currentPrincipal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
        Log-Debug ("Execution context: User={0}, IsAdmin={1}, IsSystem={2}" -f $currentIdentity.Name, $isAdmin, ($currentIdentity.Name -eq "NT AUTHORITY\SYSTEM"))
    } catch {
        Log-Debug ("Failed to get execution context: {0}" -f $_.Exception.Message)
    }

    $rc = [int]::MinValue
    try {
        $rc = [Interop.MdmHelpers]::TryUnregisterWithApartmentFallback($EnrollmentId)

        $exc = [Interop.MdmHelpers]::LastUnregisterExceptionCode
        $stage = [Interop.MdmHelpers]::LastUnregisterStage
        $coInit = [Interop.MdmHelpers]::LastUnregisterCoInitHr
        $threadTimedOut = [Interop.MdmHelpers]::LastUnregisterThreadTimedOut
        $message = [Interop.MdmHelpers]::LastUnregisterMessage

        if ($rc -eq 0) {
            Log-Debug ("Unregister succeeded (Stage={0}, ExceptionCode=0x{1:X8}, CoInitHr=0x{2:X8})" -f $stage, ($exc -band 0xFFFFFFFF), ($coInit -band 0xFFFFFFFF))
            return 0
        }

        Log-Debug ("Unregister returned: 0x{0:X8} (Stage={1}, ExceptionCode=0x{2:X8}, CoInitHr=0x{3:X8}, ThreadTimedOut={4})" -f 
            ($rc -band 0xFFFFFFFF), $stage, ($exc -band 0xFFFFFFFF), ($coInit -band 0xFFFFFFFF), $threadTimedOut)

        if (-not [string]::IsNullOrEmpty($message)) {
            Log-Debug ("Unregister message: {0}" -f $message)
        }

        if ($threadTimedOut) {
            Log-Warn ("Unregister thread timed out during {0} stage. The unregister operation may have hung." -f $stage)
        }

        if ($rc -eq [int]::MinValue) {
            Log-Warn ("UnregisterDeviceWithManagement encountered exception 0x{0:X8} during {1} stage (CoInitializeEx HR=0x{2:X8})." -f 
                ($exc -band 0xFFFFFFFF), $stage, ($coInit -band 0xFFFFFFFF))
        }
    } catch {
        Log-Error ("Exception in TryUnregisterWithApartmentFallback: {0}" -f $_.Exception.Message)
        Log-Debug ("Exception details: {0}" -f $_.Exception.ToString())
        $rc = [int]::MinValue
        # Don't re-throw - return error code instead to prevent script from exiting
    } finally {
        # Clear the logging callback
        [Interop.MdmHelpers]::SetLogCallback($null)
    }

    return $rc
}

function Test-TenantParams {
    param(
        [string]$TenantName,
        [string]$BlueprintId,
        [string]$EnrollmentCode,
        [string]$TenantId,
        [string]$TenantLocation
    )

    $valid = $true

    if ([string]::IsNullOrEmpty($TenantName)) {
        Log-Error "Tenant name cannot be empty"
        $valid = $false
    } elseif ($TenantName.Contains(".")) {
        Log-Error "Tenant name should not include domain (e.g., use 'contoso' not 'contoso.com')"
        $valid = $false
    }

    if ([string]::IsNullOrEmpty($BlueprintId)) {
        Log-Error "Blueprint ID cannot be empty"
        $valid = $false
    } elseif ($BlueprintId.Length -lt 5) {
        Log-Error "Blueprint ID seems too short - please verify"
        $valid = $false
    }

    if ([string]::IsNullOrEmpty($EnrollmentCode)) {
        Log-Error "Enrollment code cannot be empty"
        $valid = $false
    }

    if ([string]::IsNullOrWhiteSpace($TenantId)) {
        Log-Error "Tenant ID cannot be empty"
        $valid = $false
    } elseif ($TenantId -match "\s") {
        Log-Error "Tenant ID cannot contain whitespace characters"
        $valid = $false
    }

    if ([string]::IsNullOrWhiteSpace($TenantLocation)) {
        Log-Error "Tenant location must be specified as 'US' or 'EU'"
        $valid = $false
    } else {
        $normalizedLocation = $TenantLocation.Trim().ToUpperInvariant()
        if ($normalizedLocation -ne "US" -and $normalizedLocation -ne "EU") {
            Log-Error "Tenant location must be either 'US' or 'EU'"
            $valid = $false
        }
    }

    return $valid
}

function Build-EnrollmentUrl {
    param(
        [string]$TenantName,
        [string]$BlueprintId,
        [string]$EnrollmentCode,
        [string]$TenantLocation
    )

    $normalizedLocation = if ([string]::IsNullOrWhiteSpace($TenantLocation)) { "US" } else { $TenantLocation.Trim().ToUpperInvariant() }
    $format = if ($normalizedLocation -eq "EU") {
        "https://{0}.gateway.eu.iru.com/main-backend/app/v1/mdm/enroll-ota/{1}?code={2}&platform=windows"
    } else {
        "https://{0}.gateway.iru.com/main-backend/app/v1/mdm/enroll-ota/{1}?code={2}&platform=windows"
    }

    return ($format -f $TenantName, $BlueprintId, $EnrollmentCode)
}

function Build-ManagementUrl {
    param(
        [string]$TenantId,
        [string]$TenantLocation
    )

    if ([string]::IsNullOrWhiteSpace($TenantId)) {
        return $null
    }

    $normalizedLocation = if ([string]::IsNullOrWhiteSpace($TenantLocation)) { "US" } else { $TenantLocation.Trim().ToUpperInvariant() }
    $cleanTenantId = $TenantId.Trim().ToLowerInvariant()
    $format = if ($normalizedLocation -eq "EU") {
        "https://{0}.web-api.eu.kandji.io/ms/enrollment/discovery"
    } else {
        "https://{0}.web-api.kandji.io/ms/enrollment/discovery"
    }

    return ($format -f $cleanTenantId)
}

function New-Font {
    param(
        [string]$Name,
        [float]$Size,
        [System.Drawing.FontStyle]$Style = [System.Drawing.FontStyle]::Regular
    )
    try {
        return New-Object System.Drawing.Font($Name, $Size, $Style, [System.Drawing.GraphicsUnit]::Point)
    } catch {
        return New-Object System.Drawing.Font("Segoe UI", $Size, $Style, [System.Drawing.GraphicsUnit]::Point)
    }
}

function Show-MigrationDialog {
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][string]$BodyText,
        [int]$Width = 680,
        [int]$Height = 440,
        [int[]]$ContentPadding = @(28, 28, 28, 36),
        [int[]]$FooterPadding = @(28, 20, 0, 24),
        [int]$FooterHeight = 80,
        [int]$BodyMarginBottom = 32,
        [int]$BodyMaxWidth = 0,
        [string]$PrimaryButtonText = "OK",
        [string]$PrimaryResult = "Primary",
        [string]$SecondaryButtonText,
        [string]$SecondaryResult = "Secondary",
        [switch]$DisableContentAutoScroll
    )

    $script:UiAssembliesLoaded = $false
    if (-not $script:UiAssembliesLoaded) {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        $script:UiAssembliesLoaded = $true
    }

    if ($ContentPadding.Count -lt 4) {
        throw "ContentPadding must include four integers (left, top, right, bottom)."
    }
    if ($FooterPadding.Count -lt 4) {
        throw "FooterPadding must include four integers (left, top, right, bottom)."
    }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = $Title
    $form.Size = New-Object System.Drawing.Size($Width, $Height)
    $form.StartPosition = "CenterScreen"
    $form.Topmost = $true
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.BackColor = [System.Drawing.Color]::White
    $form.Tag = $null
    $contentPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $contentPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $contentPanel.Padding = New-Object System.Windows.Forms.Padding($ContentPadding[0], $ContentPadding[1], $ContentPadding[2], $ContentPadding[3])
    $contentPanel.BackColor = [System.Drawing.Color]::White
    $contentPanel.FlowDirection = [System.Windows.Forms.FlowDirection]::TopDown
    $contentPanel.WrapContents = $false
    $contentPanel.AutoScroll = -not $DisableContentAutoScroll.IsPresent
    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = $Title
    $titleLabel.AutoSize = $true
    $titleLabel.Font = New-Font "Segoe UI Semibold" 16 ([System.Drawing.FontStyle]::Bold)
    $titleLabel.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 12)
    $titleLabel.UseMnemonic = $false
    $maxTextWidth = if ($BodyMaxWidth -gt 0) { $BodyMaxWidth } else { [Math]::Max(200, $form.ClientSize.Width - $contentPanel.Padding.Left - $contentPanel.Padding.Right) }
    $bodyLabel = New-Object System.Windows.Forms.Label
    $bodyLabel.Text = $BodyText
    $bodyLabel.AutoSize = $true
    $bodyLabel.MaximumSize = New-Object System.Drawing.Size($maxTextWidth, 0)
    $bodyLabel.Font = New-Font "Segoe UI" 11
    $bodyLabel.UseMnemonic = $false
    $bodyLabel.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, $BodyMarginBottom)
    $contentPanel.Controls.Add($titleLabel)
    $contentPanel.Controls.Add($bodyLabel)
    $footerPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $footerPanel.Dock = [System.Windows.Forms.DockStyle]::Bottom
    $footerPanel.Height = $FooterHeight
    $footerPanel.FlowDirection = [System.Windows.Forms.FlowDirection]::RightToLeft
    $footerPanel.Padding = New-Object System.Windows.Forms.Padding($FooterPadding[0], $FooterPadding[1], $FooterPadding[2], $FooterPadding[3])
    $footerPanel.WrapContents = $false
    $footerPanel.BackColor = [System.Drawing.Color]::FromArgb(245, 245, 245)
    $footerPanel.AutoSize = $false
    $primaryButtonTextValue = if ([string]::IsNullOrWhiteSpace($PrimaryButtonText)) { "OK" } else { $PrimaryButtonText }
    $primaryResultValue = if ([string]::IsNullOrWhiteSpace($PrimaryResult)) { $primaryButtonTextValue } else { $PrimaryResult }
    $primaryButton = New-Object System.Windows.Forms.Button
    $primaryButton.Text = $primaryButtonTextValue
    $primaryButton.Width = 120
    $primaryButton.Height = 38
    $primaryButton.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 0)
    $primaryButton.Font = New-Font "Segoe UI Semibold" 10
    $primaryButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $primaryButton.FlatAppearance.BorderSize = 0
    $primaryButton.BackColor = [System.Drawing.SystemColors]::Highlight
    $primaryButton.ForeColor = [System.Drawing.Color]::White
    $primaryButton.UseVisualStyleBackColor = $false
    $primaryButton.Add_Click({
        $formRef = $this.FindForm()
        if ($formRef) {
            $formRef.Tag = $primaryResultValue
            $formRef.Close()
        }
    })
    $secondaryButton = $null
    if (-not [string]::IsNullOrWhiteSpace($SecondaryButtonText)) {
        $secondaryButton = New-Object System.Windows.Forms.Button
        $secondaryButton.Text = $SecondaryButtonText
        $secondaryButton.Width = 120
        $secondaryButton.Height = 38
        $secondaryButton.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 0)
        $secondaryButton.Font = New-Font "Segoe UI" 10
        $secondaryButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $secondaryButton.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(200, 200, 200)
        $secondaryButton.FlatAppearance.BorderSize = 1
        $secondaryButton.BackColor = [System.Drawing.Color]::White
        $secondaryButton.UseVisualStyleBackColor = $false
        $secondaryResultValue = if ([string]::IsNullOrWhiteSpace($SecondaryResult)) { $SecondaryButtonText } else { $SecondaryResult }
        $secondaryButton.Add_Click({
            $formRef = $this.FindForm()
            if ($formRef) {
                $formRef.Tag = $secondaryResultValue
                $formRef.Close()
            }
        })
        $footerPanel.Controls.Add($secondaryButton)
        $primaryButton.Margin = New-Object System.Windows.Forms.Padding(0, 0, 12, 0)
        $form.CancelButton = $secondaryButton
    } else {
        $form.CancelButton = $primaryButton
    }
    $footerPanel.Controls.Add($primaryButton)
    $form.Controls.Add($contentPanel)
    $form.Controls.Add($footerPanel)
    $form.AcceptButton = $primaryButton
    $dialogResult = $form.ShowDialog()
    return [pscustomobject]@{
        Result = $form.Tag
        DialogResult = $dialogResult
    }
}

#Beginning of Script
Initialize-Logger
Log-Info "Starting MDM management tool..."

$tenantName = if ($PSBoundParameters.ContainsKey('TenantName') -and -not [string]::IsNullOrWhiteSpace($TenantName)) { $TenantName.Trim() } elseif (-not [string]::IsNullOrWhiteSpace($TenantNameDefault)) { $TenantNameDefault.Trim() } else { $null }
$blueprintId = if ($PSBoundParameters.ContainsKey('BlueprintId') -and -not [string]::IsNullOrWhiteSpace($BlueprintId)) { $BlueprintId.Trim() } elseif (-not [string]::IsNullOrWhiteSpace($BlueprintIdDefault)) { $BlueprintIdDefault.Trim() } else { $null }
$enrollmentCode = if ($PSBoundParameters.ContainsKey('EnrollmentCode') -and -not [string]::IsNullOrWhiteSpace($EnrollmentCode)) { $EnrollmentCode.Trim() } elseif (-not [string]::IsNullOrWhiteSpace($EnrollmentCodeDefault)) { $EnrollmentCodeDefault.Trim() } else { $null }
$tenantId = if ($PSBoundParameters.ContainsKey('TenantId') -and -not [string]::IsNullOrWhiteSpace($TenantId)) { $TenantId.Trim() } elseif (-not [string]::IsNullOrWhiteSpace($TenantIdDefault)) { $TenantIdDefault.Trim() } else { $null }
$tenantLocation = if ($PSBoundParameters.ContainsKey('TenantLocation') -and -not [string]::IsNullOrWhiteSpace($TenantLocation)) { $TenantLocation.Trim() } elseif (-not [string]::IsNullOrWhiteSpace($TenantLocationDefault)) { $TenantLocationDefault.Trim() } else { $null }
if (-not [string]::IsNullOrWhiteSpace($tenantLocation)) {
    $tenantLocation = $tenantLocation.ToUpperInvariant()
}
$managementUrl = if (-not [string]::IsNullOrWhiteSpace($tenantId)) { Build-ManagementUrl -TenantId $tenantId -TenantLocation $tenantLocation } else { $null }

# Process uninstall application parameters
# Use parameter if provided, otherwise use default array, filtering out null/empty values and trimming
if ($PSBoundParameters.ContainsKey('UninstallApp') -and $null -ne $UninstallApp) {
    $uninstallApp = @($UninstallApp | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() })
} elseif ($null -ne $UninstallAppDefault -and $UninstallAppDefault.Count -gt 0) {
    $uninstallApp = @($UninstallAppDefault | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() })
} else {
    $uninstallApp = @()
}

$script:DebugMode = $Debug.IsPresent -or $EnableDebugDefault
$silentMode = $Silent.IsPresent -or $EnableSilentDefault
    
if (-not (Test-TenantParams -TenantName $tenantName -BlueprintId $blueprintId -EnrollmentCode $enrollmentCode -TenantId $tenantId -TenantLocation $tenantLocation)) {
    Log-Error "Script exit code: 1"
    exit 1
}

$userCancelled = $false
if (-not $silentMode) {
    try {
        $titleText = "Device Management Enrollment"
        $bodyText = @"
We will be helping to enroll your Windows device into your new MDM experience. Click the Enroll button to begin the process.

- Your computer may unenroll from the current device management system. You'll briefly see a Windows message confirming your device was removed from management.

- Then, it will automatically enroll into the new MDM experience.

The enrollment takes only a few minutes, and you can continue working while it runs.
"@

     $dialog = Show-MigrationDialog `
            -Title $titleText `
            -BodyText $bodyText `
            -Width 680 `
            -Height 440 `
            -ContentPadding @(28, 28, 28, 36) `
            -FooterPadding @(28, 20, 0, 24) `
            -FooterHeight 80 `
            -BodyMarginBottom 32 `
            -PrimaryButtonText "Enroll" `
            -PrimaryResult "Enroll" `
            -SecondaryButtonText "Cancel" `
            -SecondaryResult "Cancel"
        switch ($dialog.Result) {
            "Enroll" {
                Log-Info "User confirmed enrollment via dialog."
            }
            "Cancel" {
                Log-Info "User canceled enrollment via dialog; exiting."
                Log-Info "Script exit code: 0 (user canceled)"
                $userCancelled = $true
            }
            default {
                if ($dialog.DialogResult -eq [System.Windows.Forms.DialogResult]::Cancel) {
                    Log-Info "User dismissed enrollment dialog; exiting."
                    Log-Info "Script exit code: 0 (user canceled)"
                    $userCancelled = $true
                }
            }
        }
    } catch {
        Log-Warn ("Failed to display enrollment prompt: {0}. Continuing without prompt." -f $_.Exception.Message)
    }

    if ($userCancelled) {
        exit 0
    }
}

if ($silentMode) {
    Log-Info "Silent mode enabled; user dialogs suppressed."
}

if ([Environment]::Is64BitOperatingSystem) {
    Log-Info "OS architecture: x64"

    if ([Environment]::Is64BitProcess) {
        Log-Info "Process architecture: x64"
    } else {
        Log-Info "Process architecture: x86"
    }
} else {
    Log-Info "OS architecture: x86"
    Log-Info "Process architecture: x86"
}

if ($script:DebugMode) {
    Log-Debug ("Command-line argument count: {0}" -f $args.Count)
    for ($i = 0; $i -lt $args.Count; ++$i) {
        $s = if ($args[$i]) { $args[$i] } else { "" }
        Log-Debug ("argv[{0}] (len={1}): '{2}'" -f $i, $s.Length, $s)
    }
}

if (-not (Test-TenantParams -TenantName $tenantName -BlueprintId $blueprintId -EnrollmentCode $enrollmentCode -TenantID $tenantID -TenantLocation $tenantLocation)) {
    Log-Error "Script exit code: 1"
    exit 1
}

$tenantUrl = Build-EnrollmentUrl -TenantName $tenantName -BlueprintId $blueprintId -EnrollmentCode $enrollmentCode -TenantLocation $tenantLocation
Log-Info ("Generated enrollment URL: {0}" -f $tenantUrl)

# Get UPN or account name for logged-in user
# Unified approach: Get interactive user's SID -> Query registry by SID
# This works for: Entra/AzureAD, Domain-joined, Local accounts (returns account name), and works when running as SYSTEM
Log-Info "Retrieving logged-in user's UPN or account name..."
$upn = Get-InteractiveUserUpn

if (-not [string]::IsNullOrEmpty($upn)) {
    if ($upn.Contains('@')) {
        Log-Info ("Using UPN for enrollment: {0}" -f $upn)
    } else {
        # Local account name (no @ symbol) - use it for enrollment
        Log-Info ("Using local account name for enrollment: {0}" -f $upn)
    }
} else {
    Log-Warn "Could not determine user identity. Using NULL for UPN field."
    $upn = $null
}

if (-not (Test-IsElevated)) {
    Log-Error "Must be run elevated (Administrator)."
    exit 1
}

if (-not (Initialize-MdmRegistration)) {
    exit 1
}

$exitCode = 0

try {
    Log-Info "Retrieving enrollment parameters before migration steps..."
    $enrollParams = Get-MdmEnrollmentParams -EnrollmentUrl $tenantUrl
    if ([string]::IsNullOrEmpty($enrollParams.Token)) {
        Log-Error "Failed to retrieve enrollment token. Aborting migration."
        $exitCode = 1
        return
    }

    $enrollParams.ManagementUrl = $managementUrl
    Log-Info ("Using management URL for registration: {0}" -f $managementUrl)

    $candidates = Get-EnrollmentCandidates
    $candidateArray = @()
    if ($null -ne $candidates) {
        $candidateArray = @($candidates)
    }
    $candidateCount = $candidateArray.Count

    if ($candidateCount -eq 0) {
        Log-Info "No enrollment IDs found after filtering. Device appears not currently MDM enrolled."
        Log-Info "Skipping unenrollment and moving directly to registration."
    } else {
        Log-Info ("Found {0} enrollment(s) to process." -f $candidateCount)

        $successes = 0
        $failures = 0

        foreach ($c in $candidateArray) {
            Log-Info ("Attempting unenroll: ID={0}, ProviderID='{1}', UPN='{2}'" -f $c.Id, $c.ProviderId, $c.Upn)
            try {
                # Retry logic: Only retry once (2 attempts total) for this specific enrollment ID
                # Each attempt will try the full process: primary -> MTA -> STA
                $attempt = 1
                $maxAttempts = 2
                $rc = [int]::MinValue
                $threadTimedOut = $false
                $exceptionCode = 0
                $stage = ""
                
                # First attempt
                Log-Info ("Unregister attempt {0} of {1} for enrollment ID '{2}'" -f $attempt, $maxAttempts, $c.Id)
                $rc = Try-UnregisterWithFallback -EnrollmentId $c.Id
                $threadTimedOut = [Interop.MdmHelpers]::LastUnregisterThreadTimedOut
                $anyThreadTimedOut = [Interop.MdmHelpers]::LastUnregisterAnyThreadTimedOut
                $exceptionCode = [Interop.MdmHelpers]::LastUnregisterExceptionCode
                $stage = [Interop.MdmHelpers]::LastUnregisterStage
                
                # If first attempt succeeded, we're done with this enrollment ID
                # If it failed but no timeout occurred at any stage, no retry needed
                # If any stage timed out (even if later stages completed), retry once
                if ($anyThreadTimedOut -and $attempt -lt $maxAttempts) {
                    # Any thread timed out during first attempt (MTA, STA, etc.) - retry once more for this enrollment ID only
                    $attempt++
                    Log-Warn ("UnregisterDeviceWithManagement('{0}') thread timed out during first attempt (stage: {1}). Retrying once more for this enrollment ID (will try primary, then MTA, then STA again)..." -f $c.Id, $stage)
                    Start-Sleep -Milliseconds 1000  # Pause before retry to allow COM state to settle and hung threads to potentially complete
                    
                    Log-Info ("Unregister attempt {0} of {1} for enrollment ID '{2}'" -f $attempt, $maxAttempts, $c.Id)
                    $rc = Try-UnregisterWithFallback -EnrollmentId $c.Id
                    $threadTimedOut = [Interop.MdmHelpers]::LastUnregisterThreadTimedOut
                    $anyThreadTimedOut = [Interop.MdmHelpers]::LastUnregisterAnyThreadTimedOut
                    $exceptionCode = [Interop.MdmHelpers]::LastUnregisterExceptionCode
                    $stage = [Interop.MdmHelpers]::LastUnregisterStage
                }
                
                if ($rc -eq 0) {
                    $successes++

                    Log-Info ("SUCCESS: UnregisterDeviceWithManagement('{0}') returned 0 on retry attempt {1}." -f $c.Id, $attempt)

                    # Clean up all enrollment artifacts (scheduled tasks, registry keys) since unenrollment was successful
                    Remove-EnrollmentArtifacts -EnrollmentId $c.Id
                } elseif ($anyThreadTimedOut) {
                    # Thread timed out on both attempts (or any stage timed out) - mark as failure but continue anyway
                    $failures++
                    Log-Warn ("FAILED: UnregisterDeviceWithManagement('{0}') thread timed out during attempt(s). Return code: 0x{1:X8}, ExceptionCode: 0x{2:X8}, Stage: {3}, CurrentThreadTimedOut: {4}" -f $c.Id, ($rc -band 0xFFFFFFFF), ($exceptionCode -band 0xFFFFFFFF), $stage, $threadTimedOut)
                    Log-Info ("Continuing to enrollment anyway - if device is still enrolled, enrollment will fail; otherwise it will proceed.")
                } else {
                    $failures++
                    Log-Warn ("FAILED: UnregisterDeviceWithManagement('{0}') returned 0x{1:X8}." -f $c.Id, ($rc -band 0xFFFFFFFF))
                    Log-Info ("Continuing to enrollment anyway - if device is still enrolled, enrollment will fail; otherwise it will proceed.")
                }
            } catch {
                $failures++
                Log-Error ("EXCEPTION during unregister for enrollment ID '{0}': {1}" -f $c.Id, $_.Exception.Message)
                Log-Debug ("Exception details: {0}" -f $_.Exception.ToString())
                Log-Info ("Continuing to enrollment anyway - if device is still enrolled, enrollment will fail; otherwise it will proceed.")
            }
        }

        Log-Info ("Unenroll pass complete. Success={0}, Failed={1}." -f $successes, $failures)
        if ($failures -gt 0) {
            Log-Warn "Continuing to registration despite unenrollment failures."
        }
    }
    Log-Info "Device is ready for MDM registration"
    Log-Info "Proceeding to MDM registration"
    Log-Info "Calling enrollment API to register device..."

    $registrationFailure = 0
    if (-not (Register-WithMdm -ManagementUrl $enrollParams.ManagementUrl -Token $enrollParams.Token -Upn $upn -FailureCode ([ref]$registrationFailure))) {
        Log-Error "MDM registration failed."
        if ($registrationFailure -eq 0) {
            $exitCode = 1
        } else {
            $exitCode = [int]$registrationFailure
        }
        return
    }

    Log-Info "MDM migration completed successfully."

    # Execute application uninstalls after successful MDM registration
    # Use the uninstall array directly, filtering out any null/empty values
    $uninstallCommands = @($uninstallApp | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($null -ne $uninstallCommands -and $uninstallCommands.Count -gt 0) {
        Log-Info ("MDM registration succeeded. Executing application uninstall step: {0} uninstall command(s) configured." -f $uninstallCommands.Count)
        try {
            Invoke-ApplicationUninstalls -UninstallCommands $uninstallCommands
        } catch {
            Log-Warn ("Error during application uninstall step: {0}. Migration completed successfully, but uninstalls encountered errors." -f $_.Exception.Message)
            Log-Debug ("Uninstall exception details: {0}" -f $_.Exception.ToString())
        }
    } else {
        Log-Debug "No uninstall commands configured, skipping application uninstall step."
    }
} finally {
    Cleanup-MdmRegistration
    if ($exitCode -eq 0) {
        Log-Info "Script exit code: 0 (success)"
    } else {
        Log-Error ("Script exit code: {0}" -f $exitCode)
    }

    if (-not $silentMode) {
        try {
            $resultTitle = "Device Management Enrollment"
            $resultBody = if ($exitCode -eq 0) {
                "The enrollment completed successfully!"
            } else {
                "The enrollment failed to complete successfully.`r`nError code: $exitCode"
            }
            $null = Show-MigrationDialog `
                -Title $resultTitle `
                -BodyText $resultBody `
                -Width 450 `
                -Height 260 `
                -ContentPadding @(28, 28, 28, 28) `
                -FooterPadding @(28, 20, 0, 15) `
                -FooterHeight 78 `
                -BodyMarginBottom 24 `
                -BodyMaxWidth 460 `
                -PrimaryButtonText "OK" `
                -PrimaryResult "OK" `
                -DisableContentAutoScroll
        } catch {
            Log-Warn ("Failed to display completion prompt: {0}" -f $_.Exception.Message)
        }
    }

    exit $exitCode
}
