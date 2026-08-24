$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$env:PYTHONIOENCODING = 'utf-8'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$FixturePath = Join-Path $PSScriptRoot 'fixtures\031-d-daily-auto-update-gate.json'
$CollectScript = Join-Path $RepoRoot 'scripts\collect-evidence.ps1'
$CollectPy = Join-Path $RepoRoot 'scripts\collect-evidence.py'
$GenerateScript = Join-Path $RepoRoot 'scripts\generate-morning-brief.ps1'
$GeneratePy = Join-Path $RepoRoot 'scripts\generate-morning-brief.py'
$UpdateScript = Join-Path $RepoRoot 'scripts\update-morning-brief.ps1'
$ProdBriefPath = Join-Path $RepoRoot 'data\morning-brief.json'
$LatestPath = Join-Path $RepoRoot 'data\morning-brief\latest.json'
$ProdCasesPath = Join-Path $RepoRoot 'data\investment-cases.json'
$ProdQueuePath = Join-Path $RepoRoot 'data\research-queue.json'
$ThesesDir = Join-Path $RepoRoot 'data\theses'
$GlassCardPath = Join-Path $RepoRoot 'research\glass-bridge\card.json'
$HbmCardPath = Join-Path $RepoRoot 'research\hbm\card.json'
$CpoCardPath = Join-Path $RepoRoot 'research\cpo\card.json'
$FauCardPath = Join-Path $RepoRoot 'research\fau\card.json'
$AppPath = Join-Path $RepoRoot 'app.js'
$DataEnginePath = Join-Path $RepoRoot 'js\data-engine.js'
$IndexPath = Join-Path $RepoRoot 'index.html'

if (-not (Test-Path $FixturePath)) { throw "Missing fixture: $FixturePath" }
if (-not (Test-Path $UpdateScript)) { throw "Missing daily update script: $UpdateScript" }

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
}

$Contract = [System.IO.File]::ReadAllText($FixturePath, $Utf8) | ConvertFrom-Json
$script:Results = New-Object System.Collections.Generic.List[object]
$script:TempRoot = Join-Path $env:TEMP ('InvestorTwin-031D-' + [guid]::NewGuid().ToString('N'))

function Add-TestResult($id, $passed, $details) {
  $status = if ($passed) { 'PASS' } else { 'FAIL' }
  $script:Results.Add([PSCustomObject]@{ Id = $id; Status = $status; Details = $details })
  Write-Output ("{0}: {1}" -f $id, $status)
  if ($details) { Write-Output $details }
}

function Read-JsonFile($path) {
  return ([System.IO.File]::ReadAllText($path, $Utf8) | ConvertFrom-Json)
}

function New-PipelineRoot($name) {
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

function Invoke-Script($file, $argSplat) {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $file @argSplat 2>&1
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

try {
  $collectSrc = [System.IO.File]::ReadAllText($CollectPy, $Utf8)
  $generateSrc = [System.IO.File]::ReadAllText($GeneratePy, $Utf8)
  $updateSrc = [System.IO.File]::ReadAllText($UpdateScript, $Utf8)
  $appSrc = [System.IO.File]::ReadAllText($AppPath, $Utf8)
  $engineSrc = [System.IO.File]::ReadAllText($DataEnginePath, $Utf8)
  $indexSrc = [System.IO.File]::ReadAllText($IndexPath, $Utf8)

  New-Item -ItemType Directory -Path $script:TempRoot | Out-Null
  $pipeRoot = New-PipelineRoot 'daily'
  $briefBefore = (Get-FileHash -Path (Join-Path $pipeRoot 'data\morning-brief.json') -Algorithm SHA256).Hash
  $queueBefore = (Get-FileHash -Path (Join-Path $pipeRoot 'data\research-queue.json') -Algorithm SHA256).Hash
  $casesBefore = (Get-FileHash -Path (Join-Path $pipeRoot 'data\investment-cases.json') -Algorithm SHA256).Hash
  $hbmBefore = (Get-FileHash -Path (Join-Path $pipeRoot 'research\hbm\card.json') -Algorithm SHA256).Hash
  $oldDate = (Read-JsonFile (Join-Path $pipeRoot 'data\morning-brief.json')).date
  $cardCountBefore = @(Get-ChildItem -Path (Join-Path $pipeRoot 'research') -Recurse -Filter 'card.json').Count

  $collect = Invoke-Script $CollectScript @{
    InputPath = (Join-Path $PSScriptRoot 'fixtures\014-fred-observation-date.json')
    RootPath = $pipeRoot
  }
  $fail1 = New-Object System.Collections.Generic.List[string]
  if ($collect.ExitCode -ne 0) { $fail1.Add("collector failed: $($collect.Text)") }
  $evidenceFiles = @(Get-ChildItem -Path (Join-Path $pipeRoot 'data\evidence') -Recurse -File -ErrorAction SilentlyContinue)
  if ($evidenceFiles.Count -lt 1) { $fail1.Add('collector wrote no Evidence files') }
  $us10 = @(Get-ChildItem -Path (Join-Path $pipeRoot 'data\evidence') -Recurse -Filter 'US10Y.json' -ErrorAction SilentlyContinue)
  if ($us10.Count -lt 1) { $fail1.Add('collector did not produce US10Y Evidence') }
  Add-TestResult 'TEST 1' ($fail1.Count -eq 0) ($fail1 -join "`n")

  $gen = Invoke-Script $GenerateScript @{ RootPath = $pipeRoot }
  $written = Read-JsonFile (Join-Path $pipeRoot 'data\morning-brief.json')
  $fail2 = New-Object System.Collections.Generic.List[string]
  if ($gen.ExitCode -ne 0) { $fail2.Add("generator failed: $($gen.Text)") }
  if (-not $written.date) { $fail2.Add('generated brief missing date') }
  elseif ([string]$written.date -eq [string]$oldDate) { $fail2.Add("brief date was copied from old brief: $oldDate") }
  if (-not $written.executiveSummary) { $fail2.Add('generated brief missing executiveSummary') }
  if ($written.executiveSummary -notlike '*Evidence*') { $fail2.Add('generated brief is not traced to Evidence') }
  Add-TestResult 'TEST 2' ($fail2.Count -eq 0) ($fail2 -join "`n")

  $fail3 = New-Object System.Collections.Generic.List[string]
  foreach ($hid in @($Contract.homepageIds)) {
    if ($indexSrc -notlike ('*id="' + $hid + '"*')) { $fail3.Add("today workbench missing id $hid") }
  }
  if ($engineSrc -notlike "*fetch('data/morning-brief.json*") { $fail3.Add('workbench does not load data/morning-brief.json') }
  if ($appSrc -notlike '*loadMorningBrief()*') { $fail3.Add('init no longer loads Morning Brief') }
  if ($appSrc -notlike '*renderMorningBrief(openMorningBriefResearch)*') {
    $fail3.Add('today workbench no longer renders Morning Brief')
  }
  Add-TestResult 'TEST 3' ($fail3.Count -eq 0) ($fail3 -join "`n")

  $fail4 = New-Object System.Collections.Generic.List[string]
  $linked = @($written.aiIndustryHighlights | Where-Object { $_.researchId -eq $Contract.briefResearchId })
  if ($linked.Count -lt 1) { $fail4.Add('existing hbm card was not referenced from Brief') }
  foreach ($item in $linked) {
    if (-not (Test-Path -LiteralPath (Join-Path $pipeRoot ("research\" + $item.researchId + "\card.json")))) {
      $fail4.Add("researchId has no card: $($item.researchId)")
    }
  }
  if ($appSrc -notlike '*openResearchCard*') { $fail4.Add('click path missing openResearchCard') }
  Add-TestResult 'TEST 4' ($fail4.Count -eq 0) ($fail4 -join "`n")

  $fail5 = New-Object System.Collections.Generic.List[string]
  $nullItems = 0
  foreach ($block in @($written.globalMarketAndNews, $written.taiwanMarketAndNews)) {
    foreach ($item in @($block.items)) {
      if ($item.PSObject.Properties.Name -contains 'researchId' -and -not $item.researchId) { $nullItems++ }
    }
  }
  if ($nullItems -lt 1) { $fail5.Add('generated Brief has no null researchId items') }
  $cardCountAfter = @(Get-ChildItem -Path (Join-Path $pipeRoot 'research') -Recurse -Filter 'card.json').Count
  if ($cardCountAfter -ne $cardCountBefore) { $fail5.Add('pipeline created or deleted a Research Card') }
  $queueAfterGen = (Get-FileHash -Path (Join-Path $pipeRoot 'data\research-queue.json') -Algorithm SHA256).Hash
  if ($queueAfterGen -ne $queueBefore) { $fail5.Add('pipeline wrote Queue without a user click') }
  if ($engineSrc -notlike '*morning-brief-static*') { $fail5.Add('null researchId is not rendered as static') }
  Add-TestResult 'TEST 5' ($fail5.Count -eq 0) ($fail5 -join "`n")

  $fail6 = New-Object System.Collections.Generic.List[string]
  $briefAfterCollect = $briefBefore
  # collect happened before generate; re-check collector contract
  if ($collectSrc -notlike '*writesBrief": False*') { $fail6.Add('collector writesBrief is not false') }
  if ($collectSrc -notlike '*Never writes Morning Brief*') { $fail6.Add('collector no longer forbids Brief writes') }
  foreach ($rel in @($evidenceFiles | ForEach-Object { $_.FullName.Substring($pipeRoot.Length).TrimStart('\') })) {
    $unix = $rel -replace '\\', '/'
    if ($unix -notlike 'data/evidence/*') { $fail6.Add("collector wrote outside evidence: $rel") }
  }
  if ($collectSrc -like '*data/morning-brief.json*' -and $collectSrc -notlike '*FORBIDDEN_WRITES*') {
    $fail6.Add('collector no longer protects morning-brief.json')
  }
  Add-TestResult 'TEST 6' ($fail6.Count -eq 0) ($fail6 -join "`n")

  $fail7 = New-Object System.Collections.Generic.List[string]
  $hbmAfter = (Get-FileHash -Path (Join-Path $pipeRoot 'research\hbm\card.json') -Algorithm SHA256).Hash
  $casesAfter = (Get-FileHash -Path (Join-Path $pipeRoot 'data\investment-cases.json') -Algorithm SHA256).Hash
  if ($hbmAfter -ne $hbmBefore) { $fail7.Add('pipeline modified Research Card') }
  if ($casesAfter -ne $casesBefore) { $fail7.Add('pipeline modified Case / Decision / Playbook') }
  if ($generateSrc -like '*/api/queue*') { $fail7.Add('generator references /api/queue') }
  if ($generateSrc -like '*/api/research*') { $fail7.Add('generator references /api/research') }
  if ($generateSrc -like '*/api/cases*') { $fail7.Add('generator references /api/cases') }
  if ($generateSrc -notlike '*may only write data/morning-brief.json*') {
    $fail7.Add('generator write guard missing')
  }
  Add-TestResult 'TEST 7' ($fail7.Count -eq 0) ($fail7 -join "`n")
}
catch {
  Add-TestResult 'SETUP' $false $_.Exception.Message
}

$fail8 = New-Object System.Collections.Generic.List[string]
foreach ($rel in @(
    '025-research-thesis-case.ps1',
    '027-research-intake.ps1',
    '029-research-conclusion-history.ps1',
    '031-a-morning-brief-pipeline.ps1',
    '031-b-morning-brief-intelligence.ps1',
    '031-c-morning-brief-workspace.ps1'
  )) {
  $reg = Invoke-SiblingTest $rel
  if ($reg.ExitCode -ne 0) { $fail8.Add($reg.Text) }
}
Add-TestResult 'TEST 8' ($fail8.Count -eq 0) ($fail8 -join "`n")

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
$fail9 = New-Object System.Collections.Generic.List[string]
if ($afterGlass -ne $ProdHashBefore.glass) { $fail9.Add('production glass-bridge card.json changed') }
if ($afterHbm -ne $ProdHashBefore.hbm) { $fail9.Add('production hbm card.json changed') }
if ($afterCpo -ne $ProdHashBefore.cpo) { $fail9.Add('production cpo card.json changed') }
if ($afterFau -ne $ProdHashBefore.fau) { $fail9.Add('production fau card.json changed') }
if ($afterCases -ne $ProdHashBefore.cases) { $fail9.Add('production investment-cases.json / Decision / Playbook changed') }
if ($afterQueue -ne $ProdHashBefore.queue) { $fail9.Add('production research-queue.json changed') }
if ($afterDram -ne $ProdHashBefore.dram) { $fail9.Add('production ai-dram thesis changed') }
if ($afterCpoThesis -ne $ProdHashBefore.cpoThesis) { $fail9.Add('production cpo-glass-bridge thesis changed') }
if ($afterBrief -ne $ProdHashBefore.brief) { $fail9.Add('tests rewrote production morning-brief.json') }
if ($afterLatest -ne $ProdHashBefore.latest) { $fail9.Add('production morning-brief/latest.json changed') }
Add-TestResult 'TEST 9' ($fail9.Count -eq 0) ($fail9 -join "`n")
Add-TestResult 'PRODUCTION_FILE_GUARD' ($fail9.Count -eq 0) ($fail9 -join "`n")

$fail10 = New-Object System.Collections.Generic.List[string]
$e2eRoot = $null
try {
  if (-not (Test-Path $script:TempRoot)) { New-Item -ItemType Directory -Path $script:TempRoot | Out-Null }
  $e2eRoot = New-PipelineRoot 'e2e'
  $e2eOld = (Read-JsonFile (Join-Path $e2eRoot 'data\morning-brief.json')).date
  if ($updateSrc -like '*Register-ScheduledTask*') { $fail10.Add('update script registers a scheduled task') }
  if ($updateSrc -like '*schtasks*') { $fail10.Add('update script calls schtasks') }
  if ($updateSrc -like '*.github/workflows*') { $fail10.Add('update script adds GitHub Actions') }
  if ($updateSrc -like '*vercel.json*') { $fail10.Add('update script adds a Vercel schedule file') }
  if ($updateSrc -notlike '*DAILY_UPDATE_COLLECT*') { $fail10.Add('update script does not run Collector') }
  if ($updateSrc -notlike '*DAILY_UPDATE_GENERATE*') { $fail10.Add('update script does not run Generator') }
  $e2e = Invoke-Script $UpdateScript @{
    RootPath = $e2eRoot
    InputPath = (Join-Path $PSScriptRoot 'fixtures\014-fred-observation-date.json')
  }
  if ($e2e.ExitCode -ne 0) { $fail10.Add("daily update failed: $($e2e.Text)") }
  if ($e2e.Text -notlike '*DAILY_UPDATE_OK*') { $fail10.Add('daily update did not print DAILY_UPDATE_OK') }
  if ($e2e.Text -notlike '*EVIDENCE_OK*') { $fail10.Add('daily update collector did not print EVIDENCE_OK') }
  if ($e2e.Text -notlike '*BRIEF_GEN_OK*') { $fail10.Add('daily update generator did not print BRIEF_GEN_OK') }
  $e2eBrief = Read-JsonFile (Join-Path $e2eRoot 'data\morning-brief.json')
  if ([string]$e2eBrief.date -eq [string]$e2eOld) { $fail10.Add('daily update copied the old Brief date') }
  $e2eEvidence = @(Get-ChildItem -Path (Join-Path $e2eRoot 'data\evidence') -Recurse -File -ErrorAction SilentlyContinue)
  if ($e2eEvidence.Count -lt 1) { $fail10.Add('daily update wrote no Evidence') }
  $e2eQueue = (Get-FileHash -Path (Join-Path $e2eRoot 'data\research-queue.json') -Algorithm SHA256).Hash
  $seedQueue = (Get-FileHash -Path $ProdQueuePath -Algorithm SHA256).Hash
  if ($e2eQueue -ne $seedQueue) { $fail10.Add('daily update wrote Queue') }
}
catch {
  $fail10.Add($_.Exception.Message)
}
Add-TestResult 'TEST 10' ($fail10.Count -eq 0) ($fail10 -join "`n")

if (Test-Path $script:TempRoot) {
  Remove-Item -Recurse -Force $script:TempRoot -ErrorAction SilentlyContinue
}

$failed = @($script:Results | Where-Object { $_.Status -ne 'PASS' })
Write-Output ''
Write-Output '=== 031-D SUMMARY ==='
foreach ($row in $script:Results) {
  Write-Output ("{0}: {1}" -f $row.Id, $row.Status)
  if ($row.Status -ne 'PASS' -and $row.Details) { Write-Output $row.Details }
}
if ($failed.Count -gt 0) { exit 1 }
exit 0
