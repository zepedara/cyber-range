# Runs ON the DC. Add the missing audit ACE so user attribute writes generate 5136.
#
# ESTABLISHED BY MEASUREMENT, not assumption:
#   - subcategory "Directory Service Changes" = Success (enabled this session; NOT GPO-managed, so it
#     persists - LAB-Baseline-Audit's audit.csv defines 11 subcategories and this is not one of them)
#   - the only inheritable audit ACEs are Microsoft's DEFAULTS scoped to gPLink/gPOptions
#     (f30e3bbe/f30e3bbf) on organizationalUnit (bf967aa5) - irrelevant to user attributes
#   - the broad WriteProperty ACE on the domain root has inheritance=None, so it covers the domain
#     object ONLY
#   - a real write with the subcategory ON produced 5136=0, confirming the SACL is the missing half
#
# SCOPE: Everyone / WriteProperty / Success / Descendents, inheritedObjectType = user class
# (bf967aba-0de6-11d0-a285-00aa003049e2). This is an AUDITING change only - it grants no access and
# alters no permissions.
#
# REVERT (single command, documented so this is never a one-way door):
#   $d=(Get-ADDomain).DistinguishedName; $a=Get-Acl "AD:$d" -Audit
#   $a.RemoveAuditRule($ace)  # or: remove via ADUC > domain > Security > Advanced > Auditing
#   Set-Acl -Path "AD:$d" -AclObject $a
#
# VOLUME RISK, stated up front: system writes to lastLogon / logonCount / badPwdCount / pwdLastSet also
# fire 5136, and this estate already runs ~643k docs/hour. The rate is therefore MEASURED below and the
# revert is one command if it proves excessive.
$ErrorActionPreference = 'Stop'
Import-Module ActiveDirectory -EA Stop

$dom  = (Get-ADDomain).DistinguishedName
$USER_CLASS = [guid]'bf967aba-0de6-11d0-a285-00aa003049e2'

$acl = Get-Acl -Path "AD:$dom" -Audit
$before = @($acl.GetAuditRules($true,$true,[System.Security.Principal.NTAccount])).Count
Write-Output ("  audit ACEs before: {0}" -f $before)

# Idempotency: do not stack duplicates across re-runs.
$exists = @($acl.GetAuditRules($true,$true,[System.Security.Principal.NTAccount]) | Where-Object {
    "$($_.IdentityReference)" -match 'Everyone' -and
    $_.InheritedObjectType -eq $USER_CLASS -and
    $_.ActiveDirectoryRights -band [System.DirectoryServices.ActiveDirectoryRights]::WriteProperty
})
if ($exists.Count -gt 0) {
    Write-Output "  ACE already present - skipping add"
} else {
    $ace = New-Object System.DirectoryServices.ActiveDirectoryAuditRule(
        (New-Object System.Security.Principal.NTAccount('Everyone')),
        [System.DirectoryServices.ActiveDirectoryRights]::WriteProperty,
        [System.Security.AccessControl.AuditFlags]::Success,
        [System.DirectoryServices.ActiveDirectorySecurityInheritance]::Descendents,
        $USER_CLASS)
    $acl.AddAuditRule($ace)
    Set-Acl -Path "AD:$dom" -AclObject $acl
    Write-Output "  ACE added: Everyone / WriteProperty / Success / Descendents / user class"
}

$acl2 = Get-Acl -Path "AD:$dom" -Audit
Write-Output ("  audit ACEs after: {0}" -f @($acl2.GetAuditRules($true,$true,[System.Security.Principal.NTAccount])).Count)

# ---- prove it on a real write
Write-Output ""
Write-Output "  == live test =="
Start-Sleep -Seconds 5
$probe = Get-ADUser -Filter { info -eq 'range-active-workforce' } -ResultSetSize 1
$t0 = Get-Date
$stamp = 'sacl-probe-' + (Get-Date).ToUniversalTime().ToString('HHmmss')
Set-ADUser -Identity $probe.DistinguishedName -Replace @{ description = $stamp } -EA Stop
Write-Output ("     wrote {0} on {1}" -f $stamp, $probe.SamAccountName)
Start-Sleep -Seconds 15

$ev = @(Get-WinEvent -FilterHashtable @{LogName='Security'; Id=5136; StartTime=$t0} -EA SilentlyContinue)
Write-Output ("     5136 since the write: {0}" -f $ev.Count)
foreach ($e in ($ev | Select-Object -First 6)) {
    $x=[xml]$e.ToXml(); $d=@{}; foreach($n in $x.Event.EventData.Data){$d[$n.Name]=$n.'#text'}
    Write-Output ("       attr={0,-22} op={1,-14} val={2}" -f $d['AttributeLDAPDisplayName'], $d['OperationType'], $d['AttributeValue'])
}

# ---- volume: how fast is 5136 arriving overall?
Write-Output ""
Write-Output "  == volume check =="
Start-Sleep -Seconds 45
$w = (Get-Date).AddMinutes(-2)
$n2 = @(Get-WinEvent -FilterHashtable @{LogName='Security'; Id=5136; StartTime=$w} -EA SilentlyContinue).Count
Write-Output ("     5136 in the last 2 minutes: {0}  => ~{1:N0}/hour projected" -f $n2, ($n2*30))
$top = @(Get-WinEvent -FilterHashtable @{LogName='Security'; Id=5136; StartTime=$w} -EA SilentlyContinue) |
  ForEach-Object { $x=[xml]$_.ToXml(); ($x.Event.EventData.Data | Where-Object {$_.Name -eq 'AttributeLDAPDisplayName'}).'#text' } |
  Group-Object | Sort-Object Count -Desc | Select-Object -First 8
foreach ($t in $top) { Write-Output ("       {0,-26} {1}" -f $t.Name, $t.Count) }

Write-Output ""
Write-Output "  == GATE =="
Write-Output ("     [{0}] a user attribute write now produces 5136 ({1} events)" -f $(if($ev.Count -ge 1){'PASS'}else{'FAIL'}), $ev.Count)
