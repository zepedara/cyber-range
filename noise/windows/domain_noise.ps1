# Continuous domain activity for the range's Windows half.  v2 adds RDP and PE transfer.
#
# Spec 7.1: zeek writes a protocol log only when it OBSERVES that protocol, so every log type
# the range wants hunted has to be generated here. Randomised throughout - a perfectly
# periodic beacon is itself an unrealistic signature and would teach the wrong instinct.

$ErrorActionPreference = "SilentlyContinue"
$DC  = "10.31.10.10"
$DCF = "ir-dc01.lab.local"
$FS  = "10.31.10.11"
$log = "C:\Windows\Temp\domain_noise.log"

function Note($m) { "$(Get-Date -Format o)  $m" | Out-File -Append -FilePath $log -Encoding ascii }

Start-Sleep -Seconds (Get-Random -Minimum 0 -Maximum 45)

# --- KERBEROS ---------------------------------------------------------------------------
if ((Get-Random -Maximum 100) -lt 70) {
    klist purge | Out-Null
    Get-ChildItem "\\$DCF\SYSVOL"   -ErrorAction SilentlyContinue | Out-Null
    Get-ChildItem "\\$DCF\NETLOGON" -ErrorAction SilentlyContinue | Out-Null
    Note "kerberos: purged and re-acquired"
}

# --- LDAP -------------------------------------------------------------------------------
if ((Get-Random -Maximum 100) -lt 80) {
    $filters = @("(objectClass=user)", "(objectClass=computer)", "(objectClass=group)", "(servicePrincipalName=*)")
    $f = $filters | Get-Random
    $s = New-Object DirectoryServices.DirectorySearcher([ADSI]"LDAP://$DC/DC=lab,DC=local")
    $s.Filter = $f; $s.SizeLimit = (Get-Random -Minimum 5 -Maximum 40)
    Note ("ldap: $f -> " + ($s.FindAll()).Count)
    nltest /dsgetdc:lab.local | Out-Null
}

# --- SMB + PE transfer ------------------------------------------------------------------
if ((Get-Random -Maximum 100) -lt 75) {
    foreach ($p in @("\\$FS\Public", "\\$DCF\SYSVOL")) {
        Get-ChildItem $p -ErrorAction SilentlyContinue | Select-Object -First 5 | Out-Null
    }
    # Copy a genuine signed Windows binary across the wire so files.log classifies a PE and
    # pe.log gets written. These are stock OS binaries - nothing malicious on the range.
    $bins = @("notepad.exe", "net.exe", "whoami.exe", "ipconfig.exe", "tasklist.exe")
    $b = $bins | Get-Random
    Copy-Item "\\$DCF\C$\Windows\System32\$b" "C:\Windows\Temp\pe_$b" -Force -ErrorAction SilentlyContinue
    if (Test-Path "C:\Windows\Temp\pe_$b") {
        Note "pe: transferred $b over smb"
        Remove-Item "C:\Windows\Temp\pe_$b" -Force -ErrorAction SilentlyContinue
    } else { Note "smb: browsed shares" }
}

# --- DCE_RPC ----------------------------------------------------------------------------
if ((Get-Random -Maximum 100) -lt 45) {
    sc.exe \\$FS query | Out-Null
    Get-Service -ComputerName $FS -ErrorAction SilentlyContinue | Select-Object -First 3 | Out-Null
    Get-WmiObject -Class Win32_OperatingSystem -ComputerName $DC -ErrorAction SilentlyContinue | Out-Null
    Note "dce_rpc: svcctl/wmi"
}

# --- RDP --------------------------------------------------------------------------------
# A bare TCP connect to 3389 produces no rdp.log; zeek needs the X.224 Connection Request.
# Send a standard TPKT/X.224 CR so the analyzer recognises the session, then close.
if ((Get-Random -Maximum 100) -lt 40) {
    foreach ($t in @($DC, $FS)) {
        try {
            $c = New-Object Net.Sockets.TcpClient
            $c.Connect($t, 3389)
            $s = $c.GetStream()
            $cr = [byte[]](0x03,0x00,0x00,0x13,0x0E,0xE0,0x00,0x00,0x00,0x00,0x00,
                           0x01,0x00,0x08,0x00,0x03,0x00,0x00,0x00)
            $s.Write($cr, 0, $cr.Length); $s.Flush()
            Start-Sleep -Milliseconds 400
            $buf = New-Object byte[] 64
            if ($s.DataAvailable) { $s.Read($buf, 0, 64) | Out-Null }
            $c.Close()
            Note "rdp: x224 connection request to $t"
        } catch { Note "rdp: $t failed" }
    }
}

# --- GPO --------------------------------------------------------------------------------
if ((Get-Random -Maximum 100) -lt 25) { gpupdate /target:computer | Out-Null; Note "gpupdate" }

# --- HTTP / TLS -------------------------------------------------------------------------
if ((Get-Random -Maximum 100) -lt 60) {
    foreach ($u in @("http://$FS/", "https://$DC/", "http://intranet.lab.local/")) {
        try { Invoke-WebRequest -Uri $u -TimeoutSec 5 -UseBasicParsing | Out-Null } catch {}
    }
    Note "http/tls"
}

if ((Test-Path $log) -and ((Get-Item $log).Length -gt 512000)) {
    Get-Content $log -Tail 500 | Set-Content $log
}
