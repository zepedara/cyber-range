# Runs ON the DC. Two fixes, both found by measuring the workforce export.
#
# FINDING 1: givenName / sn / displayName are empty on ALL 2,446 person accounts. BadBlood created
# sAMAccountNames like LUCILE_DAY but never set the name attributes. A directory where nobody has a first
# or last name is not enumerable the way a real one is (no "search by surname", no displayName in any
# client, and every tool that shows "Name" shows nothing).
#
# FINDING 2: 86 accounts are service-account-shaped (sAMAccountName carries digits / ends in "SA", no real
# name). My earlier HR backfill wrongly classed them as PEOPLE because they carry no SPN, and gave them
# nonsense emails like sa.user1@range.lan plus a department, title and manager. Service accounts should
# not have HR attributes at all. Those attributes are cleared here.
#
# IDEMPOTENT: skips accounts that already have a GivenName.
$ErrorActionPreference = 'Stop'
Import-Module ActiveDirectory -EA Stop
$MAILDOMAIN = 'range.lan'

$startUtc = (Get-Date).ToUniversalTime().ToString('HH:mm:ssZ')
Write-Output "  START=$startUtc"

$all = Get-ADUser -Filter * -Properties GivenName,Surname,DisplayName,Department,Title,Company,`
    physicalDeliveryOfficeName,l,mail,telephoneNumber,Manager,servicePrincipalName,info -ResultSetSize $null
$people = @($all | Where-Object {
    -not $_.servicePrincipalName -and
    $_.SamAccountName -notin @('Administrator','Guest','krbtgt','DefaultAccount')
})

# Split on shape: a real person's sam is FIRST_LAST with no digits.
$human = @($people | Where-Object { $_.SamAccountName -match '^[A-Za-z]+_[A-Za-z]+$' })
$svc   = @($people | Where-Object { $_.SamAccountName -notmatch '^[A-Za-z]+_[A-Za-z]+$' })
Write-Output ("  person-like={0}  human-shaped={1}  service-shaped={2}" -f $people.Count, $human.Count, $svc.Count)

# ---- FIX 1: real names + a clean email for the humans
function TitleCase($s) {
    if (-not $s) { return $s }
    return (Get-Culture).TextInfo.ToTitleCase($s.ToLower())
}
$seen = @{}
$n1 = 0; $e1 = 0
foreach ($u in ($human | Sort-Object SamAccountName)) {
    if ($u.GivenName) { continue }                     # idempotent
    $p = $u.SamAccountName -split '_'
    $fn = TitleCase $p[0]; $ln = TitleCase $p[1]
    $disp = "$fn $ln"
    # first.last@, with a numeric suffix ONLY on collision - which is how real orgs disambiguate.
    $base = ("{0}.{1}" -f $fn, $ln).ToLower()
    $mail = "$base@$MAILDOMAIN"
    if ($seen.ContainsKey($base)) { $seen[$base]++; $mail = "$base$($seen[$base])@$MAILDOMAIN" } else { $seen[$base] = 1 }
    try {
        Set-ADUser -Identity $u.DistinguishedName -GivenName $fn -Surname $ln -DisplayName $disp `
                   -Replace @{ mail = $mail } -EA Stop
        $n1++
    } catch { $e1++; if ($e1 -le 4) { Write-Output ("    ERR name {0}: {1}" -f $u.SamAccountName, $_.Exception.Message) } }
    if ($n1 % 200 -eq 0 -and $n1 -gt 0) { Write-Output ("    names ... {0}" -f $n1); Start-Sleep -Milliseconds 500 }
}
Write-Output ("  FIX1 names+mail set: {0}  errors={1}" -f $n1, $e1)

# ---- FIX 2: strip HR attributes from the service-shaped accounts
$n2 = 0; $e2 = 0
foreach ($u in $svc) {
    try {
        $clear = @()
        foreach ($a in 'department','title','company','physicalDeliveryOfficeName','l','mail','telephoneNumber') {
            if ($u.$a) { $clear += $a }
        }
        if ($clear.Count -gt 0) { Set-ADUser -Identity $u.DistinguishedName -Clear $clear -EA Stop }
        if ($u.Manager)        { Set-ADUser -Identity $u.DistinguishedName -Manager $null -EA Stop }
        if ($clear.Count -gt 0 -or $u.Manager) { $n2++ }
    } catch { $e2++; if ($e2 -le 4) { Write-Output ("    ERR svc {0}: {1}" -f $u.SamAccountName, $_.Exception.Message) } }
}
Write-Output ("  FIX2 service accounts cleaned: {0}  errors={1}" -f $n2, $e2)

# ---- verify
Write-Output ""
Write-Output "  == VERIFY (re-read from AD) =="
$after = Get-ADUser -Filter * -Properties GivenName,Surname,DisplayName,Department,mail,servicePrincipalName -ResultSetSize $null
$ap = @($after | Where-Object { -not $_.servicePrincipalName -and $_.SamAccountName -notin @('Administrator','Guest','krbtgt','DefaultAccount') })
$ah = @($ap | Where-Object { $_.SamAccountName -match '^[A-Za-z]+_[A-Za-z]+$' })
$asv= @($ap | Where-Object { $_.SamAccountName -notmatch '^[A-Za-z]+_[A-Za-z]+$' })
$withName = @($ah | Where-Object { $_.GivenName -and $_.Surname }).Count
$withDisp = @($ah | Where-Object { $_.DisplayName }).Count
$svcWithHr= @($asv | Where-Object { $_.Department -or $_.mail }).Count
$dupMail  = @($ap | Where-Object {$_.mail} | Group-Object mail | Where-Object {$_.Count -gt 1}).Count
Write-Output ("     humans with givenName+sn : {0}/{1}" -f $withName, $ah.Count)
Write-Output ("     humans with displayName  : {0}/{1}" -f $withDisp, $ah.Count)
Write-Output ("     service accts still w/ HR: {0}/{1}" -f $svcWithHr, $asv.Count)
Write-Output ("     duplicate mail values    : {0}" -f $dupMail)
Write-Output "     samples:"
$ah | Select-Object -First 4 | ForEach-Object {
    Write-Output ("       {0,-20} {1,-10} {2,-12} {3,-22} {4}" -f $_.SamAccountName, $_.GivenName, $_.Surname, $_.DisplayName, $_.mail) }

Write-Output ""
Write-Output "  == GATE =="
$c1 = $withName -ge ($ah.Count * 0.99)
$c2 = $withDisp -ge ($ah.Count * 0.99)
$c3 = $svcWithHr -eq 0
$c4 = $dupMail -eq 0
Write-Output ("     [{0}] >=99% humans have givenName+sn" -f $(if($c1){'PASS'}else{'FAIL'}))
Write-Output ("     [{0}] >=99% humans have displayName" -f $(if($c2){'PASS'}else{'FAIL'}))
Write-Output ("     [{0}] 0 service accounts retain HR attributes" -f $(if($c3){'PASS'}else{'FAIL'}))
Write-Output ("     [{0}] 0 duplicate mail values" -f $(if($c4){'PASS'}else{'FAIL'}))
Write-Output ("     OVERALL: {0}" -f $(if($c1 -and $c2 -and $c3 -and $c4){'PASS'}else{'FAIL'}))
Write-Output ("  END={0}" -f (Get-Date).ToUniversalTime().ToString('HH:mm:ssZ'))
