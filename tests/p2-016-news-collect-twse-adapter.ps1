$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$Adapter = Join-Path $RepoRoot 'scripts\collect-twse-news-openapi.py'
$Pipeline = Join-Path $RepoRoot 'scripts\collect-news.py'
$Contract = Join-Path $RepoRoot 'scripts\news-object-contract.py'
$FixtureJson = Join-Path $PSScriptRoot 'fixtures\p2-016-twse-news-openapi.json'
$SampleNews = Join-Path $PSScriptRoot 'fixtures\p2-016-news-twse-sample.json'
$ForbiddenNews = Join-Path $PSScriptRoot 'fixtures\p2-016-news-twse-forbidden-importance.json'
$StoreA = Join-Path $RepoRoot 'tmp\p2-016-twse-news-store-a'
$StoreB = Join-Path $RepoRoot 'tmp\p2-016-twse-news-store-live'
$StoreDispatch = Join-Path $RepoRoot 'tmp\p2-016-twse-dispatch-store'

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

function Reset-Store([string]$Path, [switch]$EnableTwseOnly) {
  if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Recurse -Force }
  New-Item -ItemType Directory -Path $Path -Force | Out-Null
  Copy-Item (Join-Path $RepoRoot 'data\news\schemaVersion.json') (Join-Path $Path 'schemaVersion.json') -Force
  Copy-Item (Join-Path $RepoRoot 'data\news\news-object-v1.contract.json') (Join-Path $Path 'news-object-v1.contract.json') -Force
  Copy-Item (Join-Path $RepoRoot 'data\news\seen.example.json') (Join-Path $Path 'seen.example.json') -Force
  Copy-Item (Join-Path $RepoRoot 'data\news\pipeline-seen.example.json') (Join-Path $Path 'pipeline-seen.example.json') -Force
  New-Item -ItemType Directory -Path (Join-Path $Path 'history\by-url') -Force | Out-Null
  Copy-Item (Join-Path $RepoRoot 'data\news\history\by-url\index.example.json') (Join-Path $Path 'history\by-url\index.example.json') -Force
  New-Item -ItemType Directory -Path (Join-Path $Path 'runs') -Force | Out-Null
  if ($EnableTwseOnly) {
    $sources = @{
      schemaVersion = '1.0'
      description = 'tmp p2-016 TWSE-only dispatch store'
      sources = @(
        @{
          sourceId = 'twse-news-openapi'
          label = 'TWSE 證交所新聞 OpenAPI'
          enabled = $true
          adapter = 'collect-twse-news-openapi.py'
          feedUrl = 'https://openapi.twse.com.tw/v1/news/newsList'
        }
      )
    }
    $sources | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $Path 'sources.json') -Encoding utf8
  } else {
    Copy-Item (Join-Path $RepoRoot 'data\news\sources.json') (Join-Path $Path 'sources.json') -Force
  }
}

foreach ($path in @($Adapter, $Pipeline, $Contract, $FixtureJson, $SampleNews, $ForbiddenNews)) {
  if (-not (Test-Path -LiteralPath $path)) { throw "Missing: $path" }
}

# --- Contract fixtures ---
$ok = Invoke-Py $Contract @('--validate-file', $SampleNews, '--require-collect-url')
Add-TestResult 'TEST 016-CONTRACT-OK' ($ok.ExitCode -eq 0) $(if ($ok.ExitCode -eq 0) { 'TWSE sample News Object OK' } else { $ok.Output })

$forbid = Invoke-Py $Contract @('--validate-file', $ForbiddenNews, '--require-collect-url')
Add-TestResult 'TEST 016-CONTRACT-FORBIDDEN' ($forbid.ExitCode -ne 0) $(if ($forbid.ExitCode -ne 0) { 'importance rejected' } else { 'FAIL: importance accepted' })

# --- Fixture adapter ---
Reset-Store $StoreA
$r1 = Invoke-Py $Adapter @('--fixture', $FixtureJson, '--store-root', $StoreA)
$run1 = $null
try { $run1 = ($r1.Output | ConvertFrom-Json) } catch {}
$fixtureOk = ($r1.ExitCode -eq 0) -and ($run1 -ne $null) -and ($run1.status -eq 'ok') -and ([int]$run1.normalizedCount -ge 2)
Add-TestResult 'TEST 016-A-FIXTURE' $fixtureOk ("exit=$($r1.ExitCode); status=$($run1.status); normalized=$($run1.normalizedCount); fetched=$($run1.fetchedCount)")

$runDir1 = Join-Path $StoreA ("runs\" + $run1.runId)
$rawPath = Join-Path $runDir1 'raw\twse-news-openapi.json'
$normDir = Join-Path $runDir1 'normalized'
$normFiles = @()
if (Test-Path -LiteralPath $normDir) { $normFiles = @(Get-ChildItem -LiteralPath $normDir -Filter '*.json' -File) }
Add-TestResult 'TEST 016-A-RAW' (Test-Path -LiteralPath $rawPath) $rawPath
Add-TestResult 'TEST 016-A-NORM-COUNT' ($normFiles.Count -ge 2) ("files=$($normFiles.Count)")

$mapFail = New-Object System.Collections.Generic.List[string]
foreach ($file in $normFiles) {
  $news = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
  if (-not $news.source) { $mapFail.Add('missing source') }
  if (-not $news.title) { $mapFail.Add('missing title') }
  if (-not $news.publishedTime) { $mapFail.Add('missing publishedTime') }
  if (-not $news.url) { $mapFail.Add('missing url') }
  if (-not $news.summary) { $mapFail.Add('missing summary') }
  if ($news.sourceId -ne 'twse-news-openapi') { $mapFail.Add('bad sourceId') }
  if ($null -ne $news.eventRef) { $mapFail.Add('eventRef must be null') }
  if ($null -ne $news.PSObject.Properties['importance'] -and $null -ne $news.importance) { $mapFail.Add('has importance') }
  if ($null -ne $news.PSObject.Properties['relevance'] -and $null -ne $news.relevance) { $mapFail.Add('has relevance') }
  if ($null -ne $news.PSObject.Properties['impact'] -and $null -ne $news.impact) { $mapFail.Add('has impact') }
  if ($null -ne $news.PSObject.Properties['researchCandidate'] -and $null -ne $news.researchCandidate) { $mapFail.Add('has researchCandidate') }
  if ($null -ne $news.PSObject.Properties['candidate'] -and $null -ne $news.candidate) { $mapFail.Add('has candidate') }
  if ($news.publishedTime -notlike '*T00:00:00Z') { $mapFail.Add("unexpected publishedTime=$($news.publishedTime)") }
  if ($news.title -like '*FIXTURE*' -and $news.summary -ne $news.title) { $mapFail.Add('summary should equal title when API has no body') }
  $cv = Invoke-Py $Contract @('--validate-file', $file.FullName, '--require-collect-url')
  if ($cv.ExitCode -ne 0) { $mapFail.Add("contract fail $($file.Name)") }
}
$titles = @($normFiles | ForEach-Object { (Get-Content $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json).title })
if (-not ($titles | Where-Object { $_ -like '*FIXTURE*' })) { $mapFail.Add('fixture title marker missing') }
# ROC 1150911 → 2026-09-11
$dates = @($normFiles | ForEach-Object { (Get-Content $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json).publishedTime })
if (-not ($dates | Where-Object { $_ -eq '2026-09-11T00:00:00Z' })) { $mapFail.Add('ROC date mapping missing 2026-09-11') }
Add-TestResult 'TEST 016-A-MAPPING-CONTRACT' ($mapFail.Count -eq 0) ($mapFail -join '; ')

# Dedup
$beforeSeen = Get-Content -LiteralPath (Join-Path $StoreA 'seen.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$beforeUrlCount = @($beforeSeen.byUrl.PSObject.Properties).Count
$r2 = Invoke-Py $Adapter @('--fixture', $FixtureJson, '--store-root', $StoreA)
$run2 = $null
try { $run2 = ($r2.Output | ConvertFrom-Json) } catch {}
$dupOk = ($run2 -ne $null) -and ([int]$run2.normalizedCount -eq 0) -and ([int]$run2.skippedSeenCount -ge 2)
$afterSeen = Get-Content -LiteralPath (Join-Path $StoreA 'seen.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$afterUrlCount = @($afterSeen.byUrl.PSObject.Properties).Count
Add-TestResult 'TEST 016-A-DEDUP' ($dupOk -and ($afterUrlCount -eq $beforeUrlCount)) ("normalized=$($run2.normalizedCount); skipped=$($run2.skippedSeenCount); seenUrls=$afterUrlCount")

# News Intelligence engines only (adapter runId/helper edits are not engine edits).
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
Add-TestResult 'TEST 016-A-NO-ENGINE-EDIT' ($dirty.Count -eq 0) $(if ($dirty.Count -eq 0) { 'NI engines untouched' } else { $dirty -join ', ' })

# collect-news.py dispatch (TWSE-only temp registry + fixture)
Reset-Store $StoreDispatch -EnableTwseOnly
$rd = Invoke-Py $Pipeline @('--fixture', $FixtureJson, '--store-root', $StoreDispatch)
$sum = $null
try { $sum = ($rd.Output | ConvertFrom-Json) } catch {}
$dispatchOk = ($rd.ExitCode -eq 0) -and ($sum -ne $null) -and ($null -ne $sum.collectRuns) -and (@($sum.collectRuns).Count -ge 1)
$twseRun = $null
if ($dispatchOk) {
  $twseRun = @($sum.collectRuns | Where-Object { $_.sourceId -eq 'twse-news-openapi' } | Select-Object -First 1)
  $dispatchOk = ($null -ne $twseRun) -and ([int]$twseRun.normalizedCount -ge 2)
}
# Fixture integrate may succeed (2 news) — either ok or skipped_* is fine for dispatch check; focus source ran
Add-TestResult 'TEST 016-DISPATCH' $dispatchOk ("pipelineStatus=$($sum.status); twseNormalized=$($twseRun.normalizedCount); collectRuns=$(@($sum.collectRuns).Count)")

# Live OpenAPI smoke
Reset-Store $StoreB
$live = Invoke-Py $Adapter @('--store-root', $StoreB)
$liveRun = $null
try { $liveRun = ($live.Output | ConvertFrom-Json) } catch {}
$liveOk = ($live.ExitCode -eq 0) -and ($liveRun -ne $null) -and ($liveRun.status -ne 'failed') -and ([int]$liveRun.normalizedCount -gt 0)
$liveDetail = if ($liveRun) {
  "status=$($liveRun.status); fetched=$($liveRun.fetchedCount); normalized=$($liveRun.normalizedCount); skippedSeen=$($liveRun.skippedSeenCount); errors=$($liveRun.errorCount); pagination=$($liveRun.pagination); urlRule=$($liveRun.urlCompositionRule)"
} else {
  $live.Output.Substring(0, [Math]::Min(800, $live.Output.Length))
}
Add-TestResult 'TEST 016-A-LIVE' $liveOk $liveDetail

if ($liveOk) {
  $liveRunDir = Join-Path $StoreB ("runs\" + $liveRun.runId)
  $liveNorm = @(Get-ChildItem -LiteralPath (Join-Path $liveRunDir 'normalized') -Filter '*.json' -File -ErrorAction SilentlyContinue)
  $liveContractFail = 0
  $badFields = 0
  foreach ($file in ($liveNorm | Select-Object -First 8)) {
    $news = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($null -ne $news.eventRef) { $badFields++ }
    if ($null -ne $news.PSObject.Properties['importance'] -and $null -ne $news.importance) { $badFields++ }
    $cv = Invoke-Py $Contract @('--validate-file', $file.FullName, '--require-collect-url')
    if ($cv.ExitCode -ne 0) { $liveContractFail++ }
  }
  Add-TestResult 'TEST 016-A-LIVE-CONTRACT' (($liveContractFail -eq 0) -and ($badFields -eq 0)) ("checked=$([Math]::Min(8, $liveNorm.Count)); contractFail=$liveContractFail; badFields=$badFields")

  $live2 = Invoke-Py $Adapter @('--store-root', $StoreB)
  $liveRun2 = $null
  try { $liveRun2 = ($live2.Output | ConvertFrom-Json) } catch {}
  $liveDupOk = ($liveRun2 -ne $null) -and ([int]$liveRun2.normalizedCount -eq 0) -and ([int]$liveRun2.skippedSeenCount -ge 1)
  Add-TestResult 'TEST 016-A-LIVE-DEDUP' $liveDupOk ("normalized=$($liveRun2.normalizedCount); skipped=$($liveRun2.skippedSeenCount)")
} else {
  Add-TestResult 'TEST 016-A-LIVE-CONTRACT' $false 'skipped because live collect failed'
  Add-TestResult 'TEST 016-A-LIVE-DEDUP' $false 'skipped because live collect failed'
}

Write-Output ''
Write-Output '=== P2-016 TWSE ADAPTER SUMMARY ==='
$script:Results | ForEach-Object {
  Write-Output ("{0}: {1}" -f $_.Id, $_.Status)
  if ($_.Details) { Write-Output $_.Details }
}
$failed = @($script:Results | Where-Object { $_.Status -ne 'PASS' })
if ($failed.Count -gt 0) { exit 1 }
exit 0
