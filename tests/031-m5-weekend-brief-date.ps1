$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$env:PYTHONIOENCODING = 'utf-8'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$CollectScript = Join-Path $RepoRoot 'scripts\collect-evidence.ps1'
$CollectPy = Join-Path $RepoRoot 'scripts\collect-evidence.py'
$GenerateScript = Join-Path $RepoRoot 'scripts\generate-morning-brief.ps1'
$GeneratePy = Join-Path $RepoRoot 'scripts\generate-morning-brief.py'
$UnitPy = Join-Path $PSScriptRoot '031-m5-weekend-brief-date.py'
$FixtureDir = Join-Path $PSScriptRoot 'fixtures'
$ProdBriefPath = Join-Path $RepoRoot 'data\morning-brief.json'
$LatestPath = Join-Path $RepoRoot 'data\morning-brief\latest.json'
$QueuePath = Join-Path $RepoRoot 'data\research-queue.json'
$CasesPath = Join-Path $RepoRoot 'data\investment-cases.json'
$ThesesDir = Join-Path $RepoRoot 'data\theses'
$GlassCardPath = Join-Path $RepoRoot 'research\glass-bridge\card.json'
$HbmCardPath = Join-Path $RepoRoot 'research\hbm\card.json'
$CpoCardPath = Join-Path $RepoRoot 'research\cpo\card.json'
$FauCardPath = Join-Path $RepoRoot 'research\fau\card.json'
$UpdateScript = Join-Path $RepoRoot 'scripts\update-morning-brief.ps1'
$AppPath = Join-Path $RepoRoot 'app.js'
$IndexPath = Join-Path $RepoRoot 'index.html'

$WeekendFixture = Join-Path $FixtureDir '031-m5-weekend-brief-date.json'
$WeekdayFixture = Join-Path $FixtureDir '031-m5-weekday-brief-date.json'
foreach ($path in @($WeekendFixture, $WeekdayFixture, $UnitPy)) {
  if (-not (Test-Path $path)) { throw "Missing: $path" }
}

$Utf8 = New-Object System.Text.UTF8Encoding $false
$NotLatestLabel = [System.Text.Encoding]::UTF8.GetString([byte[]](0xE9, 0x9D, 0x9E, 0xE6, 0x9C, 0x80, 0xE6, 0x96, 0xB0))
$ProdHashBefore = @{
  brief = (Get-FileHash -Path $ProdBriefPath -Algorithm SHA256).Hash
  latest = (Get-FileHash -Path $LatestPath -Algorithm SHA256).Hash
  queue = (Get-FileHash -Path $QueuePath -Algorithm SHA256).Hash
  cases = (Get-FileHash -Path $CasesPath -Algorithm SHA256).Hash
  glass = (Get-FileHash -Path $GlassCardPath -Algorithm SHA256).Hash
  hbm = (Get-FileHash -Path $HbmCardPath -Algorithm SHA256).Hash
  cpo = (Get-FileHash -Path $CpoCardPath -Algorithm SHA256).Hash
  fau = (Get-FileHash -Path $FauCardPath -Algorithm SHA256).Hash
  dram = (Get-FileHash -Path (Join-Path $ThesesDir 'ai-dram.json') -Algorithm SHA256).Hash
  cpoThesis = (Get-FileHash -Path (Join-Path $ThesesDir 'cpo-glass-bridge.json') -Algorithm SHA256).Hash
  generate = (Get-FileHash -Path $GeneratePy -Algorithm SHA256).Hash
  update = (Get-FileHash -Path $UpdateScript -Algorithm SHA256).Hash
  app = (Get-FileHash -Path $AppPath -Algorithm SHA256).Hash
  index = (Get-FileHash -Path $IndexPath -Algorithm SHA256).Hash
}

$script:Results = New-Object System.Collections.Generic.List[object]
$script:TempRoot = Join-Path $env:TEMP ('InvestorTwin-031M5-' + [guid]::NewGuid().ToString('N'))

function Add-TestResult($id, $passed, $details) {
  $status = if ($passed) { 'PASS' } else { 'FAIL' }
  $script:Results.Add([PSCustomObject]@{ Id = $id; Status = $status; Details = $details })
  Write-Output ("{0}: {1}" -f $id, $status)
  if ($details) { Write-Output $details }
}

function Read-Json($path) {
  return ([System.IO.File]::ReadAllText($path, $Utf8) | ConvertFrom-Json)
}

function New-SeedRoot($path) {
  New-Item -ItemType Directory -Path (Join-Path $path 'data\morning-brief') -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $path 'data\theses') -Force | Out-Null
  Copy-Item $ProdBriefPath (Join-Path $path 'data\morning-brief.json')
  Copy-Item $LatestPath (Join-Path $path 'data\morning-brief\latest.json')
  Copy-Item $QueuePath (Join-Path $path 'data\research-queue.json')
  Copy-Item $CasesPath (Join-Path $path 'data\investment-cases.json')
  Copy-Item (Join-Path $RepoRoot 'data\opportunity-radar.json') (Join-Path $path 'data\opportunity-radar.json')
  Copy-Item (Join-Path $ThesesDir 'ai-dram.json') (Join-Path $path 'data\theses\ai-dram.json')
  foreach ($id in @('glass-bridge', 'fau', 'cpo', 'hbm')) {
    $dir = Join-Path $path ("research\" + $id)
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Copy-Item (Join-Path $RepoRoot ("research\" + $id + "\card.json")) (Join-Path $dir 'card.json')
  }
}

function Invoke-Collect($inputPath, $rootPath) {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $CollectScript -InputPath $inputPath -RootPath $rootPath 2>&1
    return @{ ExitCode = [int]$LASTEXITCODE; Text = (($out | ForEach-Object { "$_" }) -join "`n") }
  } finally {
    $ErrorActionPreference = $prev
  }
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

function Get-RunDir($root, $text) {
  if ($text -match 'runDir=(.+)') { return $Matches[1].Trim() }
  $runs = Join-Path $root 'data\evidence\runs'
  $dirs = @(Get-ChildItem -Path $runs -Directory -ErrorAction SilentlyContinue | Sort-Object Name)
  if ($dirs.Count -lt 1) { throw 'no evidence run directory' }
  return $dirs[-1].FullName
}

try {
  New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null
  $src = [System.IO.File]::ReadAllText($CollectPy, $Utf8)
  $fail0 = New-Object System.Collections.Generic.List[string]
  if ($src -notmatch 'def default_expected_as_of') { $fail0.Add('default_expected_as_of missing') }
  if ($src -notlike '*captured_dt.date().isoformat()*') { $fail0.Add('calendar-date default missing') }
  if ($src -like '*last_weekday(captured_dt.date())*') { $fail0.Add('live/fixture default still uses last_weekday(capturedAt)') }
  $genSrc = [System.IO.File]::ReadAllText($GeneratePy, $Utf8)
  if ($genSrc -notlike '*date = resolve_run_date(root)*') { $fail0.Add('generator no longer uses expectedAsOf as Brief date') }
  Add-TestResult 'TEST 0' ($fail0.Count -eq 0) ($fail0 -join "`n")

  $fail1 = New-Object System.Collections.Generic.List[string]
  $py = $env:INVESTORTWIN_PYTHON
  if (-not $py) { $py = 'python' }
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $unitOut = & $py $UnitPy 2>&1
    $unitCode = [int]$LASTEXITCODE
  } finally {
    $ErrorActionPreference = $prev
  }
  $unitText = (($unitOut | ForEach-Object { "$_" }) -join "`n")
  if ($unitCode -ne 0) { $fail1.Add("unit failed: $unitText") }
  Add-TestResult 'TEST 1' ($fail1.Count -eq 0) ($fail1 -join "`n")

  $weekendRoot = Join-Path $script:TempRoot 'weekend'
  New-SeedRoot $weekendRoot
  $weekendCollect = Invoke-Collect $WeekendFixture $weekendRoot
  $fail2 = New-Object System.Collections.Generic.List[string]
  if ($weekendCollect.ExitCode -ne 0) { $fail2.Add("weekend collect failed: $($weekendCollect.Text)") }
  $weekendRun = $null
  if ($weekendCollect.ExitCode -eq 0) { $weekendRun = Get-RunDir $weekendRoot $weekendCollect.Text }
  if ($weekendRun) {
    $summary = Read-Json (Join-Path $weekendRun 'run.json')
    $taiex = Read-Json (Join-Path $weekendRun 'normalized\TAIEX.json')
    $foreign = Read-Json (Join-Path $weekendRun 'normalized\TW_FOREIGN_NET.json')
    if ($summary.expectedAsOf -ne '2026-08-29') { $fail2.Add("expectedAsOf=$($summary.expectedAsOf) expected 2026-08-29") }
    if ($summary.expectedAsOf -eq '2026-08-28') { $fail2.Add('weekend expectedAsOf rolled to last_weekday Friday') }
    if ($taiex.asOf -ne '2026-08-28') { $fail2.Add("TAIEX asOf=$($taiex.asOf) expected Friday session") }
    if ($taiex.asOf -eq '2026-08-29') { $fail2.Add('TAIEX asOf rewritten to Saturday runDate') }
    if ($taiex.status -ne 'stale') { $fail2.Add("TAIEX status=$($taiex.status) expected stale") }
    if ([double]$taiex.value -ne 46331.45) { $fail2.Add("TAIEX value=$($taiex.value)") }
    if ($foreign.asOf -ne '2026-08-28') { $fail2.Add("FOREIGN asOf=$($foreign.asOf)") }
    if ($foreign.status -ne 'stale') { $fail2.Add("FOREIGN status=$($foreign.status)") }
  } else {
    $fail2.Add('weekend run missing')
  }
  Add-TestResult 'TEST 2' ($fail2.Count -eq 0) ($fail2 -join "`n")

  $fail3 = New-Object System.Collections.Generic.List[string]
  $weekendGen = Invoke-Generate $weekendRoot
  if ($weekendGen.ExitCode -ne 0) { $fail3.Add("weekend generator failed: $($weekendGen.Text)") }
  $brief = Read-Json (Join-Path $weekendRoot 'data\morning-brief.json')
  $taiwanBlob = ([string]$brief.taiwanMarketAndNews.summary + ' | ' + ((@($brief.taiwanMarketAndNews.items | ForEach-Object { [string]$_.title }) -join ' | ')))
  $lensText = (@($brief.macroDecisionLens) -join ' ')
  if ([string]$brief.date -ne '2026-08-29') { $fail3.Add("Brief date=$($brief.date) expected 2026-08-29") }
  if ([string]$brief.date -eq '2026-08-28') { $fail3.Add('Brief date used Friday TAIEX asOf') }
  if ($taiwanBlob -notlike '*TAIEX*') { $fail3.Add('TAIEX missing from taiwanMarketAndNews') }
  if ($taiwanBlob -notlike '*2026-08-28*') { $fail3.Add('TAIEX asOf 2026-08-28 missing from Brief') }
  if ($taiwanBlob -notlike ('*' + $NotLatestLabel + '*')) { $fail3.Add('TAIEX missing not-latest label') }
  if ($taiwanBlob -like '*asOf 2026-08-29*') { $fail3.Add('TAIEX asOf rewritten to Brief date') }
  if ($lensText -notlike '*TAIEX*') { $fail3.Add('TAIEX missing from macroDecisionLens') }
  if ($lensText -notlike ('*' + $NotLatestLabel + '*')) { $fail3.Add('lens TAIEX missing not-latest label') }
  Add-TestResult 'TEST 3' ($fail3.Count -eq 0) ($fail3 -join "`n")

  $weekdayRoot = Join-Path $script:TempRoot 'weekday'
  New-SeedRoot $weekdayRoot
  $weekdayCollect = Invoke-Collect $WeekdayFixture $weekdayRoot
  $fail4 = New-Object System.Collections.Generic.List[string]
  if ($weekdayCollect.ExitCode -ne 0) { $fail4.Add("weekday collect failed: $($weekdayCollect.Text)") }
  if ($weekdayCollect.ExitCode -eq 0) {
    $weekdayRun = Get-RunDir $weekdayRoot $weekdayCollect.Text
    $weekdaySummary = Read-Json (Join-Path $weekdayRun 'run.json')
    $weekdayTaiex = Read-Json (Join-Path $weekdayRun 'normalized\TAIEX.json')
    if ($weekdaySummary.expectedAsOf -ne '2026-08-28') { $fail4.Add("weekday expectedAsOf=$($weekdaySummary.expectedAsOf)") }
    if ($weekdaySummary.expectedAsOf -eq '2026-08-27') { $fail4.Add('Friday expectedAsOf rolled to Thursday') }
    if ($weekdayTaiex.asOf -ne '2026-08-28') { $fail4.Add("weekday TAIEX asOf=$($weekdayTaiex.asOf)") }
    if ($weekdayTaiex.status -ne 'fresh') { $fail4.Add("weekday TAIEX status=$($weekdayTaiex.status) expected fresh") }
    $weekdayGen = Invoke-Generate $weekdayRoot
    if ($weekdayGen.ExitCode -ne 0) { $fail4.Add("weekday generator failed: $($weekdayGen.Text)") }
    $weekdayBrief = Read-Json (Join-Path $weekdayRoot 'data\morning-brief.json')
    $weekdayTaiwan = ([string]$weekdayBrief.taiwanMarketAndNews.summary)
    if ([string]$weekdayBrief.date -ne '2026-08-28') { $fail4.Add("weekday Brief date=$($weekdayBrief.date)") }
    if ($weekdayTaiwan -like ('*' + $NotLatestLabel + '*')) { $fail4.Add('Friday same-session TAIEX labeled not-latest') }
  }
  Add-TestResult 'TEST 4' ($fail4.Count -eq 0) ($fail4 -join "`n")
}
catch {
  Add-TestResult 'SETUP' $false $_.Exception.Message
}
finally {
  if (Test-Path $script:TempRoot) {
    Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}

$failGuard = New-Object System.Collections.Generic.List[string]
if ((Get-FileHash -Path $ProdBriefPath -Algorithm SHA256).Hash -ne $ProdHashBefore.brief) { $failGuard.Add('production morning-brief.json changed') }
if ((Get-FileHash -Path $LatestPath -Algorithm SHA256).Hash -ne $ProdHashBefore.latest) { $failGuard.Add('production latest.json changed') }
if ((Get-FileHash -Path $QueuePath -Algorithm SHA256).Hash -ne $ProdHashBefore.queue) { $failGuard.Add('production research-queue.json changed') }
if ((Get-FileHash -Path $CasesPath -Algorithm SHA256).Hash -ne $ProdHashBefore.cases) { $failGuard.Add('production investment-cases.json / Decision / Playbook changed') }
if ((Get-FileHash -Path $GlassCardPath -Algorithm SHA256).Hash -ne $ProdHashBefore.glass) { $failGuard.Add('production glass-bridge card.json changed') }
if ((Get-FileHash -Path $HbmCardPath -Algorithm SHA256).Hash -ne $ProdHashBefore.hbm) { $failGuard.Add('production hbm card.json changed') }
if ((Get-FileHash -Path $CpoCardPath -Algorithm SHA256).Hash -ne $ProdHashBefore.cpo) { $failGuard.Add('production cpo card.json changed') }
if ((Get-FileHash -Path $FauCardPath -Algorithm SHA256).Hash -ne $ProdHashBefore.fau) { $failGuard.Add('production fau card.json changed') }
if ((Get-FileHash -Path (Join-Path $ThesesDir 'ai-dram.json') -Algorithm SHA256).Hash -ne $ProdHashBefore.dram) { $failGuard.Add('production ai-dram thesis changed') }
if ((Get-FileHash -Path (Join-Path $ThesesDir 'cpo-glass-bridge.json') -Algorithm SHA256).Hash -ne $ProdHashBefore.cpoThesis) { $failGuard.Add('production cpo-glass-bridge thesis changed') }
if ((Get-FileHash -Path $GeneratePy -Algorithm SHA256).Hash -ne $ProdHashBefore.generate) { $failGuard.Add('generator source changed') }
if ((Get-FileHash -Path $UpdateScript -Algorithm SHA256).Hash -ne $ProdHashBefore.update) { $failGuard.Add('scheduler/update script changed') }
if ((Get-FileHash -Path $AppPath -Algorithm SHA256).Hash -ne $ProdHashBefore.app) { $failGuard.Add('app.js changed') }
if ((Get-FileHash -Path $IndexPath -Algorithm SHA256).Hash -ne $ProdHashBefore.index) { $failGuard.Add('index.html changed') }
Add-TestResult 'PRODUCTION_FILE_GUARD' ($failGuard.Count -eq 0) ($failGuard -join "`n")

$failed = @($script:Results | Where-Object { $_.Status -ne 'PASS' })
Write-Output ''
Write-Output '=== 031-M-5 SUMMARY ==='
foreach ($row in $script:Results) {
  Write-Output ("{0}: {1}" -f $row.Id, $row.Status)
  if ($row.Status -ne 'PASS' -and $row.Details) { Write-Output $row.Details }
}
if ($failed.Count -gt 0) { exit 1 }
exit 0
