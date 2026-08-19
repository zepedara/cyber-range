<#
=============================================================================
 netladder.ps1 - try EVERY way out, in order of what survives hostile networks.
 Windows counterpart of netladder.sh.

 On a restricted network you cannot know in advance what is blocked. Probe all
 of it, report which rungs work, bring up the best, then pivot egress to home.

 Rungs (ordered by survivability, not speed):
   0 baseline       raw-IP reachability, DNS, captive-portal/interception check
   1 ts-direct      Tailscale peer-to-peer, UDP 41641      fast, often blocked
   2 ts-derp        Tailscale relay over HTTPS/TCP 443     usually works
   3 ts-proxy       control plane via corporate proxy
   4 ts-customderp  self-hosted DERP on your domain :443   beats SNI filtering
   5 wg-udp         WireGuard to home, UDP                 fast, blocked often
   6 wg-tcp443      WireGuard in TLS (wstunnel)            looks like HTTPS
   7 ssh443         sshd on 443 at home                    very commonly open
   8 https-beacon   ntfy POST                              near-universal
   9 doh            DNS-over-HTTPS                         last-resort signal

 Usage:
   .\netladder.ps1                # probe, report, bring up best, pivot to home
   .\netladder.ps1 -ProbeOnly     # change nothing
   .\netladder.ps1 -Json          # machine-readable

 Config: C:\ProgramData\range\netladder.json
=============================================================================
#>
[CmdletBinding()]
param(
  [switch]$ProbeOnly,
  [switch]$Json,
  [string]$ConfigPath = "C:\ProgramData\range\netladder.json"
)

$ErrorActionPreference = "SilentlyContinue"
$TimeoutSec = 8

# --- config -------------------------------------------------------------------
$cfg = @{ HomeTsIp=""; HomePublic=""; Ssh443Port=443; CustomDerp="";
          NtfyUrl="https://ntfy.sh"; NtfyTopic=""; HomeProxyPort=3128 }
if(Test-Path $ConfigPath){
  try{ (Get-Content $ConfigPath -Raw | ConvertFrom-Json).PSObject.Properties |
       ForEach-Object { $cfg[$_.Name] = $_.Value } }catch{}
}
$proxy = $env:HTTPS_PROXY; if(-not $proxy){ $proxy = $env:https_proxy }

$R = [ordered]@{}
function Rung($name,$state,$note=""){ $R[$name] = @{ state=$state; note=$note } }

function TcpOk($h,$p){
  try{
    $c = New-Object Net.Sockets.TcpClient
    $iar = $c.BeginConnect($h,$p,$null,$null)
    $ok = $iar.AsyncWaitHandle.WaitOne($TimeoutSec*1000,$false)
    if($ok -and $c.Connected){ $c.Close(); return $true }
    $c.Close(); return $false
  }catch{ return $false }
}
function HttpCode($url,$extra=@{}){
  try{
    $r = Invoke-WebRequest -Uri $url -TimeoutSec $TimeoutSec -UseBasicParsing -MaximumRedirection 0 @extra
    return [int]$r.StatusCode
  }catch{
    if($_.Exception.Response){ return [int]$_.Exception.Response.StatusCode }
    return 0
  }
}

# --- rung 0: baseline ---------------------------------------------------------
# Raw IPs deliberately: a broken resolver must never look like a dead link.
$icmp = $false
foreach($ip in @("1.1.1.1","8.8.8.8","9.9.9.9")){
  if(Test-Connection -Quiet -Count 1 -TimeoutSeconds 2 $ip){ $icmp=$true; break }
}
Rung "baseline-icmp" $(if($icmp){"ok"}else{"fail"}) $(if(-not $icmp){"ICMP blocked or no route"}else{""})
Rung "baseline-443"  $(if(TcpOk "1.1.1.1" 443){"ok"}else{"fail"}) "outbound 443 is the most predictive probe"

$dns = $false
try{ if(Resolve-DnsName one.one.one.one -QuickTimeout -ErrorAction Stop){ $dns=$true } }catch{}
if(-not $dns){ try{ [Net.Dns]::GetHostEntry("one.one.one.one") | Out-Null; $dns=$true }catch{} }
Rung "baseline-dns" $(if($dns){"ok"}else{"fail"}) $(if(-not $dns){"no resolver answered"}else{""})

$cp = HttpCode "http://cp.cloudflare.com/generate_204"
if($cp -eq 204){ Rung "baseline-noportal" "ok" }
elseif($cp -ne 0){ Rung "baseline-noportal" "fail" "captive portal/proxy intercepting: HTTP $cp" }
else{ Rung "baseline-noportal" "fail" "no HTTP egress" }

# --- rungs 1-3: tailscale -----------------------------------------------------
$tsExe = "C:\Program Files\Tailscale\tailscale.exe"
if(Test-Path $tsExe){
  & $tsExe status *>$null
  if($LASTEXITCODE -eq 0){
    $st = & $tsExe status 2>$null
    if($st -match "direct "){ Rung "ts-direct" "ok" "peer-to-peer established" }
    else { Rung "ts-direct" "fail" "no direct peers (UDP likely filtered)" }
    Rung "ts-derp" "ok" "tailscale up: $(& $tsExe ip -4 2>$null | Select-Object -First 1)"
  } else {
    Rung "ts-direct" "fail" "tailscale not up"
    if(TcpOk "controlplane.tailscale.com" 443){ Rung "ts-derp" "ok" "control plane reachable, not logged in" }
    else { Rung "ts-derp" "fail" "controlplane.tailscale.com:443 blocked" }
  }
} else {
  Rung "ts-direct" "fail" "tailscale not installed"
  Rung "ts-derp"   "fail" "tailscale not installed"
}
if($proxy){
  $ph = ($proxy -replace '^https?://','' -replace '/.*$','' -replace '.*@','')
  $parts = $ph.Split(':')
  $pp = if($parts.Count -gt 1){ [int]$parts[1] } else { 8080 }
  Rung "ts-proxy" $(if(TcpOk $parts[0] $pp){"ok"}else{"fail"}) "proxy $ph"
} else { Rung "ts-proxy" "skip" "no HTTPS_PROXY set" }

# --- rung 4: custom DERP ------------------------------------------------------
if($cfg.CustomDerp){
  Rung "ts-customderp" $(if(TcpOk $cfg.CustomDerp 443){"ok"}else{"fail"}) "$($cfg.CustomDerp):443"
} else { Rung "ts-customderp" "skip" "no CustomDerp set - the answer if *.tailscale.com is SNI-blocked" }

# --- rungs 5-6: wireguard -----------------------------------------------------
$wgSvc = Get-Service -Name "WireGuardTunnel*" -ErrorAction SilentlyContinue
if($wgSvc){
  Rung "wg-udp" $(if($wgSvc.Status -eq "Running"){"ok"}else{"fail"}) "tunnel service $($wgSvc.Status)"
} else { Rung "wg-udp" "skip" "no WireGuard tunnel installed" }
if($cfg.HomePublic -and (Get-Command wstunnel -ErrorAction SilentlyContinue)){
  Rung "wg-tcp443" $(if(TcpOk $cfg.HomePublic 443){"ok"}else{"fail"}) "wstunnel target"
} else { Rung "wg-tcp443" "skip" "wstunnel not installed / HomePublic unset - wraps WG in TLS" }

# --- rung 7: ssh over 443 -----------------------------------------------------
if($cfg.HomePublic){
  if(TcpOk $cfg.HomePublic $cfg.Ssh443Port){
    $banner = ""
    try{
      $c = New-Object Net.Sockets.TcpClient($cfg.HomePublic, $cfg.Ssh443Port)
      $s = $c.GetStream(); $s.ReadTimeout = 4000
      $buf = New-Object byte[] 40; $n = $s.Read($buf,0,40)
      $banner = [Text.Encoding]::ASCII.GetString($buf,0,$n); $c.Close()
    }catch{}
    if($banner -like "SSH-*"){ Rung "ssh443" "ok" "SSH banner on :$($cfg.Ssh443Port)" }
    else { Rung "ssh443" "fail" "port open but not SSH (proxy intercepting?)" }
  } else { Rung "ssh443" "fail" "$($cfg.HomePublic):$($cfg.Ssh443Port) blocked" }
} else { Rung "ssh443" "skip" "HomePublic unset - sshd on 443 at home is among the most reliable rungs" }

# --- rung 8: https beacon -----------------------------------------------------
if($cfg.NtfyTopic){
  $c = HttpCode "$($cfg.NtfyUrl)/$($cfg.NtfyTopic)" @{ Method="POST"; Body="netladder probe" }
  Rung "https-beacon" $(if($c -eq 200){"ok"}else{"fail"}) "HTTP $c"
} else { Rung "https-beacon" "skip" "no NtfyTopic" }

# --- rung 9: DoH --------------------------------------------------------------
$c = HttpCode "https://cloudflare-dns.com/dns-query?name=example.com&type=A" @{ Headers=@{accept="application/dns-json"} }
Rung "doh" $(if($c -eq 200){"ok"}else{"fail"}) "HTTP $c"

# --- report -------------------------------------------------------------------
if($Json){ [pscustomobject]@{ host=$env:COMPUTERNAME; ts=(Get-Date -Format o); rungs=$R } | ConvertTo-Json -Depth 5; exit 0 }

Write-Host ""
Write-Host "netladder - $env:COMPUTERNAME - $(Get-Date -Format o)"
Write-Host ""
foreach($k in $R.Keys){
  $m = switch($R[$k].state){ "ok"{"  OK  "} "fail"{" FAIL "} default{" skip "} }
  "{0} {1,-16} {2}" -f "[$m]", $k, $R[$k].note | Write-Host
}
Write-Host ""

$best = $null
foreach($k in @("ts-direct","ts-derp","ts-customderp","wg-udp","wg-tcp443","ssh443","https-beacon")){
  if($R[$k].state -eq "ok"){ $best = $k; break }
}
if($best){ Write-Host "  BEST WORKING PATH: $best" }
else{
  Write-Host "  NO TUNNEL PATH WORKS."
  if($R["https-beacon"].state -eq "ok" -or $R["doh"].state -eq "ok"){
    Write-Host "  But HTTPS egress EXISTS - a custom DERP on your own domain (rung 4) or"
    Write-Host "  sshd on 443 at home (rung 7) would very likely work. Build one."
  } else {
    Write-Host "  No HTTPS egress at all. Look for a mandatory proxy and set HTTPS_PROXY."
  }
}

if($cfg.NtfyTopic -and $R["https-beacon"].state -eq "ok"){
  $sum = ($R.Keys | ForEach-Object { "$_=$($R[$_].state)" }) -join " "
  try{ Invoke-WebRequest -Uri "$($cfg.NtfyUrl)/$($cfg.NtfyTopic)" -Method POST -TimeoutSec 10 `
        -Headers @{ Title="[NETLADDER] $env:COMPUTERNAME" } -Body "best=$best`n$sum" -UseBasicParsing | Out-Null }catch{}
}

if($ProbeOnly){ exit 0 }

# --- act ----------------------------------------------------------------------
if((Test-Path $tsExe) -and $R["ts-derp"].state -eq "ok"){
  & $tsExe status *>$null
  if($LASTEXITCODE -ne 0){
    Write-Host "  bringing tailscale up..."
    & $tsExe up --unattended --accept-dns=false 2>$null | Out-Null
  }
}

# --- PIVOT: egress through home ----------------------------------------------
# The whole point: the local perimeter is slow and filtered; home is fast and
# unrestricted. Once any tunnel exists, send Claude's API traffic via home.
# Per-application, not an exit node, so the lab subnet stays directly reachable.
if($cfg.HomeTsIp){
  if(TcpOk $cfg.HomeTsIp $cfg.HomeProxyPort){
    $p = "http://$($cfg.HomeTsIp):$($cfg.HomeProxyPort)"
    Write-Host "  home proxy reachable - pivoting egress to $p"
    [Environment]::SetEnvironmentVariable("HTTPS_PROXY",$p,"Machine")
    [Environment]::SetEnvironmentVariable("HTTP_PROXY", $p,"Machine")
    [Environment]::SetEnvironmentVariable("NO_PROXY","localhost,127.0.0.1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,100.64.0.0/10","Machine")
    # Prove it reaches Anthropic rather than assuming. 401/403 = transport works.
    try{
      $r = Invoke-WebRequest -Uri "https://api.anthropic.com/v1/models" -Proxy $p -TimeoutSec 15 -UseBasicParsing
      Write-Host "  VERIFIED: api.anthropic.com reachable via home (HTTP $([int]$r.StatusCode))"
    }catch{
      $sc = if($_.Exception.Response){ [int]$_.Exception.Response.StatusCode } else { 0 }
      if($sc -in 401,403){ Write-Host "  VERIFIED: api.anthropic.com reachable via home (HTTP $sc = auth required, transport works)" }
      elseif($sc -eq 0){ Write-Host "  WARN: proxy up but api.anthropic.com did NOT respond through it" }
      else{ Write-Host "  api.anthropic.com via home returned HTTP $sc" }
    }
    Write-Host "  NOTE: machine-level env set. Open a NEW shell for it to take effect."
  } else {
    Write-Host "  home proxy $($cfg.HomeTsIp):$($cfg.HomeProxyPort) not reachable"
    Write-Host "  stand one up at home (bound to its TAILNET address only) - README option 2"
  }
}
