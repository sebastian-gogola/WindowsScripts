<#
.SYNOPSIS
    Grants the logged-on user read access to the Okta SCEP certificate private key
    in the Local Machine store.

.DESCRIPTION
    Identifies the Okta/SCEP certificate deployed via Iru's SCEP Library Item and
    grants the currently logged-on user GENERIC_READ access to its private key.
    This is a workaround for the certificate being installed to the Local Computer
    store instead of the Current User store.

    Certificate selection, in order of precedence:

      1. -Thumbprint  : exact match, no heuristics. Fully deterministic, but note
                        that SCEP renewal reissues the certificate and changes the
                        thumbprint, so a pinned thumbprint will stop matching after
                        renewal.
      2. -IssuerMatch : regex hard-filter on the Issuer DN, applied before scoring.
                        Survives renewal; recommended for production deployments.
      3. SearchHints  : scored heuristic across Subject / Issuer / FriendlyName /
                        DNS SANs. At least one hint must match (see -MinimumScore)
                        so the script fails closed instead of ACLing an unrelated
                        client-auth key (e.g. an MDM enrollment or EAP-TLS cert).

.PARAMETER Thumbprint
    Exact SHA-1 thumbprint of the target certificate in Cert:\LocalMachine\My.
    Bypasses all heuristics. Whitespace is ignored.

.PARAMETER SearchHints
    Substrings matched case-insensitively against the certificate's Subject,
    Issuer, FriendlyName and DNS SANs. Each matching hint adds 40 points.
    Replace or extend the defaults with a tenant-specific value (e.g. your Okta
    org identifier) before deploying.

.PARAMETER IssuerMatch
    Optional regex applied to the Issuer DN as a hard filter before scoring.

.PARAMETER MinimumScore
    Minimum score required to act on a certificate. Default 40, which requires at
    least one SearchHints match. The Client Authentication EKU contributes 30
    points and is deliberately insufficient on its own.

.EXAMPLE
    .\Grant-OktaSCEPPrivateKeyAccess.ps1 -WhatIf

.EXAMPLE
    .\Grant-OktaSCEPPrivateKeyAccess.ps1 -IssuerMatch 'Okta'

.EXAMPLE
    .\Grant-OktaSCEPPrivateKeyAccess.ps1 -Thumbprint 0123456789ABCDEF0123456789ABCDEF01234567

.NOTES
    Author:  Sebastian Gogola
    Version: 2.0

    Version 2.0 changes:
      - Selection fails closed: the baseline points previously awarded for
        validity and private-key presence are gone (every candidate had them, so
        any client-auth certificate could clear the old threshold with zero hint
        matches and the script could ACL the wrong private key).
      - Ambiguity guard: distinct certificates tying on score abort with guidance;
        same-subject ties (renewal overlap) resolve to the newest NotAfter.
      - Added -Thumbprint and -IssuerMatch for deterministic targeting.
      - Fixed the NCrypt key handle lifetime (DangerousAddRef/DangerousRelease
        around the P/Invoke; the previous inline DangerousGetHandle() left the
        duplicated SafeHandle unrooted and collectible mid-call).
      - DACL enumeration no longer assumes every ACE is a CommonAce.
      - File ACLs are granted and checked by SID instead of account name
        (NTAccount translation of Entra "AzureAD\UPN" identities is unreliable).
      - File ACL presence check requires the full Read mask, not any read bit.
      - Real -WhatIf/-Confirm support via SupportsShouldProcess.
      - Add-Type guarded for repeated in-session runs; formerly silent catch
        blocks now emit -Verbose diagnostics.

    Legal Disclaimer
    This script is provided "as is" without any warranties or guarantees of any kind,
    either expressed or implied. By using this script, you acknowledge and agree that
    you do so entirely at your own risk and discretion.

    Iru shall not be held responsible or liable for any damages, losses, security
    issues, data loss, system failures, legal consequences, or any other outcomes
    resulting from the use, misuse, or inability to use this script.

    It is the user's sole responsibility to review, test, and ensure the script is
    suitable, secure, and compliant with their intended environment and applicable
    laws before use.
#>

# =============================================================================
# DISCLAIMER: Experimental helper script - provided as-is, without warranty or
# official Iru support. Sandbox scripts have not gone through the review and
# validation applied to the official Iru WindowsScripts. Review the code and
# validate on test hardware before any production use.
# =============================================================================

#Requires -Version 5.1
#Requires -RunAsAdministrator

[CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'Heuristic')]
param(
    [Parameter(ParameterSetName = 'Thumbprint', Mandatory = $true)]
    [string]$Thumbprint,

    [Parameter(ParameterSetName = 'Heuristic')]
    [string[]]$SearchHints = @(
        'Okta',
        'SCEP'
    ),

    [Parameter(ParameterSetName = 'Heuristic')]
    [string]$IssuerMatch,

    [Parameter(ParameterSetName = 'Heuristic')]
    [int]$MinimumScore = 40
)

if (-not ('CngKeyAclHelper' -as [type])) {
    Add-Type -Language CSharp @"
using System;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;

public static class CngKeyAclHelper
{
    private const int DACL_SECURITY_INFORMATION = 0x00000004;
    private const int GENERIC_READ = unchecked((int)0x80000000);

    [DllImport("ncrypt.dll", CharSet = CharSet.Unicode)]
    private static extern int NCryptOpenStorageProvider(
        out IntPtr phProvider,
        string pszProviderName,
        int dwFlags);

    [DllImport("ncrypt.dll", CharSet = CharSet.Unicode)]
    private static extern int NCryptGetProperty(
        IntPtr hObject,
        string pszProperty,
        byte[] pbOutput,
        int cbOutput,
        out int pcbResult,
        int dwFlags);

    [DllImport("ncrypt.dll", CharSet = CharSet.Unicode)]
    private static extern int NCryptSetProperty(
        IntPtr hObject,
        string pszProperty,
        byte[] pbInput,
        int cbInput,
        int dwFlags);

    [DllImport("ncrypt.dll")]
    private static extern int NCryptFreeObject(IntPtr hObject);

    private static string FormatError(int status, string action)
    {
        return action + " failed. NCrypt status: 0x" + status.ToString("X8");
    }

    public static bool ProviderSupportsSecurityDescriptors(string providerName)
    {
        IntPtr hProvider = IntPtr.Zero;

        try
        {
            int status = NCryptOpenStorageProvider(out hProvider, providerName, 0);
            if (status != 0)
            {
                throw new Exception(FormatError(status, "NCryptOpenStorageProvider"));
            }

            byte[] buffer = new byte[4];
            int resultSize;

            status = NCryptGetProperty(
                hProvider,
                "Security Descr Support",
                buffer,
                buffer.Length,
                out resultSize,
                0);

            if (status != 0)
            {
                return false;
            }

            return BitConverter.ToInt32(buffer, 0) == 1;
        }
        finally
        {
            if (hProvider != IntPtr.Zero)
            {
                NCryptFreeObject(hProvider);
            }
        }
    }

    public static void GrantRead(IntPtr hKey, string sidString)
    {
        SecurityIdentifier sid = new SecurityIdentifier(sidString);

        byte[] existingSd = GetDaclSecurityDescriptor(hKey);

        CommonSecurityDescriptor csd = new CommonSecurityDescriptor(
            false,
            false,
            existingSd,
            0);

        if (csd.DiscretionaryAcl == null)
        {
            csd.DiscretionaryAcl = new DiscretionaryAcl(false, false, 1);
        }

        bool found = false;
        foreach (GenericAce genericAce in csd.DiscretionaryAcl)
        {
            CommonAce ace = genericAce as CommonAce;
            if (ace == null)
            {
                continue;
            }

            if (ace.AceQualifier == AceQualifier.AccessAllowed &&
                ace.SecurityIdentifier != null &&
                ace.SecurityIdentifier.Equals(sid) &&
                (ace.AccessMask & GENERIC_READ) != 0)
            {
                found = true;
                break;
            }
        }

        if (!found)
        {
            csd.DiscretionaryAcl.AddAccess(
                AccessControlType.Allow,
                sid,
                GENERIC_READ,
                InheritanceFlags.None,
                PropagationFlags.None);
        }

        byte[] newSd = new byte[csd.BinaryLength];
        csd.GetBinaryForm(newSd, 0);

        int status = NCryptSetProperty(
            hKey,
            "Security Descr",
            newSd,
            newSd.Length,
            DACL_SECURITY_INFORMATION);

        if (status != 0)
        {
            throw new Exception(FormatError(status, "NCryptSetProperty(Security Descr)"));
        }
    }

    private static byte[] GetDaclSecurityDescriptor(IntPtr hKey)
    {
        int pcbResult;
        int status = NCryptGetProperty(
            hKey,
            "Security Descr",
            null,
            0,
            out pcbResult,
            DACL_SECURITY_INFORMATION);

        if (pcbResult <= 0)
        {
            throw new Exception(FormatError(status, "NCryptGetProperty(Security Descr size)"));
        }

        byte[] buffer = new byte[pcbResult];

        status = NCryptGetProperty(
            hKey,
            "Security Descr",
            buffer,
            buffer.Length,
            out pcbResult,
            DACL_SECURITY_INFORMATION);

        if (status != 0)
        {
            throw new Exception(FormatError(status, "NCryptGetProperty(Security Descr)"));
        }

        return buffer;
    }
}
"@
}

function Get-LoggedOnUser {
    [CmdletBinding()]
    param()

    # Console user first; explorer.exe owner as fallback covers cases where
    # Win32_ComputerSystem.UserName is empty (e.g. RDP sessions). If multiple
    # interactive sessions exist, the first explorer process wins - acceptable
    # for single-user endpoints, revisit for multi-session hosts.
    $csUser = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
    if ($csUser) {
        try {
            $sid = ([System.Security.Principal.NTAccount]$csUser).Translate([System.Security.Principal.SecurityIdentifier]).Value
            return [PSCustomObject]@{
                Name = $csUser
                Sid  = $sid
            }
        }
        catch {
            Write-Verbose "NTAccount translation failed for '$csUser': $($_.Exception.Message). Falling back to explorer.exe owner."
        }
    }

    $explorer = Get-CimInstance Win32_Process -Filter "Name = 'explorer.exe'" -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if ($explorer) {
        $ownerResult = Invoke-CimMethod -InputObject $explorer -MethodName GetOwner -ErrorAction SilentlyContinue
        $sidResult   = Invoke-CimMethod -InputObject $explorer -MethodName GetOwnerSid -ErrorAction SilentlyContinue

        if ($ownerResult.ReturnValue -eq 0 -and $sidResult.ReturnValue -eq 0) {
            $name = if ($ownerResult.Domain) {
                "$($ownerResult.Domain)\$($ownerResult.User)"
            }
            else {
                $ownerResult.User
            }

            return [PSCustomObject]@{
                Name = $name
                Sid  = $sidResult.Sid
            }
        }
    }

    throw "No interactive user is currently logged in."
}

function Test-ClientAuthenticationEku {
    param(
        [Parameter(Mandatory = $true)]
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$Cert
    )

    $clientAuthOid = '1.3.6.1.5.5.7.3.2'

    foreach ($ext in $Cert.Extensions) {
        if ($ext.Oid.Value -eq '2.5.29.37') {
            try {
                $ekuExt = [System.Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]$ext
                foreach ($oid in $ekuExt.EnhancedKeyUsages) {
                    if ($oid.Value -eq $clientAuthOid) {
                        return $true
                    }
                }
            }
            catch {
                Write-Verbose "Failed to decode EKU extension on $($Cert.Thumbprint): $($_.Exception.Message)"
            }
        }
    }

    return $false
}

function Get-CertificateTextBlob {
    param(
        [Parameter(Mandatory = $true)]
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$Cert
    )

    $parts = @()

    if ($Cert.Subject) { $parts += $Cert.Subject }
    if ($Cert.Issuer) { $parts += $Cert.Issuer }
    if ($Cert.FriendlyName) { $parts += $Cert.FriendlyName }

    try {
        $dnsNames = $Cert.DnsNameList | ForEach-Object { $_.Unicode }
        if ($dnsNames) { $parts += $dnsNames }
    }
    catch {
        Write-Verbose "Failed to read DNS SANs on $($Cert.Thumbprint): $($_.Exception.Message)"
    }

    return ($parts -join ' ')
}

function Get-CertificateScore {
    param(
        [Parameter(Mandatory = $true)]
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$Cert,
        [string[]]$Hints
    )

    # Deliberately no points for validity or private-key presence: every candidate
    # is pre-filtered on those, so they carry no signal. EKU alone (30) must stay
    # below the default threshold (40) so an unrelated client-auth certificate
    # can never be selected without at least one hint match.
    $score = 0

    if (Test-ClientAuthenticationEku -Cert $Cert) { $score += 30 }

    $blob = Get-CertificateTextBlob -Cert $Cert

    foreach ($hint in $Hints) {
        if ([string]::IsNullOrWhiteSpace($hint)) { continue }
        if ($blob -match [regex]::Escape($hint)) { $score += 40 }
    }

    return $score
}

function Get-CertificateByThumbprint {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Thumbprint
    )

    $normalized = ($Thumbprint -replace '\s', '').ToUpper()
    if ($normalized -notmatch '^[0-9A-F]{40}$') {
        throw "Thumbprint '$Thumbprint' is not a valid SHA-1 thumbprint (expected 40 hex characters)."
    }

    $cert = Get-ChildItem "Cert:\LocalMachine\My\$normalized" -ErrorAction SilentlyContinue
    if (-not $cert) {
        throw "No certificate with thumbprint $normalized was found in Cert:\LocalMachine\My."
    }
    if (-not $cert.HasPrivateKey) {
        throw "Certificate $normalized does not have an associated private key."
    }

    $now = Get-Date
    if ($cert.NotAfter -le $now -or $cert.NotBefore -ge $now) {
        Write-Warning "Certificate $normalized is not currently time-valid (NotBefore=$($cert.NotBefore), NotAfter=$($cert.NotAfter)). Proceeding because the thumbprint was explicitly specified."
    }

    return $cert
}

function Find-BestOktaLikeCertificate {
    param(
        [string[]]$Hints,
        [string]$IssuerMatch,
        [int]$MinimumScore = 40
    )

    $now = Get-Date

    $certs = Get-ChildItem Cert:\LocalMachine\My -ErrorAction Stop | Where-Object {
        $_.HasPrivateKey -and
        $_.NotBefore -lt $now -and
        $_.NotAfter -gt $now
    }

    if (-not $certs) {
        throw "No valid certificates with private keys were found in Cert:\LocalMachine\My."
    }

    if (-not [string]::IsNullOrWhiteSpace($IssuerMatch)) {
        $certs = @($certs | Where-Object { $_.Issuer -match $IssuerMatch })
        if (-not $certs) {
            throw "No valid certificate with a private key matched -IssuerMatch '$IssuerMatch' in Cert:\LocalMachine\My."
        }
    }

    $ranked = @(foreach ($cert in $certs) {
        [PSCustomObject]@{
            Cert  = $cert
            Score = Get-CertificateScore -Cert $cert -Hints $Hints
        }
    })

    $ranked = @($ranked | Sort-Object @{ Expression = 'Score'; Descending = $true }, @{ Expression = { $_.Cert.NotAfter }; Descending = $true })

    Write-Host "Top certificate candidates:"
    $ranked | Select-Object -First 5 | ForEach-Object {
        Write-Host ("  Score={0} | Subject={1} | Issuer={2} | Thumbprint={3}" -f $_.Score, $_.Cert.Subject, $_.Cert.Issuer, $_.Cert.Thumbprint)
    }

    $best = $ranked[0]

    if ($best.Score -lt $MinimumScore) {
        throw "Could not confidently identify the Okta/SCEP certificate. Best score was $($best.Score), below threshold $MinimumScore. Add a tenant-specific value to -SearchHints, or target the certificate with -IssuerMatch or -Thumbprint."
    }

    if ($ranked.Count -gt 1 -and $ranked[1].Score -eq $best.Score) {
        if ($ranked[1].Cert.Subject -eq $best.Cert.Subject) {
            # Same subject at the same score is the renewal-overlap case; the sort
            # already put the newest NotAfter first, so proceed with it.
            Write-Verbose "Multiple certificates with subject '$($best.Cert.Subject)' tied at score $($best.Score); selecting the one with the latest NotAfter ($($best.Cert.NotAfter))."
        }
        else {
            throw "Ambiguous match: '$($best.Cert.Subject)' ($($best.Cert.Thumbprint)) and '$($ranked[1].Cert.Subject)' ($($ranked[1].Cert.Thumbprint)) both scored $($best.Score). Refusing to guess. Re-run with -IssuerMatch or -Thumbprint."
        }
    }

    return $best.Cert
}

function Get-CngKeyContextFromCert {
    param(
        [Parameter(Mandatory = $true)]
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$Cert
    )

    try {
        $rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($Cert)
        if ($rsa -is [System.Security.Cryptography.RSACng]) {
            return [PSCustomObject]@{
                Algorithm    = 'RSA'
                ProviderName = [string]$rsa.Key.Provider
                UniqueName   = $rsa.Key.UniqueName
                Key          = $rsa.Key
                KeyObject    = $rsa
                IsTpm        = ([string]$rsa.Key.Provider -match 'Platform Crypto Provider|TPM')
            }
        }
    }
    catch {
        Write-Verbose "RSA private key probe failed for $($Cert.Thumbprint): $($_.Exception.Message)"
    }

    try {
        $ecdsa = [System.Security.Cryptography.X509Certificates.ECDsaCertificateExtensions]::GetECDsaPrivateKey($Cert)
        if ($ecdsa -is [System.Security.Cryptography.ECDsaCng]) {
            return [PSCustomObject]@{
                Algorithm    = 'ECDSA'
                ProviderName = [string]$ecdsa.Key.Provider
                UniqueName   = $ecdsa.Key.UniqueName
                Key          = $ecdsa.Key
                KeyObject    = $ecdsa
                IsTpm        = ([string]$ecdsa.Key.Provider -match 'Platform Crypto Provider|TPM')
            }
        }
    }
    catch {
        Write-Verbose "ECDSA private key probe failed for $($Cert.Thumbprint): $($_.Exception.Message)"
    }

    return $null
}

function Get-PrivateKeyFilePath {
    param(
        [Parameter(Mandatory = $true)]
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$Cert
    )

    if (-not $Cert.HasPrivateKey) {
        throw "Certificate does not have a private key."
    }

    $pathsToTry = New-Object System.Collections.Generic.List[string]

    try {
        if ($Cert.PrivateKey -and $Cert.PrivateKey.CspKeyContainerInfo) {
            $container = $Cert.PrivateKey.CspKeyContainerInfo.UniqueKeyContainerName
            if ($container) {
                $pathsToTry.Add((Join-Path $env:ProgramData "Microsoft\Crypto\RSA\MachineKeys\$container"))
            }
        }
    }
    catch {
        Write-Verbose "CspKeyContainerInfo probe failed: $($_.Exception.Message)"
    }

    try {
        $thumbprint = ($Cert.Thumbprint -replace '\s', '').ToUpper()
        $certutilOutput = & certutil.exe -store my $thumbprint 2>&1
        if (-not $certutilOutput) {
            $certutilOutput = & certutil.exe -v -store my $thumbprint 2>&1
        }

        if ($certutilOutput) {
            foreach ($line in $certutilOutput) {
                if ($line -match '(?i)^\s*Unique container name:\s*(.+?)\s*$') {
                    $container = $matches[1].Trim()
                    $pathsToTry.Add((Join-Path $env:ProgramData "Microsoft\Crypto\RSA\MachineKeys\$container"))
                    $pathsToTry.Add((Join-Path $env:ProgramData "Microsoft\Crypto\Keys\$container"))
                }
                elseif ($line -match '(?i)^\s*Key Container\s*=\s*(.+?)\s*$') {
                    $container = $matches[1].Trim()
                    $pathsToTry.Add((Join-Path $env:ProgramData "Microsoft\Crypto\RSA\MachineKeys\$container"))
                    $pathsToTry.Add((Join-Path $env:ProgramData "Microsoft\Crypto\Keys\$container"))
                }
            }
        }
    }
    catch {
        Write-Verbose "certutil key container probe failed: $($_.Exception.Message)"
    }

    $uniquePaths = $pathsToTry | Where-Object { $_ } | Select-Object -Unique

    foreach ($path in $uniquePaths) {
        if (Test-Path $path) {
            return $path
        }
    }

    throw "Could not locate a file-backed private key path."
}

function Grant-FileBackedPrivateKeyRead {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$KeyPath,

        [Parameter(Mandatory = $true)]
        [string]$Identity,

        [Parameter(Mandatory = $true)]
        [string]$IdentitySid
    )

    $sid = New-Object System.Security.Principal.SecurityIdentifier($IdentitySid)
    $readMask = [System.Security.AccessControl.FileSystemRights]::Read

    $acl = Get-Acl -Path $KeyPath -ErrorAction Stop

    $existingRule = $acl.Access | Where-Object {
        $ruleSid = $null
        try {
            $ruleSid = $_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value
        }
        catch {
            Write-Verbose "Could not translate ACL identity '$($_.IdentityReference)' to a SID."
        }

        ($ruleSid -eq $IdentitySid) -and
        ($_.AccessControlType -eq 'Allow') -and
        (($_.FileSystemRights -band $readMask) -eq $readMask)
    } | Select-Object -First 1

    if ($existingRule) {
        Write-Host "Read permission already exists for '$Identity' ($IdentitySid)."
        return
    }

    if (-not $PSCmdlet.ShouldProcess($KeyPath, "Grant Read access to '$Identity' ($IdentitySid)")) {
        return
    }

    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $sid,
        $readMask,
        [System.Security.AccessControl.AccessControlType]::Allow
    )

    $acl.AddAccessRule($rule) | Out-Null

    Set-Acl -Path $KeyPath -AclObject $acl -ErrorAction Stop
    Write-Host "Granted Read access to '$Identity' ($IdentitySid) on '$KeyPath'"
}

function Grant-CngPrivateKeyRead {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        $CngContext,

        [Parameter(Mandatory = $true)]
        [string]$Identity,

        [Parameter(Mandatory = $true)]
        [string]$IdentitySid
    )

    if (-not [CngKeyAclHelper]::ProviderSupportsSecurityDescriptors($CngContext.ProviderName)) {
        throw "The provider '$($CngContext.ProviderName)' does not report support for key security descriptors, so the key ACL cannot be modified through NCrypt."
    }

    if (-not $PSCmdlet.ShouldProcess("CNG key '$($CngContext.UniqueName)'", "Grant GENERIC_READ to '$Identity' ($IdentitySid)")) {
        return
    }

    # CngKey.Handle returns a new duplicated SafeNCryptKeyHandle on each access.
    # Hold it in a variable and pin it with DangerousAddRef/DangerousRelease so
    # the native handle cannot be released by the GC while NCrypt is using it.
    $safeHandle = $CngContext.Key.Handle
    $addRefSucceeded = $false
    try {
        $safeHandle.DangerousAddRef([ref]$addRefSucceeded)
        [CngKeyAclHelper]::GrantRead($safeHandle.DangerousGetHandle(), $IdentitySid)
    }
    finally {
        if ($addRefSucceeded) {
            $safeHandle.DangerousRelease()
        }
        $safeHandle.Dispose()
    }

    Write-Host "Granted CNG key read access to '$Identity' ($IdentitySid) on '$($CngContext.UniqueName)'"
}

try {
    Write-Host "Detecting logged-on user..."
    $userContext = Get-LoggedOnUser
    $identity = $userContext.Name
    $identitySid = $userContext.Sid

    Write-Host "Logged-on user: $identity"
    Write-Host "Logged-on SID:  $identitySid"
    Write-Host ""

    if ($PSCmdlet.ParameterSetName -eq 'Thumbprint') {
        Write-Host "Looking up certificate by thumbprint..."
        $cert = Get-CertificateByThumbprint -Thumbprint $Thumbprint
        $selectionMethod = "explicit thumbprint"
    }
    else {
        Write-Host "Searching for best matching Okta/SCEP certificate..."
        $cert = Find-BestOktaLikeCertificate -Hints $SearchHints -IssuerMatch $IssuerMatch -MinimumScore $MinimumScore
        $selectionMethod = "heuristic (threshold $MinimumScore)"
    }

    Write-Host ""
    Write-Host "Selected certificate ($selectionMethod):"
    Write-Host "  Subject:       $($cert.Subject)"
    Write-Host "  Issuer:        $($cert.Issuer)"
    Write-Host "  Thumbprint:    $($cert.Thumbprint)"
    Write-Host "  NotBefore:     $($cert.NotBefore)"
    Write-Host "  NotAfter:      $($cert.NotAfter)"
    Write-Host "  HasPrivateKey: $($cert.HasPrivateKey)"
    Write-Host ""

    $cng = Get-CngKeyContextFromCert -Cert $cert

    if ($cng) {
        Write-Host "Detected CNG-backed key:"
        Write-Host "  Algorithm:    $($cng.Algorithm)"
        Write-Host "  Provider:     $($cng.ProviderName)"
        Write-Host "  Unique Name:  $($cng.UniqueName)"
        Write-Host "  TPM-backed:   $($cng.IsTpm)"
        Write-Host ""

        Write-Host "Applying CNG key ACL change..."
        Grant-CngPrivateKeyRead -CngContext $cng -Identity $identity -IdentitySid $identitySid
    }
    else {
        Write-Host "Detected file-backed / legacy key."
        Write-Host "Locating private key file..."
        $keyPath = Get-PrivateKeyFilePath -Cert $cert
        Write-Host "Private key file: $keyPath"
        Write-Host ""

        Write-Host "Applying file ACL change..."
        Grant-FileBackedPrivateKeyRead -KeyPath $keyPath -Identity $identity -IdentitySid $identitySid
    }

    Write-Host ""
    Write-Host "Completed successfully."
    exit 0
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}