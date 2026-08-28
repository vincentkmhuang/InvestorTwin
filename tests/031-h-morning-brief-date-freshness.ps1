$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$env:PYTHONIOENCODING = 'utf-8'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$FixturePath = Join-Path $PSScriptRoot 'fixtures\031-h-morning-brief-date-freshness.json'
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
$script:TempRoot = Join-Path $env:TEMP ('InvestorTwin-031H-' + [guid]::NewGuid().ToString('N'))

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

function Write-History($root, $instrument, $asOf, $value, $unit, $sourceId, $status) {
  $histDir = Join-Path $root ("data\evidence\history\" + $instrument)
  New-Item -ItemType Directory -Path $histDir -Force | Out-Null
  Write-JsonFile (Join-Path $histDir ($asOf + '.json')) ([ordered]@{
    instrument = $instrument
    value = $value
    unit = $unit
    asOf = $asOf
    asOfKind = 'close'
    sourceId = $sourceId
    status = $status
  })
}

function Write-Normalized($root, $runId, $row) {
  $dir = Join-Path $root ("data\evidence\runs\" + $runId + '\normalized')
  New-Item -ItemType Directory -Path $dir -Force | Out-Null
  Write-JsonFile (Join-Path $dir ($row.instrument + '.json')) $row
}

try {
  New-Item -ItemType Directory -Path $script:TempRoot | Out-Null
  $generateSrc = [System.IO.File]::ReadAllText($GeneratePy, $Utf8)
  $collectSrc = [System.IO.File]::ReadAllText($CollectPy, $Utf8)

  $fail0 = New-Object System.Collections.Generic.List[string]
  if ($generateSrc -like '*date = sorted(valued_dates)*') { $fail0.Add('Brief date is still max Evidence asOf') }
  if ($generateSrc -notlike '*resolve_run_date*') { $fail0.Add('resolve_run_date missing') }
  if ($generateSrc -notlike '*expectedAsOf*') { $fail0.Add('generator does not read run expectedAsOf') }
  if ($collectSrc -notlike '*Never writes Morning Brief*') { $fail0.Add('collector comment changed') }
  Add-TestResult 'TEST 0' ($fail0.Count -eq 0) ($fail0 -join "`n")

  $noRunRoot = New-GenRoot 'no-run'
  Write-History $noRunRoot 'TAIEX' '2026-08-24' 44762.32 'index' 'twse-taiex' 'fresh'
  $noRunBriefBefore = (Get-FileHash -Path (Join-Path $noRunRoot 'data\morning-brief.json') -Algorithm SHA256).Hash
  $noRun = Invoke-Generate $noRunRoot
  $fail1 = New-Object System.Collections.Generic.List[string]
  if ($noRun.ExitCode -eq 0) { $fail1.Add('generator succeeded without an Evidence run') }
  if ($noRun.Text -notlike '*no Evidence run found*') { $fail1.Add('generator did not require a runDate') }
  $noRunBriefAfter = (Get-FileHash -Path (Join-Path $noRunRoot 'data\morning-brief.json') -Algorithm SHA256).Hash
  if ($noRunBriefAfter -ne $noRunBriefBefore) { $fail1.Add('missing run overwrote the previous Brief') }
  Add-TestResult 'TEST 1' ($fail1.Count -eq 0) ($fail1 -join "`n")

  $root = New-GenRoot 'run-date'
  $oldBrief = Read-JsonFile (Join-Path $root 'data\morning-brief.json')
  $queueBefore = (Get-FileHash -Path (Join-Path $root 'data\research-queue.json') -Algorithm SHA256).Hash
  $casesBefore = (Get-FileHash -Path (Join-Path $root 'data\investment-cases.json') -Algorithm SHA256).Hash
  $hbmBefore = (Get-FileHash -Path (Join-Path $root 'research\hbm\card.json') -Algorithm SHA256).Hash
  $cardCountBefore = @(Get-ChildItem -Path (Join-Path $root 'research') -Recurse -Filter 'card.json').Count
  $latestBefore = (Get-FileHash -Path (Join-Path $root 'data\morning-brief\latest.json') -Algorithm SHA256).Hash

  Write-History $root 'TAIEX' ([string]$Contract.priorTaiexAsOf) 44762.32 'index' 'twse-taiex' 'fresh'
  Write-History $root 'US10Y' ([string]$Contract.staleYieldAsOf) 4.74 'percent' 'fred-dgs10' 'stale'
  $runId = 'run-20260825T000000Z'
  $runDir = Join-Path $root ("data\evidence\runs\" + $runId)
  New-Item -ItemType Directory -Path (Join-Path $runDir 'normalized') -Force | Out-Null
  Write-JsonFile (Join-Path $runDir 'run.json') ([ordered]@{
    runId = $runId
    capturedAt = '2026-08-25T00:00:00Z'
    expectedAsOf = [string]$Contract.runDate
    writesBrief = $false
  })
  Write-Normalized $root $runId ([ordered]@{
    instrument = 'TAIEX'
    value = $null
    unit = 'index'
    asOf = $null
    asOfKind = 'close'
    expectedAsOf = [string]$Contract.runDate
    sourceId = 'twse-taiex'
    status = 'unavailable'
  })
  Write-Normalized $root $runId ([ordered]@{
    instrument = 'US10Y'
    value = 4.74
    unit = 'percent'
    asOf = [string]$Contract.staleYieldAsOf
    asOfKind = 'close'
    expectedAsOf = [string]$Contract.runDate
    sourceId = 'fred-dgs10'
    status = 'stale'
  })

  $gen = Invoke-Generate $root
  $written = Read-JsonFile (Join-Path $root 'data\morning-brief.json')
  $fail2 = New-Object System.Collections.Generic.List[string]
  if ($gen.ExitCode -ne 0) { $fail2.Add("generator failed: $($gen.Text)") }
  if ([string]$written.date -ne [string]$Contract.runDate) {
    $fail2.Add("date=$($written.date) expected runDate $($Contract.runDate)")
  }
  if ([string]$written.date -eq [string]$Contract.priorTaiexAsOf) { $fail2.Add('partial unavailable rolled Brief date to prior TAIEX asOf') }
  if ([string]$written.date -eq [string]$oldBrief.date) { $fail2.Add('Brief date was copied from the previous Brief') }
  Add-TestResult 'TEST 2' ($fail2.Count -eq 0) ($fail2 -join "`n")

  $fail3 = New-Object System.Collections.Generic.List[string]
  $taiwanTitles = @($written.taiwanMarketAndNews.items | ForEach-Object { [string]$_.title })
  $taiwanBlob = ($taiwanTitles -join ' ')
  if (-not ($taiwanTitles | Where-Object { $_ -like '*TAIEX*' })) {
    $fail3.Add('prior TAIEX was not selected as latest-valid taiwan news')
  }
  if ($taiwanBlob -notlike ('*' + [string]$Contract.priorTaiexAsOf + '*')) {
    $fail3.Add('prior TAIEX asOf was not preserved')
  }
  if ($taiwanBlob -notlike ('*' + $NotLatestLabel + '*')) { $fail3.Add('prior TAIEX was not labeled as not-latest') }
  if ($taiwanBlob -like ('*' + [string]$Contract.runDate + '*')) {
    $fail3.Add('prior TAIEX asOf was rewritten to runDate')
  }
  $tempKeys = @($written.marketTemperature.PSObject.Properties.Name)
  if ($tempKeys -contains 'TAIEX') { $fail3.Add('TAIEX was written as marketTemperature latest') }
  $summary = [string]$written.executiveSummary
  if ($summary -notlike '*TAIEX*') { $fail3.Add('dated TAIEX missing from executiveSummary') }
  if ($summary -notlike ('*' + [string]$Contract.priorTaiexAsOf + '*')) {
    $fail3.Add('executiveSummary dropped prior TAIEX asOf')
  }
  if ($summary -notlike ('*' + $NotLatestLabel + '*')) { $fail3.Add('executiveSummary missing not-latest label') }
  if ($summary -like ('*asOf ' + [string]$Contract.runDate + '*')) {
    $fail3.Add('executiveSummary rewrote TAIEX asOf to runDate')
  }
  $todayBlob = (@($written.today3Things | ForEach-Object {
    @([string]$_.title, [string]$_.text, (@($_.evidence) -join ' ')) -join ' '
  }) -join ' ')
  if ($todayBlob -notlike '*TAIEX*') { $fail3.Add('dated TAIEX missing from today3Things') }
  if ($todayBlob -notlike ('*' + [string]$Contract.priorTaiexAsOf + '*')) {
    $fail3.Add('today3Things dropped prior TAIEX asOf')
  }
  if ($todayBlob -notlike ('*' + $NotLatestLabel + '*')) { $fail3.Add('today3Things missing not-latest label') }
  if ($todayBlob -like ('*asOf ' + [string]$Contract.runDate + '*')) {
    $fail3.Add('today3Things rewrote TAIEX asOf to runDate')
  }
  Add-TestResult 'TEST 3' ($fail3.Count -eq 0) ($fail3 -join "`n")

  $fail4 = New-Object System.Collections.Generic.List[string]
  $macroText = @($written.macroDecisionLens) -join ' '
  if ($macroText -notlike '*US10Y*') { $fail4.Add('stale US10Y was dropped from macroDecisionLens') }
  if ($macroText -notlike ('*' + [string]$Contract.staleYieldAsOf + '*')) { $fail4.Add('stale US10Y asOf was not preserved') }
  if ($macroText -like ('*' + [string]$Contract.runDate + '*')) { $fail4.Add('stale US10Y asOf was rewritten to runDate') }
  Add-TestResult 'TEST 4' ($fail4.Count -eq 0) ($fail4 -join "`n")

  $fail5 = New-Object System.Collections.Generic.List[string]
  foreach ($key in @($Contract.canonicalFields)) {
    if (-not ($written.PSObject.Properties.Name -contains $key)) { $fail5.Add("canonical field missing: $key") }
  }
  $extra = @($written.PSObject.Properties.Name | Where-Object { @($Contract.canonicalFields) -notcontains $_ -and $_ -ne '_selection' })
  if ($extra.Count -gt 0) { $fail5.Add('new Brief schema keys: ' + ($extra -join ',')) }
  Add-TestResult 'TEST 5' ($fail5.Count -eq 0) ($fail5 -join "`n")

  $fail6 = New-Object System.Collections.Generic.List[string]
  $cardCountAfter = @(Get-ChildItem -Path (Join-Path $root 'research') -Recurse -Filter 'card.json').Count
  if ($cardCountAfter -ne $cardCountBefore) { $fail6.Add('generator created or deleted a Research Card') }
  if ((Get-FileHash -Path (Join-Path $root 'data\research-queue.json') -Algorithm SHA256).Hash -ne $queueBefore) {
    $fail6.Add('generator wrote Queue')
  }
  if ((Get-FileHash -Path (Join-Path $root 'data\investment-cases.json') -Algorithm SHA256).Hash -ne $casesBefore) {
    $fail6.Add('generator wrote Case / Decision / Playbook')
  }
  if ((Get-FileHash -Path (Join-Path $root 'research\hbm\card.json') -Algorithm SHA256).Hash -ne $hbmBefore) {
    $fail6.Add('generator wrote Research Card')
  }
  if ((Get-FileHash -Path (Join-Path $root 'data\morning-brief\latest.json') -Algorithm SHA256).Hash -ne $latestBefore) {
    $fail6.Add('generator wrote latest.json as a second canonical Brief')
  }
  $canonical = @(Get-ChildItem -Path (Join-Path $root 'data') -Filter 'morning-brief.json' -File)
  if ($canonical.Count -ne 1) { $fail6.Add('expected one canonical Brief') }
  Add-TestResult 'TEST 6' ($fail6.Count -eq 0) ($fail6 -join "`n")
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
  if ($reg.ExitCode -ne 0) { $failReg.Add($reg.Text) }
}
Add-TestResult 'REGRESSION' ($failReg.Count -eq 0) ($failReg -join "`n")

if (Test-Path $script:TempRoot) {
  Remove-Item -Recurse -Force $script:TempRoot -ErrorAction SilentlyContinue
}

$failed = @($script:Results | Where-Object { $_.Status -ne 'PASS' })
Write-Output ''
Write-Output '=== 031-H SUMMARY ==='
foreach ($row in $script:Results) {
  Write-Output ("{0}: {1}" -f $row.Id, $row.Status)
  if ($row.Status -ne 'PASS' -and $row.Details) { Write-Output $row.Details }
}
if ($failed.Count -gt 0) { exit 1 }
exit 0
