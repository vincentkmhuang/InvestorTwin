$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$Adapter = Join-Path $RepoRoot 'scripts\collect-fsc-press-rss.py'
$Contract = Join-Path $RepoRoot 'scripts\news-object-contract.py'
$FixtureRss = Join-Path $PSScriptRoot 'fixtures\p2-015-fsc-press-rss.xml'
$SampleNews = Join-Path $PSScriptRoot 'fixtures\p2-015-news-fsc-sample.json'
$ForbiddenNews = Join-Path $PSScriptRoot 'fixtures\p2-015-news-fsc-forbidden-importance.json'
$StoreA = Join-Path $RepoRoot 'tmp\p2-015-fsc-news-store-a'
$StoreB = Join-Path $RepoRoot 'tmp\p2-015-fsc-news-store-live'

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
  Copy-Item (Join-Path $RepoRoot 'data\news\schemaVersion.json') (Join-Path $Path 'schemaVersion.json') -Force
  Copy-Item (Join-Path $RepoRoot 'data\news\news-object-v1.contract.json') (Join-Path $Path 'news-object-v1.contract.json') -Force
  Copy-Item (Join-Path $RepoRoot 'data\news\seen.example.json') (Join-Path $Path 'seen.example.json') -Force
  New-Item -ItemType Directory -Path (Join-Path $Path 'history\by-url') -Force | Out-Null
  Copy-Item (Join-Path $RepoRoot 'data\news\history\by-url\index.example.json') (Join-Path $Path 'history\by-url\index.example.json') -Force
  New-Item -ItemType Directory -Path (Join-Path $Path 'runs') -Force | Out-Null
}

foreach ($path in @($Adapter, $Contract, $FixtureRss, $SampleNews, $ForbiddenNews)) {
  if (-not (Test-Path -LiteralPath $path)) { throw "Missing: $path" }
}

# --- Contract (standalone News Object fixtures) ---
$ok = Invoke-Py $Contract @('--validate-file', $SampleNews, '--require-collect-url')
Add-TestResult 'TEST 015-CONTRACT-OK' ($ok.ExitCode -eq 0) $(if ($ok.ExitCode -eq 0) { 'FSC sample News Object OK' } else { $ok.Output })

$forbid = Invoke-Py $Contract @('--validate-file', $ForbiddenNews, '--require-collect-url')
Add-TestResult 'TEST 015-CONTRACT-FORBIDDEN' ($forbid.ExitCode -ne 0) $(if ($forbid.ExitCode -ne 0) { 'importance rejected' } else { 'FAIL: importance was accepted' })

Reset-Dir $StoreA

# 1) Fixture collect
$r1 = Invoke-Py $Adapter @('--fixture', $FixtureRss, '--store-root', $StoreA)
$run1 = $null
try { $run1 = ($r1.Output | ConvertFrom-Json) } catch { }
$fixtureOk = ($r1.ExitCode -eq 0) -and ($run1 -ne $null) -and ($run1.status -eq 'ok') -and ([int]$run1.normalizedCount -ge 2)
Add-TestResult 'TEST 015-A-FIXTURE' $fixtureOk ("exit=$($r1.ExitCode); status=$($run1.status); normalized=$($run1.normalizedCount); fetched=$($run1.fetchedCount)")

$runDir1 = Join-Path $StoreA ("runs\" + $run1.runId)
$rawPath = Join-Path $runDir1 'raw\fsc-press-rss.xml'
$normDir = Join-Path $runDir1 'normalized'
$normFiles = @()
if (Test-Path -LiteralPath $normDir) {
  $normFiles = @(Get-ChildItem -LiteralPath $normDir -Filter '*.json' -File)
}
Add-TestResult 'TEST 015-A-RAW' (Test-Path -LiteralPath $rawPath) $rawPath
Add-TestResult 'TEST 015-A-NORM-COUNT' ($normFiles.Count -ge 2) ("files=$($normFiles.Count)")

# 2) Mapping + entity decode + missing-description kept + contract + forbidden fields
$mapFail = New-Object System.Collections.Generic.List[string]
$decodedUrlCount = 0
$titleFallbackCount = 0
foreach ($file in $normFiles) {
  $news = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
  if (-not $news.source) { $mapFail.Add('missing source') }
  if (-not $news.title) { $mapFail.Add('missing title') }
  if (-not $news.publishedTime) { $mapFail.Add('missing publishedTime') }
  if (-not $news.url) { $mapFail.Add('missing url') }
  if (-not $news.summary) { $mapFail.Add('missing summary') }
  if ($news.sourceId -ne 'fsc-press-rss') { $mapFail.Add('bad sourceId') }
  if ($null -ne $news.PSObject.Properties['importance'] -and $null -ne $news.importance) { $mapFail.Add('has importance') }
  if ($null -ne $news.PSObject.Properties['relevance'] -and $null -ne $news.relevance) { $mapFail.Add('has relevance') }
  if ($null -ne $news.PSObject.Properties['impact'] -and $null -ne $news.impact) { $mapFail.Add('has impact') }
  if ($null -ne $news.PSObject.Properties['researchCandidate'] -and $null -ne $news.researchCandidate) { $mapFail.Add('has researchCandidate') }
  if ($news.url -like '*&amp;*') { $mapFail.Add("url still has amp entity: $($news.url)") }
  if ($news.url -like '*&parentpath=*') { $decodedUrlCount++ }
  if ($news.title -like '*無 description*' -and $news.summary -eq $news.title) { $titleFallbackCount++ }
  # publishedTime must come from midnight GMT fixture, not invented clock time
  if ($news.publishedTime -notmatch 'T00:00:00Z$') {
    # allow either Z or if parse kept raw — fixture uses 00:00:00 GMT
    if ($news.publishedTime -notlike '*00:00:00*') { $mapFail.Add("unexpected publishedTime precision: $($news.publishedTime)") }
  }
  $cv = Invoke-Py $Contract @('--validate-file', $file.FullName, '--require-collect-url')
  if ($cv.ExitCode -ne 0) { $mapFail.Add("contract fail $($file.Name)") }
}
$titles = @($normFiles | ForEach-Object { (Get-Content $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json).title })
if (-not ($titles | Where-Object { $_ -like '*FIXTURE*' })) { $mapFail.Add('fixture title marker missing') }
if ($decodedUrlCount -lt 2) { $mapFail.Add("decoded urls=$decodedUrlCount expected>=2") }
if ($titleFallbackCount -lt 1) { $mapFail.Add('missing-description item was dropped or not title-fallback') }
Add-TestResult 'TEST 015-A-MAPPING-CONTRACT' ($mapFail.Count -eq 0) ($mapFail -join '; ')

# 3) Duplicate URL skip on second run
$beforeSeen = Get-Content -LiteralPath (Join-Path $StoreA 'seen.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$beforeUrlCount = @($beforeSeen.byUrl.PSObject.Properties).Count
$r2 = Invoke-Py $Adapter @('--fixture', $FixtureRss, '--store-root', $StoreA)
$run2 = $null
try { $run2 = ($r2.Output | ConvertFrom-Json) } catch { }
$dupOk = ($run2 -ne $null) -and ([int]$run2.normalizedCount -eq 0) -and ([int]$run2.skippedSeenCount -ge 2)
$afterSeen = Get-Content -LiteralPath (Join-Path $StoreA 'seen.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$afterUrlCount = @($afterSeen.byUrl.PSObject.Properties).Count
Add-TestResult 'TEST 015-A-DEDUP' ($dupOk -and ($afterUrlCount -eq $beforeUrlCount)) ("normalized=$($run2.normalizedCount); skipped=$($run2.skippedSeenCount); seenUrls=$afterUrlCount")

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
Add-TestResult 'TEST 015-A-NO-ENGINE-EDIT' ($dirty.Count -eq 0) $(if ($dirty.Count -eq 0) { 'protected files untouched' } else { $dirty -join ', ' })

# 5) Live RSS
Reset-Dir $StoreB
$live = Invoke-Py $Adapter @('--store-root', $StoreB)
$liveRun = $null
try { $liveRun = ($live.Output | ConvertFrom-Json) } catch { }
$liveOk = ($live.ExitCode -eq 0) -and ($liveRun -ne $null) -and ($liveRun.status -ne 'failed') -and ([int]$liveRun.normalizedCount -gt 0)
$liveDetail = if ($liveRun) {
  "status=$($liveRun.status); fetched=$($liveRun.fetchedCount); normalized=$($liveRun.normalizedCount); skippedSeen=$($liveRun.skippedSeenCount); errors=$($liveRun.errorCount)"
} else {
  $live.Output.Substring(0, [Math]::Min(800, $live.Output.Length))
}
Add-TestResult 'TEST 015-A-LIVE' $liveOk $liveDetail

if ($liveOk) {
  $liveRunDir = Join-Path $StoreB ("runs\" + $liveRun.runId)
  $liveNorm = @(Get-ChildItem -LiteralPath (Join-Path $liveRunDir 'normalized') -Filter '*.json' -File -ErrorAction SilentlyContinue)
  $liveContractFail = 0
  $ampFail = 0
  foreach ($file in ($liveNorm | Select-Object -First 8)) {
    $news = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($news.url -like '*&amp;*') { $ampFail++ }
    $cv = Invoke-Py $Contract @('--validate-file', $file.FullName, '--require-collect-url')
    if ($cv.ExitCode -ne 0) { $liveContractFail++ }
  }
  Add-TestResult 'TEST 015-A-LIVE-CONTRACT' (($liveContractFail -eq 0) -and ($ampFail -eq 0)) ("checked=$([Math]::Min(8, $liveNorm.Count)); contractFail=$liveContractFail; ampFail=$ampFail")

  # duplicate live run
  $live2 = Invoke-Py $Adapter @('--store-root', $StoreB)
  $liveRun2 = $null
  try { $liveRun2 = ($live2.Output | ConvertFrom-Json) } catch { }
  $liveDupOk = ($liveRun2 -ne $null) -and ([int]$liveRun2.normalizedCount -eq 0) -and ([int]$liveRun2.skippedSeenCount -ge 1)
  Add-TestResult 'TEST 015-A-LIVE-DEDUP' $liveDupOk ("normalized=$($liveRun2.normalizedCount); skipped=$($liveRun2.skippedSeenCount)")
} else {
  Add-TestResult 'TEST 015-A-LIVE-CONTRACT' $false 'skipped because live collect failed'
  Add-TestResult 'TEST 015-A-LIVE-DEDUP' $false 'skipped because live collect failed'
}

Write-Output ''
Write-Output '=== P2-015 FSC ADAPTER SUMMARY ==='
$script:Results | ForEach-Object {
  Write-Output ("{0}: {1}" -f $_.Id, $_.Status)
  if ($_.Details) { Write-Output $_.Details }
}
$failed = @($script:Results | Where-Object { $_.Status -ne 'PASS' })
if ($failed.Count -gt 0) { exit 1 }
exit 0
