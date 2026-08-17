# Runs ON each Windows guest. Give logonnoise a STABLE PER-HOST set of assigned users.
#
# CURRENT BEHAVIOUR: the pool is every account tagged range-active-workforce (24 of them) and the script
# does `$u = $pool | Get-Random`, so all 24 accounts log into all 4 hosts uniformly.
#
# WHY CHANGE IT: in a real estate a workstation has 1-3 assigned users. Uniform any-user-anywhere is not
# just unrealistic - it makes "unusual logon" and lateral-movement detection IMPOSSIBLE, because with
# every account appearing on every host nothing can ever be anomalous. Assigning a stable subset creates
# the baseline those exercises need, and the occasional cross-host logon becomes a genuine signal.
#
# NOTE - I initially blamed logonnoise for ws01's 355 profiles. That was WRONG: the pool is only 24
# accounts, so it cannot have created 355. Those profiles are a one-time bulk artifact from the build.
#
# DESIGN: the assigned set is derived deterministically from COMPUTERNAME, so it is stable across runs and
# reboots without storing state. 5 assigned users per host, and 10% of logons come from outside that set
# (real people do occasionally use a colleague's machine - and that rarity is what makes it detectable).
#
# IDEMPOTENT + VALIDATED: skips if already patched, and the result must PARSE as PowerShell before install.
$ErrorActionPreference = 'Stop'
$f = 'C:\Windows\Temp\logonnoise.ps1'
Write-Output ("=== {0} ===" -f $env:COMPUTERNAME)
if (-not (Test-Path $f)) { Write-Output "   logonnoise.ps1 absent - skipping"; exit 0 }

$raw = Get-Content $f -Raw
if ($raw -match 'RANGE_HOST_ASSIGNED') { Write-Output "   already patched - skipping"; exit 0 }

$old = '$u  = $pool | Get-Random'
if ($raw -notmatch [regex]::Escape($old)) {
    # try the looser form
    $old = '$u = $pool | Get-Random'
    if ($raw -notmatch [regex]::Escape($old)) {
        Write-Output "   selection line not found - REFUSING to guess. Lines containing 'Get-Random':"
        Select-String -Path $f -Pattern 'Get-Random' | ForEach-Object { Write-Output ("     " + $_.LineNumber + ": " + $_.Line.Trim()) }
        exit 1
    }
}
Write-Output ("   found selection line: {0}" -f $old)

$new = @'
# RANGE_HOST_ASSIGNED: pick from the users ASSIGNED TO THIS HOST, not the whole workforce.
  # A stable subset derived from COMPUTERNAME (no stored state, survives reboots). Uniform
  # any-user-on-any-host would make anomalous-logon detection impossible.
  $__sorted = @($pool | Sort-Object)
  $__seed = 0
  foreach ($__ch in $env:COMPUTERNAME.ToCharArray()) { $__seed = ($__seed * 31 + [int]$__ch) % 999983 }
  $__rng = [System.Random]::new($__seed)
  $__assigned = @($__sorted | Sort-Object { $__rng.Next() } | Select-Object -First 5)
  # 10% of logons come from OUTSIDE the assigned set - rare cross-host use is real, and its rarity is
  # exactly what makes it detectable.
  if ((Get-Random -Minimum 0.0 -Maximum 1.0) -lt 0.10) {
    $u  = $pool | Get-Random
    Say ("visitor logon (outside assigned set): " + $u)
  } else {
    $u  = $__assigned | Get-Random
  }
  Say ("assigned set for " + $env:COMPUTERNAME + ": " + ($__assigned -join ','))
'@

$patched = $raw.Replace($old, $new)
if ($patched -eq $raw) { Write-Output "   replacement produced no change - aborting"; exit 1 }

# Validate it PARSES before installing - a broken generator would silently stop producing logons.
$tmp = 'C:\Windows\Temp\logonnoise.patched.ps1'
Set-Content -Path $tmp -Value $patched -Encoding UTF8
$errs = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($tmp, [ref]$null, [ref]$errs)
if ($errs -and $errs.Count -gt 0) {
    Write-Output ("   *** PARSE FAILED ({0} errors) - refusing to install ***" -f $errs.Count)
    $errs | Select-Object -First 3 | ForEach-Object { Write-Output ("     " + $_.Message) }
    exit 1
}
Write-Output "   parse: OK"

Copy-Item $f "$f.bak-assigned" -Force
Copy-Item $tmp $f -Force
Write-Output "   installed"

# Show the assigned set this host will now use.
$sorted = $null
try {
    $s = New-Object DirectoryServices.DirectorySearcher
    $s.Filter = '(&(objectCategory=person)(objectClass=user)(info=range-active-workforce))'
    $pool = @($s.FindAll() | ForEach-Object { $_.Properties['samaccountname'][0] })
} catch { $pool = @() }
if ($pool.Count -lt 2) { Write-Output "   (ADSI empty here; the embedded fallback list will be used)"; exit 0 }
$seed = 0; foreach ($ch in $env:COMPUTERNAME.ToCharArray()) { $seed = ($seed * 31 + [int]$ch) % 999983 }
$rng = [System.Random]::new($seed)
$assigned = @(@($pool | Sort-Object) | Sort-Object { $rng.Next() } | Select-Object -First 5)
Write-Output ("   pool={0}  assigned to this host: {1}" -f $pool.Count, ($assigned -join ', '))
