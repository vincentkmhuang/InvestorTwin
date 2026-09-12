$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$Helper = Join-Path $RepoRoot 'scripts\news-collect-run-id.py'
$Adapters = @(
  (Join-Path $RepoRoot 'scripts\collect-cna-finance-rss.py'),
  (Join-Path $RepoRoot 'scripts\collect-fsc-press-rss.py'),
  (Join-Path $RepoRoot 'scripts\collect-twse-news-openapi.py'),
  (Join-Path $RepoRoot 'scripts\collect-mops-material-openapi.py')
)
$FixtureCna = Join-Path $PSScriptRoot 'fixtures\p2-014-cna-finance-rss.xml'
$FixtureFsc = Join-Path $PSScriptRoot 'fixtures\p2-015-fsc-press-rss.xml'
$FixtureTwse = Join-Path $PSScriptRoot 'fixtures\p2-016-twse-news-openapi.json'
$FixtureMops = Join-Path $PSScriptRoot 'fixtures\p2-017-mops-material-openapi.json'
$Store = Join-Path $RepoRoot 'tmp\p2-020a-runid-store'

$script:Results = New-Object System.Collections.Generic.List[object]
function Add-TestResult($id, $passed, $details) {
  if ($passed) { $status = 'PASS' } else { $status = 'FAIL' }
  $script:Results.Add([PSCustomObject]@{ Id = $id; Status = $status; Details = $details })
  Write-Output ("{0}: {1}" -f $id, $status)
  if ($details) { Write-Output $details }
}

function Invoke-Py {
  param([string]$Py, [string[]]$ArgList)
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  $out = & python $Py @ArgList 2>&1 | Out-String
  $code = $LASTEXITCODE
  $ErrorActionPreference = $prev
  return [PSCustomObject]@{ ExitCode = $code; Output = $out }
}

foreach ($p in (@($Helper) + $Adapters + @($FixtureCna, $FixtureFsc, $FixtureTwse, $FixtureMops))) {
  if (-not (Test-Path -LiteralPath $p)) { throw "Missing: $p" }
}

# --- 1) Same-second / same-when uniqueness via shared helper ---
$uniqOut = & python -c @"
import importlib.util, sys
from datetime import datetime, timezone
from pathlib import Path
root = Path(r'$RepoRoot')
path = root / 'scripts' / 'news-collect-run-id.py'
spec = importlib.util.spec_from_file_location('news_collect_run_id', path)
mod = importlib.util.module_from_spec(spec)
sys.modules['news_collect_run_id'] = mod
spec.loader.exec_module(mod)
when = datetime(2026, 9, 12, 15, 24, 13, tzinfo=timezone.utc)
ids = [mod.make_run_id(when) for _ in range(2)]
print('IDS', ids[0], ids[1])
print('UNIQUE', ids[0] != ids[1])
print('FMT_OK', all(i.startswith('run-20260912T152413') and 'Z-' in i for i in ids))
"@
Add-TestResult 'TEST 020A-RUNID-SAME-SECOND' ($uniqOut -match 'UNIQUE True' -and $uniqOut -match 'FMT_OK True') ($uniqOut | Out-String).Trim()

# --- 2) Four adapters share sys.modules counter; burst unique ---
$burstOut = & python -c @"
import importlib.util, sys, os
from pathlib import Path
root = Path(r'$RepoRoot')
# Clear any prior load so this process starts clean for the test narrative
sys.modules.pop('news_collect_run_id', None)

def load_adapter(filename, modname):
    path = root / 'scripts' / filename
    spec = importlib.util.spec_from_file_location(modname, path)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m

adapters = [
    load_adapter('collect-cna-finance-rss.py', 'cna_rid'),
    load_adapter('collect-fsc-press-rss.py', 'fsc_rid'),
    load_adapter('collect-twse-news-openapi.py', 'twse_rid'),
    load_adapter('collect-mops-material-openapi.py', 'mops_rid'),
]
ids = [a.make_run_id() for a in adapters for _ in range(3)]
print('COUNT', len(ids))
print('UNIQUE', len(set(ids)) == len(ids))
print('SAMPLE', ids[:4])
print('SHARED_MOD', 'news_collect_run_id' in sys.modules)
"@
Add-TestResult 'TEST 020A-RUNID-FOUR-SOURCE-BURST' ($burstOut -match 'UNIQUE True' -and $burstOut -match 'SHARED_MOD True') ($burstOut | Out-String).Trim()

# --- 3) Fast fixture collect: four sources → four distinct run directories ---
if (Test-Path -LiteralPath $Store) { Remove-Item -LiteralPath $Store -Recurse -Force }
New-Item -ItemType Directory -Path $Store -Force | Out-Null
Copy-Item (Join-Path $RepoRoot 'data\news\schemaVersion.json') (Join-Path $Store 'schemaVersion.json') -Force
Copy-Item (Join-Path $RepoRoot 'data\news\news-object-v1.contract.json') (Join-Path $Store 'news-object-v1.contract.json') -Force
Copy-Item (Join-Path $RepoRoot 'data\news\seen.example.json') (Join-Path $Store 'seen.example.json') -Force
Copy-Item (Join-Path $RepoRoot 'data\news\pipeline-seen.example.json') (Join-Path $Store 'pipeline-seen.example.json') -Force
New-Item -ItemType Directory -Path (Join-Path $Store 'history\by-url') -Force | Out-Null
Copy-Item (Join-Path $RepoRoot 'data\news\history\by-url\index.example.json') (Join-Path $Store 'history\by-url\index.example.json') -Force
New-Item -ItemType Directory -Path (Join-Path $Store 'runs') -Force | Out-Null

$collectOut = & python -c @"
import importlib.util, json, sys
from pathlib import Path
root = Path(r'$RepoRoot')
store = Path(r'$Store')
sys.modules.pop('news_collect_run_id', None)

def load(filename, name):
    spec = importlib.util.spec_from_file_location(name, root/'scripts'/filename)
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m); return m

jobs = [
    ('collect-cna-finance-rss.py','cna', root/'tests'/'fixtures'/'p2-014-cna-finance-rss.xml'),
    ('collect-fsc-press-rss.py','fsc', root/'tests'/'fixtures'/'p2-015-fsc-press-rss.xml'),
    ('collect-twse-news-openapi.py','twse', root/'tests'/'fixtures'/'p2-016-twse-news-openapi.json'),
    ('collect-mops-material-openapi.py','mops', root/'tests'/'fixtures'/'p2-017-mops-material-openapi.json'),
]
runs = []
for file, name, fixture in jobs:
    m = load(file, name+'_collect')
    run = m.collect(fixture_path=str(fixture), store_root=str(store))
    runs.append({'source': name, 'runId': run.get('runId'), 'status': run.get('status'), 'normalized': run.get('normalizedCount')})

ids = [r['runId'] for r in runs]
dirs = [p.name for p in (store/'runs').iterdir() if p.is_dir()]
print(json.dumps({'runs': runs, 'uniqueIds': len(set(ids))==len(ids), 'dirCount': len(dirs), 'dirsMatch': set(ids)==set(dirs)}, ensure_ascii=False))
"@
$collectJson = $null
try { $collectJson = ($collectOut | ConvertFrom-Json) } catch {}
$collectOk = ($null -ne $collectJson) -and ($collectJson.uniqueIds -eq $true) -and ([int]$collectJson.dirCount -eq 4) -and ($collectJson.dirsMatch -eq $true)
Add-TestResult 'TEST 020A-RUNID-FOUR-COLLECT-DIRS' $collectOk ($collectOut | Out-String).Trim()

# --- 4) Protected engines untouched ---
$protected = @(
  'scripts/evaluate-news-intelligence.py',
  'scripts/link-news-events.py',
  'scripts/integrate-news-event-evaluation.py',
  'scripts/publish-research-candidates-handoff.py',
  'js/investment-meaning-gate.js',
  'scripts/generate-morning-brief.py',
  'data/news/sources.json'
)
$dirty = @()
foreach ($rel in $protected) {
  $diff = & git -C $RepoRoot diff --name-only -- $rel
  if ($diff) { $dirty += $rel }
}
Add-TestResult 'TEST 020A-RUNID-NO-ENGINE-EDIT' ($dirty.Count -eq 0) $(if ($dirty.Count -eq 0) { 'engines+sources clean' } else { $dirty -join ', ' })

Write-Output ''
Write-Output '=== P2-020A-FIX RUNID SUMMARY ==='
$script:Results | ForEach-Object {
  Write-Output ("{0}: {1}" -f $_.Id, $_.Status)
  if ($_.Details) { Write-Output $_.Details }
}
$failed = @($script:Results | Where-Object { $_.Status -eq 'FAIL' })
if ($failed.Count -gt 0) { exit 1 }
exit 0
