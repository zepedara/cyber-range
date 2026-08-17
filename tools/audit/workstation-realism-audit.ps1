# Runs ON a Windows guest. COMPACT audit - summary numbers only, no per-profile listing.
# Motivated by finding 355 profiles on WS01: at ~30 MB each that is ~10.6 GB consumed by my own
# logonnoise generator (every LogonUser type-2 for a new account materialises a local profile).
# DISK SPACE is now the urgent number - a full C: would take the guest down and that would be a
# self-inflicted outage, so it is measured first.
$ErrorActionPreference = 'SilentlyContinue'
$k = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
       'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')

$d = Get-PSDrive C
$freeGB = [math]::Round($d.Free/1GB,1); $usedGB = [math]::Round($d.Used/1GB,1)
$pct = [math]::Round(100.0*$d.Free/($d.Free+$d.Used),1)

$profs = @(Get-ChildItem 'C:\Users' -Directory)
$userDirBytes = ($profs | ForEach-Object { (Get-ChildItem $_.FullName -Recurse -File -Force | Measure-Object Length -Sum).Sum } | Measure-Object -Sum).Sum
$apps = @(Get-ItemProperty $k | Where-Object { $_.DisplayName } | Select-Object -ExpandProperty DisplayName | Sort-Object -Unique)
$sha = [System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash(
        [System.Text.Encoding]::UTF8.GetBytes(($apps -join '|')))).Replace('-','').Substring(0,16)

# browser history presence across all profiles
$ffCount = 0; $ffBytes = 0; $crCount = 0; $crBytes = 0
foreach ($p in $profs) {
    foreach ($f in @(Get-ChildItem (Join-Path $p.FullName 'AppData\Roaming\Mozilla\Firefox\Profiles') -Directory)) {
        $pl = Join-Path $f.FullName 'places.sqlite'
        if (Test-Path $pl) { $ffCount++; $ffBytes += (Get-Item $pl).Length }
    }
    foreach ($rel in @('AppData\Local\Microsoft\Edge\User Data\Default\History',
                       'AppData\Local\Google\Chrome\User Data\Default\History')) {
        $h = Join-Path $p.FullName $rel
        if (Test-Path $h) { $crCount++; $crBytes += (Get-Item $h).Length }
    }
}

# how varied are profile sizes? identical sizes == batch-created, not organic
$sizes = @($profs | ForEach-Object { (Get-ChildItem $_.FullName -Recurse -File -Force | Measure-Object Length -Sum).Sum })
$distinctMb = @($sizes | ForEach-Object { [math]::Round($_/1MB,0) } | Sort-Object -Unique).Count

Write-Output ("HOST={0}" -f $env:COMPUTERNAME)
Write-Output ("  C: free={0} GB used={1} GB ({2}% free)" -f $freeGB, $usedGB, $pct)
Write-Output ("  profiles={0}  C:\Users total={1} GB  distinct size-buckets(MB)={2}" -f $profs.Count, [math]::Round($userDirBytes/1GB,2), $distinctMb)
Write-Output ("  registry ProfileList entries={0}" -f @(Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList').Count)
Write-Output ("  firefox places.sqlite files={0} totalKB={1:N0}" -f $ffCount, ($ffBytes/1KB))
Write-Output ("  chromium History files={0} totalKB={1:N0}" -f $crCount, ($crBytes/1KB))
Write-Output ("  installed programs={0} SOFTWARE_FINGERPRINT={1}" -f $apps.Count, $sha)
Write-Output ("  office installed={0}" -f $(if ($apps -match 'Office|Word|Excel') {'YES'} else {'NO'}))
Write-Output ("  prefetch={0}" -f @(Get-ChildItem 'C:\Windows\Prefetch' -Filter '*.pf').Count)
Write-Output ("  profiles modified in last 24h={0}" -f @($profs | Where-Object { $_.LastWriteTime -gt (Get-Date).AddHours(-24) }).Count)
Write-Output ("  APPS: {0}" -f (($apps | Select-Object -First 12) -join '; '))
