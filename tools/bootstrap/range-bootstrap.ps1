<#
=============================================================================
 range-bootstrap.ps1 - stand up a WINDOWS build host that STAYS reachable.

 Installs and configures:
   1. Tailscale        - primary path. Outbound-only, traverses CGNAT via DERP.
   2. WireGuard        - SECOND independent path (home-router VPN profile).
   3. OpenSSH Server   - so the host can be reached directly, key-only.
   4. Node.js + Claude Code
   5. LinkWatch        - scheduled task: probe, heal, escalate.
   6. PhoneHome        - outbound ntfy beacon; works when SSH does not.
   7. Sleep/hibernate disabled, and Fast Startup off (it breaks Wake-on-LAN).

 WHY THIS EXISTS - a real outage on 2026-08-19:
   A Windows build workstation lost its lab NIC three times in one day. On the
   third, Tailscale went flat-dead - Online:False, LastHandshake never, rx 0 -
   at an exact hour boundary. With a single path there was no way in and no way
   to see why. Root cause of the earlier two was a routing bug: 10.10.1.0/24 was
   on-link on a USB adapter that was not attached to that switch, so traffic
   left the wrong NIC. Both classes of failure are addressed below.

 Usage (elevated PowerShell):
   .\range-bootstrap.ps1 -Check
   .\range-bootstrap.ps1 -TsAuthKey "tskey-auth-xxxx" -NtfyTopic "mytopic"
   .\range-bootstrap.ps1 -TsAuthKey ... -WgConf C:\path\home.conf -SshPubKey "ssh-ed25519 AAAA..."

 Idempotent: every step checks before acting. Safe to re-run.
=============================================================================
#>
[CmdletBinding()]
param(
  [switch]$Check,
  [string]$TsAuthKey  = $env:TS_AUTHKEY,
  [string]$NtfyTopic  = $env:NTFY_TOPIC,
  [string]$NtfyUrl    = "https://ntfy.sh",
  [string]$WgConf     = "",
  [string]$SshPubKey  = "",
  [string]$HomeTsIp   = "",   # tailnet IP of the home proxy host - the egress pivot
  [string]$HomePublic = "",   # public name of home, for ssh443 / wstunnel rungs
  [string]$CustomDerp = "",   # your own DERP host, if *.tailscale.com is blocked
  [string]$TsHostname = $env:COMPUTERNAME
)

$ErrorActionPreference = "Continue"
$Log = "C:\ProgramData\range-bootstrap.log"

function Say($m){
  $line = "[{0}] {1}" -f (Get-Date -Format "HH:mm:ssZ"), $m
  Write-Host $line
  Add-Content -Path $Log -Value $line -ErrorAction SilentlyContinue
}
function Have($cmd){ [bool](Get-Command $cmd -ErrorAction SilentlyContinue) }
function Act($desc, [scriptblock]$block){
  if($Check){ Write-Host "   WOULD DO: $desc"; return }
  Say "   $desc"; & $block
}

if(-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
   ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
  Write-Error "Must run elevated (Run as Administrator)."; exit 1
}

Say "=== range-bootstrap (Windows) starting, check=$Check ==="
Say "host=$env:COMPUTERNAME os=$((Get-CimInstance Win32_OperatingSystem).Caption)"

# --- 0. package manager -------------------------------------------------------
if(-not (Have winget)){
  Say "WARN: winget not available. Install 'App Installer' from the Store, or use the MSI paths noted below."
}

# --- 1. Tailscale -------------------------------------------------------------
Say "--- tailscale"
$tsExe = "C:\Program Files\Tailscale\tailscale.exe"
if(Test-Path $tsExe){
  Say "tailscale present: $(& $tsExe version 2>$null | Select-Object -First 1)"
} else {
  Act "install Tailscale" { winget install --id Tailscale.Tailscale -e --silent --accept-package-agreements --accept-source-agreements | Out-Null }
}
if(-not $Check -and (Test-Path $tsExe)){
  $st = & $tsExe status 2>$null
  if($LASTEXITCODE -eq 0){
    Say "tailscale already up: $(& $tsExe ip -4 2>$null | Select-Object -First 1)"
  } elseif($TsAuthKey){
    # --accept-dns=false: do NOT let Tailscale rewrite DNS on a range host; it
    # fights your internal resolver and produces 'DNS works but nothing resolves'.
    Act "tailscale up" { & $tsExe up --authkey $TsAuthKey --hostname $TsHostname --accept-dns=false --unattended | Out-Null }
    Say "tailscale ip: $(& $tsExe ip -4 2>$null | Select-Object -First 1)"
  } else {
    Say "WARN: no -TsAuthKey and not logged in. Run: tailscale up --unattended"
  }
  # --unattended matters: without it Tailscale disconnects when the user logs out,
  # which silently kills remote access on an unattended build box.
}

# --- 2. WireGuard - second path ----------------------------------------------
Say "--- wireguard (second path)"
if(-not (Test-Path "C:\Program Files\WireGuard\wireguard.exe")){
  Act "install WireGuard" { winget install --id WireGuard.WireGuard -e --silent --accept-package-agreements | Out-Null }
}
if($WgConf -and (Test-Path $WgConf)){
  Act "install tunnel service from $WgConf" {
    & "C:\Program Files\WireGuard\wireguard.exe" /installtunnelservice $WgConf | Out-Null
  }
} else {
  Say "no -WgConf supplied - SKIPPED. A second path is the point; add one when you have the profile."
}

# --- 3. OpenSSH Server - direct reach ----------------------------------------
Say "--- openssh server"
$cap = Get-WindowsCapability -Online -Name OpenSSH.Server* -ErrorAction SilentlyContinue
if($cap -and $cap.State -ne "Installed"){
  Act "install OpenSSH.Server" { Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 | Out-Null }
} else { Say "OpenSSH Server already installed" }
Act "enable + start sshd" {
  Set-Service -Name sshd -StartupType Automatic -ErrorAction SilentlyContinue
  Start-Service sshd -ErrorAction SilentlyContinue
}
if($SshPubKey){
  # TRAP: keys for ADMIN accounts do NOT go in ~\.ssh\authorized_keys on Windows.
  # They go in the machine-wide file below, with strict ACLs, or sshd ignores them.
  $adminKeys = "C:\ProgramData\ssh\administrators_authorized_keys"
  Act "authorize key in administrators_authorized_keys" {
    if(-not (Test-Path $adminKeys)){ New-Item -ItemType File -Path $adminKeys -Force | Out-Null }
    if(-not (Select-String -Path $adminKeys -SimpleMatch $SshPubKey -Quiet -ErrorAction SilentlyContinue)){
      Add-Content -Path $adminKeys -Value $SshPubKey
    }
    icacls $adminKeys /inheritance:r /grant "SYSTEM:F" /grant "BUILTIN\Administrators:F" | Out-Null
  }
}

# --- 4. Node.js + Claude Code -------------------------------------------------
Say "--- claude code"
if(-not (Have node)){
  Act "install Node.js LTS" { winget install --id OpenJS.NodeJS.LTS -e --silent --accept-package-agreements | Out-Null }
  $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + $env:Path
}
if(Have claude){
  Say "claude present: $(claude --version 2>$null)"
} else {
  Act "npm install -g @anthropic-ai/claude-code" { npm install -g @anthropic-ai/claude-code 2>$null | Out-Null }
}

# --- 5. power settings - never sleep, no fast startup ------------------------
Say "--- power"
Act "disable sleep/hibernate/monitor timeouts on AC" {
  powercfg /change standby-timeout-ac 0
  powercfg /change hibernate-timeout-ac 0
  powercfg /change monitor-timeout-ac 0
  powercfg /change disk-timeout-ac 0
  # Fast Startup leaves the NIC in a state where Wake-on-LAN often fails.
  reg add "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power" /v HiberbootEnabled /t REG_DWORD /d 0 /f | Out-Null
}
Act "allow NICs to wake the machine" {
  foreach($n in (Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object Status -eq "Up")){
    powercfg /deviceenablewake "$($n.InterfaceDescription)" 2>$null | Out-Null
  }
}

# --- 6. LinkWatch scheduled task ---------------------------------------------
Say "--- linkwatch"
$lw = "C:\ProgramData\range\linkwatch.ps1"
Act "write linkwatch script" {
  New-Item -ItemType Directory -Path "C:\ProgramData\range" -Force | Out-Null
  @'
# LinkWatch - probe, heal, escalate. Run every 2 min by scheduled task.
$targets = @("1.1.1.1","8.8.8.8","9.9.9.9")   # raw IPs: a broken resolver must not look like a dead link
$state   = "C:\ProgramData\range\linkwatch.state"
$tsExe   = "C:\Program Files\Tailscale\tailscale.exe"
$topic   = (Get-Content "C:\ProgramData\range\ntfy.topic" -EA SilentlyContinue)

$ok = $false
foreach($t in $targets){ if(Test-Connection -Quiet -Count 1 -TimeoutSeconds 2 $t -EA SilentlyContinue){ $ok=$true; break } }
$fails = 0
if(Test-Path $state){ $fails = [int](Get-Content $state -EA SilentlyContinue) }

if($ok){
  if($fails -gt 0 -and $topic){
    curl.exe -s -H "Title: [LINKWATCH] $env:COMPUTERNAME" -d "link restored after $fails failed cycles" "https://ntfy.sh/$topic" | Out-Null
  }
  Set-Content $state 0
} else {
  $fails++; Set-Content $state $fails
  Write-EventLog -LogName Application -Source "LinkWatch" -EventId 900 -Message "no connectivity, cycle $fails" -EA SilentlyContinue

  if($fails -eq 2){   # stage 1: bounce any down physical adapter
    Get-NetAdapter -Physical | Where-Object Status -ne "Up" | ForEach-Object {
      Disable-NetAdapter -Name $_.Name -Confirm:$false -EA SilentlyContinue
      Start-Sleep 3
      Enable-NetAdapter  -Name $_.Name -Confirm:$false -EA SilentlyContinue
    }
  }
  if($fails -eq 4){   # stage 2: kick tailscale
    Restart-Service Tailscale -Force -EA SilentlyContinue
    Start-Sleep 5
    & $tsExe up --unattended --accept-dns=false 2>$null | Out-Null
  }
  # stage 3 (reboot) intentionally omitted by default. Uncomment only if you
  # accept a remote box rebooting itself unattended:
  # if($fails -ge 30){ Restart-Computer -Force }
}
'@ | Set-Content -Path $lw -Encoding UTF8
  if($NtfyTopic){ Set-Content "C:\ProgramData\range\ntfy.topic" $NtfyTopic }
  New-EventLog -LogName Application -Source "LinkWatch" -EA SilentlyContinue
}
Act "register LinkWatch scheduled task (every 2 min, as SYSTEM)" {
  $a = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$lw`""
  $t = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 2)
  $p = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
  Register-ScheduledTask -TaskName "RangeLinkWatch" -Action $a -Trigger $t -Principal $p -Force | Out-Null
}

# --- 7. PhoneHome beacon ------------------------------------------------------
if($NtfyTopic){
  Say "--- phone-home beacon"
  $ph = "C:\ProgramData\range\phonehome.ps1"
  Act "write beacon script" {
    @'
$topic = (Get-Content "C:\ProgramData\range\ntfy.topic" -EA SilentlyContinue)
if(-not $topic){ exit }
$tsExe = "C:\Program Files\Tailscale\tailscale.exe"
$tsip  = & $tsExe ip -4 2>$null | Select-Object -First 1
& $tsExe status *>$null; $tsup = if($LASTEXITCODE -eq 0){"up"}else{"DOWN"}
$up    = (Get-Date) - (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
$links = (Get-NetAdapter -Physical | Where-Object Status -eq "Up" | ForEach-Object { $_.Name }) -join ","
$routes= (Get-NetRoute -DestinationPrefix "0.0.0.0/0" -EA SilentlyContinue | ForEach-Object { "$($_.InterfaceAlias):$($_.RouteMetric)" }) -join " "
$body = "host=$env:COMPUTERNAME`nuptime=$([int]$up.TotalHours)h`ntailscale=$tsup ip=$tsip`nlinks_up=$links`ndefault_routes=$routes"
curl.exe -s -H "Title: [BEACON] $env:COMPUTERNAME" -d $body "https://ntfy.sh/$topic" | Out-Null
'@ | Set-Content -Path $ph -Encoding UTF8
  }
  Act "register PhoneHome task (every 15 min)" {
    $a = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$ph`""
    $t = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 15)
    $p = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName "RangePhoneHome" -Action $a -Trigger $t -Principal $p -Force | Out-Null
  }
  if(-not $Check){ & powershell -NoProfile -File $ph; Say "test beacon sent" }
}

# --- 8. netladder - install, configure, RUN ----------------------------------
Say "--- netladder (multi-path egress)"
$ladderSrc = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "netladder.ps1"
$ladderDst = "C:\ProgramData\range\netladder.ps1"
Act "install netladder" {
  New-Item -ItemType Directory -Path "C:\ProgramData\range" -Force | Out-Null
  if(Test-Path $ladderSrc){ Copy-Item $ladderSrc $ladderDst -Force }
  else { Say "WARN: netladder.ps1 not found beside this script" }
}
Act "write netladder config" {
  if(-not (Test-Path "C:\ProgramData\range\netladder.json")){
    @{ HomeTsIp=$HomeTsIp; HomeProxyPort=3128; HomePublic=$HomePublic;
       Ssh443Port=443; CustomDerp=$CustomDerp;
       NtfyUrl=$NtfyUrl; NtfyTopic=$NtfyTopic } |
      ConvertTo-Json | Set-Content "C:\ProgramData\range\netladder.json" -Encoding UTF8
  }
}
# Re-probe on a timer: a path blocked at 09:00 may be open at 21:00, and vice
# versa. Static assumptions about a hostile network go stale.
Act "register NetLadder task (every 30 min)" {
  $a = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$ladderDst`""
  $t = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 30)
  $p = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
  Register-ScheduledTask -TaskName "RangeNetLadder" -Action $a -Trigger $t -Principal $p -Force | Out-Null
}
if(-not $Check -and (Test-Path $ladderDst)){
  Say "--- running the ladder now"
  & powershell -NoProfile -ExecutionPolicy Bypass -File $ladderDst
}

# --- summary ------------------------------------------------------------------
Say "=== summary ==="
"{0,-14} {1}" -f "tailscale", $(if(Test-Path $tsExe){ (& $tsExe ip -4 2>$null | Select-Object -First 1) } else {"MISSING"}) | Write-Host
"{0,-14} {1}" -f "wireguard", $(if(Get-Service WireGuardTunnel* -EA SilentlyContinue){"configured"}else{"not configured"}) | Write-Host
"{0,-14} {1}" -f "sshd",      $((Get-Service sshd -EA SilentlyContinue).Status) | Write-Host
"{0,-14} {1}" -f "claude",    $(if(Have claude){ claude --version 2>$null } else {"MISSING"}) | Write-Host
"{0,-14} {1}" -f "linkwatch", $((Get-ScheduledTask -TaskName RangeLinkWatch -EA SilentlyContinue).State) | Write-Host
"{0,-14} {1}" -f "phonehome", $((Get-ScheduledTask -TaskName RangePhoneHome -EA SilentlyContinue).State) | Write-Host
Say "=== done ==="

<#
 MULTI-WAN NOTE - the bug that caused the original outage.
 With a puck AND a wired lab NIC, Windows picks a path by route metric, and an
 unattached USB adapter can win. Pin it explicitly:

   Get-NetRoute -DestinationPrefix 0.0.0.0/0 | Format-Table ifIndex,InterfaceAlias,RouteMetric
   Get-NetIPInterface | Format-Table ifIndex,InterfaceAlias,InterfaceMetric

   # lower metric = preferred. Make the lab NIC authoritative for the lab subnet:
   New-NetRoute -DestinationPrefix "10.10.1.0/24" -InterfaceIndex <LAB_IF> -NextHop <LAB_GW> -RouteMetric 1 -PolicyStore PersistentStore

 Verify with:  Test-NetConnection <lab-host> -TraceRoute
 and confirm the first hop leaves the intended adapter.
#>
