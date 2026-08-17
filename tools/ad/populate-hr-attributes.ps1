# Runs ON the DC. Populate HR attributes + a real manager chain on the 2,446 person-like AD accounts.
#
# WHY THIS IS NEEDED: the domain was built with BadBlood (github.com/davidprowe/BadBlood), which creates
# users, groups, computers and deliberately invasive ACLs but sets NO HR attributes. Measured before this
# ran: Department/Title/Company/Office/Manager/EmailAddress/OfficePhone/City were 0/2446 - literally zero.
# An enumerable directory with no departments and no org chart is the single biggest realism gap left.
#
# VOCABULARY IS BORROWED, NOT INVENTED. corpdb.employees on sql01 already defines the workforce
# taxonomy: 9 departments, a title list, 4 offices (Chicago/Osaka/Lyon/Manchester) and the email form
# first.last<id>@range.lan. This script reuses all of it so AD and the HR database describe ONE company.
# Two deliberate departures from corpdb, both because corpdb itself is skewed:
#   - corpdb has manager_id ALL NULL, so there is no chain to copy; one is constructed here.
#   - corpdb makes 26 of 38 Sales staff "Sales Director" and Executive 5.6% of headcount. Copying that
#     inverted pyramid onto 2,446 users would look generated. A normal pyramid is used instead.
#
# BadBlood's random group names and messy permissions are left completely alone - they are the point of
# BadBlood and carry the AD-attack-path training value. This change is purely additive.
#
# IDEMPOTENT: users that already have a Department are skipped, so re-runs are cheap and safe.
$ErrorActionPreference = 'Stop'
Import-Module ActiveDirectory -EA Stop

$COMPANY   = '<COMPANY_NAME>'   # NEW convention - nothing in the estate defined a company name.
$MAILDOMAIN= 'range.lan'               # matches corpdb.employees.email
$SEED      = 20260817
$rng       = [System.Random]::new($SEED)

$startUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
Write-Output "  START_UTC=$startUtc"

# ---- weighted pick helper (deterministic given the seed)
function Pick($table) {
    $total = ($table.Values | Measure-Object -Sum).Sum
    $r = $rng.Next(0, $total)
    $acc = 0
    foreach ($k in ($table.Keys | Sort-Object)) {
        $acc += $table[$k]
        if ($r -lt $acc) { return $k }
    }
    return ($table.Keys | Sort-Object | Select-Object -Last 1)
}

# Department mix: corpdb's vocabulary, but plausible enterprise proportions (corpdb's Executive at 5.6%
# would mean 137 executives out of 2,446).
$DEPTS = @{ 'Sales'=20; 'Engineering'=18; 'Operations'=18; 'IT'=13; 'Finance'=11;
            'Marketing'=8; 'HR'=7; 'Legal'=4; 'Executive'=1 }
# Chicago reads as HQ given corpdb's distribution.
$OFFICES = @{ 'Chicago'=45; 'Manchester'=22; 'Lyon'=18; 'Osaka'=15 }
# Site dial-in prefixes, so a phone number implies a site the way a real DID range does.
$PHONE = @{ 'Chicago'='+1 312 555'; 'Manchester'='+44 161 496'; 'Lyon'='+33 4 72 40'; 'Osaka'='+81 6 6130' }
# Seniority pyramid. L1 IC heavy, one VP tier at the top.
$LEVELS = @{ 1=62; 2=25; 3=9; 4=3; 5=1 }

$TITLES = @{
  'IT'          = @{1=@('Help Desk Technician','Desktop Support Technician');2=@('Systems Administrator','Security Analyst');3=@('IT Manager');4=@('IT Director');5=@('VP Information Technology')}
  'Sales'       = @{1=@('Account Executive','Inside Sales Representative');2=@('Senior Account Executive');3=@('Sales Manager');4=@('Sales Director');5=@('VP Sales')}
  'Engineering' = @{1=@('Software Engineer','QA Analyst');2=@('Senior Engineer');3=@('Engineering Manager');4=@('Engineering Director');5=@('VP Engineering')}
  'Operations'  = @{1=@('Logistics Coordinator','Warehouse Associate');2=@('Senior Logistics Coordinator');3=@('Operations Manager');4=@('Operations Director');5=@('VP Operations')}
  'Finance'     = @{1=@('Accountant','Accounts Payable Clerk');2=@('Financial Analyst');3=@('Finance Manager');4=@('Controller');5=@('Chief Financial Officer')}
  'Marketing'   = @{1=@('Marketing Specialist');2=@('Senior Marketing Specialist');3=@('Marketing Manager');4=@('Marketing Director');5=@('VP Marketing')}
  'HR'          = @{1=@('HR Generalist','Recruiting Coordinator');2=@('Recruiter');3=@('HR Manager');4=@('HR Director');5=@('VP People')}
  'Legal'       = @{1=@('Paralegal');2=@('Counsel');3=@('Senior Counsel');4=@('Associate General Counsel');5=@('General Counsel')}
  'Executive'   = @{1=@('Executive Assistant');2=@('Chief of Staff');3=@('Chief of Staff');4=@('Chief Operating Officer');5=@('Chief Executive Officer')}
}

# Real directories are NOT 100% complete - uniform completeness is itself a generated-data tell.
# These fractions leave believable gaps.
$MISS_PHONE = 7   # percent with no OfficePhone
$MISS_MGR   = 4   # percent with no Manager (vacancies, contractors)
$MISS_TITLE = 3   # percent with no Title

Write-Output "  loading users..."
$all = Get-ADUser -Filter * -Properties Department,Title,GivenName,Surname,servicePrincipalName -ResultSetSize $null
$people = @($all | Where-Object {
    -not $_.servicePrincipalName -and
    $_.SamAccountName -notin @('Administrator','Guest','krbtgt','DefaultAccount')
} | Sort-Object SamAccountName)   # sorted => deterministic assignment given the seed

$todo = @($people | Where-Object { -not $_.Department })
Write-Output ("  person-like={0}  already populated={1}  to populate={2}" -f $people.Count, ($people.Count-$todo.Count), $todo.Count)
if ($todo.Count -eq 0) { Write-Output "  nothing to do"; exit 0 }

# ---- pass 1: decide everything in memory (no writes yet)
$plan = @{}
$i = 0
foreach ($u in $todo) {
    $i++
    $dept = Pick $DEPTS
    $off  = Pick $OFFICES
    $lvl  = [int](Pick $LEVELS)
    if ($dept -eq 'Executive') { $lvl = @(1,4,5)[$rng.Next(0,3)] }   # exec dept is senior by nature

    $tl = $TITLES[$dept][$lvl]
    $title = $tl[$rng.Next(0,$tl.Count)]

    # Names: prefer real AD name attributes, fall back to the SamAccountName convention FIRST_LAST.
    $fn = $u.GivenName; $ln = $u.Surname
    if (-not $fn -or -not $ln) {
        $parts = $u.SamAccountName -split '[_.\-]'
        if ($parts.Count -ge 2) { $fn = $parts[0]; $ln = $parts[1] } else { $fn = $u.SamAccountName; $ln = 'user' }
    }
    $fnc = ($fn -replace '[^A-Za-z]','').ToLower(); $lnc = ($ln -replace '[^A-Za-z]','').ToLower()
    if (-not $fnc) { $fnc = 'user' }; if (-not $lnc) { $lnc = "u$i" }

    $plan[$u.DistinguishedName] = @{
        Sam=$u.SamAccountName; Dept=$dept; Office=$off; Level=$lvl; Title=$title
        Mail  = "$fnc.$lnc$i@$MAILDOMAIN"                       # id suffix mirrors corpdb's form
        Phone = "$($PHONE[$off]) $('{0:d4}' -f $rng.Next(1000,9999))"
        NoPhone = ($rng.Next(0,100) -lt $MISS_PHONE)
        NoMgr   = ($rng.Next(0,100) -lt $MISS_MGR)
        NoTitle = ($rng.Next(0,100) -lt $MISS_TITLE)
        Mgr = $null
    }
}

# ---- pass 2: build the management chain from the plan
# L1/L2 -> an L3 in the same department; L3 -> L4; L4 -> L5(VP); L5 -> the CEO.
$byDeptLevel = @{}
foreach ($dn in $plan.Keys) {
    $p = $plan[$dn]
    $k = "$($p.Dept)|$($p.Level)"
    if (-not $byDeptLevel.ContainsKey($k)) { $byDeptLevel[$k] = New-Object System.Collections.ArrayList }
    [void]$byDeptLevel[$k].Add($dn)
}
# Guarantee each department has at least one L3/L4/L5 to report into, promoting the first member if not.
foreach ($d in $DEPTS.Keys) {
    foreach ($lv in @(5,4,3)) {
        $k = "$d|$lv"
        if (-not $byDeptLevel.ContainsKey($k) -or $byDeptLevel[$k].Count -eq 0) {
            $cand = @($plan.Keys | Where-Object { $plan[$_].Dept -eq $d } | Sort-Object) | Select-Object -First 1
            if ($cand) {
                $plan[$cand].Level = $lv
                $t = $TITLES[$d][$lv]; $plan[$cand].Title = $t[0]
                if (-not $byDeptLevel.ContainsKey($k)) { $byDeptLevel[$k] = New-Object System.Collections.ArrayList }
                [void]$byDeptLevel[$k].Add($cand)
            }
        }
    }
}
$ceo = @($byDeptLevel['Executive|5']) | Select-Object -First 1

function PickFrom($list) { if (-not $list -or $list.Count -eq 0) { return $null }; return $list[$rng.Next(0,$list.Count)] }

$mgrAssigned = 0
foreach ($dn in ($plan.Keys | Sort-Object)) {
    $p = $plan[$dn]
    if ($p.NoMgr) { continue }
    $target = switch ($p.Level) {
        1 { PickFrom $byDeptLevel["$($p.Dept)|3"] }
        2 { PickFrom $byDeptLevel["$($p.Dept)|3"] }
        3 { PickFrom $byDeptLevel["$($p.Dept)|4"] }
        4 { PickFrom $byDeptLevel["$($p.Dept)|5"] }
        5 { $ceo }
    }
    if ($target -and $target -ne $dn) { $p.Mgr = $target; $mgrAssigned++ }
}
Write-Output ("  planned: {0} users, {1} with a manager, CEO={2}" -f $plan.Count, $mgrAssigned, $(if($ceo){$plan[$ceo].Sam}else{'none'}))

# ---- pass 3: write, PACED.
# 2,446 modifications emit a 4738 each. Pacing keeps it from looking like a single mass-modification
# burst and keeps the DC responsive; the window is printed so the spike is documented, not mysterious.
$n = 0; $errs = 0
foreach ($dn in ($plan.Keys | Sort-Object)) {
    $p = $plan[$dn]
    $repl = @{ department=$p.Dept; company=$COMPANY; physicalDeliveryOfficeName=$p.Office
               l=$p.Office; mail=$p.Mail }
    if (-not $p.NoTitle) { $repl['title'] = $p.Title }
    if (-not $p.NoPhone) { $repl['telephoneNumber'] = $p.Phone }
    try {
        Set-ADUser -Identity $dn -Replace $repl -EA Stop
        if ($p.Mgr) { Set-ADUser -Identity $dn -Manager $p.Mgr -EA Stop }
        $n++
    } catch { $errs++; if ($errs -le 5) { Write-Output ("    ERR {0}: {1}" -f $p.Sam, $_.Exception.Message) } }
    if ($n % 150 -eq 0) { Write-Output ("    ... {0}/{1}" -f $n, $plan.Count); Start-Sleep -Milliseconds 800 }
}
$endUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
Write-Output ("  wrote={0}  errors={1}" -f $n, $errs)
Write-Output "  END_UTC=$endUtc"
