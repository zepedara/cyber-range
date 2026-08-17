#!/usr/bin/env python3
"""
Runs ON cthost01. Rebuild corpdb.employees so the HR database and Active Directory describe the SAME
2,446 people, and give it a real manager hierarchy.

WHY: corpdb had 250 employees while AD has 2,446 - two different populations. An analyst therefore could
not pivot AD user -> HR record -> file-share activity, which is a core hunt skill. corpdb.manager_id was
also entirely NULL, so no org chart existed on the database side either.

SAFETY, all verified before writing:
  - information_schema.key_column_usage shows NO foreign key references employees, so a rebuild cannot
    orphan orders/invoices/customers.
  - The existing 250 rows are backed up to employees_bak_20260817 first (a real table, not a dump file).

SCHEMA CHANGE (additive): adds `sam_account_name`. Without a link column the AD<->DB join has to be made
on first+last name, which is fragile and ambiguous; a login field is also what a real HR system carries.

GENERATED BUSINESS DATA (explicitly permitted; detection content is the thing that must be retrieved):
  - hire_date: tenure is correlated with seniority, so directors and VPs are not all recent hires.
  - salary: banded by seniority and adjusted for office cost-of-living.
Deterministic under seed 20260817 so a re-run reproduces the same database.
"""
import csv, random, subprocess, sys, collections
from datetime import date, timedelta

PSV  = '/tmp/workforce.psv'
SEED = 20260817
random.seed(SEED)

def mysql(sql, db='corpdb'):
    """Run SQL inside the sql01 container. stdin is closed - incus exec would otherwise consume it."""
    p = subprocess.run(
        ['incus', 'exec', 'sql01', '--', 'mysql', '--defaults-file=/etc/mysql/debian.cnf', '-N', '-B',
         '-e', sql, db],
        stdin=subprocess.DEVNULL, capture_output=True, text=True)
    if p.returncode != 0:
        print('   SQL ERROR: %s' % p.stderr.strip()[:400]); sys.exit(1)
    return p.stdout

# ---------- read the export
rows = []
with open(PSV, encoding='utf-8-sig') as f:      # utf-8-sig strips PowerShell's BOM
    for r in csv.DictReader(f, delimiter='|'):
        if r.get('sam') and r.get('department'):
            rows.append(r)
print('   parsed %d workforce rows' % len(rows))
if len(rows) < 1000:
    print('   REFUSING: expected ~2,400 rows; the export looks wrong'); sys.exit(1)

missing_names = [r for r in rows if not r['first'].strip() or not r['last'].strip()]
print('   rows missing first/last: %d' % len(missing_names))
if missing_names:
    print('   REFUSING: names are still empty - re-run the AD name fix before loading'); sys.exit(1)

# ---------- seniority model, used for BOTH tenure and salary
SENIOR = [  # (substring, level, base salary)
    ('Chief', 5, 240000), ('VP ', 5, 195000), ('General Counsel', 5, 205000),
    ('Director', 4, 155000), ('Controller', 4, 150000), ('Associate General Counsel', 4, 160000),
    ('Manager', 3, 120000), ('Senior Counsel', 3, 135000), ('Chief of Staff', 3, 130000),
    ('Senior', 2, 105000), ('Counsel', 2, 115000),
]
def seniority(title):
    for frag, lvl, base in SENIOR:
        if frag.lower() in (title or '').lower():
            return lvl, base
    return 1, 72000

COL = {'Chicago': 1.00, 'Manchester': 0.85, 'Lyon': 0.90, 'Osaka': 0.95}
TODAY = date(2026, 8, 17)

# ---------- assign ids and generate business fields
by_sam = {}
recs = []
for i, r in enumerate(sorted(rows, key=lambda x: x['sam']), start=1):
    lvl, base = seniority(r['title'])
    # Tenure correlates with seniority: an IC may be brand new, a VP is not.
    floor_years = {1: 0, 2: 2, 3: 4, 4: 6, 5: 8}[lvl]
    span_years  = {1: 9, 2: 10, 3: 11, 4: 13, 5: 15}[lvl]
    # Skew toward recent hires for ICs (real headcount pyramids churn at the bottom).
    frac = random.random() ** (1.6 if lvl == 1 else 1.0)
    years = floor_years + frac * (span_years - floor_years)
    hire = TODAY - timedelta(days=int(years * 365.25) + random.randint(0, 300))
    if hire < date(2011, 1, 1): hire = date(2011, 1, 1) + timedelta(days=random.randint(0, 200))
    salary = base * COL.get(r['office'], 1.0) * random.uniform(0.88, 1.14)
    rec = dict(id=i, sam=r['sam'], first=r['first'].strip(), last=r['last'].strip(),
               email=r['email'].strip(), dept=r['department'].strip(), title=r['title'].strip(),
               office=r['office'].strip(), mgr_sam=(r.get('manager_sam') or '').strip(),
               hire=hire.isoformat(), salary=round(salary, 2))
    recs.append(rec); by_sam[rec['sam']] = i

resolved = sum(1 for r in recs if r['mgr_sam'] and r['mgr_sam'] in by_sam)
print('   manager_sam resolvable to an id: %d of %d' % (resolved, len(recs)))

# ---------- backup, schema, load
print('   backing up the existing table...')
mysql("DROP TABLE IF EXISTS employees_bak_20260817;")
mysql("CREATE TABLE employees_bak_20260817 AS SELECT * FROM employees;")
n_bak = mysql("SELECT COUNT(*) FROM employees_bak_20260817;").strip()
print('   employees_bak_20260817 rows: %s' % n_bak)

cols = mysql("SELECT column_name FROM information_schema.columns "
             "WHERE table_schema='corpdb' AND table_name='employees';")
if 'sam_account_name' not in cols:
    mysql("ALTER TABLE employees ADD COLUMN sam_account_name varchar(64) NULL AFTER id, "
          "ADD INDEX idx_sam (sam_account_name);")
    print('   added column sam_account_name')
else:
    print('   sam_account_name already present')

mysql("DELETE FROM employees;")

def esc(s): return (s or '').replace('\\', '\\\\').replace("'", "''")

BATCH = 200
for start in range(0, len(recs), BATCH):
    chunk = recs[start:start+BATCH]
    vals = []
    for r in chunk:
        mid = by_sam.get(r['mgr_sam'])
        vals.append("(%d,'%s','%s','%s','%s','%s','%s',%s,'%s',%.2f,'%s')" % (
            r['id'], esc(r['sam']), esc(r['first']), esc(r['last']), esc(r['email']),
            esc(r['dept']), esc(r['title']),
            (str(mid) if mid and mid != r['id'] else 'NULL'),
            r['hire'], r['salary'], esc(r['office'])))
    mysql("INSERT INTO employees (id,sam_account_name,first_name,last_name,email,department,title,"
          "manager_id,hire_date,salary,office) VALUES " + ','.join(vals) + ";")
print('   inserted %d rows' % len(recs))

# ---------- verify by re-reading the database
print()
print('   == VERIFY (read back from MySQL) ==')
tot   = int(mysql("SELECT COUNT(*) FROM employees;").strip() or 0)
mgr   = int(mysql("SELECT COUNT(*) FROM employees WHERE manager_id IS NOT NULL;").strip() or 0)
sam   = int(mysql("SELECT COUNT(*) FROM employees WHERE sam_account_name IS NOT NULL;").strip() or 0)
dupem = int(mysql("SELECT COUNT(*) FROM (SELECT email FROM employees GROUP BY email HAVING COUNT(*)>1) x;").strip() or 0)
orph  = int(mysql("SELECT COUNT(*) FROM employees e LEFT JOIN employees m ON e.manager_id=m.id "
                  "WHERE e.manager_id IS NOT NULL AND m.id IS NULL;").strip() or 0)
print('   rows=%d  with manager_id=%d  with sam=%d  dup emails=%d  orphan manager_id=%d'
      % (tot, mgr, sam, dupem, orph))
print('   departments:')
print('\n'.join('     ' + l for l in mysql(
    "SELECT department, COUNT(*) FROM employees GROUP BY department ORDER BY 2 DESC;").strip().splitlines()))
print('   tenure by seniority (mean years, proves the correlation is real):')
print('\n'.join('     ' + l for l in mysql(
    "SELECT CASE WHEN title LIKE '%Chief%' OR title LIKE 'VP %' THEN '5-exec' "
    "WHEN title LIKE '%Director%' OR title LIKE '%Controller%' THEN '4-director' "
    "WHEN title LIKE '%Manager%' THEN '3-manager' WHEN title LIKE 'Senior%' THEN '2-senior' "
    "ELSE '1-ic' END lvl, COUNT(*), ROUND(AVG(DATEDIFF('2026-08-17',hire_date)/365.25),1), "
    "ROUND(AVG(salary)) FROM employees GROUP BY lvl ORDER BY lvl DESC;").strip().splitlines()))
print('   a 3-level chain read from the DB:')
print('\n'.join('     ' + l for l in mysql(
    "SELECT e.sam_account_name, m.sam_account_name, m.title, g.sam_account_name, g.title "
    "FROM employees e JOIN employees m ON e.manager_id=m.id JOIN employees g ON m.manager_id=g.id "
    "LIMIT 3;").strip().splitlines()))

print()
print('   == GATE ==')
c1 = tot >= 2300
c2 = mgr >= tot * 0.90
c3 = sam == tot
c4 = dupem == 0
c5 = orph == 0
for ok, lbl in ((c1, 'rows >= 2300 (%d)' % tot),
                (c2, 'manager_id on >=90%% (%d)' % mgr),
                (c3, 'every row carries sam_account_name (%d/%d)' % (sam, tot)),
                (c4, 'no duplicate emails (%d)' % dupem),
                (c5, 'no orphan manager_id (%d)' % orph)):
    print('     [%s] %s' % ('PASS' if ok else 'FAIL', lbl))
print('     OVERALL: %s' % ('PASS' if all([c1,c2,c3,c4,c5]) else 'FAIL'))
