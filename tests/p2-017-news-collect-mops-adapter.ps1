$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$Adapter = Join-Path $RepoRoot 'scripts\collect-mops-material-openapi.py'
$Pipeline = Join-Path $RepoRoot 'scripts\collect-news.py'
$Contract = Join-Path $RepoRoot 'scripts\news-object-contract.py'
$FixtureJson = Join-Path $PSScriptRoot 'fixtures\p2-017-mops-material-openapi.json'
$SampleNews = Join-Path $PSScriptRoot 'fixtures\p2-017-news-mops-sample.json'
$ForbiddenNews = Join-Path $PSScriptRoot 'fixtures\p2-017-news-mops-forbidden-importance.json'
$StoreA = Join-Path $RepoRoot 'tmp\p2-017-mops-news-store-a'
$StoreLive = Join-Path $RepoRoot 'tmp\p2-017-mops-news-store-live'
$StoreDispatch = Join-Path $RepoRoot 'tmp\p2-017-mops-dispatch-store'

$script:Results = New-Object System.Collections.Generic.List[object]
function Add-TestResult($id, $passed, $details) {
  # IMPORTANT: in PowerShell, ($true -eq 'UNKNOWN') is True because non-empty strings coerce to True.
  # Check UNKNOWN before boolean truthiness.
  if ("$passed" -eq 'UNKNOWN') {
    $status = 'UNKNOWN'
  } elseif ($passed) {
    $status = 'PASS'
  } else {
    $status = 'FAIL'
  }
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

function Reset-Store([string]$Path, [switch]$EnableMopsOnly) {
  if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Recurse -Force }
  New-Item -ItemType Directory -Path $Path -Force | Out-Null
  Copy-Item (Join-Path $RepoRoot 'data\news\schemaVersion.json') (Join-Path $Path 'schemaVersion.json') -Force
  Copy-Item (Join-Path $RepoRoot 'data\news\news-object-v1.contract.json') (Join-Path $Path 'news-object-v1.contract.json') -Force
  Copy-Item (Join-Path $RepoRoot 'data\news\seen.example.json') (Join-Path $Path 'seen.example.json') -Force
  Copy-Item (Join-Path $RepoRoot 'data\news\pipeline-seen.example.json') (Join-Path $Path 'pipeline-seen.example.json') -Force
  New-Item -ItemType Directory -Path (Join-Path $Path 'history\by-url') -Force | Out-Null
  Copy-Item (Join-Path $RepoRoot 'data\news\history\by-url\index.example.json') (Join-Path $Path 'history\by-url\index.example.json') -Force
  New-Item -ItemType Directory -Path (Join-Path $Path 'runs') -Force | Out-Null
  if ($EnableMopsOnly) {
    $json = @'
{
  "schemaVersion": "1.0",
  "description": "tmp p2-017 MOPS-only dispatch store",
  "sources": [
    {
      "sourceId": "mops-material-openapi",
      "label": "MOPS 重大訊息 OpenAPI",
      "enabled": true,
      "adapter": "collect-mops-material-openapi.py",
      "feedUrl": "https://openapi.twse.com.tw/v1/opendata/t187ap04_L"
    }
  ]
}
'@
    Set-Content -LiteralPath (Join-Path $Path 'sources.json') -Value $json -Encoding utf8
  } else {
    Copy-Item (Join-Path $RepoRoot 'data\news\sources.json') (Join-Path $Path 'sources.json') -Force
  }
}

foreach ($path in @($Adapter, $Pipeline, $Contract, $FixtureJson, $SampleNews, $ForbiddenNews)) {
  if (-not (Test-Path -LiteralPath $path)) { throw "Missing: $path" }
}

# Contract fixtures
$ok = Invoke-Py $Contract @('--validate-file', $SampleNews, '--require-collect-url')
Add-TestResult 'TEST 017-CONTRACT-OK' ($ok.ExitCode -eq 0) $(if ($ok.ExitCode -eq 0) { 'MOPS sample News Object OK' } else { $ok.Output })

$forbid = Invoke-Py $Contract @('--validate-file', $ForbiddenNews, '--require-collect-url')
Add-TestResult 'TEST 017-CONTRACT-FORBIDDEN' ($forbid.ExitCode -ne 0) $(if ($forbid.ExitCode -ne 0) { 'importance rejected' } else { 'FAIL: importance accepted' })

# Fixture collect
Reset-Store $StoreA
$r1 = Invoke-Py $Adapter @('--fixture', $FixtureJson, '--store-root', $StoreA)
$run1 = $null
try { $run1 = ($r1.Output | ConvertFrom-Json) } catch {}
$fixtureOk = ($r1.ExitCode -eq 0) -and ($run1 -ne $null) -and ($run1.status -eq 'ok') -and ([int]$run1.normalizedCount -ge 2)
Add-TestResult 'TEST 017-A-FIXTURE' $fixtureOk ("exit=$($r1.ExitCode); status=$($run1.status); normalized=$($run1.normalizedCount); listed=$($run1.counts.listed); otc=$($run1.counts.otc)")

$runDir1 = Join-Path $StoreA ("runs\" + $run1.runId)
$normDir = Join-Path $runDir1 'normalized'
$normFiles = @()
if (Test-Path -LiteralPath $normDir) { $normFiles = @(Get-ChildItem -LiteralPath $normDir -Filter '*.json' -File) }

$mapFail = New-Object System.Collections.Generic.List[string]
$listedOk = $false
$otcOk = $false
$identityNoteOk = ($run1.urlCompositionRule -like '*identity/dedup*') -and ($run1.urlCompositionRule -like '*NOT an official*')
if (-not $identityNoteOk) { $mapFail.Add('run.json missing identity URL policy note') }

foreach ($file in $normFiles) {
  $news = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
  if ($news.sourceId -ne 'mops-material-openapi') { $mapFail.Add('bad sourceId') }
  if (-not ("$($news.source)" -like 'MOPS*')) { $mapFail.Add("bad source=$($news.source)") }
  if ($null -ne $news.eventRef) { $mapFail.Add('eventRef must be null') }
  if ($null -ne $news.PSObject.Properties['importance'] -and $null -ne $news.importance) { $mapFail.Add('has importance') }
  if ($null -ne $news.PSObject.Properties['relevance'] -and $null -ne $news.relevance) { $mapFail.Add('has relevance') }
  if ($null -ne $news.PSObject.Properties['impact'] -and $null -ne $news.impact) { $mapFail.Add('has impact') }
  if ($null -ne $news.PSObject.Properties['researchCandidate'] -and $null -ne $news.researchCandidate) { $mapFail.Add('has researchCandidate') }
  if ($null -ne $news.PSObject.Properties['candidate'] -and $null -ne $news.candidate) { $mapFail.Add('has candidate') }
  if ($news.url -notlike 'https://mops.twse.com.tw/material/*') { $mapFail.Add("bad identity url $($news.url)") }
  if ($news.url -like '*/web/*' -or $news.url -like '*ajax*') { $mapFail.Add('looks like guessed SPA url') }
  # Use URL path market markers (ASCII-safe) instead of Chinese subject matching.
  if ($news.url -like '*/material/listed/1721/*') { $listedOk = $true }
  if ($news.url -like '*/material/otc/4530/*') { $otcOk = $true }
  if ("$($news.subject)" -notmatch '^\[[^\]]+\] \[[^\]]+\] \[[^\]]+\]$') {
    $mapFail.Add("bad subject shape=$($news.subject)")
  }
  if ("$($news.title)" -like '*FIXTURE*' -and "$($news.url)" -like '*/listed/*' -and $news.publishedTime -ne '2026-09-11T13:58:44Z') {
    $mapFail.Add("listed publishedTime=$($news.publishedTime)")
  }
  if ("$($news.url)" -like '*/otc/*' -and $news.publishedTime -ne '2026-09-10T07:00:04Z') {
    $mapFail.Add("otc publishedTime=$($news.publishedTime)")
  }
  if ("$($news.url)" -like '*/otc/*' -and $news.summary -ne $news.title) {
    $mapFail.Add('otc empty 說明 should fallback to title')
  }
  $cv = Invoke-Py $Contract @('--validate-file', $file.FullName, '--require-collect-url')
  if ($cv.ExitCode -ne 0) { $mapFail.Add("contract fail $($file.Name)") }
}
if (-not $listedOk) { $mapFail.Add('listed News Object missing') }
if (-not $otcOk) { $mapFail.Add('otc News Object missing') }
Add-TestResult 'TEST 017-A-LISTED-MAPPING' $listedOk 'listed subject/title/time'
Add-TestResult 'TEST 017-A-OTC-MAPPING' $otcOk 'otc subject/title/time + summary fallback'
Add-TestResult 'TEST 017-A-IDENTITY-URL' (($mapFail | Where-Object { $_ -like '*identity*' -or $_ -like '*SPA*' -or $_ -like '*bad identity*' }).Count -eq 0 -and $identityNoteOk) ($run1.urlCompositionRule)
Add-TestResult 'TEST 017-A-MAPPING-CONTRACT' ($mapFail.Count -eq 0) ($mapFail -join '; ')

# Dedup
$beforeSeen = Get-Content -LiteralPath (Join-Path $StoreA 'seen.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$beforeUrlCount = @($beforeSeen.byUrl.PSObject.Properties).Count
$r2 = Invoke-Py $Adapter @('--fixture', $FixtureJson, '--store-root', $StoreA)
$run2 = $null
try { $run2 = ($r2.Output | ConvertFrom-Json) } catch {}
$dupOk = ($run2 -ne $null) -and ([int]$run2.normalizedCount -eq 0) -and ([int]$run2.skippedSeenCount -ge 2)
$afterSeen = Get-Content -LiteralPath (Join-Path $StoreA 'seen.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$afterUrlCount = @($afterSeen.byUrl.PSObject.Properties).Count
Add-TestResult 'TEST 017-A-DEDUP' ($dupOk -and ($afterUrlCount -eq $beforeUrlCount)) ("normalized=$($run2.normalizedCount); skipped=$($run2.skippedSeenCount); seenUrls=$afterUrlCount")

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
Add-TestResult 'TEST 017-A-NO-ENGINE-EDIT' ($dirty.Count -eq 0) $(if ($dirty.Count -eq 0) { 'NI engines untouched' } else { $dirty -join ', ' })

# Dispatch
Reset-Store $StoreDispatch -EnableMopsOnly
$rd = Invoke-Py $Pipeline @('--fixture', $FixtureJson, '--store-root', $StoreDispatch)
$sum = $null
try { $sum = ($rd.Output | ConvertFrom-Json) } catch {}
$tw = $null
if ($sum -and $sum.collectRuns) {
  $tw = @($sum.collectRuns | Where-Object { $_.sourceId -eq 'mops-material-openapi' } | Select-Object -First 1)
}
$dispatchOk = ($rd.ExitCode -eq 0) -and ($null -ne $tw) -and ([int]$tw.normalizedCount -ge 2)
Add-TestResult 'TEST 017-DISPATCH' $dispatchOk ("pipelineStatus=$($sum.status); mopsNormalized=$($tw.normalizedCount)")

# Live smoke — mark UNKNOWN if unreachable (do not fake PASS)
Reset-Store $StoreLive
$live = Invoke-Py $Adapter @('--store-root', $StoreLive)
$liveRun = $null
try { $liveRun = ($live.Output | ConvertFrom-Json) } catch {}
if (($live.ExitCode -eq 0) -and ($liveRun -ne $null) -and ($liveRun.status -ne 'failed') -and ([int]$liveRun.normalizedCount -gt 0)) {
  Add-TestResult 'TEST 017-A-LIVE-LISTED' ([int]$liveRun.counts.listed -gt 0) ("listed=$($liveRun.counts.listed)")
  Add-TestResult 'TEST 017-A-LIVE-OTC' ([int]$liveRun.counts.otc -gt 0) ("otc=$($liveRun.counts.otc)")
  Add-TestResult 'TEST 017-A-LIVE' $true ("status=$($liveRun.status); fetched=$($liveRun.fetchedCount); normalized=$($liveRun.normalizedCount); listed=$($liveRun.counts.listed); otc=$($liveRun.counts.otc)")

  $liveRunDir = Join-Path $StoreLive ("runs\" + $liveRun.runId)
  $liveNorm = @(Get-ChildItem -LiteralPath (Join-Path $liveRunDir 'normalized') -Filter '*.json' -File -ErrorAction SilentlyContinue)
  $liveContractFail = 0
  $badFields = 0
  $badUrl = 0
  foreach ($file in ($liveNorm | Select-Object -First 10)) {
    $news = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($null -ne $news.eventRef) { $badFields++ }
    if ($null -ne $news.PSObject.Properties['importance'] -and $null -ne $news.importance) { $badFields++ }
    if ($news.url -notlike 'https://mops.twse.com.tw/material/*') { $badUrl++ }
    $cv = Invoke-Py $Contract @('--validate-file', $file.FullName, '--require-collect-url')
    if ($cv.ExitCode -ne 0) { $liveContractFail++ }
  }
  Add-TestResult 'TEST 017-A-LIVE-CONTRACT' (($liveContractFail -eq 0) -and ($badFields -eq 0) -and ($badUrl -eq 0)) ("checked=$([Math]::Min(10, $liveNorm.Count)); contractFail=$liveContractFail; badFields=$badFields; badUrl=$badUrl")
} else {
  $detail = if ($liveRun) { "status=$($liveRun.status); errors=$($liveRun.errorCount)" } else { $live.Output.Substring(0, [Math]::Min(500, $live.Output.Length)) }
  Add-TestResult 'TEST 017-A-LIVE-LISTED' 'UNKNOWN' $detail
  Add-TestResult 'TEST 017-A-LIVE-OTC' 'UNKNOWN' $detail
  Add-TestResult 'TEST 017-A-LIVE' 'UNKNOWN' $detail
  Add-TestResult 'TEST 017-A-LIVE-CONTRACT' 'UNKNOWN' 'skipped because live collect unavailable'
}

Write-Output ''
Write-Output '=== P2-017 MOPS ADAPTER SUMMARY ==='
$script:Results | ForEach-Object {
  Write-Output ("{0}: {1}" -f $_.Id, $_.Status)
  if ($_.Details) { Write-Output $_.Details }
}
$failed = @($script:Results | Where-Object { $_.Status -eq 'FAIL' })
if ($failed.Count -gt 0) { exit 1 }
exit 0
