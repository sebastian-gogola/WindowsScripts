<#
.SYNOPSIS
    Grants the logged-in user read access to the Okta SCEP certificate private key
    in the Local Machine store.

.DESCRIPTION
    This script identifies the Okta/SCEP certificate deployed via Iru's SCEP Library
    Item and grants the currently logged-in user GENERIC_READ access to its private
    key. This is a workaround for the certificate being installed to the Local Computer
    store instead of the Current User store.

.NOTES
    Author:  Sebastian Gogola
    Version: 1.0

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

[CmdletBinding()]
param(
    [string[]]$SearchHints = @(
        'YOUR_OKTA_TENANT_IDENTIFIER',
        'Okta',
        'SCEP'
    ),
    [int]$MinimumScore = 50,
    [switch]$WhatIf
)

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
        foreach (CommonAce ace in csd.DiscretionaryAcl)
        {
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

function Get-LoggedOnUser {
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
    }

    return ($parts -join ' ')
}

function Get-CertificateScore {
    param(
        [Parameter(Mandatory = $true)]
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$Cert,
        [string[]]$Hints
    )

    $score = 0
    $now = Get-Date

    if ($Cert.HasPrivateKey) { $score += 20 }
    if ($Cert.NotBefore -lt $now -and $Cert.NotAfter -gt $now) { $score += 20 }
    if (Test-ClientAuthenticationEku -Cert $Cert) { $score += 30 }

    $blob = Get-CertificateTextBlob -Cert $Cert

    foreach ($hint in $Hints) {
        if ([string]::IsNullOrWhiteSpace($hint)) { continue }
        if ($blob -match [regex]::Escape($hint)) { $score += 25 }
    }

    return $score
}

function Find-BestOktaLikeCertificate {
    param(
        [string[]]$Hints,
        [int]$MinimumScore = 50
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

    $ranked = foreach ($cert in $certs) {
        [PSCustomObject]@{
            Cert  = $cert
            Score = Get-CertificateScore -Cert $cert -Hints $Hints
        }
    }

    $ranked = $ranked | Sort-Object @{ Expression = 'Score'; Descending = $true }, @{ Expression = { $_.Cert.NotAfter }; Descending = $true }

    Write-Host "Top certificate candidates:"
    $ranked | Select-Object -First 5 | ForEach-Object {
        Write-Host ("  Score={0} | Subject={1} | Thumbprint={2}" -f $_.Score, $_.Cert.Subject, $_.Cert.Thumbprint)
    }

    $best = $ranked | Select-Object -First 1

    if (-not $best) {
        throw "Unable to identify a candidate certificate."
    }

    if ($best.Score -lt $MinimumScore) {
        throw "Could not confidently identify the Okta/SCEP certificate. Best score was $($best.Score), below threshold $MinimumScore."
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
    param(
        [Parameter(Mandatory = $true)]
        [string]$KeyPath,

        [Parameter(Mandatory = $true)]
        [string]$Identity,

        [switch]$WhatIf
    )

    $acl = Get-Acl -Path $KeyPath -ErrorAction Stop

    $existingRule = $acl.Access | Where-Object {
        $_.IdentityReference -eq $Identity -and
        $_.AccessControlType -eq 'Allow' -and
        (($_.FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::Read) -ne 0)
    } | Select-Object -First 1

    if ($existingRule) {
        Write-Host "Read permission already exists for '$Identity'."
        return
    }

    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $Identity,
        [System.Security.AccessControl.FileSystemRights]::Read,
        [System.Security.AccessControl.AccessControlType]::Allow
    )

    $acl.AddAccessRule($rule) | Out-Null

    if ($WhatIf) {
        Write-Host "[WhatIf] Would grant Read access to '$Identity' on '$KeyPath'"
        return
    }

    Set-Acl -Path $KeyPath -AclObject $acl -ErrorAction Stop
    Write-Host "Granted Read access to '$Identity' on '$KeyPath'"
}

function Grant-CngPrivateKeyRead {
    param(
        [Parameter(Mandatory = $true)]
        $CngContext,

        [Parameter(Mandatory = $true)]
        [string]$Identity,

        [Parameter(Mandatory = $true)]
        [string]$IdentitySid,

        [switch]$WhatIf
    )

    if (-not [CngKeyAclHelper]::ProviderSupportsSecurityDescriptors($CngContext.ProviderName)) {
        throw "The provider '$($CngContext.ProviderName)' does not report support for key security descriptors."
    }

    $handle = $CngContext.Key.Handle.DangerousGetHandle()

    if ($WhatIf) {
        Write-Host "[WhatIf] Would grant GENERIC_READ on CNG key '$($CngContext.UniqueName)' to '$Identity' ($IdentitySid)"
        return
    }

    [CngKeyAclHelper]::GrantRead($handle, $IdentitySid)
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

    Write-Host "Searching for best matching Okta/SCEP certificate..."
    $cert = Find-BestOktaLikeCertificate -Hints $SearchHints -MinimumScore $MinimumScore

    Write-Host ""
    Write-Host "Selected certificate:"
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
        Grant-CngPrivateKeyRead -CngContext $cng -Identity $identity -IdentitySid $identitySid -WhatIf:$WhatIf
    }
    else {
        Write-Host "Detected file-backed / legacy key."
        Write-Host "Locating private key file..."
        $keyPath = Get-PrivateKeyFilePath -Cert $cert
        Write-Host "Private key file: $keyPath"
        Write-Host ""

        Write-Host "Applying file ACL change..."
        Grant-FileBackedPrivateKeyRead -KeyPath $keyPath -Identity $identity -WhatIf:$WhatIf
    }

    Write-Host ""
    Write-Host "Completed successfully."
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
