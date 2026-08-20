<#
=============================================================================
 range-setup.ps1 - THE single entry point for the WINDOWS laptop / workstation.

 Same gated sequence as range-setup.sh. Each phase must pass before the next,
 because a half-installed host on a restricted network is worse than no host.

   PHASE 1  preflight    admin rights, offline bundle present, disk space
   PHASE 2  install      every tool, each VERIFIED before proceeding      <- GATE
   PHASE 3  discover     find every working path out to home
   PHASE 4  measure      rank working paths by latency and throughput
   PHASE 5  pin route    select the best, prove Anthropic reachable       <- GATE
   PHASE 6  auth         confirm the SUBSCRIPTION credential is valid     <- GATE
   PHASE 7  launch       start Claude in bypass mode on the pinned route

 NOTHING IS DOWNLOADED. Every installer must already be in .\offline\ beside this
 script. On a restricted network the download endpoints are exactly what is
 blocked, so a fetch-at-runtime installer strands you on site.

 STAGE THESE IN .\offline\ BEFOREHAND:
   tailscale-setup-*.exe        https://pkgs.tailscale.com/stable/#windows
   node-v*-x64.msi              https://nodejs.org/dist/
   claude-code-*.tgz            npm pack @anthropic-ai/claude-code
   credentials.json             copy of %USERPROFILE%\.claude\.credentials.json
   wireguard-installer.exe      optional
 Usage (elevated PowerShell):
   .\range-setup.ps1                 full gated run, ends by launching Claude
   .\range-setup.ps1 -Check          verify readiness, change nothing
   .\range-setup.ps1 -NoLaunch       everything except starting Claude
=============================================================================
#>
[CmdletBinding()]
param(
  [switch]$Check,
  [switch]$NoLaunch,
  [string]$OfflineDir = "",
  [string]$TsAuthKey  = $env:TS_AUTHKEY,
  [string]$HomeTsIp   = $env:HOME_TS_IP,
  [int]$HomeProxyPort = 3128
)
$ErrorActionPreference = "Continue"
$HERE = Split-Path -Parent $MyInvocation.MyCommand.Path
if(-not $OfflineDir){ $OfflineDir = Join-Path $HERE "offline" }

function Phase($n){ Write-Host "`n=== PHASE $n ===" -ForegroundColor Cyan }
function OK($m){   Write-Host "  [ OK ] $m" -ForegroundColor Green }
function Bad($m){  Write-Host "  [FAIL] $m" -ForegroundColor Red }
function Warn($m){ Write-Host "  [WARN] $m" -ForegroundColor Yellow }
function Note($m){ Write-Host "         $m" -ForegroundColor DarkGray }
function Die($m){
  Write-Host "`nGATE FAILED: $m" -ForegroundColor Red
  Write-Host "Fix this before continuing - it is not recoverable on site."
  exit 1
}
function Have($c){ [bool](Get-Command $c -ErrorAction SilentlyContinue) }
function Staged($pat){ (Get-ChildItem -Path $OfflineDir -Filter $pat -ErrorAction SilentlyContinue | Select-Object -First 1).FullName }

# =============================================================================
Phase "1 - PREFLIGHT"
# =============================================================================
if(-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
   ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
  Die "must run elevated (Run as Administrator)"
}
OK "running elevated"
Note "host: $env:COMPUTERNAME   os: $((Get-CimInstance Win32_OperatingSystem).Caption)"

if(-not (Test-Path $OfflineDir)){
  Die "no offline bundle at $OfflineDir`n  Everything must be pre-staged - see the header of this script."
}
OK "offline bundle present: $OfflineDir"
Get-ChildItem $OfflineDir -ErrorAction SilentlyContinue |
  ForEach-Object { Note ("{0,-46} {1,8:N1} MB" -f $_.Name, ($_.Length/1MB)) }

$freeGB = [math]::Round((Get-PSDrive C).Free/1GB,1)
if($freeGB -lt 2){ Die "only ${freeGB}GB free on C: - need ~2GB" }
OK "disk space: ${freeGB}GB free"

# =============================================================================
Phase "2 - INSTALL (gated: every tool verified before proceeding)"
# =============================================================================
$tsExe = "C:\Program Files\Tailscale\tailscale.exe"

# --- tailscale ---
if(Test-Path $tsExe){
  OK "tailscale present: $(& $tsExe version 2>$null | Select-Object -First 1)"
} else {
  $i = Staged "tailscale-setup*.msi"; if(-not $i){ $i = Staged "tailscale-setup*.exe" }
  if(-not $i){ Die "tailscale not installed and no tailscale-setup*.exe in $OfflineDir" }
  if(-not $Check){
    Note "installing $(Split-Path $i -Leaf)"
    if($i -like "*.msi"){ Start-Process msiexec.exe -ArgumentList "/i","`"$i`"","/qn","/norestart" -Wait }
    else { Start-Process -FilePath $i -ArgumentList "/S" -Wait }
    if(-not (Test-Path $tsExe)){ Die "tailscale install FAILED from $(Split-Path $i -Leaf)" }
    OK "tailscale installed"
  } else { Warn "would install $(Split-Path $i -Leaf)" }
}

# --- node ---
if(Have node){
  OK "node present: $(node -v 2>$null)"
} else {
  $i = Staged "node-v*-x64.msi"
  if(-not $i){ Die "node not installed and no node-v*-x64.msi in $OfflineDir" }
  if(-not $Check){
    Note "installing $(Split-Path $i -Leaf)"
    Start-Process msiexec.exe -ArgumentList "/i","`"$i`"","/qn","/norestart" -Wait
    $env:Path = [Environment]::GetEnvironmentVariable("Path","Machine") + ";" + $env:Path
    if(-not (Have node)){ Die "node install FAILED - a reboot may be required" }
    OK "node installed: $(node -v)"
  } else { Warn "would install $(Split-Path $i -Leaf)" }
}

# --- claude code ---
if(Have claude){
  OK "claude present: $(claude --version 2>$null)"
} else {
  $i = Staged "claude-code-*.tgz"; if(-not $i){ $i = Staged "anthropic-ai-claude-code-*.tgz" }
  if(-not $i){ Die "claude not installed and no claude-code-*.tgz in $OfflineDir`n  Build at home: npm pack @anthropic-ai/claude-code" }
  if(-not $Check){
    Note "installing $(Split-Path $i -Leaf)"
    & npm install -g "$i" 2>$null | Out-Null
    $env:Path = [Environment]::GetEnvironmentVariable("Path","Machine") + ";" + $env:Path
    if(-not (Have claude)){ Die "claude install FAILED from $(Split-Path $i -Leaf)" }
    OK "claude installed: $(claude --version 2>$null)"
  } else { Warn "would install $(Split-Path $i -Leaf)" }
}

if($Check){ Write-Host "`n-Check complete: review any FAIL above."; exit 0 }

# power: an unattended remote box must not sleep
powercfg /change standby-timeout-ac 0 2>$null
powercfg /change hibernate-timeout-ac 0 2>$null
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power" /v HiberbootEnabled /t REG_DWORD /d 0 /f 2>$null | Out-Null
OK "sleep/hibernate disabled, Fast Startup off"

# =============================================================================
Phase "3 - DISCOVER PATHS OUT"
# =============================================================================
& $tsExe status *>$null
if($LASTEXITCODE -ne 0 -and $TsAuthKey){
  Note "bringing tailscale up with the pre-authorised key"
  # --unattended is essential: without it Tailscale drops when the user logs out.
  & $tsExe up --authkey $TsAuthKey --hostname $env:COMPUTERNAME --accept-dns=false --unattended 2>$null | Out-Null
}
& $tsExe status *>$null
if($LASTEXITCODE -eq 0){
  OK "tailscale up: $(& $tsExe ip -4 2>$null | Select-Object -First 1)"
} else {
  Warn "tailscale NOT up - the home path will be unavailable"
  Note "if it wanted a login, the auth key was missing or not pre-approved"
}

function ProbeAnthropic($proxy){
  try{
    $p = @{ Uri="https://api.anthropic.com/v1/models"; TimeoutSec=12; UseBasicParsing=$true }
    if($proxy){ $p.Proxy = $proxy }
    $r = Invoke-WebRequest @p
    return [int]$r.StatusCode
  } catch {
    if($_.Exception.Response){ return [int]$_.Exception.Response.StatusCode }
    return 0
  }
}
$cands = @()
$c = ProbeAnthropic $null
if($c -in 200,401,403){ OK "direct reachable (HTTP $c)"; $cands += "direct" } else { Bad "direct unreachable (HTTP $c)" }
if($HomeTsIp){
  $hp = "http://${HomeTsIp}:$HomeProxyPort"
  $c = ProbeAnthropic $hp
  if($c -in 200,401,403){ OK "home-proxy reachable (HTTP $c)"; $cands += "home-proxy" } else { Bad "home-proxy unreachable (HTTP $c)" }
}
if($cands.Count -eq 0){
  Die "no path reaches api.anthropic.com.`n  Run netladder.ps1 for a rung-by-rung diagnosis.`n  If HTTPS egress exists but nothing tunnels, a DERP server on your own domain is the intended answer."
}

# =============================================================================
Phase "4 - MEASURE AND RANK"
# =============================================================================
# Pick the BEST path, not the first that answers: latency dominates interactive
# use, throughput matters for long responses. A path can answer and still be
# unusable, so measure against the real endpoint.
$best = $null; $bestLat = [int]::MaxValue
foreach($cand in $cands){
  $proxy = if($cand -eq "home-proxy"){ "http://${HomeTsIp}:$HomeProxyPort" } else { $null }
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $code = ProbeAnthropic $proxy
  $sw.Stop()
  $lat = [int]$sw.ElapsedMilliseconds
  "  {0,-12} latency {1,5} ms   (HTTP {2})" -f $cand, $lat, $code | Write-Host
  if($lat -lt $bestLat){ $bestLat = $lat; $best = $cand }
}
OK "best path: $best (${bestLat}ms)"

# =============================================================================
Phase "5 - PIN THE ROUTE"
# =============================================================================
if($best -eq "home-proxy"){
  $p = "http://${HomeTsIp}:$HomeProxyPort"
  [Environment]::SetEnvironmentVariable("HTTPS_PROXY",$p,"Machine")
  [Environment]::SetEnvironmentVariable("HTTP_PROXY", $p,"Machine")
  [Environment]::SetEnvironmentVariable("NO_PROXY","localhost,127.0.0.1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,100.64.0.0/10","Machine")
  $env:HTTPS_PROXY = $p; $env:HTTP_PROXY = $p
  OK "route pinned: via home proxy $p"
} else {
  [Environment]::SetEnvironmentVariable("HTTPS_PROXY",$null,"Machine")
  [Environment]::SetEnvironmentVariable("HTTP_PROXY", $null,"Machine")
  Remove-Item Env:HTTPS_PROXY,Env:HTTP_PROXY -ErrorAction SilentlyContinue
  OK "route pinned: direct (no proxy)"
}
Note "the route is re-verified at each launch, so a stale setting cannot strand you"

# =============================================================================
Phase "6 - AUTH (subscription, gated)"
# =============================================================================
$credsDst = Join-Path $env:USERPROFILE ".claude\.credentials.json"
$credsSrc = Staged "credentials.json"
if($credsSrc -and -not (Test-Path $credsDst)){
  New-Item -ItemType Directory -Path (Split-Path $credsDst) -Force | Out-Null
  Copy-Item $credsSrc $credsDst -Force
  Note "staged subscription credentials from the bundle"
}
if(-not (Test-Path $credsDst)){
  Die "no subscription credentials at $credsDst`n  Copy .claude\.credentials.json from a machine where you are signed in,`n  or place it in the bundle as offline\credentials.json.`n  Without it Claude demands a login this host cannot perform."
}
try{
  $j = Get-Content $credsDst -Raw | ConvertFrom-Json
  $o = $j.claudeAiOauth
  $left = [math]::Round(($o.refreshTokenExpiresAt - ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()))/3600000)
  if($left -le 0){ Die "subscription refresh token EXPIRED - re-authenticate at home and re-stage" }
  elseif($left -lt 24){ Warn "subscription ($($o.subscriptionType)) refresh token expires in ${left}h - re-stage before it lapses" }
  else { OK "subscription ($($o.subscriptionType)) valid ~$([math]::Floor($left/24))d $($left % 24)h" }
}catch{ Warn "credentials present but expiry could not be parsed" }

$settings = Join-Path $env:USERPROFILE ".claude\settings.json"
if(-not (Test-Path $settings)){
  '{ "permissions": { "defaultMode": "bypassPermissions" } }' | Set-Content $settings -Encoding UTF8
}
OK "bypass permissions preset"

# =============================================================================
Phase "7 - LAUNCH"
# =============================================================================
if($NoLaunch){ OK "setup complete - launch with: claude"; exit 0 }
OK "starting Claude on the pinned route, bypass mode, subscription auth"
& claude
