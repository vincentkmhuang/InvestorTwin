$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$Pipeline = Join-Path $RepoRoot 'scripts\collect-news.py'
$FixtureRss = Join-Path $PSScriptRoot 'fixtures\p2-014-cna-finance-rss.xml'
$Store = Join-Path $RepoRoot 'tmp\p2-014-pipeline-store'
$HandoffTmp = Join-Path $RepoRoot 'tmp\p2-014-pipeline-handoff.json'
$BriefPath = Join-Path $RepoRoot 'data\morning-brief.json'
$HandoffProd = Join-Path $RepoRoot 'data\research-candidates-handoff.json'
$MeaningPath = Join-Path $RepoRoot 'data\meaning-gate-state.json'

$script:Results = New-Object System.Collections.Generic.List[object]
function Add-TestResult($id, $passed, $details) {
  $status = if ($passed) { 'PASS' } else { 'FAIL' }
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

function Get-FileHashSafe([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return 'MISSING' }
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Reset-Store([string]$Path) {
  if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Recurse -Force }
  New-Item -ItemType Directory -Path $Path -Force | Out-Null
  Copy-Item (Join-Path $RepoRoot 'data\news\schemaVersion.json') (Join-Path $Path 'schemaVersion.json') -Force
  Copy-Item (Join-Path $RepoRoot 'data\news\news-object-v1.contract.json') (Join-Path $Path 'news-object-v1.contract.json') -Force
  Copy-Item (Join-Path $RepoRoot 'data\news\sources.json') (Join-Path $Path 'sources.json') -Force
  Copy-Item (Join-Path $RepoRoot 'data\news\seen.example.json') (Join-Path $Path 'seen.example.json') -Force
  Copy-Item (Join-Path $RepoRoot 'data\news\pipeline-seen.example.json') (Join-Path $Path 'pipeline-seen.example.json') -Force
  New-Item -ItemType Directory -Path (Join-Path $Path 'history\by-url') -Force | Out-Null
  Copy-Item (Join-Path $RepoRoot 'data\news\history\by-url\index.example.json') (Join-Path $Path 'history\by-url\index.example.json') -Force
  New-Item -ItemType Directory -Path (Join-Path $Path 'runs') -Force | Out-Null
}

foreach ($p in @($Pipeline, $FixtureRss)) {
  if (-not (Test-Path -LiteralPath $p)) { throw "Missing: $p" }
}

$briefBefore = Get-FileHashSafe $BriefPath
$handoffBefore = Get-FileHashSafe $HandoffProd
$meaningBefore = Get-FileHashSafe $MeaningPath

Reset-Store $Store
if (Test-Path -LiteralPath $HandoffTmp) { Remove-Item -LiteralPath $HandoffTmp -Force }

# A) Fixture pipeline → integrate (+ temp handoff, not production)
$r1 = Invoke-Py $Pipeline @(
  '--fixture', $FixtureRss,
  '--store-root', $Store,
  '--publish-handoff', $HandoffTmp
)
$s1 = $null
try { $s1 = ($r1.Output | ConvertFrom-Json) } catch {}
$aOk = ($r1.ExitCode -eq 0) -and ($s1.status -eq 'ok') -and ([int]$s1.newsSentToIntegrate -ge 2) -and ($null -ne $s1.integrate)
Add-TestResult 'TEST 014-P-FIXTURE' $aOk ("status=$($s1.status); sent=$($s1.newsSentToIntegrate); events=$($s1.integrate.eventCount); evals=$($s1.integrate.evaluationCount)")

$tmpHandoffOk = (Test-Path -LiteralPath $HandoffTmp)
Add-TestResult 'TEST 014-P-HANDOFF-TMP' $tmpHandoffOk 'temp handoff written'

# D) Uses existing integrate path flag + engines untouched
Add-TestResult 'TEST 014-P-USES-INTEGRATE' ([bool]$s1.usesExistingIntegrate) 'usesExistingIntegrate=true'

$protected = @(
  'scripts/evaluate-news-intelligence.py',
  'scripts/link-news-events.py',
  'scripts/integrate-news-event-evaluation.py',
  'scripts/publish-research-candidates-handoff.py',
  'js/investment-meaning-gate.js',
  'scripts/generate-morning-brief.py'
)
$dirty = @()
foreach ($rel in $protected) {
  $diff = & git -C $RepoRoot diff --name-only -- $rel
  if ($diff) { $dirty += $rel }
}
Add-TestResult 'TEST 014-P-NO-ENGINE-EDIT' ($dirty.Count -eq 0) $(if ($dirty.Count -eq 0) { 'protected files untouched' } else { $dirty -join ', ' })

# C) Duplicate: second pipeline run should not re-send same URLs
$r2 = Invoke-Py $Pipeline @(
  '--fixture', $FixtureRss,
  '--store-root', $Store,
  '--publish-handoff', $HandoffTmp
)
$s2 = $null
try { $s2 = ($r2.Output | ConvertFrom-Json) } catch {}
$dupOk = ($s2.status -eq 'skipped_no_new_news') -and ([int]$s2.newsSentToIntegrate -eq 0)
Add-TestResult 'TEST 014-P-DEDUP' $dupOk ("status=$($s2.status); sent=$($s2.newsSentToIntegrate)")

# E/F/G) Production Brief / handoff / meaning-gate unchanged (no Brief dump; no Today injection)
$briefAfter = Get-FileHashSafe $BriefPath
$handoffAfter = Get-FileHashSafe $HandoffProd
$meaningAfter = Get-FileHashSafe $MeaningPath
Add-TestResult 'TEST 014-P-BRIEF-UNCHANGED' ($briefBefore -eq $briefAfter) 'morning-brief.json hash stable'
Add-TestResult 'TEST 014-P-HANDOFF-PROD-UNCHANGED' ($handoffBefore -eq $handoffAfter) 'production handoff hash stable'
Add-TestResult 'TEST 014-P-MEANING-UNCHANGED' ($meaningBefore -eq $meaningAfter) 'meaning-gate-state hash stable'
Add-TestResult 'TEST 014-P-NO-BRIEF-WRITE' (-not [bool]$s1.writesBrief) 'pipeline writesBrief=false'

# G) Failure path: insufficient news does not publish fake candidates / does not touch Brief
$failStore = Join-Path $RepoRoot 'tmp\p2-014-pipeline-fail-store'
Reset-Store $failStore
# Seed one normalized news only via a fake run dir (no invent through adapter)
$fakeRun = 'run-fake-one-news'
$fakeDir = Join-Path $failStore ("runs\" + $fakeRun + '\normalized')
New-Item -ItemType Directory -Path $fakeDir -Force | Out-Null
$onePath = Join-Path $fakeDir 'one.json'
$oneJson = '{"source":"CNA Finance RSS","title":"[FIXTURE] single news insufficient for integrate","publishedTime":"2026-09-10T09:25:00Z","url":"https://www.cna.com.tw/news/afe/fixture-single-only.aspx","summary":"[FIXTURE] single item","subject":null,"eventRef":null,"id":"https://www.cna.com.tw/news/afe/fixture-single-only.aspx"}'
[System.IO.File]::WriteAllText($onePath, $oneJson, (New-Object System.Text.UTF8Encoding $false))
$failHandoff = Join-Path $RepoRoot 'tmp\p2-014-pipeline-fail-handoff.json'
if (Test-Path $failHandoff) { Remove-Item $failHandoff -Force }
$rFail = Invoke-Py $Pipeline @(
  '--skip-collect', '--run-id', $fakeRun,
  '--store-root', $failStore,
  '--publish-handoff', $failHandoff
)
$sFail = $null
try { $sFail = ($rFail.Output | ConvertFrom-Json) } catch {}
$failOk = ($sFail.status -eq 'skipped_insufficient_news') -and (-not (Test-Path -LiteralPath $failHandoff))
Add-TestResult 'TEST 014-P-FAIL-NO-FAKE' $failOk ("status=$($sFail.status); handoffExists=$(Test-Path $failHandoff)")
$briefAfterFail = Get-FileHashSafe $BriefPath
Add-TestResult 'TEST 014-P-FAIL-BRIEF-SAFE' ($briefBefore -eq $briefAfterFail) 'Brief unchanged after insufficient-news path'

# B) Live CNA → integrate (temp store + temp handoff; no production publish)
$liveStore = Join-Path $RepoRoot 'tmp\p2-014-pipeline-live-store'
$liveHandoff = Join-Path $RepoRoot 'tmp\p2-014-pipeline-live-handoff.json'
Reset-Store $liveStore
if (Test-Path $liveHandoff) { Remove-Item $liveHandoff -Force }
$rLive = Invoke-Py $Pipeline @('--store-root', $liveStore, '--publish-handoff', $liveHandoff)
$sLive = $null
try { $sLive = ($rLive.Output | ConvertFrom-Json) } catch {}
$liveOk = ($rLive.ExitCode -eq 0) -and ($sLive.status -eq 'ok') -and ([int]$sLive.newsSentToIntegrate -ge 2) -and ($null -ne $sLive.integrate)
Add-TestResult 'TEST 014-P-LIVE' $liveOk ("status=$($sLive.status); sent=$($sLive.newsSentToIntegrate); events=$($sLive.integrate.eventCount); candidates=$($sLive.integrate.candidateCount)")
$briefAfterLive = Get-FileHashSafe $BriefPath
$handoffAfterLive = Get-FileHashSafe $HandoffProd
Add-TestResult 'TEST 014-P-LIVE-PROD-SAFE' (($briefBefore -eq $briefAfterLive) -and ($handoffBefore -eq $handoffAfterLive)) 'live pipeline did not touch production Brief/handoff'

# Contract regression still green
$contract = Invoke-Py (Join-Path $RepoRoot 'scripts\news-object-contract.py') @('--check-store')
Add-TestResult 'TEST 014-P-CONTRACT-STORE' ($contract.ExitCode -eq 0) 'news store contract check'

Write-Output ''
Write-Output '=== P2-014 PIPELINE SUMMARY ==='
$script:Results | ForEach-Object {
  Write-Output ("{0}: {1}" -f $_.Id, $_.Status)
  if ($_.Details) { Write-Output $_.Details }
}
$failed = @($script:Results | Where-Object { $_.Status -ne 'PASS' })
if ($failed.Count -gt 0) { exit 1 }
exit 0
