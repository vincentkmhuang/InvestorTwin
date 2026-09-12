$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$ContractPy = Join-Path $RepoRoot 'scripts\news-object-contract.py'
$SampleNews = Join-Path $PSScriptRoot 'fixtures\p2-014-news-cna-sample.json'
$ForbiddenNews = Join-Path $PSScriptRoot 'fixtures\p2-014-news-cna-forbidden-importance.json'
$BadNews = Join-Path $PSScriptRoot 'fixtures\p2-001-news-malformed-missing-title.json'
$RssFixture = Join-Path $PSScriptRoot 'fixtures\p2-014-cna-finance-rss.xml'
$StoreRoot = Join-Path $RepoRoot 'data\news'

$script:Results = New-Object System.Collections.Generic.List[object]
function Add-TestResult($id, $passed, $details) {
  $status = if ($passed) { 'PASS' } else { 'FAIL' }
  $script:Results.Add([PSCustomObject]@{ Id = $id; Status = $status; Details = $details })
  Write-Output ("{0}: {1}" -f $id, $status)
  if ($details) { Write-Output $details }
}

function Invoke-PyContract {
  param([string[]]$ArgList)
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  $out = & python $ContractPy @ArgList 2>&1 | Out-String
  $code = $LASTEXITCODE
  $ErrorActionPreference = $prev
  return [PSCustomObject]@{ ExitCode = $code; Output = $out }
}

foreach ($path in @($ContractPy, $SampleNews, $ForbiddenNews, $BadNews, $RssFixture, $StoreRoot)) {
  if (-not (Test-Path -LiteralPath $path)) { throw "Missing: $path" }
}

# Store layout
$store = Invoke-PyContract @('--check-store')
Add-TestResult 'TEST 014-STORE' ($store.ExitCode -eq 0) $(if ($store.ExitCode -eq 0) { 'data/news layout OK' } else { $store.Output })

# Valid Collect News Object (reuse core validator + require url)
$ok = Invoke-PyContract @('--validate-file', $SampleNews, '--require-collect-url')
Add-TestResult 'TEST 014-NEWS-OK' ($ok.ExitCode -eq 0) $(if ($ok.ExitCode -eq 0) { 'sample CNA News Object OK' } else { $ok.Output })

# Forbidden evaluation fields must fail
$forbid = Invoke-PyContract @('--validate-file', $ForbiddenNews, '--require-collect-url')
Add-TestResult 'TEST 014-FORBIDDEN' ($forbid.ExitCode -ne 0) $(if ($forbid.ExitCode -ne 0) { 'importance rejected' } else { 'FAIL: importance was accepted' })

# Malformed (missing title) must fail — reuse existing p2-001 fixture
$bad = Invoke-PyContract @('--validate-file', $BadNews, '--require-collect-url')
Add-TestResult 'TEST 014-BAD' ($bad.ExitCode -ne 0) $(if ($bad.ExitCode -ne 0) { 'missing title rejected' } else { 'FAIL: missing title accepted' })

# RSS fixture present and looks like RSS (Adapter not run in this step)
$rssText = [System.IO.File]::ReadAllText($RssFixture, [System.Text.UTF8Encoding]::new($false))
$rssOk = ($rssText -like '*<rss*') -and ($rssText -like '*cna-fixture-20260910a001*') -and ($rssText -like '*FIXTURE*') -and ($rssText -like '*<item>*')
Add-TestResult 'TEST 014-RSS-FIXTURE' $rssOk 'offline fictional CNA-shaped RSS fixture present'

# Gitignore covers runtime news state (not formal investment data)
$gi = Join-Path $RepoRoot '.gitignore'
$giText = if (Test-Path -LiteralPath $gi) { [System.IO.File]::ReadAllText($gi) } else { '' }
$giOk = ($giText -like '*data/news/seen.json*') -and ($giText -like '*data/news/runs/run-*') -and ($giText -like '*history/by-url/index.json*')
Add-TestResult 'TEST 014-GITIGNORE' $giOk '.gitignore ignores news runtime seen/history/runs'

# Existing NI engines untouched (name-only check vs git for this step expectation)
$protected = @(
  'scripts/evaluate-news-intelligence.py',
  'scripts/link-news-events.py',
  'scripts/integrate-news-event-evaluation.py',
  'scripts/publish-research-candidates-handoff.py',
  'js/investment-meaning-gate.js'
)
$dirty = @()
foreach ($rel in $protected) {
  $diff = & git -C $RepoRoot diff --name-only -- $rel
  if ($diff) { $dirty += $rel }
}
Add-TestResult 'TEST 014-NO-ENGINE-EDIT' ($dirty.Count -eq 0) $(if ($dirty.Count -eq 0) { 'NI engines not modified in working tree' } else { ($dirty -join ', ') })

Write-Output ''
Write-Output '=== P2-014 CONTRACT SUMMARY ==='
$script:Results | ForEach-Object {
  Write-Output ("{0}: {1}" -f $_.Id, $_.Status)
  if ($_.Details) { Write-Output $_.Details }
}
$failed = @($script:Results | Where-Object { $_.Status -ne 'PASS' })
if ($failed.Count -gt 0) { exit 1 }
exit 0
