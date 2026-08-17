# Runs ON the DC. GATE for the AD user-base realism change. Re-reads from AD - does not trust the
# writer's own success count.
#
# Five named conditions, each PASS/FAIL printed explicitly. A gate that reports one number and says
# "GOOD" is how a check passes for the wrong reason, which already happened once in this project.
$ErrorActionPreference = 'Stop'
Import-Module ActiveDirectory -EA Stop

$props = @('Department','Title','Company','Office','Manager','EmailAddress','OfficePhone','City')
$all = Get-ADUser -Filter * -Properties ($props + 'servicePrincipalName') -ResultSetSize $null
$people = @($all | Where-Object {
    -not $_.servicePrincipalName -and $_.SamAccountName -notin @('Administrator','Guest','krbtgt','DefaultAccount') })
$T = $people.Count
Write-Output ("  person-like accounts: {0}" -f $T)
Write-Output ""
Write-Output "  field           set/total   pct"
$pct = @{}
foreach ($p in $props) {
    $s = @($people | Where-Object { $v=$_.$p; $null -ne $v -and "$v".Trim() -ne '' }).Count
    $pct[$p] = 100.0*$s/[Math]::Max($T,1)
    Write-Output ("     {0,-14} {1,5}/{2,-6} {3,5:N1}%" -f $p, $s, $T, $pct[$p])
}

Write-Output ""
Write-Output "  == department distribution =="
$people | Group-Object Department | Sort-Object Count -Desc |
  ForEach-Object { Write-Output ("     {0,-14} {1,5}  {2,5:N1}%" -f $_.Name, $_.Count, (100.0*$_.Count/$T)) }

Write-Output ""
Write-Output "  == title pyramid (top 12) =="
$people | Group-Object Title | Sort-Object Count -Desc | Select-Object -First 12 |
  ForEach-Object { Write-Output ("     {0,-34} {1,5}" -f $_.Name, $_.Count) }

Write-Output ""
Write-Output "  == is the org chart actually TRAVERSABLE? walk 3 ICs upward =="
$deepest = 0
foreach ($u in (@($people | Where-Object { $_.Manager }) | Select-Object -First 3)) {
    $chain = @($u.SamAccountName); $cur = $u; $d = 0
    while ($cur.Manager -and $d -lt 12) {
        $cur = Get-ADUser -Identity $cur.Manager -Properties Manager,Title
        $chain += ("{0}({1})" -f $cur.SamAccountName, $cur.Title)
        $d++
    }
    if ($d -gt $deepest) { $deepest = $d }
    Write-Output ("     " + ($chain -join ' -> '))
}

Write-Output ""
Write-Output "  == distinct values (a real directory has many, a fake one has few) =="
foreach ($p in @('Department','Title','Office','Company')) {
    $n = (@($people | Where-Object {$_.$p} | Select-Object -ExpandProperty $p -Unique)).Count
    Write-Output ("     distinct {0,-12} {1}" -f $p, $n)
}
$mailDup = @($people | Where-Object {$_.EmailAddress} | Group-Object EmailAddress | Where-Object {$_.Count -gt 1}).Count
Write-Output ("     duplicate email addresses: {0}" -f $mailDup)

Write-Output ""
Write-Output "  == GATE =="
$c1 = $pct['Department'] -ge 95
$c2 = $pct['Title'] -ge 90 -and $pct['Title'] -lt 100      # deliberate gaps: NOT 100%
$c3 = $pct['Manager'] -ge 90 -and $pct['Manager'] -lt 100
$c4 = $deepest -ge 2
$c5 = $mailDup -eq 0
Write-Output ("     [{0}] Department >=95%                      ({1:N1}%)" -f $(if($c1){'PASS'}else{'FAIL'}), $pct['Department'])
Write-Output ("     [{0}] Title 90-99.9% (gaps are deliberate)  ({1:N1}%)" -f $(if($c2){'PASS'}else{'FAIL'}), $pct['Title'])
Write-Output ("     [{0}] Manager 90-99.9%                      ({1:N1}%)" -f $(if($c3){'PASS'}else{'FAIL'}), $pct['Manager'])
Write-Output ("     [{0}] org chart depth >=2 levels            (depth {1})" -f $(if($c4){'PASS'}else{'FAIL'}), $deepest)
Write-Output ("     [{0}] no duplicate email addresses          ({1} dups)" -f $(if($c5){'PASS'}else{'FAIL'}), $mailDup)
Write-Output ("     OVERALL: {0}" -f $(if($c1-and$c2-and$c3-and$c4-and$c5){'PASS'}else{'FAIL'}))
