$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$Bootstrap = Join-Path $RepoRoot 'scripts\bootstrap-fsc-press-seen.py'
$Adapter = Join-Path $RepoRoot 'scripts\collect-fsc-press-rss.py'
$Pipeline = Join-Path $RepoRoot 'scripts\collect-news.py'
$Contract = Join-Path $RepoRoot 'scripts\news-object-contract.py'
$FixtureBoot = Join-Path $PSScriptRoot 'fixtures\p2-018-fsc-bootstrap.xml'
$FixturePlus = Join-Path $PSScriptRoot 'fixtures\p2-018-fsc-bootstrap-plus-one.xml'
$Store = Join-Path $RepoRoot 'tmp\p2-018-fsc-bootstrap-store'
$StoreLive = Join-Path $RepoRoot 'tmp\p2-018-fsc-bootstrap-live'
$StoreEnable = Join-Path $RepoRoot 'tmp\p2-018-fsc-enable-incremental'

$script:Results = New-Object System.Collections.Generic.List[object]
function Add-TestResult($id, $passed, $details) {
  if ("$passed" -eq 'UNKNOWN') { $status = 'UNKNOWN' }
  elseif ($passed) { $status = 'PASS' }
  else { $status = 'FAIL' }
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

function Reset-Store([string]$Path, [switch]$EnableFsc) {
  if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Recurse -Force }
  New-Item -ItemType Directory -Path $Path -Force | Out-Null
  Copy-Item (Join-Path $RepoRoot 'data\news\schemaVersion.json') (Join-Path $Path 'schemaVersion.json') -Force
  Copy-Item (Join-Path $RepoRoot 'data\news\news-object-v1.contract.json') (Join-Path $Path 'news-object-v1.contract.json') -Force
  Copy-Item (Join-Path $RepoRoot 'data\news\seen.example.json') (Join-Path $Path 'seen.example.json') -Force
  Copy-Item (Join-Path $RepoRoot 'data\news\pipeline-seen.example.json') (Join-Path $Path 'pipeline-seen.example.json') -Force
  Copy-Item (Join-Path $RepoRoot 'data\news\bootstrap-state.example.json') (Join-Path $Path 'bootstrap-state.example.json') -Force
  New-Item -ItemType Directory -Path (Join-Path $Path 'history\by-url') -Force | Out-Null
  Copy-Item (Join-Path $RepoRoot 'data\news\history\by-url\index.example.json') (Join-Path $Path 'history\by-url\index.example.json') -Force
  New-Item -ItemType Directory -Path (Join-Path $Path 'runs') -Force | Out-Null
  if ($EnableFsc) {
    $json = @'
{
  "schemaVersion": "1.0",
  "description": "tmp p2-018 FSC enabled after bootstrap",
  "sources": [
    {
      "sourceId": "fsc-press-rss",
      "label": "FSC 金管會新聞稿 RSS",
      "enabled": true,
      "adapter": "collect-fsc-press-rss.py",
      "feedUrl": "https://www.fsc.gov.tw/RSS/Messages?serno=201202290009&language=chinese"
    }
  ]
}
'@
    Set-Content -LiteralPath (Join-Path $Path 'sources.json') -Value $json -Encoding utf8
  } else {
    Copy-Item (Join-Path $RepoRoot 'data\news\sources.json') (Join-Path $Path 'sources.json') -Force
  }
}

function Count-NormFiles([string]$StorePath) {
  $n = 0
  $runs = Join-Path $StorePath 'runs'
  if (-not (Test-Path -LiteralPath $runs)) { return 0 }
  Get-ChildItem -LiteralPath $runs -Directory -ErrorAction SilentlyContinue | ForEach-Object {
    $nd = Join-Path $_.FullName 'normalized'
    if (Test-Path -LiteralPath $nd) {
      $n += @(Get-ChildItem -LiteralPath $nd -Filter '*.json' -File -ErrorAction SilentlyContinue).Count
    }
  }
  return $n
}

foreach ($p in @($Bootstrap, $Adapter, $Pipeline, $Contract, $FixtureBoot, $FixturePlus)) {
  if (-not (Test-Path -LiteralPath $p)) { throw "Missing: $p" }
}

# --- 1) First bootstrap fixture ---
Reset-Store $Store
$b1 = Invoke-Py $Bootstrap @('--fixture', $FixtureBoot, '--store-root', $Store)
$boot1 = $null
try { $boot1 = ($b1.Output | ConvertFrom-Json) } catch {}
$bootOk = ($b1.ExitCode -eq 0) -and ($boot1.status -eq 'ok') -and ([int]$boot1.fetchedCount -eq 2) -and ([int]$boot1.seededCount -eq 2) -and ([int]$boot1.normalizedCount -eq 0) -and ([int]$boot1.integrateCount -eq 0) -and ($boot1.writesNormalized -eq $false) -and ($boot1.callsIntegrate -eq $false)
Add-TestResult 'TEST 018-BOOT-1' $bootOk ("fetched=$($boot1.fetchedCount); seeded=$($boot1.seededCount); normalized=$($boot1.normalizedCount); integrate=$($boot1.integrateCount)")

$seenPath = Join-Path $Store 'seen.json'
$seen = Get-Content -LiteralPath $seenPath -Raw -Encoding UTF8 | ConvertFrom-Json
$seenCount = @($seen.byUrl.PSObject.Properties).Count
Add-TestResult 'TEST 018-SEEN-WRITE' ($seenCount -eq 2) ("seenUrls=$seenCount")
Add-TestResult 'TEST 018-NO-NORM' ((Count-NormFiles $Store) -eq 0) ("normFiles=$(Count-NormFiles $Store)")
Add-TestResult 'TEST 018-STATE' (Test-Path -LiteralPath (Join-Path $Store 'bootstrap-state.json')) 'bootstrap-state.json present'

# Identity: decoded &amp; must match collect identity (no literal amp entity in seen keys)
$ampFail = 0
foreach ($prop in $seen.byUrl.PSObject.Properties) {
  if ($prop.Name -like '*&amp;*') { $ampFail++ }
  if ($prop.Name -notlike 'https://www.fsc.gov.tw/*') { $ampFail++ }
}
Add-TestResult 'TEST 018-IDENTITY' ($ampFail -eq 0) ("ampFail=$ampFail")

# --- 2) Second bootstrap same feed (idempotent) ---
$b2 = Invoke-Py $Bootstrap @('--fixture', $FixtureBoot, '--store-root', $Store)
$boot2 = $null
try { $boot2 = ($b2.Output | ConvertFrom-Json) } catch {}
$boot2Ok = ($b2.ExitCode -eq 0) -and ([int]$boot2.fetchedCount -eq 2) -and ([int]$boot2.seededCount -eq 0) -and ([int]$boot2.alreadySeenCount -eq 2) -and ([int]$boot2.normalizedCount -eq 0)
Add-TestResult 'TEST 018-BOOT-2-IDEMPOTENT' $boot2Ok ("seeded=$($boot2.seededCount); alreadySeen=$($boot2.alreadySeenCount); normalized=$($boot2.normalizedCount)")

# --- 3) Same feed collect → all skipped ---
$c1 = Invoke-Py $Adapter @('--fixture', $FixtureBoot, '--store-root', $Store)
$run1 = $null
try { $run1 = ($c1.Output | ConvertFrom-Json) } catch {}
$skipOk = ($c1.ExitCode -eq 0) -and ([int]$run1.normalizedCount -eq 0) -and ([int]$run1.skippedSeenCount -eq 2) -and ([int]$run1.fetchedCount -eq 2)
Add-TestResult 'TEST 018-COLLECT-ALL-SKIPPED' $skipOk ("fetched=$($run1.fetchedCount); skipped=$($run1.skippedSeenCount); normalized=$($run1.normalizedCount)")

# Collect may create a run dir with empty normalized — assert no news files
$normAfterSkip = Count-NormFiles $Store
Add-TestResult 'TEST 018-STILL-NO-NEWS-FILES' ($normAfterSkip -eq 0) ("normFiles=$normAfterSkip")

# --- 4) Plus-one feed → only new URL normalized ---
$c2 = Invoke-Py $Adapter @('--fixture', $FixturePlus, '--store-root', $Store)
$run2 = $null
try { $run2 = ($c2.Output | ConvertFrom-Json) } catch {}
$incOk = ($c2.ExitCode -eq 0) -and ([int]$run2.normalizedCount -eq 1) -and ([int]$run2.skippedSeenCount -eq 2) -and ([int]$run2.fetchedCount -eq 3)
Add-TestResult 'TEST 018-INCREMENTAL-ONE' $incOk ("fetched=$($run2.fetchedCount); skipped=$($run2.skippedSeenCount); normalized=$($run2.normalizedCount)")

$normFiles = @()
$runDir2 = Join-Path $Store ("runs\" + $run2.runId)
$nd2 = Join-Path $runDir2 'normalized'
if (Test-Path -LiteralPath $nd2) { $normFiles = @(Get-ChildItem -LiteralPath $nd2 -Filter '*.json' -File) }
$mapFail = New-Object System.Collections.Generic.List[string]
foreach ($file in $normFiles) {
  $news = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
  if ($news.url -notlike '*fixtureBootNEW003*') { $mapFail.Add("unexpected url $($news.url)") }
  if ($null -ne $news.eventRef) { $mapFail.Add('eventRef not null') }
  if ($null -ne $news.PSObject.Properties['importance'] -and $null -ne $news.importance) { $mapFail.Add('importance') }
  if ($null -ne $news.PSObject.Properties['relevance'] -and $null -ne $news.relevance) { $mapFail.Add('relevance') }
  if ($null -ne $news.PSObject.Properties['impact'] -and $null -ne $news.impact) { $mapFail.Add('impact') }
  if ($null -ne $news.PSObject.Properties['researchCandidate'] -and $null -ne $news.researchCandidate) { $mapFail.Add('researchCandidate') }
  if ($null -ne $news.PSObject.Properties['candidate'] -and $null -ne $news.candidate) { $mapFail.Add('candidate') }
  $cv = Invoke-Py $Contract @('--validate-file', $file.FullName, '--require-collect-url')
  if ($cv.ExitCode -ne 0) { $mapFail.Add('contract fail') }
}
Add-TestResult 'TEST 018-NEW-CONTRACT' (($normFiles.Count -eq 1) -and ($mapFail.Count -eq 0)) ($mapFail -join '; ')

# --- 5) Enable incremental via collect-news dispatch (isolated store) ---
Reset-Store $StoreEnable -EnableFsc
$be = Invoke-Py $Bootstrap @('--fixture', $FixtureBoot, '--store-root', $StoreEnable)
$bootE = $null
try { $bootE = ($be.Output | ConvertFrom-Json) } catch {}
$pe = Invoke-Py $Pipeline @('--fixture', $FixturePlus, '--store-root', $StoreEnable)
$sumE = $null
try { $sumE = ($pe.Output | ConvertFrom-Json) } catch {}
$fscRun = $null
if ($sumE -and $sumE.collectRuns) {
  $fscRun = @($sumE.collectRuns | Where-Object { $_.sourceId -eq 'fsc-press-rss' } | Select-Object -First 1)
}
# After bootstrap of 2, plus-one fixture → 1 new; integrate may run with 1 news → skipped_insufficient_news OR if only 1, that's OK — key is not integrating 2 bootstrap items
$enableOk = ($be.ExitCode -eq 0) -and ([int]$bootE.seededCount -eq 2) -and ($null -ne $fscRun) -and ([int]$fscRun.normalizedCount -eq 1) -and ([int]$fscRun.skippedSeenCount -eq 2)
Add-TestResult 'TEST 018-ENABLE-INCREMENTAL' $enableOk ("bootSeeded=$($bootE.seededCount); norm=$($fscRun.normalizedCount); skipped=$($fscRun.skippedSeenCount); pipelineStatus=$($sumE.status)")

# Pipeline must not claim it sent 2+ bootstrap historical items
$sent = 0
if ($sumE) { $sent = [int]$sumE.newsSentToIntegrate }
Add-TestResult 'TEST 018-NO-HIST-INTEGRATE' ($sent -le 1) ("newsSentToIntegrate=$sent; status=$($sumE.status)")

# --- 6) Protected diffs ---
$protected = @(
  'scripts/evaluate-news-intelligence.py',
  'scripts/link-news-events.py',
  'scripts/integrate-news-event-evaluation.py',
  'scripts/publish-research-candidates-handoff.py',
  'js/investment-meaning-gate.js',
  'scripts/generate-morning-brief.py',
  'scripts/collect-cna-finance-rss.py',
  'scripts/collect-fsc-press-rss.py',
  'scripts/collect-twse-news-openapi.py',
  'scripts/collect-mops-material-openapi.py'
)
$dirty = @()
foreach ($rel in $protected) {
  $diff = & git -C $RepoRoot diff --name-only -- $rel
  if ($diff) { $dirty += $rel }
}
Add-TestResult 'TEST 018-NO-ENGINE-EDIT' ($dirty.Count -eq 0) $(if ($dirty.Count -eq 0) { 'protected + adapters untouched' } else { $dirty -join ', ' })

# Production sources still disabled
$src = Get-Content -LiteralPath (Join-Path $RepoRoot 'data\news\sources.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$fscSrc = @($src.sources | Where-Object { $_.sourceId -eq 'fsc-press-rss' } | Select-Object -First 1)
Add-TestResult 'TEST 018-PROD-STILL-DISABLED' ($fscSrc.enabled -eq $false) ("prod enabled=$($fscSrc.enabled)")

# --- 7) Live bootstrap smoke (tmp only) ---
Reset-Store $StoreLive
$bl = Invoke-Py $Bootstrap @('--store-root', $StoreLive)
$bootL = $null
try { $bootL = ($bl.Output | ConvertFrom-Json) } catch {}
if (($bl.ExitCode -eq 0) -and ($bootL -ne $null) -and ($bootL.status -ne 'failed') -and ([int]$bootL.fetchedCount -gt 0)) {
  $liveOk = ([int]$bootL.seededCount -eq [int]$bootL.fetchedCount) -and ([int]$bootL.normalizedCount -eq 0) -and ([int]$bootL.integrateCount -eq 0) -and ((Count-NormFiles $StoreLive) -eq 0)
  Add-TestResult 'TEST 018-LIVE-BOOT' $liveOk ("fetched=$($bootL.fetchedCount); seeded=$($bootL.seededCount); normalized=$($bootL.normalizedCount); integrate=$($bootL.integrateCount); normFiles=$(Count-NormFiles $StoreLive)")

  $cl = Invoke-Py $Adapter @('--store-root', $StoreLive)
  $runL = $null
  try { $runL = ($cl.Output | ConvertFrom-Json) } catch {}
  $liveSkip = ($cl.ExitCode -eq 0) -and ([int]$runL.normalizedCount -eq 0) -and ([int]$runL.skippedSeenCount -ge 1)
  Add-TestResult 'TEST 018-LIVE-RECOLLECT-SKIP' $liveSkip ("fetched=$($runL.fetchedCount); skipped=$($runL.skippedSeenCount); normalized=$($runL.normalizedCount)")
} else {
  $detail = if ($bootL) { "status=$($bootL.status)" } else { $bl.Output.Substring(0, [Math]::Min(400, $bl.Output.Length)) }
  Add-TestResult 'TEST 018-LIVE-BOOT' 'UNKNOWN' $detail
  Add-TestResult 'TEST 018-LIVE-RECOLLECT-SKIP' 'UNKNOWN' 'skipped because live bootstrap unavailable'
}

Write-Output ''
Write-Output '=== P2-018 FSC BOOTSTRAP SUMMARY ==='
$script:Results | ForEach-Object {
  Write-Output ("{0}: {1}" -f $_.Id, $_.Status)
  if ($_.Details) { Write-Output $_.Details }
}
$failed = @($script:Results | Where-Object { $_.Status -eq 'FAIL' })
if ($failed.Count -gt 0) { exit 1 }
exit 0
