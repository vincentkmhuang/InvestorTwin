$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$Adapter = Join-Path $RepoRoot 'scripts\collect-cna-finance-rss.py'
$Contract = Join-Path $RepoRoot 'scripts\news-object-contract.py'
$FixtureRss = Join-Path $PSScriptRoot 'fixtures\p2-014-cna-finance-rss.xml'
$StoreA = Join-Path $RepoRoot 'tmp\p2-014-news-store-a'
$StoreB = Join-Path $RepoRoot 'tmp\p2-014-news-store-live'

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

function Reset-Dir([string]$Path) {
  if (Test-Path -LiteralPath $Path) {
    Remove-Item -LiteralPath $Path -Recurse -Force
  }
  New-Item -ItemType Directory -Path $Path -Force | Out-Null
  # Minimal store skeleton for adapter runtime
  $newsRoot = $Path
  Copy-Item (Join-Path $RepoRoot 'data\news\schemaVersion.json') (Join-Path $newsRoot 'schemaVersion.json') -Force
  Copy-Item (Join-Path $RepoRoot 'data\news\news-object-v1.contract.json') (Join-Path $newsRoot 'news-object-v1.contract.json') -Force
  Copy-Item (Join-Path $RepoRoot 'data\news\seen.example.json') (Join-Path $newsRoot 'seen.example.json') -Force
  New-Item -ItemType Directory -Path (Join-Path $newsRoot 'history\by-url') -Force | Out-Null
  Copy-Item (Join-Path $RepoRoot 'data\news\history\by-url\index.example.json') (Join-Path $newsRoot 'history\by-url\index.example.json') -Force
  New-Item -ItemType Directory -Path (Join-Path $newsRoot 'runs') -Force | Out-Null
}

foreach ($path in @($Adapter, $Contract, $FixtureRss)) {
  if (-not (Test-Path -LiteralPath $path)) { throw "Missing: $path" }
}

Reset-Dir $StoreA

# 1) Fixture collect
$r1 = Invoke-Py $Adapter @('--fixture', $FixtureRss, '--store-root', $StoreA)
$run1 = $null
try { $run1 = ($r1.Output | ConvertFrom-Json) } catch { }
$fixtureOk = ($r1.ExitCode -eq 0) -and ($run1 -ne $null) -and ($run1.status -eq 'ok') -and ([int]$run1.normalizedCount -ge 2)
Add-TestResult 'TEST 014-A-FIXTURE' $fixtureOk ("exit=$($r1.ExitCode); status=$($run1.status); normalized=$($run1.normalizedCount); fetched=$($run1.fetchedCount)")

$runDir1 = Join-Path $StoreA ("runs\" + $run1.runId)
$rawPath = Join-Path $runDir1 'raw\cna-finance-rss.xml'
$normDir = Join-Path $runDir1 'normalized'
$normFiles = @()
if (Test-Path -LiteralPath $normDir) {
  $normFiles = @(Get-ChildItem -LiteralPath $normDir -Filter '*.json' -File)
}
Add-TestResult 'TEST 014-A-RAW' (Test-Path -LiteralPath $rawPath) $rawPath
Add-TestResult 'TEST 014-A-NORM-COUNT' ($normFiles.Count -ge 2) ("files=$($normFiles.Count)")

# 2) Mapping + contract + forbidden fields
$mapFail = New-Object System.Collections.Generic.List[string]
foreach ($file in $normFiles) {
  $news = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
  if (-not $news.source) { $mapFail.Add('missing source') }
  if (-not $news.title) { $mapFail.Add('missing title') }
  if (-not $news.publishedTime) { $mapFail.Add('missing publishedTime') }
  if (-not $news.url) { $mapFail.Add('missing url') }
  if (-not $news.summary) { $mapFail.Add('missing summary') }
  if ($null -ne $news.PSObject.Properties['importance'] -and $null -ne $news.importance) { $mapFail.Add('has importance') }
  if ($null -ne $news.PSObject.Properties['relevance'] -and $null -ne $news.relevance) { $mapFail.Add('has relevance') }
  if ($null -ne $news.PSObject.Properties['impact'] -and $null -ne $news.impact) { $mapFail.Add('has impact') }
  if ($null -ne $news.PSObject.Properties['researchCandidate'] -and $null -ne $news.researchCandidate) { $mapFail.Add('has researchCandidate') }
  $cv = Invoke-Py $Contract @('--validate-file', $file.FullName, '--require-collect-url')
  if ($cv.ExitCode -ne 0) { $mapFail.Add("contract fail $($file.Name)") }
}
# Expect fixture titles marked FIXTURE
$titles = @($normFiles | ForEach-Object { (Get-Content $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json).title })
if (-not ($titles | Where-Object { $_ -like '*FIXTURE*' })) { $mapFail.Add('fixture title marker missing') }
Add-TestResult 'TEST 014-A-MAPPING-CONTRACT' ($mapFail.Count -eq 0) ($mapFail -join '; ')

# 3) Duplicate URL skip on second run
$beforeSeen = Get-Content -LiteralPath (Join-Path $StoreA 'seen.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$beforeUrlCount = @($beforeSeen.byUrl.PSObject.Properties).Count
$r2 = Invoke-Py $Adapter @('--fixture', $FixtureRss, '--store-root', $StoreA)
$run2 = $null
try { $run2 = ($r2.Output | ConvertFrom-Json) } catch { }
$dupOk = ($run2 -ne $null) -and ([int]$run2.normalizedCount -eq 0) -and ([int]$run2.skippedSeenCount -ge 2)
$afterSeen = Get-Content -LiteralPath (Join-Path $StoreA 'seen.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$afterUrlCount = @($afterSeen.byUrl.PSObject.Properties).Count
Add-TestResult 'TEST 014-A-DEDUP' ($dupOk -and ($afterUrlCount -eq $beforeUrlCount)) ("normalized=$($run2.normalizedCount); skipped=$($run2.skippedSeenCount); seenUrls=$afterUrlCount")

# 4) Protected engines not modified
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
Add-TestResult 'TEST 014-A-NO-ENGINE-EDIT' ($dirty.Count -eq 0) $(if ($dirty.Count -eq 0) { 'protected files untouched' } else { $dirty -join ', ' })

# 5) Live RSS (report clearly; network dependent)
Reset-Dir $StoreB
$live = Invoke-Py $Adapter @('--store-root', $StoreB)
$liveRun = $null
try { $liveRun = ($live.Output | ConvertFrom-Json) } catch { }
$liveOk = ($live.ExitCode -eq 0) -and ($liveRun -ne $null) -and ($liveRun.status -ne 'failed') -and ([int]$liveRun.normalizedCount -gt 0)
$liveDetail = if ($liveRun) {
  "status=$($liveRun.status); fetched=$($liveRun.fetchedCount); normalized=$($liveRun.normalizedCount); errors=$($liveRun.errorCount)"
} else {
  $live.Output.Substring(0, [Math]::Min(800, $live.Output.Length))
}
Add-TestResult 'TEST 014-A-LIVE' $liveOk $liveDetail

if ($liveOk) {
  $liveRunDir = Join-Path $StoreB ("runs\" + $liveRun.runId)
  $liveNorm = @(Get-ChildItem -LiteralPath (Join-Path $liveRunDir 'normalized') -Filter '*.json' -File -ErrorAction SilentlyContinue)
  $liveContractFail = 0
  foreach ($file in ($liveNorm | Select-Object -First 5)) {
    $cv = Invoke-Py $Contract @('--validate-file', $file.FullName, '--require-collect-url')
    if ($cv.ExitCode -ne 0) { $liveContractFail++ }
  }
  Add-TestResult 'TEST 014-A-LIVE-CONTRACT' ($liveContractFail -eq 0) ("checked=$([Math]::Min(5, $liveNorm.Count)); fail=$liveContractFail")
} else {
  Add-TestResult 'TEST 014-A-LIVE-CONTRACT' $false 'skipped because live collect failed'
}

Write-Output ''
Write-Output '=== P2-014 ADAPTER SUMMARY ==='
$script:Results | ForEach-Object {
  Write-Output ("{0}: {1}" -f $_.Id, $_.Status)
  if ($_.Details) { Write-Output $_.Details }
}
$failed = @($script:Results | Where-Object { $_.Status -ne 'PASS' })
# Live failure should still fail the harness so we know — user asked for live result
if ($failed.Count -gt 0) { exit 1 }
exit 0
