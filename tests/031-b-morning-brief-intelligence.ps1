$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$env:PYTHONIOENCODING = 'utf-8'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$FixturePath = Join-Path $PSScriptRoot 'fixtures\031-b-morning-brief-intelligence.json'
$GenerateScript = Join-Path $RepoRoot 'scripts\generate-morning-brief.ps1'
$GeneratePy = Join-Path $RepoRoot 'scripts\generate-morning-brief.py'
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

if (-not (Test-Path $FixturePath)) { throw "Missing fixture: $FixturePath" }
if (-not (Test-Path $GeneratePy)) { throw "Missing generator: $GeneratePy" }

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
  thermal = (Get-FileHash -Path (Join-Path $ThesesDir 'ai-thermal.json') -Algorithm SHA256).Hash
}

$Contract = [System.IO.File]::ReadAllText($FixturePath, $Utf8) | ConvertFrom-Json
$script:Results = New-Object System.Collections.Generic.List[object]
$script:TempRoot = Join-Path $env:TEMP ('InvestorTwin-031B-' + [guid]::NewGuid().ToString('N'))

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

function Write-Evidence($root, $instrument, $asOf, $value, $unit, $sourceId, $status) {
  $histDir = Join-Path $root ("data\evidence\history\" + $instrument)
  New-Item -ItemType Directory -Path $histDir -Force | Out-Null
  $row = [ordered]@{
    instrument = $instrument
    value = $value
    unit = $unit
    asOf = $asOf
    asOfKind = 'close'
    sourceId = $sourceId
    status = $status
  }
  Write-JsonFile (Join-Path $histDir ($asOf + '.json')) $row
}

function Write-Run($root, $runId, $expectedAsOf) {
  $dir = Join-Path $root ("data\evidence\runs\" + $runId)
  New-Item -ItemType Directory -Path $dir -Force | Out-Null
  Write-JsonFile (Join-Path $dir 'run.json') ([ordered]@{
    runId = $runId
    capturedAt = ($expectedAsOf + 'T00:00:00Z')
    expectedAsOf = $expectedAsOf
    writesBrief = $false
  })
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

function Get-NewsResearchIds($brief) {
  $ids = @()
  foreach ($block in @($brief.globalMarketAndNews, $brief.taiwanMarketAndNews)) {
    foreach ($item in @($block.items)) {
      if ($item.PSObject.Properties.Name -contains 'researchId') { $ids += ,$item.researchId }
    }
  }
  foreach ($item in @($brief.aiIndustryHighlights)) {
    if ($item.PSObject.Properties.Name -contains 'researchId') { $ids += ,$item.researchId }
  }
  foreach ($item in @($brief.today3Things)) {
    if ($item.PSObject.Properties.Name -contains 'researchId') { $ids += ,$item.researchId }
  }
  return $ids
}

function Get-BriefText($brief) {
  return ($brief | ConvertTo-Json -Depth 20)
}

function Invoke-SiblingTest($relPath) {
  $path = Join-Path $PSScriptRoot $relPath
  $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $path 2>&1 | Out-String
  return @{ ExitCode = $LASTEXITCODE; Text = $out }
}

try {
  $generateSrc = [System.IO.File]::ReadAllText($GeneratePy, $Utf8)
  $appSrc = [System.IO.File]::ReadAllText($AppPath, $Utf8)
  $engineSrc = [System.IO.File]::ReadAllText($DataEnginePath, $Utf8)

  New-Item -ItemType Directory -Path $script:TempRoot | Out-Null
  $genRoot = New-GenRoot 'generate'
  Write-Evidence $genRoot 'US10Y' '2026-08-20' 4.69 'percent' 'fred-dgs10' 'stale'
  Write-Evidence $genRoot 'US30Y' '2026-08-20' 5.23 'percent' 'fred-dgs30' 'stale'
  Write-Evidence $genRoot 'TAIEX' '2026-08-21' 45224.29 'index' 'twse-taiex' 'fresh'
  Write-Evidence $genRoot 'SOX' '2026-08-21' 11740.4 'index' 'us-index-sox' 'fresh'
  Write-Evidence $genRoot 'Nasdaq' '2026-08-21' 26180.46 'index' 'us-index-nasdaq' 'fresh'
  Write-Evidence $genRoot 'ORPHAN_NEWS' '2026-08-21' 1 'index' 'orphan-source' 'fresh'
  Write-Evidence $genRoot 'TW_DEALER_NET' '2026-08-21' 0.1 'TWD_hundred_million' 'twse-institutional' 'fresh'
  Write-Run $genRoot 'run-20260821T000000Z' '2026-08-21'
  $queueBefore = (Get-FileHash -Path (Join-Path $genRoot 'data\research-queue.json') -Algorithm SHA256).Hash
  $casesBefore = (Get-FileHash -Path (Join-Path $genRoot 'data\investment-cases.json') -Algorithm SHA256).Hash
  $cardCountBefore = @(Get-ChildItem -Path (Join-Path $genRoot 'research') -Recurse -Filter 'card.json').Count
  $gen = Invoke-Generate $genRoot
  $written = Read-JsonFile (Join-Path $genRoot 'data\morning-brief.json')
  $briefText = Get-BriefText $written

  $fail1 = New-Object System.Collections.Generic.List[string]
  if ($gen.ExitCode -ne 0) { $fail1.Add("generator failed: $($gen.Text)") }
  if ($generateSrc -notlike '*def select_evidence*') { $fail1.Add('select_evidence layer missing') }
  if ($briefText -notlike '*TAIEX*') { $fail1.Add('TAIEX Evidence was not selected into Brief') }
  if ($briefText -notlike '*SOX*') { $fail1.Add('SOX Evidence was not selected into Brief') }
  Add-TestResult 'TEST 1' ($fail1.Count -eq 0) ($fail1 -join "`n")

  $fail2 = New-Object System.Collections.Generic.List[string]
  if ($briefText -like '*ORPHAN_NEWS*') { $fail2.Add('unmapped ORPHAN_NEWS was selected into Brief') }
  if ($briefText -like '*orphan-source*') { $fail2.Add('unmapped orphan source was selected into Brief') }
  $todayEvidence = New-Object System.Collections.Generic.List[string]
  foreach ($item in @($written.today3Things)) {
    foreach ($ev in @($item.evidence)) {
      if ($null -ne $ev -and "$ev" -ne '') { $todayEvidence.Add([string]$ev) }
    }
  }
  if ($todayEvidence -contains $Contract.noiseInstrument) { $fail2.Add('noise TW_DEALER_NET was selected as Today 3 Things') }
  Add-TestResult 'TEST 2' ($fail2.Count -eq 0) ($fail2 -join "`n")

  $fail3 = New-Object System.Collections.Generic.List[string]
  $macroText = @($written.macroDecisionLens) -join ' '
  if ($macroText -notlike '*US10Y*') { $fail3.Add('US10Y was not mapped to macroDecisionLens') }
  $globalTitles = @($written.globalMarketAndNews.items | ForEach-Object { [string]$_.title })
  if (-not ($globalTitles | Where-Object { $_ -like '*US10Y*' -or $_ -like '*US30Y*' })) {
    $fail3.Add('US yields were not mapped to globalMarketAndNews')
  }
  $taiwanTitles = @($written.taiwanMarketAndNews.items | ForEach-Object { [string]$_.title })
  if (-not ($taiwanTitles | Where-Object { $_ -like '*TAIEX*' })) {
    $fail3.Add('TAIEX was not mapped to taiwanMarketAndNews')
  }
  $aiTitles = @($written.aiIndustryHighlights | ForEach-Object { [string]$_.title })
  if (-not ($aiTitles | Where-Object { $_ -like '*SOX*' })) { $fail3.Add('SOX was not mapped to aiIndustryHighlights') }
  if (-not $written.marketTemperature.Nasdaq) { $fail3.Add('latest Nasdaq was not mapped to marketTemperature') }
  if ($written.marketTemperature.Nasdaq.value -eq '--') { $fail3.Add('latest Nasdaq was written as missing') }
  Add-TestResult 'TEST 3' ($fail3.Count -eq 0) ($fail3 -join "`n")

  $fail4 = New-Object System.Collections.Generic.List[string]
  $aiHbm = @($written.aiIndustryHighlights | Where-Object { $_.researchId -eq $Contract.soxResearchId })
  $thingsHbm = @($written.today3Things | Where-Object { $_.researchId -eq $Contract.soxResearchId })
  if (($aiHbm.Count + $thingsHbm.Count) -lt 1) { $fail4.Add('existing hbm card was not linked from SOX Evidence') }
  Add-TestResult 'TEST 4' ($fail4.Count -eq 0) ($fail4 -join "`n")

  $fail5 = New-Object System.Collections.Generic.List[string]
  $taiwanIds = @($written.taiwanMarketAndNews.items | ForEach-Object { $_.researchId })
  if ($taiwanIds | Where-Object { $_ }) { $fail5.Add('TAIEX Evidence was given a researchId') }
  $globalIds = @($written.globalMarketAndNews.items | ForEach-Object { $_.researchId })
  if ($globalIds | Where-Object { $_ }) { $fail5.Add('macro/global Evidence was given a researchId') }
  $allIds = Get-NewsResearchIds $written
  foreach ($rid in $allIds) {
    if ($rid -and $rid -eq $Contract.missingResearchId) { $fail5.Add('missing card was written as researchId') }
    if ($rid -and -not (Test-Path -LiteralPath (Join-Path $genRoot ("research\" + $rid + "\card.json")))) {
      $fail5.Add("researchId has no card: $rid")
    }
  }
  Add-TestResult 'TEST 5' ($fail5.Count -eq 0) ($fail5 -join "`n")

  $fail6 = New-Object System.Collections.Generic.List[string]
  $cardCountAfter = @(Get-ChildItem -Path (Join-Path $genRoot 'research') -Recurse -Filter 'card.json').Count
  if ($cardCountAfter -ne $cardCountBefore) { $fail6.Add('generator created or deleted a Research Card') }
  if (Test-Path -LiteralPath (Join-Path $genRoot ("research\" + $Contract.missingResearchId + "\card.json"))) {
    $fail6.Add('generator created a card for unmatched Evidence')
  }
  if (Test-Path -LiteralPath (Join-Path $genRoot ("research\" + $Contract.excludedInstrument + "\card.json"))) {
    $fail6.Add('generator created a card for unmapped Evidence')
  }
  Add-TestResult 'TEST 6' ($fail6.Count -eq 0) ($fail6 -join "`n")

  $fail7 = New-Object System.Collections.Generic.List[string]
  $queueAfter = (Get-FileHash -Path (Join-Path $genRoot 'data\research-queue.json') -Algorithm SHA256).Hash
  if ($queueAfter -ne $queueBefore) { $fail7.Add('generator wrote research-queue.json') }
  if ($generateSrc -like '*/api/queue*') { $fail7.Add('generator references POST /api/queue') }
  if ($generateSrc -like '*/api/research*') { $fail7.Add('generator references POST /api/research') }
  if ($generateSrc -like '*/api/cases*') { $fail7.Add('generator references POST /api/cases') }
  if ($appSrc -notlike '*renderMorningBrief(openMorningBriefResearch)*') {
    $fail7.Add('today workbench no longer uses one-arg renderMorningBrief')
  }
  Add-TestResult 'TEST 7' ($fail7.Count -eq 0) ($fail7 -join "`n")

  $fail8 = New-Object System.Collections.Generic.List[string]
  $signalLines = @([regex]::Matches([string]$written.executiveSummary, '(?m)^\d+\.\s').Count)
  if ($signalLines -gt 3) { $fail8.Add("executiveSummary has $signalLines signals; max is 3") }
  if ($signalLines -lt 1) { $fail8.Add('executiveSummary has no Evidence signals') }
  if ([string]$written.executiveSummary -notlike '*Evidence*') { $fail8.Add('executiveSummary is not traced to Evidence') }
  if ($generateSrc -notlike '*MAX_EXEC_SIGNALS = 3*') { $fail8.Add('MAX_EXEC_SIGNALS is not 3') }
  Add-TestResult 'TEST 8' ($fail8.Count -eq 0) ($fail8 -join "`n")

  $sparseRoot = New-GenRoot 'sparse'
  Write-Evidence $sparseRoot 'US10Y' '2026-08-21' 4.69 'percent' 'fred-dgs10' 'fresh'
  Write-Run $sparseRoot 'run-20260821T000000Z' '2026-08-21'
  $sparseGen = Invoke-Generate $sparseRoot
  $sparse = Read-JsonFile (Join-Path $sparseRoot 'data\morning-brief.json')
  $fail9 = New-Object System.Collections.Generic.List[string]
  if ($sparseGen.ExitCode -ne 0) { $fail9.Add("sparse generator failed: $($sparseGen.Text)") }
  $sparseThings = @($sparse.today3Things)
  if ($sparseThings.Count -gt 3) { $fail9.Add('Today 3 Things exceeded 3 items') }
  if ($sparseThings.Count -ne 1) { $fail9.Add("sparse Today 3 Things count=$($sparseThings.Count); expected 1, not padded") }
  $sparseText = Get-BriefText $sparse
  if ($sparseText -like ('*' + $Contract.paddingPhrase + '*')) { $fail9.Add('Today 3 Things was padded with invented copy') }
  if ($sparseText -like '*TAIEX*') { $fail9.Add('sparse Brief invented TAIEX') }
  if ($sparseText -like '*unavailable*') { $fail9.Add('sparse Brief invented unavailable values') }
  foreach ($item in $sparseThings) {
    if (-not $item.evidence) { $fail9.Add('Today 3 Things item missing evidence reference') }
    if (-not $item.whyItMatters) { $fail9.Add('Today 3 Things item missing whyItMatters') }
    if (-not $item.text) { $fail9.Add('Today 3 Things item missing text for existing renderer') }
  }
  Add-TestResult 'TEST 9' ($fail9.Count -eq 0) ($fail9 -join "`n")

  $fail10 = New-Object System.Collections.Generic.List[string]
  $radar = @($written.opportunityRadar)
  foreach ($rid in @('glass-bridge', 'fau', 'cpo', 'hbm')) {
    if ($radar -notcontains $rid) { $fail10.Add("opportunityRadar missing catalog card $rid") }
  }
  if ($radar -contains 'ORPHAN_NEWS') { $fail10.Add('ordinary unmapped Evidence was written as Opportunity Radar') }
  if ($radar -contains 'TAIEX') { $fail10.Add('ordinary TAIEX Evidence was written as Opportunity Radar') }
  if ($radar -contains 'US10Y') { $fail10.Add('ordinary US10Y Evidence was written as Opportunity Radar') }
  if ($written.opportunityRadarException -eq $true) { $fail10.Add('daily Evidence set opportunityRadarException') }
  if ($engineSrc -notlike '*weekday === 1*') { $fail10.Add('Monday radar display rule missing') }
  Add-TestResult 'TEST 10' ($fail10.Count -eq 0) ($fail10 -join "`n")
}
catch {
  Add-TestResult 'SETUP' $false $_.Exception.Message
}

$fail11 = New-Object System.Collections.Generic.List[string]
$afterGlass = (Get-FileHash -Path $GlassCardPath -Algorithm SHA256).Hash
$afterHbm = (Get-FileHash -Path $HbmCardPath -Algorithm SHA256).Hash
$afterCpo = (Get-FileHash -Path $CpoCardPath -Algorithm SHA256).Hash
$afterFau = (Get-FileHash -Path $FauCardPath -Algorithm SHA256).Hash
$afterCases = (Get-FileHash -Path $ProdCasesPath -Algorithm SHA256).Hash
$afterQueue = (Get-FileHash -Path $ProdQueuePath -Algorithm SHA256).Hash
$afterDram = (Get-FileHash -Path (Join-Path $ThesesDir 'ai-dram.json') -Algorithm SHA256).Hash
$afterCpoThesis = (Get-FileHash -Path (Join-Path $ThesesDir 'cpo-glass-bridge.json') -Algorithm SHA256).Hash
$afterThermal = (Get-FileHash -Path (Join-Path $ThesesDir 'ai-thermal.json') -Algorithm SHA256).Hash
$afterLatest = (Get-FileHash -Path $LatestPath -Algorithm SHA256).Hash
if ($afterGlass -ne $ProdHashBefore.glass) { $fail11.Add('production glass-bridge card.json changed') }
if ($afterHbm -ne $ProdHashBefore.hbm) { $fail11.Add('production hbm card.json changed') }
if ($afterCpo -ne $ProdHashBefore.cpo) { $fail11.Add('production cpo card.json changed') }
if ($afterFau -ne $ProdHashBefore.fau) { $fail11.Add('production fau card.json changed') }
if ($afterCases -ne $ProdHashBefore.cases) { $fail11.Add('production investment-cases.json / Playbook changed') }
if ($afterQueue -ne $ProdHashBefore.queue) { $fail11.Add('production research-queue.json changed') }
if ($afterDram -ne $ProdHashBefore.dram) { $fail11.Add('production ai-dram thesis changed') }
if ($afterCpoThesis -ne $ProdHashBefore.cpoThesis) { $fail11.Add('production cpo-glass-bridge thesis changed') }
if ($afterThermal -ne $ProdHashBefore.thermal) { $fail11.Add('production ai-thermal thesis changed') }
if ($afterLatest -ne $ProdHashBefore.latest) { $fail11.Add('production morning-brief/latest.json changed') }
Add-TestResult 'TEST 11' ($fail11.Count -eq 0) ($fail11 -join "`n")

$fail12 = New-Object System.Collections.Generic.List[string]
$reg025 = Invoke-SiblingTest '025-research-thesis-case.ps1'
if ($reg025.ExitCode -ne 0) { $fail12.Add($reg025.Text) }
$reg027 = Invoke-SiblingTest '027-research-intake.ps1'
if ($reg027.ExitCode -ne 0) { $fail12.Add($reg027.Text) }
$reg029 = Invoke-SiblingTest '029-research-conclusion-history.ps1'
if ($reg029.ExitCode -ne 0) { $fail12.Add($reg029.Text) }
$reg031a = Invoke-SiblingTest '031-a-morning-brief-pipeline.ps1'
if ($reg031a.ExitCode -ne 0) { $fail12.Add($reg031a.Text) }
Add-TestResult 'TEST 12' ($fail12.Count -eq 0) ($fail12 -join "`n")

$afterBrief = (Get-FileHash -Path $ProdBriefPath -Algorithm SHA256).Hash
$guardOk = ($afterBrief -eq $ProdHashBefore.brief) -and ($afterCases -eq $ProdHashBefore.cases) -and ($afterQueue -eq $ProdHashBefore.queue) -and ($afterGlass -eq $ProdHashBefore.glass) -and ($afterHbm -eq $ProdHashBefore.hbm) -and ($afterDram -eq $ProdHashBefore.dram)
Add-TestResult 'TEST 13' $guardOk $(if ($guardOk) { '' } else { 'production files were modified by tests' })
Add-TestResult 'PRODUCTION_FILE_GUARD' $guardOk $(if ($guardOk) { '' } else { 'production files were modified by tests' })

if (Test-Path $script:TempRoot) {
  Remove-Item -Recurse -Force $script:TempRoot -ErrorAction SilentlyContinue
}

$failed = @($script:Results | Where-Object { $_.Status -ne 'PASS' })
Write-Output ''
Write-Output '=== 031-B SUMMARY ==='
foreach ($row in $script:Results) {
  Write-Output ("{0}: {1}" -f $row.Id, $row.Status)
  if ($row.Status -ne 'PASS' -and $row.Details) { Write-Output $row.Details }
}
if ($failed.Count -gt 0) { exit 1 }
exit 0
