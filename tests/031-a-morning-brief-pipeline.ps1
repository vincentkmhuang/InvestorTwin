$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$env:PYTHONIOENCODING = 'utf-8'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$FixturePath = Join-Path $PSScriptRoot 'fixtures\031-a-morning-brief-pipeline.json'
$CollectScript = Join-Path $RepoRoot 'scripts\collect-evidence.ps1'
$CollectPy = Join-Path $RepoRoot 'scripts\collect-evidence.py'
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
$WorkflowPath = Join-Path $RepoRoot 'js\workflow-engine.js'

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
}

$Contract = [System.IO.File]::ReadAllText($FixturePath, $Utf8) | ConvertFrom-Json
$script:Results = New-Object System.Collections.Generic.List[object]
$script:TempRoot = Join-Path $env:TEMP ('InvestorTwin-031A-' + [guid]::NewGuid().ToString('N'))

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

function New-SeedBriefRoot($path) {
  New-Item -ItemType Directory -Path (Join-Path $path 'data\morning-brief') -Force | Out-Null
  Copy-Item $ProdBriefPath (Join-Path $path 'data\morning-brief.json')
  Copy-Item $LatestPath (Join-Path $path 'data\morning-brief\latest.json')
  Copy-Item $ProdQueuePath (Join-Path $path 'data\research-queue.json')
  Copy-Item $ProdCasesPath (Join-Path $path 'data\investment-cases.json')
}

function Invoke-Collect($root, $inputPath) {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $CollectScript -InputPath $inputPath -RootPath $root 2>&1
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

function Invoke-SiblingTest($relPath) {
  $path = Join-Path $PSScriptRoot $relPath
  $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $path 2>&1 | Out-String
  return @{ ExitCode = $LASTEXITCODE; Text = $out }
}

try {
  $collectSrc = [System.IO.File]::ReadAllText($CollectPy, $Utf8)
  $generateSrc = [System.IO.File]::ReadAllText($GeneratePy, $Utf8)
  $appSrc = [System.IO.File]::ReadAllText($AppPath, $Utf8)
  $engineSrc = [System.IO.File]::ReadAllText($DataEnginePath, $Utf8)
  $workflowSrc = [System.IO.File]::ReadAllText($WorkflowPath, $Utf8)
  if (-not $workflowSrc.Contains('saveResearchConclusion')) { throw 'workflow-engine.js missing saveResearchConclusion' }

  New-Item -ItemType Directory -Path $script:TempRoot | Out-Null

  $collectRoot = Join-Path $script:TempRoot 'collect'
  New-SeedBriefRoot $collectRoot
  $briefHashBeforeCollect = (Get-FileHash -Path (Join-Path $collectRoot 'data\morning-brief.json') -Algorithm SHA256).Hash
  $collect = Invoke-Collect $collectRoot (Join-Path $PSScriptRoot 'fixtures\014-fred-observation-date.json')
  $fail1 = New-Object System.Collections.Generic.List[string]
  if ($collect.ExitCode -ne 0) { $fail1.Add("collector failed: $($collect.Text)") }
  $evidenceFiles = @(Get-ChildItem -Path (Join-Path $collectRoot 'data\evidence') -Recurse -File -ErrorAction SilentlyContinue)
  if ($evidenceFiles.Count -lt 1) { $fail1.Add('collector wrote no Evidence files') }
  Add-TestResult 'TEST 1' ($fail1.Count -eq 0) ($fail1 -join "`n")

  $fail2 = New-Object System.Collections.Generic.List[string]
  $briefHashAfterCollect = (Get-FileHash -Path (Join-Path $collectRoot 'data\morning-brief.json') -Algorithm SHA256).Hash
  if ($briefHashAfterCollect -ne $briefHashBeforeCollect) { $fail2.Add('collector wrote morning-brief.json') }
  if ($collectSrc -notlike '*writesBrief": False*') { $fail2.Add('collector writesBrief is not false') }
  if ($collectSrc -notlike '*Never writes Morning Brief*') { $fail2.Add('collector comment no longer forbids Brief') }
  foreach ($rel in @($evidenceFiles | ForEach-Object { $_.FullName.Substring($collectRoot.Length).TrimStart('\') })) {
    $unix = $rel -replace '\\', '/'
    if ($unix -notlike 'data/evidence/*') { $fail2.Add("collector wrote outside evidence: $rel") }
  }
  Add-TestResult 'TEST 2' ($fail2.Count -eq 0) ($fail2 -join "`n")

  $genRoot = Join-Path $script:TempRoot 'generate'
  New-Item -ItemType Directory -Path (Join-Path $genRoot 'data\morning-brief') -Force | Out-Null
  Copy-Item $ProdBriefPath (Join-Path $genRoot 'data\morning-brief.json')
  Copy-Item (Join-Path $RepoRoot 'data\opportunity-radar.json') (Join-Path $genRoot 'data\opportunity-radar.json')
  foreach ($id in @('glass-bridge', 'fau', 'cpo', 'hbm')) {
    $dir = Join-Path $genRoot ("research\" + $id)
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Copy-Item (Join-Path $RepoRoot ("research\" + $id + "\card.json")) (Join-Path $dir 'card.json')
  }
  Write-Evidence $genRoot 'US10Y' '2026-08-20' 4.69 'percent' 'fred-dgs10' 'fresh'
  Write-Evidence $genRoot 'US30Y' '2026-08-20' 5.23 'percent' 'fred-dgs30' 'fresh'
  Write-Evidence $genRoot 'TAIEX' '2026-08-21' 45224.29 'index' 'twse-taiex' 'fresh'
  Write-Evidence $genRoot 'SOX' '2026-08-21' 11740.4 'index' 'us-index-sox' 'fresh'
  Write-Evidence $genRoot 'ORPHAN_NEWS' '2026-08-21' 1 'index' 'orphan-source' 'fresh'
  $oldDate = (Read-JsonFile (Join-Path $genRoot 'data\morning-brief.json')).date
  $gen = Invoke-Generate $genRoot
  $written = Read-JsonFile (Join-Path $genRoot 'data\morning-brief.json')
  $fail3 = New-Object System.Collections.Generic.List[string]
  if ($gen.ExitCode -ne 0) { $fail3.Add("generator failed: $($gen.Text)") }
  if ($generateSrc -notlike '*data/evidence*') { $fail3.Add('generator does not read data/evidence') }
  if ($generateSrc -notlike '*load_evidence*') { $fail3.Add('generator missing load_evidence') }
  Add-TestResult 'TEST 3' ($fail3.Count -eq 0) ($fail3 -join "`n")

  $fail4 = New-Object System.Collections.Generic.List[string]
  if (-not $written.date) { $fail4.Add('generated brief missing date') }
  elseif ([string]$written.date -eq [string]$oldDate) { $fail4.Add("brief date was copied from old brief: $oldDate") }
  if ([string]$written.date -ne '2026-08-21') { $fail4.Add("date=$($written.date) expected max Evidence asOf 2026-08-21") }
  if (-not $written.executiveSummary) { $fail4.Add('executiveSummary missing') }
  if (-not $written.today3Things) { $fail4.Add('today3Things missing') }
  if ($written.executiveSummary -notlike '*Evidence*') { $fail4.Add('executiveSummary was not generated from Evidence') }
  Add-TestResult 'TEST 4' ($fail4.Count -eq 0) ($fail4 -join "`n")

  $fail5 = New-Object System.Collections.Generic.List[string]
  $ai = @($written.aiIndustryHighlights | Where-Object { $_.researchId -eq $Contract.soxResearchId })
  $things = @($written.today3Things | Where-Object { $_.researchId -eq $Contract.soxResearchId })
  if (($ai.Count + $things.Count) -lt 1) { $fail5.Add('SOX Evidence was not linked to existing hbm card') }
  $radar = @($written.opportunityRadar)
  foreach ($rid in @('glass-bridge', 'fau', 'cpo', 'hbm')) {
    if ($radar -notcontains $rid) { $fail5.Add("opportunityRadar missing existing card $rid") }
  }
  Add-TestResult 'TEST 5' ($fail5.Count -eq 0) ($fail5 -join "`n")

  $fail6 = New-Object System.Collections.Generic.List[string]
  $globalIds = @($written.globalMarketAndNews.items | ForEach-Object { $_.researchId })
  if ($globalIds -contains $Contract.soxResearchId) { $fail6.Add('US yield/index news was linked to a Research Card') }
  $taiwanIds = @($written.taiwanMarketAndNews.items | ForEach-Object { $_.researchId })
  if ($taiwanIds | Where-Object { $_ }) { $fail6.Add('TAIEX Evidence was given a researchId') }
  if (Test-Path -LiteralPath (Join-Path $genRoot ("research\" + $Contract.missingResearchId + "\card.json"))) {
    $fail6.Add('generator created a Research Card for unmatched Evidence')
  }
  $allIds = Get-NewsResearchIds $written
  foreach ($rid in $allIds) {
    if ($rid -and $rid -eq $Contract.missingResearchId) { $fail6.Add('missing card was written as researchId') }
    if ($rid -and -not (Test-Path -LiteralPath (Join-Path $genRoot ("research\" + $rid + "\card.json")))) {
      $fail6.Add("researchId has no card: $rid")
    }
  }
  Add-TestResult 'TEST 6' ($fail6.Count -eq 0) ($fail6 -join "`n")

  $fail7 = New-Object System.Collections.Generic.List[string]
  if ($appSrc -notlike '*renderMorningBrief(openMorningBriefResearch)*') {
    $fail7.Add('today workbench no longer uses one-arg renderMorningBrief')
  }
  if ($engineSrc -like '*fetch(''/api/queue''*' -or $engineSrc -like '*fetch("/api/queue"*') {
    $fail7.Add('Brief render fetches /api/queue')
  }
  $renderFn = [regex]::Match($engineSrc, 'async renderMorningBrief\(onItemClick\) \{[\s\S]*?\n  \},')
  if ($renderFn.Success -and $renderFn.Value -like '*fetch(*') { $fail7.Add('renderMorningBrief performs fetch') }
  Add-TestResult 'TEST 7' ($fail7.Count -eq 0) ($fail7 -join "`n")
}
catch {
  Add-TestResult 'SETUP' $false $_.Exception.Message
}

$fail8 = New-Object System.Collections.Generic.List[string]
$afterGlass = (Get-FileHash -Path $GlassCardPath -Algorithm SHA256).Hash
$afterHbm = (Get-FileHash -Path $HbmCardPath -Algorithm SHA256).Hash
$afterCpo = (Get-FileHash -Path $CpoCardPath -Algorithm SHA256).Hash
$afterFau = (Get-FileHash -Path $FauCardPath -Algorithm SHA256).Hash
$afterCases = (Get-FileHash -Path $ProdCasesPath -Algorithm SHA256).Hash
$afterQueue = (Get-FileHash -Path $ProdQueuePath -Algorithm SHA256).Hash
$afterDram = (Get-FileHash -Path (Join-Path $ThesesDir 'ai-dram.json') -Algorithm SHA256).Hash
$afterCpoThesis = (Get-FileHash -Path (Join-Path $ThesesDir 'cpo-glass-bridge.json') -Algorithm SHA256).Hash
$afterLatest = (Get-FileHash -Path $LatestPath -Algorithm SHA256).Hash
if ($afterGlass -ne $ProdHashBefore.glass) { $fail8.Add('production glass-bridge card.json changed') }
if ($afterHbm -ne $ProdHashBefore.hbm) { $fail8.Add('production hbm card.json changed') }
if ($afterCpo -ne $ProdHashBefore.cpo) { $fail8.Add('production cpo card.json changed') }
if ($afterFau -ne $ProdHashBefore.fau) { $fail8.Add('production fau card.json changed') }
if ($afterCases -ne $ProdHashBefore.cases) { $fail8.Add('production investment-cases.json changed') }
if ($afterQueue -ne $ProdHashBefore.queue) { $fail8.Add('production research-queue.json changed') }
if ($afterDram -ne $ProdHashBefore.dram) { $fail8.Add('production ai-dram thesis changed') }
if ($afterCpoThesis -ne $ProdHashBefore.cpoThesis) { $fail8.Add('production cpo-glass-bridge thesis changed') }
if ($afterLatest -ne $ProdHashBefore.latest) { $fail8.Add('production morning-brief/latest.json changed') }
Add-TestResult 'TEST 8' ($fail8.Count -eq 0) ($fail8 -join "`n")

$fail9 = New-Object System.Collections.Generic.List[string]
$reg025 = Invoke-SiblingTest '025-research-thesis-case.ps1'
if ($reg025.ExitCode -ne 0) { $fail9.Add($reg025.Text) }
$reg027 = Invoke-SiblingTest '027-research-intake.ps1'
if ($reg027.ExitCode -ne 0) { $fail9.Add($reg027.Text) }
$reg029 = Invoke-SiblingTest '029-research-conclusion-history.ps1'
if ($reg029.ExitCode -ne 0) { $fail9.Add($reg029.Text) }
Add-TestResult 'TEST 9' ($fail9.Count -eq 0) ($fail9 -join "`n")

$afterBrief = (Get-FileHash -Path $ProdBriefPath -Algorithm SHA256).Hash
$guardOk = ($afterBrief -eq $ProdHashBefore.brief) -and ($afterCases -eq $ProdHashBefore.cases) -and ($afterQueue -eq $ProdHashBefore.queue) -and ($afterGlass -eq $ProdHashBefore.glass) -and ($afterHbm -eq $ProdHashBefore.hbm)
Add-TestResult 'PRODUCTION_FILE_GUARD' $guardOk $(if ($guardOk) { '' } else { 'production files were modified by tests' })

if (Test-Path $script:TempRoot) {
  Remove-Item -Recurse -Force $script:TempRoot -ErrorAction SilentlyContinue
}

$failed = @($script:Results | Where-Object { $_.Status -ne 'PASS' })
Write-Output ''
Write-Output '=== 031-A SUMMARY ==='
foreach ($row in $script:Results) {
  Write-Output ("{0}: {1}" -f $row.Id, $row.Status)
  if ($row.Status -ne 'PASS' -and $row.Details) { Write-Output $row.Details }
}
if ($failed.Count -gt 0) { exit 1 }
exit 0
