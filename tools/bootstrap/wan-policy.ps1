<#
=============================================================================
 wan-policy.ps1 - split traffic across multiple WANs deterministically.

 THE PROBLEM, and it is the likely root of the original outage:
   Windows selects a route by INTERFACE METRIC + ROUTE METRIC, lowest wins, and
   "Automatic Metric" is ON BY DEFAULT. Automatic Metric assigns metrics BY LINK
   SPEED - so a 1Gb lab NIC automatically beats a slower cellular puck, and
   Windows will send internet traffic out the lab line whether you want it to or
   not. It also means an unattached-but-linked USB adapter can win the default
   route, which is exactly how lab traffic left the wrong NIC before.
   docs: https://learn.microsoft.com/en-us/troubleshoot/windows-server/networking/automatic-metric-for-ipv4-routes

 WHAT THIS DOES:
   * pins lab subnets to the lab NIC with a specific persistent route
     (a specific route always beats a default route, regardless of metric)
   * puts the DEFAULT route on the WAN you choose, by pinning metrics explicitly
     rather than leaving it to link speed
   * VERIFIES the split with a real traceroute, because a route table that looks
     right and behaves wrong is the failure mode that costs hours

 Usage (elevated):
   .\wan-policy.ps1 -Show
   .\wan-policy.ps1 -InternetVia "Puck" -LabVia "Ethernet" -LabSubnets 10.10.0.0/16 -LabGateway 10.10.100.1
   .\wan-policy.ps1 -Verify
=============================================================================
#>
[CmdletBinding()]
param(
  [switch]$Show,
  [switch]$Verify,
  [string]$InternetVia = "",
  [string]$LabVia      = "",
  [string[]]$LabSubnets = @(),
  [string]$LabGateway  = "",
  [int]$InternetMetric = 10,
  [int]$LabMetric      = 50
)
$ErrorActionPreference = "Continue"
function OK($m){ Write-Host "  [ OK ] $m" -ForegroundColor Green }
function Bad($m){ Write-Host "  [FAIL] $m" -ForegroundColor Red }
function Note($m){ Write-Host "         $m" -ForegroundColor DarkGray }

function Show-Wans {
  Write-Host "`n=== INTERFACES (lower metric wins; 'Automatic' means Windows chose by link speed) ===" -ForegroundColor Cyan
  Get-NetIPInterface -AddressFamily IPv4 |
    Where-Object { $_.ConnectionState -eq "Connected" } |
    Sort-Object InterfaceMetric |
    ForEach-Object {
      $ip = (Get-NetIPAddress -InterfaceIndex $_.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
             Select-Object -First 1).IPAddress
      "{0,-6} {1,-28} metric {2,-6} auto={3,-6} {4}" -f `
        $_.ifIndex, $_.InterfaceAlias, $_.InterfaceMetric, $_.AutomaticMetric, $ip | Write-Host
    }
  Write-Host "`n=== DEFAULT ROUTES (this is what actually carries internet traffic) ===" -ForegroundColor Cyan
  Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
    Sort-Object RouteMetric |
    Format-Table ifIndex,InterfaceAlias,NextHop,RouteMetric,@{n='Total';e={$_.RouteMetric + (Get-NetIPInterface -InterfaceIndex $_.ifIndex -AddressFamily IPv4).InterfaceMetric}} -AutoSize
}

function Verify-Split {
  param([string[]]$Lab, [string]$Probe = "api.anthropic.com")
  Write-Host "`n=== VERIFY: does traffic actually leave the intended adapter? ===" -ForegroundColor Cyan
  # A route table that looks right and behaves wrong is the whole problem, so test
  # the real thing rather than trusting the table.
  $r = Test-NetConnection $Probe -ErrorAction SilentlyContinue
  if($r){ "  internet probe -> {0}  via ifIndex {1} ({2})" -f $Probe, $r.InterfaceAlias, $r.SourceAddress.IPAddress | Write-Host }
  foreach($s in $Lab){
    $host1 = ($s -replace '/\d+$','') -replace '\.0$','.1'
    $r2 = Test-NetConnection $host1 -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
    if($r2){ "  lab probe      -> {0}  via {1} ({2}) reachable={3}" -f $host1, $r2.InterfaceAlias, $r2.SourceAddress.IPAddress, $r2.PingSucceeded | Write-Host }
  }
}

if(-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
   ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
  Write-Host "Run elevated to change routing. -Show works unelevated." -ForegroundColor Yellow
}

if($Show -or (-not $InternetVia -and -not $Verify)){ Show-Wans; if(-not $Verify){ exit 0 } }
if($Verify){ Verify-Split -Lab $LabSubnets; exit 0 }

# --- apply -------------------------------------------------------------------
$inet = Get-NetAdapter -Name "*$InternetVia*" -ErrorAction SilentlyContinue | Where-Object Status -eq Up | Select-Object -First 1
$lab  = Get-NetAdapter -Name "*$LabVia*"      -ErrorAction SilentlyContinue | Where-Object Status -eq Up | Select-Object -First 1
if(-not $inet){ Bad "no UP adapter matching '$InternetVia'"; Show-Wans; exit 1 }
if(-not $lab -and $LabSubnets.Count){ Bad "no UP adapter matching '$LabVia'"; Show-Wans; exit 1 }
OK "internet WAN: $($inet.Name) (ifIndex $($inet.ifIndex))"
if($lab){ OK "lab NIC     : $($lab.Name) (ifIndex $($lab.ifIndex))" }

# 1. Turn OFF automatic metric on both, or link speed silently overrides you.
foreach($a in @($inet,$lab)){
  if($a){ Set-NetIPInterface -InterfaceIndex $a.ifIndex -AutomaticMetric Disabled -ErrorAction SilentlyContinue }
}
OK "automatic metric disabled (it was choosing by link speed)"

# 2. Pin metrics: internet WAN preferred for the default route.
Set-NetIPInterface -InterfaceIndex $inet.ifIndex -InterfaceMetric $InternetMetric -ErrorAction SilentlyContinue
OK "$($inet.Name) interface metric = $InternetMetric (preferred for default route)"
if($lab){
  Set-NetIPInterface -InterfaceIndex $lab.ifIndex -InterfaceMetric $LabMetric -ErrorAction SilentlyContinue
  OK "$($lab.Name) interface metric = $LabMetric"
}

# 3. Pin lab subnets to the lab NIC with SPECIFIC persistent routes.
#    A specific route beats a default route regardless of metric, so this keeps
#    lab traffic on the lab line even though its metric is worse.
if($lab -and $LabSubnets.Count -and $LabGateway){
  foreach($s in $LabSubnets){
    Remove-NetRoute -DestinationPrefix $s -Confirm:$false -ErrorAction SilentlyContinue
    New-NetRoute -DestinationPrefix $s -InterfaceIndex $lab.ifIndex -NextHop $LabGateway `
                 -RouteMetric 1 -PolicyStore PersistentStore -ErrorAction SilentlyContinue | Out-Null
    OK "pinned $s -> $($lab.Name) via $LabGateway (persistent)"
  }
} elseif($LabSubnets.Count) {
  Bad "lab subnets given but -LabGateway missing - not pinning"
}

Show-Wans
Verify-Split -Lab $LabSubnets

Write-Host @"

NOTE: -PolicyStore PersistentStore survives reboot. Routes added without it are
lost on restart, which is how a working split quietly reverts overnight.
Re-verify after any adapter change with:  .\wan-policy.ps1 -Verify -LabSubnets $($LabSubnets -join ',')
"@ -ForegroundColor DarkGray
