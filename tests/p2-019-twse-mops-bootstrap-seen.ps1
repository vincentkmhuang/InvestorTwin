$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$BootTwse = Join-Path $RepoRoot 'scripts\bootstrap-twse-news-seen.py'
$BootMops = Join-Path $RepoRoot 'scripts\bootstrap-mops-material-seen.py'
$AdapterTwse = Join-Path $RepoRoot 'scripts\collect-twse-news-openapi.py'
$AdapterMops = Join-Path $RepoRoot 'scripts\collect-mops-material-openapi.py'
$Contract = Join-Path $RepoRoot 'scripts\news-object-contract.py'
$FixtureTwse = Join-Path $PSScriptRoot 'fixtures\p2-016-twse-news-openapi.json'
$FixtureTwsePlus = Join-Path $PSScriptRoot 'fixtures\p2-019-twse-bootstrap-plus-one.json'
$FixtureMops = Join-Path $PSScriptRoot 'fixtures\p2-017-mops-material-openapi.json'
$FixtureMopsPlus = Join-Path $PSScriptRoot 'fixtures\p2-019-mops-bootstrap-plus-one.json'
$StoreTwse = Join-Path $RepoRoot 'tmp\p2-019-twse-bootstrap-store'
$StoreMops = Join-Path $RepoRoot 'tmp\p2-019-mops-bootstrap-store'
$StoreLiveTwse = Join-Path $RepoRoot 'tmp\p2-019-twse-bootstrap-live'
$StoreLiveMops = Join-Path $RepoRoot 'tmp\p2-019-mops-bootstrap-live'
$StorePreserve = Join-Path $RepoRoot 'tmp\p2-019-seen-preserve'

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

function Reset-Store([string]$Path) {
  if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Recurse -Force }
  New-Item -ItemType Directory -Path $Path -Force | Out-Null
  Copy-Item (Join-Path $RepoRoot 'data\news\schemaVersion.json') (Join-Path $Path 'schemaVersion.json') -Force
  Copy-Item (Join-Path $RepoRoot 'data\news\news-object-v1.contract.json') (Join-Path $Path 'news-object-v1.contract.json') -Force
  Copy-Item (Join-Path $RepoRoot 'data\news\seen.example.json') (Join-Path $Path 'seen.example.json') -Force
  Copy-Item (Join-Path $RepoRoot 'data\news\pipeline-seen.example.json') (Join-Path $Path 'pipeline-seen.example.json') -Force
  Copy-Item (Join-Path $RepoRoot 'data\news\bootstrap-state.example.json') (Join-Path $Path 'bootstrap-state.example.json') -Force
  Copy-Item (Join-Path $RepoRoot 'data\news\sources.json') (Join-Path $Path 'sources.json') -Force
  New-Item -ItemType Directory -Path (Join-Path $Path 'history\by-url') -Force | Out-Null
  Copy-Item (Join-Path $RepoRoot 'data\news\history\by-url\index.example.json') (Join-Path $Path 'history\by-url\index.example.json') -Force
  New-Item -ItemType Directory -Path (Join-Path $Path 'runs') -Force | Out-Null
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

function Get-SeenUrlCount($seen) {
  return @($seen.byUrl.PSObject.Properties).Count
}

function Test-ForbiddenFields($news) {
  $bad = New-Object System.Collections.Generic.List[string]
  foreach ($f in @('importance', 'relevance', 'impact', 'researchCandidate', 'candidate', 'stance')) {
    if ($null -ne $news.PSObject.Properties[$f] -and $null -ne $news.$f) { $bad.Add($f) }
  }
  if ($null -ne $news.eventRef) { $bad.Add('eventRef') }
  return $bad
}

foreach ($p in @($BootTwse, $BootMops, $AdapterTwse, $AdapterMops, $Contract, $FixtureTwse, $FixtureTwsePlus, $FixtureMops, $FixtureMopsPlus)) {
  if (-not (Test-Path -LiteralPath $p)) { throw "Missing: $p" }
}

# ============================================================================
# TWSE fixture bootstrap
# ============================================================================
Reset-Store $StoreTwse

# Seed fake CNA/FSC identities — must survive TWSE bootstrap
$seedSeen = @{
  schemaVersion = '1.0'
  byUrl = @{
    'https://www.cna.com.tw/news/afe/fixture-cna-preserve.aspx' = @{
      newsId = 'https://www.cna.com.tw/news/afe/fixture-cna-preserve.aspx'
      firstSeenAt = '2026-09-01T00:00:00Z'
      bootstrap = $false
    }
    'https://www.fsc.gov.tw/ch/home.jsp?id=96&dataserno=fixtureFscPreserve' = @{
      newsId = 'https://www.fsc.gov.tw/ch/home.jsp?id=96&dataserno=fixtureFscPreserve'
      firstSeenAt = '2026-09-01T00:00:00Z'
      bootstrap = $true
      bootstrapSourceId = 'fsc-press-rss'
    }
  }
  byGuid = @{}
} | ConvertTo-Json -Depth 6
Set-Content -LiteralPath (Join-Path $StoreTwse 'seen.json') -Value $seedSeen -Encoding utf8

$tb1 = Invoke-Py $BootTwse @('--fixture', $FixtureTwse, '--store-root', $StoreTwse)
$tboot1 = $null
try { $tboot1 = ($tb1.Output | ConvertFrom-Json) } catch {}
$tBootOk = ($tb1.ExitCode -eq 0) -and ($tboot1.status -eq 'ok') -and ([int]$tboot1.fetchedCount -eq 2) -and ([int]$tboot1.seededCount -eq 2) -and ([int]$tboot1.normalizedCount -eq 0) -and ([int]$tboot1.integrateCount -eq 0) -and ($tboot1.writesNormalized -eq $false) -and ($tboot1.callsIntegrate -eq $false)
Add-TestResult 'TEST 019-TWSE-BOOT-1' $tBootOk ("fetched=$($tboot1.fetchedCount); seeded=$($tboot1.seededCount); normalized=$($tboot1.normalizedCount); integrate=$($tboot1.integrateCount)")

$tSeen = Get-Content -LiteralPath (Join-Path $StoreTwse 'seen.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$tUrls = @($tSeen.byUrl.PSObject.Properties | ForEach-Object { $_.Name })
$tPreserve = ($tUrls -contains 'https://www.cna.com.tw/news/afe/fixture-cna-preserve.aspx') -and ($tUrls -contains 'https://www.fsc.gov.tw/ch/home.jsp?id=96&dataserno=fixtureFscPreserve')
$tTwseIds = @($tUrls | Where-Object { $_ -like 'https://www.twse.com.tw/*' })
Add-TestResult 'TEST 019-TWSE-PRESERVE-CNA-FSC' $tPreserve ("seenTotal=$(Get-SeenUrlCount $tSeen)")
Add-TestResult 'TEST 019-TWSE-IDENTITY' (($tTwseIds.Count -eq 2) -and ($tTwseIds | Where-Object { $_ -like '*fixture-twse-20260911a001*' }).Count -eq 1) ("twseIds=$($tTwseIds.Count)")
Add-TestResult 'TEST 019-TWSE-NO-NORM' ((Count-NormFiles $StoreTwse) -eq 0) ("normFiles=$(Count-NormFiles $StoreTwse)")
Add-TestResult 'TEST 019-TWSE-STATE' (Test-Path -LiteralPath (Join-Path $StoreTwse 'bootstrap-state.json')) 'bootstrap-state.json present'

# Identity parity: bootstrap keys == collect item_to_news urls
$parityOut = & python -c @"
import json, importlib.util
from pathlib import Path
root = Path(r'$RepoRoot')
spec = importlib.util.spec_from_file_location('twse', root / 'scripts' / 'collect-twse-news-openapi.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
payload = json.loads(Path(r'$FixtureTwse').read_text(encoding='utf-8-sig'))
items = m.parse_news_items(payload)
collect_urls = {m.item_to_news(it, '2026-09-12T00:00:00Z', 'x')['url'] for it in items}
seen = json.loads((Path(r'$StoreTwse') / 'seen.json').read_text(encoding='utf-8-sig'))
boot_urls = {u for u, meta in (seen.get('byUrl') or {}).items() if (meta or {}).get('bootstrapSourceId') == 'twse-news-openapi'}
print('OK' if collect_urls == boot_urls else f'FAIL collect={sorted(collect_urls)} boot={sorted(boot_urls)}')
"@
Add-TestResult 'TEST 019-TWSE-IDENTITY-PARITY' ($parityOut.Trim() -eq 'OK') $parityOut.Trim()

$tb2 = Invoke-Py $BootTwse @('--fixture', $FixtureTwse, '--store-root', $StoreTwse)
$tboot2 = $null
try { $tboot2 = ($tb2.Output | ConvertFrom-Json) } catch {}
$tBoot2Ok = ($tb2.ExitCode -eq 0) -and ([int]$tboot2.seededCount -eq 0) -and ([int]$tboot2.alreadySeenCount -eq 2) -and ([int]$tboot2.normalizedCount -eq 0)
Add-TestResult 'TEST 019-TWSE-BOOT-2-ALREADY' $tBoot2Ok ("seeded=$($tboot2.seededCount); alreadySeen=$($tboot2.alreadySeenCount)")

$tc1 = Invoke-Py $AdapterTwse @('--fixture', $FixtureTwse, '--store-root', $StoreTwse)
$trun1 = $null
try { $trun1 = ($tc1.Output | ConvertFrom-Json) } catch {}
$tSkipOk = ($tc1.ExitCode -eq 0) -and ([int]$trun1.normalizedCount -eq 0) -and ([int]$trun1.skippedSeenCount -eq 2)
Add-TestResult 'TEST 019-TWSE-COLLECT-SKIP' $tSkipOk ("skipped=$($trun1.skippedSeenCount); normalized=$($trun1.normalizedCount)")

$tc2 = Invoke-Py $AdapterTwse @('--fixture', $FixtureTwsePlus, '--store-root', $StoreTwse)
$trun2 = $null
try { $trun2 = ($tc2.Output | ConvertFrom-Json) } catch {}
$tIncOk = ($tc2.ExitCode -eq 0) -and ([int]$trun2.normalizedCount -eq 1) -and ([int]$trun2.skippedSeenCount -eq 2) -and ([int]$trun2.fetchedCount -eq 3)
Add-TestResult 'TEST 019-TWSE-INCREMENTAL-ONE' $tIncOk ("fetched=$($trun2.fetchedCount); skipped=$($trun2.skippedSeenCount); normalized=$($trun2.normalizedCount)")

$tNormFiles = @()
$tRunDir = Join-Path $StoreTwse ("runs\" + $trun2.runId)
$tNd = Join-Path $tRunDir 'normalized'
if (Test-Path -LiteralPath $tNd) { $tNormFiles = @(Get-ChildItem -LiteralPath $tNd -Filter '*.json' -File) }
$tMapFail = New-Object System.Collections.Generic.List[string]
foreach ($file in $tNormFiles) {
  $news = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
  if ($news.url -notlike '*fixture-twse-boot-NEW003*') { $tMapFail.Add("unexpected url $($news.url)") }
  foreach ($b in (Test-ForbiddenFields $news)) { $tMapFail.Add($b) }
  $cv = Invoke-Py $Contract @('--validate-file', $file.FullName, '--require-collect-url')
  if ($cv.ExitCode -ne 0) { $tMapFail.Add('contract fail') }
}
Add-TestResult 'TEST 019-TWSE-NEW-CONTRACT' (($tNormFiles.Count -eq 1) -and ($tMapFail.Count -eq 0)) ($tMapFail -join '; ')
Add-TestResult 'TEST 019-TWSE-FORBIDDEN-EVAL' ($tMapFail.Count -eq 0) $(if ($tMapFail.Count -eq 0) { 'no eval fields' } else { $tMapFail -join '; ' })

# ============================================================================
# MOPS fixture bootstrap
# ============================================================================
Reset-Store $StoreMops
$seedMops = @{
  schemaVersion = '1.0'
  byUrl = @{
    'https://www.cna.com.tw/news/afe/fixture-cna-preserve-mops.aspx' = @{
      newsId = 'https://www.cna.com.tw/news/afe/fixture-cna-preserve-mops.aspx'
      firstSeenAt = '2026-09-01T00:00:00Z'
    }
    'https://www.fsc.gov.tw/ch/home.jsp?id=96&dataserno=fixtureFscPreserveMops' = @{
      newsId = 'https://www.fsc.gov.tw/ch/home.jsp?id=96&dataserno=fixtureFscPreserveMops'
      firstSeenAt = '2026-09-01T00:00:00Z'
      bootstrapSourceId = 'fsc-press-rss'
    }
  }
  byGuid = @{}
} | ConvertTo-Json -Depth 6
Set-Content -LiteralPath (Join-Path $StoreMops 'seen.json') -Value $seedMops -Encoding utf8

$mb1 = Invoke-Py $BootMops @('--fixture', $FixtureMops, '--store-root', $StoreMops)
$mboot1 = $null
try { $mboot1 = ($mb1.Output | ConvertFrom-Json) } catch {}
$mBootOk = ($mb1.ExitCode -eq 0) -and ($mboot1.status -eq 'ok') -and ([int]$mboot1.fetchedCount -eq 2) -and ([int]$mboot1.seededCount -eq 2) -and ([int]$mboot1.listedCount -eq 1) -and ([int]$mboot1.otcCount -eq 1) -and ([int]$mboot1.normalizedCount -eq 0) -and ([int]$mboot1.integrateCount -eq 0)
Add-TestResult 'TEST 019-MOPS-BOOT-1' $mBootOk ("fetched=$($mboot1.fetchedCount); seeded=$($mboot1.seededCount); listed=$($mboot1.listedCount); otc=$($mboot1.otcCount); normalized=$($mboot1.normalizedCount)")

$mSeen = Get-Content -LiteralPath (Join-Path $StoreMops 'seen.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$mUrls = @($mSeen.byUrl.PSObject.Properties | ForEach-Object { $_.Name })
$mPreserve = ($mUrls -contains 'https://www.cna.com.tw/news/afe/fixture-cna-preserve-mops.aspx') -and ($mUrls -contains 'https://www.fsc.gov.tw/ch/home.jsp?id=96&dataserno=fixtureFscPreserveMops')
$mListed = @($mUrls | Where-Object { $_ -like 'https://mops.twse.com.tw/material/listed/*' })
$mOtc = @($mUrls | Where-Object { $_ -like 'https://mops.twse.com.tw/material/otc/*' })
Add-TestResult 'TEST 019-MOPS-PRESERVE-CNA-FSC' $mPreserve ("seenTotal=$(Get-SeenUrlCount $mSeen)")
Add-TestResult 'TEST 019-MOPS-LISTED-IDENTITY' ($mListed.Count -eq 1 -and $mListed[0] -like '*/listed/1721/*') ("listed=$($mListed.Count); eg=$($mListed[0])")
Add-TestResult 'TEST 019-MOPS-OTC-IDENTITY' ($mOtc.Count -eq 1 -and $mOtc[0] -like '*/otc/4530/*') ("otc=$($mOtc.Count); eg=$($mOtc[0])")
Add-TestResult 'TEST 019-MOPS-NO-NORM' ((Count-NormFiles $StoreMops) -eq 0) ("normFiles=$(Count-NormFiles $StoreMops)")

$mParityOut = & python -c @"
import json, importlib.util
from pathlib import Path
root = Path(r'$RepoRoot')
spec = importlib.util.spec_from_file_location('mops', root / 'scripts' / 'collect-mops-material-openapi.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
payload = json.loads(Path(r'$FixtureMops').read_text(encoding='utf-8-sig'))
items = m.parse_payload_items(payload)
collect_urls = {m.item_to_news(it, '2026-09-12T00:00:00Z', 'x')['url'] for it in items}
seen = json.loads((Path(r'$StoreMops') / 'seen.json').read_text(encoding='utf-8-sig'))
boot_urls = {u for u, meta in (seen.get('byUrl') or {}).items() if (meta or {}).get('bootstrapSourceId') == 'mops-material-openapi'}
print('OK' if collect_urls == boot_urls else f'FAIL collect={sorted(collect_urls)} boot={sorted(boot_urls)}')
"@
Add-TestResult 'TEST 019-MOPS-IDENTITY-PARITY' ($mParityOut.Trim() -eq 'OK') $mParityOut.Trim()

$mb2 = Invoke-Py $BootMops @('--fixture', $FixtureMops, '--store-root', $StoreMops)
$mboot2 = $null
try { $mboot2 = ($mb2.Output | ConvertFrom-Json) } catch {}
$mBoot2Ok = ($mb2.ExitCode -eq 0) -and ([int]$mboot2.seededCount -eq 0) -and ([int]$mboot2.alreadySeenCount -eq 2) -and ([int]$mboot2.normalizedCount -eq 0)
Add-TestResult 'TEST 019-MOPS-BOOT-2-ALREADY' $mBoot2Ok ("seeded=$($mboot2.seededCount); alreadySeen=$($mboot2.alreadySeenCount)")

$mc1 = Invoke-Py $AdapterMops @('--fixture', $FixtureMops, '--store-root', $StoreMops)
$mrun1 = $null
try { $mrun1 = ($mc1.Output | ConvertFrom-Json) } catch {}
$mSkipOk = ($mc1.ExitCode -eq 0) -and ([int]$mrun1.normalizedCount -eq 0) -and ([int]$mrun1.skippedSeenCount -eq 2)
Add-TestResult 'TEST 019-MOPS-COLLECT-SKIP' $mSkipOk ("skipped=$($mrun1.skippedSeenCount); normalized=$($mrun1.normalizedCount)")

$mc2 = Invoke-Py $AdapterMops @('--fixture', $FixtureMopsPlus, '--store-root', $StoreMops)
$mrun2 = $null
try { $mrun2 = ($mc2.Output | ConvertFrom-Json) } catch {}
$mIncOk = ($mc2.ExitCode -eq 0) -and ([int]$mrun2.normalizedCount -eq 1) -and ([int]$mrun2.skippedSeenCount -eq 2) -and ([int]$mrun2.fetchedCount -eq 3)
Add-TestResult 'TEST 019-MOPS-INCREMENTAL-ONE' $mIncOk ("fetched=$($mrun2.fetchedCount); skipped=$($mrun2.skippedSeenCount); normalized=$($mrun2.normalizedCount)")

$mNormFiles = @()
$mRunDir = Join-Path $StoreMops ("runs\" + $mrun2.runId)
$mNd = Join-Path $mRunDir 'normalized'
if (Test-Path -LiteralPath $mNd) { $mNormFiles = @(Get-ChildItem -LiteralPath $mNd -Filter '*.json' -File) }
$mMapFail = New-Object System.Collections.Generic.List[string]
foreach ($file in $mNormFiles) {
  $news = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
  if ($news.url -notlike '*/material/listed/9999/*') { $mMapFail.Add("unexpected url $($news.url)") }
  foreach ($b in (Test-ForbiddenFields $news)) { $mMapFail.Add($b) }
  $cv = Invoke-Py $Contract @('--validate-file', $file.FullName, '--require-collect-url')
  if ($cv.ExitCode -ne 0) { $mMapFail.Add('contract fail') }
}
Add-TestResult 'TEST 019-MOPS-NEW-CONTRACT' (($mNormFiles.Count -eq 1) -and ($mMapFail.Count -eq 0)) ($mMapFail -join '; ')
Add-TestResult 'TEST 019-MOPS-FORBIDDEN-EVAL' ($mMapFail.Count -eq 0) $(if ($mMapFail.Count -eq 0) { 'no eval fields' } else { $mMapFail -join '; ' })

# Sequential preserve across both bootstraps
Reset-Store $StorePreserve
$seedP = @{
  schemaVersion = '1.0'
  byUrl = @{
    'https://www.cna.com.tw/news/afe/keep.aspx' = @{ newsId = 'https://www.cna.com.tw/news/afe/keep.aspx'; firstSeenAt = '2026-09-01T00:00:00Z' }
    'https://www.fsc.gov.tw/ch/home.jsp?dataserno=keepFsc' = @{ newsId = 'https://www.fsc.gov.tw/ch/home.jsp?dataserno=keepFsc'; firstSeenAt = '2026-09-01T00:00:00Z' }
  }
  byGuid = @{}
} | ConvertTo-Json -Depth 6
Set-Content -LiteralPath (Join-Path $StorePreserve 'seen.json') -Value $seedP -Encoding utf8
$null = Invoke-Py $BootTwse @('--fixture', $FixtureTwse, '--store-root', $StorePreserve)
$null = Invoke-Py $BootMops @('--fixture', $FixtureMops, '--store-root', $StorePreserve)
$pSeen = Get-Content -LiteralPath (Join-Path $StorePreserve 'seen.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$pUrls = @($pSeen.byUrl.PSObject.Properties | ForEach-Object { $_.Name })
$pOk = ($pUrls -contains 'https://www.cna.com.tw/news/afe/keep.aspx') -and ($pUrls -contains 'https://www.fsc.gov.tw/ch/home.jsp?dataserno=keepFsc') -and ((Get-SeenUrlCount $pSeen) -eq 6)
Add-TestResult 'TEST 019-CROSS-PRESERVE' $pOk ("seenTotal=$(Get-SeenUrlCount $pSeen)")

# Protected engine / adapter / sources enabled flags
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
  'scripts/collect-mops-material-openapi.py',
  'data/news/sources.json'
)
$dirty = @()
foreach ($rel in $protected) {
  $diff = & git -C $RepoRoot diff --name-only -- $rel
  if ($diff) { $dirty += $rel }
}
Add-TestResult 'TEST 019-NO-ENGINE-EDIT' ($dirty.Count -eq 0) $(if ($dirty.Count -eq 0) { 'protected untouched' } else { $dirty -join ', ' })

$src = Get-Content -LiteralPath (Join-Path $RepoRoot 'data\news\sources.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$twseSrc = @($src.sources | Where-Object { $_.sourceId -eq 'twse-news-openapi' } | Select-Object -First 1)
$mopsSrc = @($src.sources | Where-Object { $_.sourceId -eq 'mops-material-openapi' } | Select-Object -First 1)
Add-TestResult 'TEST 019-PROD-STILL-DISABLED' (($twseSrc.enabled -eq $false) -and ($mopsSrc.enabled -eq $false)) ("twse=$($twseSrc.enabled); mops=$($mopsSrc.enabled)")

# Live smoke (tmp only)
Reset-Store $StoreLiveTwse
$tl = Invoke-Py $BootTwse @('--store-root', $StoreLiveTwse)
$tLive = $null
try { $tLive = ($tl.Output | ConvertFrom-Json) } catch {}
if (($tl.ExitCode -eq 0) -and ($tLive -ne $null) -and ($tLive.status -ne 'failed') -and ([int]$tLive.fetchedCount -gt 0)) {
  $tLiveOk = ([int]$tLive.seededCount -eq [int]$tLive.fetchedCount) -and ([int]$tLive.normalizedCount -eq 0) -and ((Count-NormFiles $StoreLiveTwse) -eq 0)
  Add-TestResult 'TEST 019-TWSE-LIVE-BOOT' $tLiveOk ("fetched=$($tLive.fetchedCount); seeded=$($tLive.seededCount); normalized=$($tLive.normalizedCount)")
  $tlc = Invoke-Py $AdapterTwse @('--store-root', $StoreLiveTwse)
  $tlr = $null
  try { $tlr = ($tlc.Output | ConvertFrom-Json) } catch {}
  Add-TestResult 'TEST 019-TWSE-LIVE-RECOLLECT-SKIP' (($tlc.ExitCode -eq 0) -and ([int]$tlr.normalizedCount -eq 0) -and ([int]$tlr.skippedSeenCount -ge 1)) ("fetched=$($tlr.fetchedCount); skipped=$($tlr.skippedSeenCount); normalized=$($tlr.normalizedCount)")
} else {
  $detail = if ($tLive) { "status=$($tLive.status)" } else { $tl.Output.Substring(0, [Math]::Min(400, $tl.Output.Length)) }
  Add-TestResult 'TEST 019-TWSE-LIVE-BOOT' 'UNKNOWN' $detail
  Add-TestResult 'TEST 019-TWSE-LIVE-RECOLLECT-SKIP' 'UNKNOWN' 'skipped'
}

Reset-Store $StoreLiveMops
$ml = Invoke-Py $BootMops @('--store-root', $StoreLiveMops)
$mLive = $null
try { $mLive = ($ml.Output | ConvertFrom-Json) } catch {}
if (($ml.ExitCode -eq 0) -and ($mLive -ne $null) -and ($mLive.status -ne 'failed') -and ([int]$mLive.fetchedCount -gt 0)) {
  $mLiveOk = ([int]$mLive.seededCount -eq [int]$mLive.fetchedCount) -and ([int]$mLive.normalizedCount -eq 0) -and ([int]$mLive.listedCount -gt 0) -and ([int]$mLive.otcCount -gt 0) -and ((Count-NormFiles $StoreLiveMops) -eq 0)
  Add-TestResult 'TEST 019-MOPS-LIVE-BOOT' $mLiveOk ("fetched=$($mLive.fetchedCount); seeded=$($mLive.seededCount); listed=$($mLive.listedCount); otc=$($mLive.otcCount)")
  $mlc = Invoke-Py $AdapterMops @('--store-root', $StoreLiveMops)
  $mlr = $null
  try { $mlr = ($mlc.Output | ConvertFrom-Json) } catch {}
  Add-TestResult 'TEST 019-MOPS-LIVE-RECOLLECT-SKIP' (($mlc.ExitCode -eq 0) -and ([int]$mlr.normalizedCount -eq 0) -and ([int]$mlr.skippedSeenCount -ge 1)) ("fetched=$($mlr.fetchedCount); skipped=$($mlr.skippedSeenCount); normalized=$($mlr.normalizedCount)")
} else {
  $detail = if ($mLive) { "status=$($mLive.status)" } else { $ml.Output.Substring(0, [Math]::Min(400, $ml.Output.Length)) }
  Add-TestResult 'TEST 019-MOPS-LIVE-BOOT' 'UNKNOWN' $detail
  Add-TestResult 'TEST 019-MOPS-LIVE-RECOLLECT-SKIP' 'UNKNOWN' 'skipped'
}

Write-Output ''
Write-Output '=== P2-019 TWSE+MOPS BOOTSTRAP SUMMARY ==='
$script:Results | ForEach-Object {
  Write-Output ("{0}: {1}" -f $_.Id, $_.Status)
  if ($_.Details) { Write-Output $_.Details }
}
$failed = @($script:Results | Where-Object { $_.Status -eq 'FAIL' })
if ($failed.Count -gt 0) { exit 1 }
exit 0
