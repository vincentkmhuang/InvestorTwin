$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$env:PYTHONIOENCODING = 'utf-8'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$FixturePath = Join-Path $PSScriptRoot 'fixtures\031-j-latest-valid-evidence.json'
$GenerateScript = Join-Path $RepoRoot 'scripts\generate-morning-brief.ps1'
$GeneratePy = Join-Path $RepoRoot 'scripts\generate-morning-brief.py'
$CollectPy = Join-Path $RepoRoot 'scripts\collect-evidence.py'
$ProdBriefPath = Join-Path $RepoRoot 'data\morning-brief.json'
$LatestPath = Join-Path $RepoRoot 'data\morning-brief\latest.json'
$ProdCasesPath = Join-Path $RepoRoot 'data\investment-cases.json'
$ProdQueuePath = Join-Path $RepoRoot 'data\research-queue.json'
$ThesesDir = Join-Path $RepoRoot 'data\theses'
$GlassCardPath = Join-Path $RepoRoot 'research\glass-bridge\card.json'
$HbmCardPath = Join-Path $RepoRoot 'research\hbm\card.json'
$CpoCardPath = Join-Path $RepoRoot 'research\cpo\card.json'
$FauCardPath = Join-Path $RepoRoot 'research\fau\card.json'

if (-not (Test-Path $FixturePath)) { throw "Missing fixture: $FixturePath" }

$Utf8 = New-Object System.Text.UTF8Encoding $false
$ProdHashBefore = @{
  brief = (Get-FileHash -Path $ProdBriefPath -Algorithm SHA256).Hash
  latest = (Get-FileHash -Path $LatestPath -Algorithm SHA256).Hash
  cases = (Get-FileHash -Path $ProdCasesPath -Algorithm SHA256).Hash
  queue = (Get-FileHash -Path $ProdQueuePath -Algorithm SHA256).Hash
  glass = (Get-FileHash -Path $GlassCardPath -Algorithm SHA256).Hash
  hbm = (Get-FileHash -Path $HbmCardPath -Algorithm SHA256).Hash
  cpo = (Get-FileHash -Path $CpoCardPath -Algorithm SHA256).Hash
  fau = (Get-FileHash -Path $FauCardPath -Algorithm SHA256).Hash
  dram = (Get-FileHash -Path (Join-Path $ThesesDir 'ai-dram.json') -Algorithm SHA256).Hash
  cpoThesis = (Get-FileHash -Path (Join-Path $ThesesDir 'cpo-glass-bridge.json') -Algorithm SHA256).Hash
  collect = (Get-FileHash -Path $CollectPy -Algorithm SHA256).Hash
}

$Contract = [System.IO.File]::ReadAllText($FixturePath, $Utf8) | ConvertFrom-Json
$NotLatestLabel = [System.Text.Encoding]::UTF8.GetString([byte[]](0xE9, 0x9D, 0x9E, 0xE6, 0x9C, 0x80, 0xE6, 0x96, 0xB0))
$script:Results = New-Object System.Collections.Generic.List[object]
$script:TempRoot = Join-Path $env:TEMP ('InvestorTwin-031J-' + [guid]::NewGuid().ToString('N'))

function Add-TestResult($id, $passed, $details) {
  $status = if ($passed) { 'PASS' } else { 'FAIL' }
  $script:Results.Add([PSCustomObject]@{ Id = $id; Status = $status; Details = $details })
  Write-Output ("{0}: {1}" -f $id, $status)
  if ($details) { Write-Output $details }
}

function Read-JsonFile($path) {
  return ([System.IO.File]::ReadAllText($path, $Utf8) | ConvertFrom-Json)
}

function Write-JsonFile($path, $obj) {
  $dir = Split-Path -Parent $path
  if (-not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
  }
  [System.IO.File]::WriteAllText($path, ($obj | ConvertTo-Json -Depth 20), $Utf8)
}

function Invoke-Generate($root) {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $GenerateScript -RootPath $root 2>&1
    return @{ ExitCode = [int]$LASTEXITCODE; Text = (($out | ForEach-Object { "$_" }) -join "`n") }
  } finally {
    $ErrorActionPreference = $prev
  }
}

function Invoke-SiblingTest($relPath) {
  $path = Join-Path $PSScriptRoot $relPath
  $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $path 2>&1 | Out-String
  return @{ ExitCode = $LASTEXITCODE; Text = $out }
}

function New-GenRoot($name) {
  $path = Join-Path $script:TempRoot $name
  New-Item -ItemType Directory -Path (Join-Path $path 'data\morning-brief') -Force | Out-Null
  Copy-Item $ProdBriefPath (Join-Path $path 'data\morning-brief.json')
  Copy-Item $LatestPath (Join-Path $path 'data\morning-brief\latest.json')
  Copy-Item $ProdQueuePath (Join-Path $path 'data\research-queue.json')
  Copy-Item $ProdCasesPath (Join-Path $path 'data\investment-cases.json')
  Copy-Item (Join-Path $RepoRoot 'data\opportunity-radar.json') (Join-Path $path 'data\opportunity-radar.json')
  foreach ($id in @('glass-bridge', 'fau', 'cpo', 'hbm')) {
    $dir = Join-Path $path ("research\" + $id)
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Copy-Item (Join-Path $RepoRoot ("research\" + $id + "\card.json")) (Join-Path $dir 'card.json')
  }
  return $path
}

function Write-History($root, $instrument, $asOf, $value, $unit, $sourceId) {
  $histDir = Join-Path $root ("data\evidence\history\" + $instrument)
  New-Item -ItemType Directory -Path $histDir -Force | Out-Null
  Write-JsonFile (Join-Path $histDir ($asOf + '.json')) ([ordered]@{
    instrument = $instrument
    value = $value
    unit = $unit
    asOf = $asOf
    asOfKind = 'close'
    sourceId = $sourceId
  })
}

function Write-Run($root, $runId, $expectedAsOf) {
  $runDir = Join-Path $root ("data\evidence\runs\" + $runId)
  New-Item -ItemType Directory -Path (Join-Path $runDir 'normalized') -Force | Out-Null
  Write-JsonFile (Join-Path $runDir 'run.json') ([ordered]@{
    runId = $runId
    capturedAt = '2026-08-25T00:00:00Z'
    expectedAsOf = $expectedAsOf
    writesBrief = $false
  })
}

function Write-Normalized($root, $runId, $row) {
  $dir = Join-Path $root ("data\evidence\runs\" + $runId + '\normalized')
  New-Item -ItemType Directory -Path $dir -Force | Out-Null
  Write-JsonFile (Join-Path $dir ($row.instrument + '.json')) $row
}

function Write-Unavailable($root, $runId, $instrument, $unit, $sourceId) {
  Write-Normalized $root $runId ([ordered]@{
    instrument = $instrument
    value = $null
    unit = $unit
    asOf = $null
    asOfKind = 'close'
    expectedAsOf = [string]$Contract.runDate
    sourceId = $sourceId
    status = 'unavailable'
  })
}

function Get-TodayBlob($brief) {
  return ((@($brief.today3Things) | ForEach-Object {
    @([string]$_.title, [string]$_.text, (@($_.evidence) -join ',')) -join ' '
  }) -join ' | ')
}

try {
  New-Item -ItemType Directory -Path $script:TempRoot | Out-Null
  $generateSrc = [System.IO.File]::ReadAllText($GeneratePy, $Utf8)
  $collectSrc = [System.IO.File]::ReadAllText($CollectPy, $Utf8)

  $fail0 = New-Object System.Collections.Generic.List[string]
  if ($generateSrc -notlike '*def is_latest*') { $fail0.Add('is_latest missing') }
  if ($generateSrc -notlike '*status == "stale"*') { $fail0.Add('is_latest no longer treats stale as not latest') }
  if ($generateSrc -notlike '*item.get("asOf") == brief_date*') { $fail0.Add('is_latest no longer requires asOf == runDate') }
  if ($generateSrc -like '*dated_macro*') { $fail0.Add('dated evidence is still limited to macro sections') }
  if ($generateSrc -notlike '*theme_items(selected, "taiwan", latest_only=True)*') {
    $fail0.Add('executiveSummary taiwan is no longer latest-only')
  }
  if ($generateSrc -notlike '*theme_items(selected, "macro", latest_only=True)*') {
    $fail0.Add('today3Things macro is no longer latest-only')
  }
  if ($collectSrc -like '*brent*' -or $collectSrc -like '*DCOIL*' -or $collectSrc -like '*VIXCLS*') {
    $fail0.Add('collector catalog added oil/VIX sources')
  }
  Add-TestResult 'TEST 0' ($fail0.Count -eq 0) ($fail0 -join "`n")

  $root = New-GenRoot 'dated-valid'
  $queueBefore = (Get-FileHash -Path (Join-Path $root 'data\research-queue.json') -Algorithm SHA256).Hash
  $casesBefore = (Get-FileHash -Path (Join-Path $root 'data\investment-cases.json') -Algorithm SHA256).Hash
  $hbmBefore = (Get-FileHash -Path (Join-Path $root 'research\hbm\card.json') -Algorithm SHA256).Hash
  $cardCountBefore = @(Get-ChildItem -Path (Join-Path $root 'research') -Recurse -Filter 'card.json').Count
  $latestBefore = (Get-FileHash -Path (Join-Path $root 'data\morning-brief\latest.json') -Algorithm SHA256).Hash

  $prior = [string]$Contract.priorAsOf
  $runDate = [string]$Contract.runDate
  $staleAsOf = [string]$Contract.staleYieldAsOf
  Write-History $root 'TAIEX' $prior 44762.32 'index' 'twse-taiex'
  Write-History $root 'TW_FOREIGN_NET' $prior -157.361313 'TWD_hundred_million' 'twse-institutional'
  Write-History $root 'TW_TRUST_NET' $prior 30.548166 'TWD_hundred_million' 'twse-institutional'
  Write-History $root 'TW_DEALER_NET' $prior -0.147009 'TWD_hundred_million' 'twse-institutional'
  Write-History $root 'US10Y' $staleAsOf 4.74 'percent' 'fred-dgs10'
  $runId = 'run-20260825T000000Z'
  Write-Run $root $runId $runDate
  Write-Unavailable $root $runId 'TAIEX' 'index' 'twse-taiex'
  Write-Unavailable $root $runId 'TW_FOREIGN_NET' 'TWD_hundred_million' 'twse-institutional'
  Write-Unavailable $root $runId 'Nasdaq' 'index' 'us-index-nasdaq'
  Write-Unavailable $root $runId 'SPX' 'index' 'us-index-spx'
  Write-Unavailable $root $runId 'DJI' 'index' 'us-index-dji'
  Write-Unavailable $root $runId 'SOX' 'index' 'us-index-sox'
  Write-Normalized $root $runId ([ordered]@{
    instrument = 'US10Y'
    value = 4.74
    unit = 'percent'
    asOf = $staleAsOf
    asOfKind = 'close'
    expectedAsOf = $runDate
    sourceId = 'fred-dgs10'
    status = 'stale'
  })

  $gen = Invoke-Generate $root
  $written = Read-JsonFile (Join-Path $root 'data\morning-brief.json')
  $taiwanTitles = @($written.taiwanMarketAndNews.items | ForEach-Object { [string]$_.title })
  $taiwanBlob = ($taiwanTitles -join ' ')
  $taiwanSummary = [string]$written.taiwanMarketAndNews.summary
  $lensText = (@($written.macroDecisionLens) -join ' ')
  $todayBlob = Get-TodayBlob $written
  $tempKeys = @($written.marketTemperature.PSObject.Properties.Name)
  $briefJson = ($written | ConvertTo-Json -Depth 20)

  $fail1 = New-Object System.Collections.Generic.List[string]
  if ($gen.ExitCode -ne 0) { $fail1.Add("generator failed: $($gen.Text)") }
  if ([string]$written.date -ne $runDate) { $fail1.Add("date=$($written.date) expected runDate $runDate") }
  if ([string]$written.date -eq $prior) { $fail1.Add('Brief date rolled back to prior TAIEX asOf') }
  Add-TestResult 'TEST 1' ($fail1.Count -eq 0) ($fail1 -join "`n")

  $fail2 = New-Object System.Collections.Generic.List[string]
  if (-not ($taiwanTitles | Where-Object { $_ -like '*TAIEX*' })) { $fail2.Add('TAIEX did not enter taiwanMarketAndNews') }
  if ($taiwanBlob -notlike '*44762.32*' -and $taiwanBlob -notlike '*44,762.32*') { $fail2.Add('TAIEX value was not the 2026-08-24 history close') }
  if ($taiwanBlob -notlike ('*' + $prior + '*')) { $fail2.Add('TAIEX asOf was not 2026-08-24') }
  if ($taiwanBlob -notlike ('*' + $NotLatestLabel + '*')) { $fail2.Add('TAIEX was not labeled as not-latest') }
  if ($taiwanBlob -like ('*' + $runDate + '*')) { $fail2.Add('TAIEX asOf was rewritten to runDate') }
  if ($taiwanSummary -like ('*' + $runDate + '*')) { $fail2.Add('taiwan summary rewrote TAIEX asOf to runDate') }
  if ($lensText -notlike '*TAIEX*') { $fail2.Add('dated TAIEX did not enter macroDecisionLens') }
  if ($lensText -notlike ('*' + $prior + '*')) { $fail2.Add('TAIEX lens asOf was not preserved') }
  Add-TestResult 'TEST 2' ($fail2.Count -eq 0) ($fail2 -join "`n")

  $fail3 = New-Object System.Collections.Generic.List[string]
  if ($taiwanBlob -notlike '*TW_FOREIGN_NET*' -and $taiwanSummary -notlike '*TW_FOREIGN_NET*') {
    $fail3.Add('TW_FOREIGN_NET did not enter taiwanMarketAndNews')
  }
  if (($taiwanBlob + ' ' + $taiwanSummary) -notlike ('*' + $prior + '*')) {
    $fail3.Add('TW_FOREIGN_NET asOf was not preserved')
  }
  if ($briefJson -like '*TW_TRUST_NET*') { $fail3.Add('noise TW_TRUST_NET was selected') }
  if ($briefJson -like '*TW_DEALER_NET*') { $fail3.Add('noise TW_DEALER_NET was selected') }
  Add-TestResult 'TEST 3' ($fail3.Count -eq 0) ($fail3 -join "`n")

  $fail4 = New-Object System.Collections.Generic.List[string]
  foreach ($name in @('Nasdaq', "S&P 500", 'Dow', 'SOX')) {
    if ($tempKeys -contains $name) { $fail4.Add("$name was invented into marketTemperature") }
  }
  if ($briefJson -like '*26,180*' -or $briefJson -like '*26180*') { $fail4.Add('Nasdaq value was invented from old Brief') }
  if ($briefJson -like '*Brent*' -or $briefJson -like '*WTI*' -or $briefJson -like '*VIX*' -or $briefJson -like '*Jackson Hole*') {
    $fail4.Add('oil/VIX/Jackson Hole was invented')
  }
  Add-TestResult 'TEST 4' ($fail4.Count -eq 0) ($fail4 -join "`n")

  $fail5 = New-Object System.Collections.Generic.List[string]
  if ($todayBlob -like '*TAIEX*') { $fail5.Add('today3Things was polluted by dated TAIEX') }
  if ($todayBlob -like '*TW_FOREIGN_NET*') { $fail5.Add('today3Things was polluted by dated TW_FOREIGN_NET') }
  if ($todayBlob -like '*US10Y*') { $fail5.Add('today3Things was polluted by stale US10Y') }
  $summary = [string]$written.executiveSummary
  if ($summary -like '*TAIEX*') { $fail5.Add('executiveSummary created a new latest taiwan signal from dated TAIEX') }
  if ($summary -like '*TW_FOREIGN_NET*') { $fail5.Add('executiveSummary created a new latest taiwan signal from dated TW_FOREIGN_NET') }
  if ($lensText -notlike '*US10Y*') { $fail5.Add('stale US10Y was dropped from macroDecisionLens') }
  if ($lensText -notlike ('*' + $staleAsOf + '*')) { $fail5.Add('stale US10Y asOf was not preserved') }
  if ($lensText -like ('*US10Y*' + $runDate + '*')) { $fail5.Add('stale US10Y asOf was rewritten to runDate') }
  Add-TestResult 'TEST 5' ($fail5.Count -eq 0) ($fail5 -join "`n")

  $freshRoot = New-GenRoot 'same-day-latest'
  Write-History $freshRoot 'TAIEX' $runDate 45000.00 'index' 'twse-taiex'
  Write-Run $freshRoot 'run-20260825T010000Z' $runDate
  Write-Normalized $freshRoot 'run-20260825T010000Z' ([ordered]@{
    instrument = 'TAIEX'
    value = 45000.00
    unit = 'index'
    asOf = $runDate
    asOfKind = 'close'
    expectedAsOf = $runDate
    sourceId = 'twse-taiex'
    status = 'fresh'
  })
  $freshGen = Invoke-Generate $freshRoot
  $freshBrief = Read-JsonFile (Join-Path $freshRoot 'data\morning-brief.json')
  $freshTaiwan = (@($freshBrief.taiwanMarketAndNews.items | ForEach-Object { [string]$_.title }) -join ' ')
  $freshToday = Get-TodayBlob $freshBrief
  $fail6 = New-Object System.Collections.Generic.List[string]
  if ($freshGen.ExitCode -ne 0) { $fail6.Add("same-day generator failed: $($freshGen.Text)") }
  if ($freshTaiwan -like ('*' + $NotLatestLabel + '*')) { $fail6.Add('same-day TAIEX was labeled as not-latest') }
  if ($freshToday -notlike '*TAIEX*') { $fail6.Add('same-day TAIEX was missing from today3Things') }
  Add-TestResult 'TEST 6' ($fail6.Count -eq 0) ($fail6 -join "`n")

  $fail7 = New-Object System.Collections.Generic.List[string]
  foreach ($key in @($Contract.canonicalFields)) {
    if (-not ($written.PSObject.Properties.Name -contains $key)) { $fail7.Add("canonical field missing: $key") }
  }
  $extra = @($written.PSObject.Properties.Name | Where-Object { @($Contract.canonicalFields) -notcontains $_ -and $_ -ne '_selection' })
  if ($extra.Count -gt 0) { $fail7.Add('new Brief schema keys: ' + ($extra -join ',')) }
  $cardCountAfter = @(Get-ChildItem -Path (Join-Path $root 'research') -Recurse -Filter 'card.json').Count
  if ($cardCountAfter -ne $cardCountBefore) { $fail7.Add('generator created or deleted a Research Card') }
  if ((Get-FileHash -Path (Join-Path $root 'data\research-queue.json') -Algorithm SHA256).Hash -ne $queueBefore) {
    $fail7.Add('generator wrote Queue')
  }
  if ((Get-FileHash -Path (Join-Path $root 'data\investment-cases.json') -Algorithm SHA256).Hash -ne $casesBefore) {
    $fail7.Add('generator wrote Case / Decision / Playbook')
  }
  if ((Get-FileHash -Path (Join-Path $root 'research\hbm\card.json') -Algorithm SHA256).Hash -ne $hbmBefore) {
    $fail7.Add('generator wrote Research Card')
  }
  if ((Get-FileHash -Path (Join-Path $root 'data\morning-brief\latest.json') -Algorithm SHA256).Hash -ne $latestBefore) {
    $fail7.Add('generator wrote latest.json as a second canonical Brief')
  }
  Add-TestResult 'TEST 7' ($fail7.Count -eq 0) ($fail7 -join "`n")
}
catch {
  Add-TestResult 'SETUP' $false $_.Exception.Message
}

$afterGlass = (Get-FileHash -Path $GlassCardPath -Algorithm SHA256).Hash
$afterHbm = (Get-FileHash -Path $HbmCardPath -Algorithm SHA256).Hash
$afterCpo = (Get-FileHash -Path $CpoCardPath -Algorithm SHA256).Hash
$afterFau = (Get-FileHash -Path $FauCardPath -Algorithm SHA256).Hash
$afterCases = (Get-FileHash -Path $ProdCasesPath -Algorithm SHA256).Hash
$afterQueue = (Get-FileHash -Path $ProdQueuePath -Algorithm SHA256).Hash
$afterDram = (Get-FileHash -Path (Join-Path $ThesesDir 'ai-dram.json') -Algorithm SHA256).Hash
$afterCpoThesis = (Get-FileHash -Path (Join-Path $ThesesDir 'cpo-glass-bridge.json') -Algorithm SHA256).Hash
$afterBrief = (Get-FileHash -Path $ProdBriefPath -Algorithm SHA256).Hash
$afterLatest = (Get-FileHash -Path $LatestPath -Algorithm SHA256).Hash
$afterCollect = (Get-FileHash -Path $CollectPy -Algorithm SHA256).Hash
$failGuard = New-Object System.Collections.Generic.List[string]
if ($afterGlass -ne $ProdHashBefore.glass) { $failGuard.Add('production glass-bridge card.json changed') }
if ($afterHbm -ne $ProdHashBefore.hbm) { $failGuard.Add('production hbm card.json changed') }
if ($afterCpo -ne $ProdHashBefore.cpo) { $failGuard.Add('production cpo card.json changed') }
if ($afterFau -ne $ProdHashBefore.fau) { $failGuard.Add('production fau card.json changed') }
if ($afterCases -ne $ProdHashBefore.cases) { $failGuard.Add('production investment-cases.json / Decision / Playbook changed') }
if ($afterQueue -ne $ProdHashBefore.queue) { $failGuard.Add('production research-queue.json changed') }
if ($afterDram -ne $ProdHashBefore.dram) { $failGuard.Add('production ai-dram thesis changed') }
if ($afterCpoThesis -ne $ProdHashBefore.cpoThesis) { $failGuard.Add('production cpo-glass-bridge thesis changed') }
if ($afterBrief -ne $ProdHashBefore.brief) { $failGuard.Add('tests rewrote production morning-brief.json') }
if ($afterLatest -ne $ProdHashBefore.latest) { $failGuard.Add('production morning-brief/latest.json changed') }
if ($afterCollect -ne $ProdHashBefore.collect) { $failGuard.Add('collector source was modified') }
Add-TestResult 'PRODUCTION_FILE_GUARD' ($failGuard.Count -eq 0) ($failGuard -join "`n")

$failReg = New-Object System.Collections.Generic.List[string]
foreach ($rel in @(
    '025-research-thesis-case.ps1',
    '027-research-intake.ps1',
    '029-research-conclusion-history.ps1',
    '031-a-morning-brief-pipeline.ps1',
    '031-b-morning-brief-intelligence.ps1',
    '031-c-morning-brief-workspace.ps1',
    '031-d-daily-auto-update-gate.ps1',
    '031-e1-scheduler-hardening.ps1',
    '031-f-windows-task-scheduler.ps1'
  )) {
  $reg = Invoke-SiblingTest $rel
  if ($reg.ExitCode -ne 0) { $failReg.Add($rel + "`n" + $reg.Text) }
}
Add-TestResult 'REGRESSION' ($failReg.Count -eq 0) ($failReg -join "`n")

if (Test-Path $script:TempRoot) {
  Remove-Item -Recurse -Force $script:TempRoot -ErrorAction SilentlyContinue
}

$failed = @($script:Results | Where-Object { $_.Status -ne 'PASS' })
Write-Output ''
Write-Output '=== 031-J SUMMARY ==='
foreach ($row in $script:Results) {
  Write-Output ("{0}: {1}" -f $row.Id, $row.Status)
  if ($row.Status -ne 'PASS' -and $row.Details) { Write-Output $row.Details }
}
if ($failed.Count -gt 0) { exit 1 }
exit 0
