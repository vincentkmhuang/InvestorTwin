$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$env:PYTHONIOENCODING = 'utf-8'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$Sprint010Path = Join-Path $PSScriptRoot 'p2-010-today-workspace-readability.ps1'
$GeneratePath = Join-Path $RepoRoot 'scripts\generate-morning-brief.py'
$IntegratePath = Join-Path $RepoRoot 'scripts\integrate-news-event-evaluation.py'
$PublishPath = Join-Path $RepoRoot 'scripts\publish-research-candidates-handoff.py'
$GateJsPath = Join-Path $RepoRoot 'js\candidate-gate.js'
$IndexPath = Join-Path $RepoRoot 'index.html'
$Spec011Path = Join-Path $RepoRoot 'docs\Phase 2 Sprint 011 Morning Brief Content Quality SPEC.md'
$Spec008Path = Join-Path $RepoRoot 'docs\Phase 2 Sprint 008 News Intelligence Morning Brief Candidate Attention SPEC.md'
$Spec009Path = Join-Path $RepoRoot 'docs\Phase 2 Sprint 009 Research Candidate Handoff Publish SPEC.md'
$Spec010Path = Join-Path $RepoRoot 'docs\Phase 2 Sprint 010 Today Workspace Readability SPEC.md'
$HandbookPath = Join-Path $RepoRoot 'docs\Investor Twin Handbook V2.0.md'
$ProdBriefPath = Join-Path $RepoRoot 'data\morning-brief.json'
$ProdQueuePath = Join-Path $RepoRoot 'data\research-queue.json'
$ProdCasesPath = Join-Path $RepoRoot 'data\investment-cases.json'
$ProdIndexPath = Join-Path $RepoRoot 'data\knowledge-index.json'
$ProdGlassPath = Join-Path $RepoRoot 'research\glass-bridge\card.json'
$ProdCpoPath = Join-Path $RepoRoot 'research\cpo\card.json'
$ProdHbmPath = Join-Path $RepoRoot 'research\hbm\card.json'
$ProdHandoffPath = Join-Path $RepoRoot 'data\research-candidates-handoff.json'
$ProdLedgerPath = Join-Path $RepoRoot 'data\candidate-gate.json'
$ForbiddenNewsDir = Join-Path $RepoRoot 'data\news'
$ForbiddenEventsDir = Join-Path $RepoRoot 'data\events'

foreach ($path in @(
  $Sprint010Path, $GeneratePath, $Spec011Path, $ProdBriefPath, $ProdQueuePath,
  $ProdCasesPath, $ProdIndexPath, $ProdGlassPath, $ProdCpoPath, $ProdHbmPath,
  $GateJsPath, $IndexPath
)) {
  if (-not (Test-Path -LiteralPath $path)) { throw "Missing: $path" }
}

$Utf8NoBom = New-Object System.Text.UTF8Encoding $false
$GenerateSrc = [System.IO.File]::ReadAllText($GeneratePath, $Utf8NoBom)
$GateSrc = [System.IO.File]::ReadAllText($GateJsPath, $Utf8NoBom)
$IndexSrc = [System.IO.File]::ReadAllText($IndexPath, $Utf8NoBom)

$ProdHashBefore = @{
  brief = (Get-FileHash -Path $ProdBriefPath -Algorithm SHA256).Hash
  queue = (Get-FileHash -Path $ProdQueuePath -Algorithm SHA256).Hash
  cases = (Get-FileHash -Path $ProdCasesPath -Algorithm SHA256).Hash
  index = (Get-FileHash -Path $ProdIndexPath -Algorithm SHA256).Hash
  glass = (Get-FileHash -Path $ProdGlassPath -Algorithm SHA256).Hash
  cpo = (Get-FileHash -Path $ProdCpoPath -Algorithm SHA256).Hash
  hbm = (Get-FileHash -Path $ProdHbmPath -Algorithm SHA256).Hash
  integrate = (Get-FileHash -Path $IntegratePath -Algorithm SHA256).Hash
  publish = if (Test-Path -LiteralPath $PublishPath) { (Get-FileHash -Path $PublishPath -Algorithm SHA256).Hash } else { $null }
  handbook = (Get-FileHash -Path $HandbookPath -Algorithm SHA256).Hash
  spec008 = (Get-FileHash -Path $Spec008Path -Algorithm SHA256).Hash
  spec009 = (Get-FileHash -Path $Spec009Path -Algorithm SHA256).Hash
  spec010 = (Get-FileHash -Path $Spec010Path -Algorithm SHA256).Hash
  gateJs = (Get-FileHash -Path $GateJsPath -Algorithm SHA256).Hash
  indexHtml = (Get-FileHash -Path $IndexPath -Algorithm SHA256).Hash
}
if (Test-Path -LiteralPath $ProdHandoffPath) {
  $ProdHashBefore.handoff = (Get-FileHash -Path $ProdHandoffPath -Algorithm SHA256).Hash
}
if (Test-Path -LiteralPath $ProdLedgerPath) {
  $ProdHashBefore.ledger = (Get-FileHash -Path $ProdLedgerPath -Algorithm SHA256).Hash
}

$script:Results = New-Object System.Collections.Generic.List[object]
$script:TempRoot = Join-Path $env:TEMP ('InvestorTwin-p2-011-' + [guid]::NewGuid().ToString('N'))

function Add-TestResult($id, $passed, $details) {
  $status = if ($passed) { 'PASS' } else { 'FAIL' }
  $script:Results.Add([PSCustomObject]@{ Id = $id; Status = $status; Details = $details })
  Write-Output ("{0}: {1}" -f $id, $status)
  if ($details) { Write-Output $details }
}

function Write-JsonFile($path, $obj) {
  $dir = Split-Path -Parent $path
  if (-not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
  }
  [System.IO.File]::WriteAllText($path, ($obj | ConvertTo-Json -Depth 20), $Utf8NoBom)
}

function Read-JsonFile($path) {
  return ([System.IO.File]::ReadAllText($path, $Utf8NoBom) | ConvertFrom-Json)
}

function Write-Evidence($root, $instrument, $asOf, $value, $unit, $sourceId, $status) {
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

function Write-Run($root, $runId, $expectedAsOf) {
  $dir = Join-Path $root ("data\evidence\runs\" + $runId)
  New-Item -ItemType Directory -Path $dir -Force | Out-Null
  Write-JsonFile (Join-Path $dir 'run.json') ([ordered]@{
    runId = $runId
    expectedAsOf = $expectedAsOf
  })
}

function Write-Card($root, $id) {
  $dir = Join-Path $root ("research\" + $id)
  New-Item -ItemType Directory -Path $dir -Force | Out-Null
  Write-JsonFile (Join-Path $dir 'card.json') ([ordered]@{
    id = $id
    title = $id.ToUpper()
    summary = ''
    status = 'researching'
    researchConclusion = @{ conclusion = 'Existing conclusion must not change'; status = 'uncertain'; asOf = '2026-08-23' }
    investmentThesis = 'Existing thesis text'
  })
}

function Test-ProtectedHashes {
  $ok = $true
  $now = @{
    brief = (Get-FileHash -Path $ProdBriefPath -Algorithm SHA256).Hash
    queue = (Get-FileHash -Path $ProdQueuePath -Algorithm SHA256).Hash
    cases = (Get-FileHash -Path $ProdCasesPath -Algorithm SHA256).Hash
    index = (Get-FileHash -Path $ProdIndexPath -Algorithm SHA256).Hash
    glass = (Get-FileHash -Path $ProdGlassPath -Algorithm SHA256).Hash
    cpo = (Get-FileHash -Path $ProdCpoPath -Algorithm SHA256).Hash
    hbm = (Get-FileHash -Path $ProdHbmPath -Algorithm SHA256).Hash
    integrate = (Get-FileHash -Path $IntegratePath -Algorithm SHA256).Hash
    handbook = (Get-FileHash -Path $HandbookPath -Algorithm SHA256).Hash
    spec008 = (Get-FileHash -Path $Spec008Path -Algorithm SHA256).Hash
    spec009 = (Get-FileHash -Path $Spec009Path -Algorithm SHA256).Hash
    spec010 = (Get-FileHash -Path $Spec010Path -Algorithm SHA256).Hash
    gateJs = (Get-FileHash -Path $GateJsPath -Algorithm SHA256).Hash
    indexHtml = (Get-FileHash -Path $IndexPath -Algorithm SHA256).Hash
  }
  foreach ($key in $now.Keys) {
    if ($now[$key] -ne $ProdHashBefore[$key]) {
      Write-Output ("Protected hash drift: {0}" -f $key)
      $ok = $false
    }
  }
  if ($ProdHashBefore.publish -and (Test-Path -LiteralPath $PublishPath)) {
    if ((Get-FileHash -Path $PublishPath -Algorithm SHA256).Hash -ne $ProdHashBefore.publish) {
      Write-Output 'Protected hash drift: publish'
      $ok = $false
    }
  }
  if ($ProdHashBefore.ContainsKey('handoff') -and (Test-Path -LiteralPath $ProdHandoffPath)) {
    if ((Get-FileHash -Path $ProdHandoffPath -Algorithm SHA256).Hash -ne $ProdHashBefore.handoff) {
      Write-Output 'Protected hash drift: handoff'
      $ok = $false
    }
  }
  if ($ProdHashBefore.ContainsKey('ledger') -and (Test-Path -LiteralPath $ProdLedgerPath)) {
    if ((Get-FileHash -Path $ProdLedgerPath -Algorithm SHA256).Hash -ne $ProdHashBefore.ledger) {
      Write-Output 'Protected hash drift: ledger'
      $ok = $false
    }
  }
  if (Test-Path -LiteralPath $ForbiddenNewsDir) { Write-Output 'Forbidden data/news appeared'; $ok = $false }
  if (Test-Path -LiteralPath $ForbiddenEventsDir) { Write-Output 'Forbidden data/events appeared'; $ok = $false }
  return $ok
}

try {
  New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null
  $briefDate = '2026-09-06'
  Write-Card $script:TempRoot 'hbm'
  Write-Evidence $script:TempRoot 'US10Y' '2026-09-03' 4.77 'percent' 'fred-dgs10' 'stale'
  Write-Evidence $script:TempRoot 'US30Y' '2026-09-03' 5.25 'percent' 'fred-dgs30' 'stale'
  Write-Evidence $script:TempRoot 'Nasdaq' '2026-08-27' 26541.35 'index' 'us-index-nasdaq' 'stale'
  Write-Evidence $script:TempRoot 'SPX' '2026-08-27' 7730.99 'index' 'us-index-spx' 'stale'
  Write-Evidence $script:TempRoot 'DJI' '2026-08-28' 53559.99 'index' 'us-index-dji' 'stale'
  Write-Evidence $script:TempRoot 'SOX' '2026-08-27' 11882.17 'index' 'us-index-sox' 'stale'
  Write-Evidence $script:TempRoot 'WTI' '2026-09-01' 91.48 'USD_per_barrel' 'fred-dcoilwtico' 'stale'
  Write-Evidence $script:TempRoot 'Brent' '2026-09-01' 96.02 'USD_per_barrel' 'fred-dcoilbrenteu' 'stale'
  Write-Evidence $script:TempRoot 'VIX' '2026-09-03' 14.32 'index' 'fred-vixcls' 'stale'
  Write-Evidence $script:TempRoot 'TAIEX' '2026-08-28' 46331.45 'index' 'twse-taiex' 'stale'
  Write-Evidence $script:TempRoot 'TW_FOREIGN_NET' '2026-08-28' 417.5 'TWD_hundred_million' 'twse-institutional' 'stale'
  Write-Run $script:TempRoot 'run-20260906T000000Z' $briefDate

  Write-JsonFile (Join-Path $script:TempRoot 'data\morning-brief.json') ([ordered]@{
    date = '2026-08-25'
    executiveSummary = 'old'
    macroDecisionLens = @()
    marketTemperature = @{}
    globalMarketAndNews = @{ summary = ''; items = @() }
    taiwanMarketAndNews = @{ summary = ''; items = @() }
    aiIndustryHighlights = @(
      @{ title = 'Reuters reported memory-related server price pressure; await formal confirmation.'; researchId = 'hbm' }
      @{ title = 'SOX 11,000.00 (asOf 2026-08-20)'; researchId = 'hbm' }
    )
    upcomingEvents = @(
      @{ title = 'Past NVIDIA earnings call'; when = '2026-08-26'; researchId = 'hbm' }
      @{ title = 'Future catalyst placeholder'; when = '2026-09-20'; researchId = 'hbm' }
      @{ title = 'Unparseable when must drop'; when = 'TBD'; researchId = 'hbm' }
    )
    today3Things = @()
    opportunityRadar = @('hbm')
    opportunityRadarException = $false
  })
  Write-JsonFile (Join-Path $script:TempRoot 'data\research-queue.json') @{ items = @() }
  Write-JsonFile (Join-Path $script:TempRoot 'data\opportunity-radar.json') @{ items = @(@{ id = 'hbm' }) }

  $gen = & python $GeneratePath --root $script:TempRoot 2>&1 | Out-String
  if ($LASTEXITCODE -ne 0) { throw "generator failed: $gen" }
  $brief = Read-JsonFile (Join-Path $script:TempRoot 'data\morning-brief.json')

  $genPathPy = $GeneratePath.Replace('\', '/')
  $needlesJson = & python -c "import importlib.util,json; spec=importlib.util.spec_from_file_location('g', r'$genPathPy'); g=importlib.util.module_from_spec(spec); spec.loader.exec_module(g); print(json.dumps({'prefix':g.MARKET_STATUS_PREFIX,'macroWhy':g.THEME_WHY['macro']},ensure_ascii=False))"
  $Needles = $needlesJson | ConvertFrom-Json
  $StatusPrefix = [string]$Needles.prefix
  $MacroWhy = [string]$Needles.macroWhy

  $fail124 = New-Object System.Collections.Generic.List[string]
  $globalTitles = @($brief.globalMarketAndNews.items | ForEach-Object { [string]$_.title })
  $taiwanTitles = @($brief.taiwanMarketAndNews.items | ForEach-Object { [string]$_.title })
  if ($globalTitles.Count -eq 0) { $fail124.Add('Global items empty') }
  foreach ($title in $globalTitles) {
    if (-not $title.StartsWith($StatusPrefix)) { $fail124.Add("Global item missing market-status framing: $title") }
  }
  foreach ($title in $taiwanTitles) {
    if (-not $title.StartsWith($StatusPrefix)) { $fail124.Add("Taiwan item missing market-status framing: $title") }
  }
  if ($GenerateSrc -notlike '*market_status_item*') { $fail124.Add('market_status_item helper missing') }
  if ($GenerateSrc -like '*def news_item*') { $fail124.Add('legacy news_item still present') }
  Add-TestResult 'TEST 124' ($fail124.Count -eq 0) ($fail124 -join "`n")

  $fail125 = New-Object System.Collections.Generic.List[string]
  $exec = [string]$brief.executiveSummary
  if ($exec -notlike '*Evidence*') { $fail125.Add('executiveSummary missing Evidence trace') }
  if ($exec.IndexOf($MacroWhy) -lt 0) { $fail125.Add('executiveSummary missing why/theme content') }
  # Quote-first means the why theme is absent or appears only after a leading raw US10Y dump.
  $firstSignal = ([regex]::Match($exec, '(?m)^\d+\.\s*(.+)$')).Groups[1].Value
  if ($firstSignal -and $firstSignal.StartsWith('US10Y ')) {
    $fail125.Add('executiveSummary still quote-first for macro')
  }
  if ($firstSignal -and $firstSignal.IndexOf($MacroWhy) -lt 0 -and $firstSignal -match 'US10Y\s+[0-9]') {
    $fail125.Add('executiveSummary macro signal lacks why before relying on quotes')
  }
  $lensText = @($brief.macroDecisionLens) -join ' '
  if ($lensText -notlike '*US10Y*' -and $lensText -notlike '*Evidence*') {
    $fail125.Add('macroDecisionLens lost Evidence traceability')
  }
  if ($lensText.IndexOf($MacroWhy) -lt 0) { $fail125.Add('macroDecisionLens missing why-oriented content') }
  Add-TestResult 'TEST 125' ($fail125.Count -eq 0) ($fail125 -join "`n")

  $fail126 = New-Object System.Collections.Generic.List[string]
  $things = @($brief.today3Things)
  if ($things.Count -lt 1) { $fail126.Add('today3Things empty') }
  foreach ($item in $things) {
    $why = [string]$item.whyItMatters
    $title = [string]$item.title
    if (-not $why) { $fail126.Add('today3Things item missing whyItMatters') }
    if ($title -like 'US10Y *') { $fail126.Add('today3Things title still quote-primary') }
    if ($why -match '(?i)\bbuy\b|(?i)\bsell\b') { $fail126.Add('buy/sell language in whyItMatters') }
  }
  $macroThing = @($things | Where-Object { @($_.evidence) -contains 'US10Y' -or @($_.evidence) -contains 'US30Y' })[0]
  if ($null -eq $macroThing) { $fail126.Add('macro today3Things missing') }
  elseif ([string]$macroThing.whyItMatters -ne $MacroWhy) { $fail126.Add('macro whyItMatters missing expected theme') }
  Add-TestResult 'TEST 126' ($fail126.Count -eq 0) ($fail126 -join "`n")

  $fail127 = New-Object System.Collections.Generic.List[string]
  $events = @($brief.upcomingEvents)
  $whens = @($events | ForEach-Object { [string]$_.when })
  if ($whens -contains '2026-08-26') { $fail127.Add('past event 2026-08-26 still in Upcoming') }
  if ($whens -contains 'TBD') { $fail127.Add('unparseable when retained') }
  if (-not ($whens -contains '2026-09-20')) { $fail127.Add('valid future event dropped') }
  if ($GenerateSrc -notlike '*filter_upcoming_events*') { $fail127.Add('filter_upcoming_events missing') }
  Add-TestResult 'TEST 127' ($fail127.Count -eq 0) ($fail127 -join "`n")

  $fail128 = New-Object System.Collections.Generic.List[string]
  $mt = $brief.marketTemperature
  foreach ($key in @('WTI', 'Brent', 'VIX', 'Nasdaq', 'SOX')) {
    if (-not ($mt.PSObject.Properties.Name -contains $key)) {
      $fail128.Add("marketTemperature missing $key")
      continue
    }
    $val = [string]$mt.$key.value
    if (-not $val -or $val -eq '--') { $fail128.Add("marketTemperature $key has empty value") }
  }
  Add-TestResult 'TEST 128' ($fail128.Count -eq 0) ($fail128 -join "`n")

  $fail129 = New-Object System.Collections.Generic.List[string]
  if ($mt.PSObject.Properties.Name -contains 'Bitcoin') { $fail129.Add('Bitcoin invented in marketTemperature') }
  if ($mt.PSObject.Properties.Name -contains 'Gold') { $fail129.Add('Gold invented in marketTemperature') }
  if ($GenerateSrc -match '"Bitcoin"\s*:') { $fail129.Add('Bitcoin mapped without Evidence path') }
  if ($GenerateSrc -match '"Gold"\s*:') { $fail129.Add('Gold mapped without Evidence path') }
  Add-TestResult 'TEST 129' ($fail129.Count -eq 0) ($fail129 -join "`n")

  $fail130 = New-Object System.Collections.Generic.List[string]
  $globalJoined = ($globalTitles -join ' | ')
  if ($globalJoined -like '*SPX *' -and $globalJoined -like '*Nasdaq *' -and $globalJoined -like '*DJI *') {
    $fail130.Add('Global still repeats full equity quote pack owned by Temperature')
  }
  if ($globalJoined -like '*WTI *' -and $globalJoined -like '*Brent *' -and $globalJoined -like '*VIX *') {
    $fail130.Add('Global still repeats full WTI/Brent/VIX quote pack owned by Temperature')
  }
  $execHasWhy = ($exec.IndexOf($MacroWhy) -ge 0)
  $thingHasWhy = @($things | Where-Object { [string]$_.whyItMatters }).Count -gt 0
  if (-not $execHasWhy -or -not $thingHasWhy) { $fail130.Add('Attention sections lack why ownership') }
  Add-TestResult 'TEST 130' ($fail130.Count -eq 0) ($fail130 -join "`n")

  $fail131 = New-Object System.Collections.Generic.List[string]
  foreach ($field in @(
    'date', 'executiveSummary', 'macroDecisionLens', 'marketTemperature',
    'globalMarketAndNews', 'taiwanMarketAndNews', 'upcomingEvents', 'today3Things',
    'aiIndustryHighlights', 'opportunityRadar', 'opportunityRadarException'
  )) {
    if (-not ($brief.PSObject.Properties.Name -contains $field)) {
      $fail131.Add("canonical field missing: $field")
    }
  }
  if ([string]$brief.date -ne $briefDate) { $fail131.Add("brief date=$($brief.date) expected $briefDate") }
  if (Test-Path -LiteralPath (Join-Path $script:TempRoot 'data\news')) { $fail131.Add('temp data/news created') }
  if (Test-Path -LiteralPath (Join-Path $script:TempRoot 'data\events')) { $fail131.Add('temp data/events created') }
  Add-TestResult 'TEST 131' ($fail131.Count -eq 0) ($fail131 -join "`n")

  $fail132 = New-Object System.Collections.Generic.List[string]
  if ((Get-FileHash -Path $GateJsPath -Algorithm SHA256).Hash -ne $ProdHashBefore.gateJs) {
    $fail132.Add('candidate-gate.js modified')
  }
  if ((Get-FileHash -Path $IndexPath -Algorithm SHA256).Hash -ne $ProdHashBefore.indexHtml) {
    $fail132.Add('index.html modified')
  }
  if ((Get-FileHash -Path $IntegratePath -Algorithm SHA256).Hash -ne $ProdHashBefore.integrate) {
    $fail132.Add('integrate script modified')
  }
  if ($ProdHashBefore.publish -and ((Get-FileHash -Path $PublishPath -Algorithm SHA256).Hash -ne $ProdHashBefore.publish)) {
    $fail132.Add('publish script modified')
  }
  if ($GateSrc -notlike '*renderAttention*') { $fail132.Add('Attention render missing') }
  if ($IndexSrc -notlike '*todayCandidateAttention*') { $fail132.Add('Attention section missing') }
  Add-TestResult 'TEST 132' ($fail132.Count -eq 0) ($fail132 -join "`n")

  $regOk = $false
  $regOut = ''
  try {
    $regOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $Sprint010Path 2>&1 | Out-String
    $regOk = ($LASTEXITCODE -eq 0)
  } catch {
    $regOk = $false
    $regOut = [string]$_
  }
  Add-TestResult 'TEST 133-REG' $regOk $(if ($regOk) { 'Sprint 001-010 regression PASS' } else { $regOut.Substring(0, [Math]::Min(2500, $regOut.Length)) })
  Add-TestResult 'TEST 133' $regOk 'Sprint 001-010 regression PASS'

  $guardOk = Test-ProtectedHashes
  Add-TestResult 'TEST 134' $guardOk $(if ($guardOk) { 'Production File Guard PASS' } else { 'Production protected files changed or forbidden dirs appeared' })
}
finally {
  if (Test-Path -LiteralPath $script:TempRoot) {
    Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}

Write-Output ''
Write-Output '=== P2-011 SUMMARY ==='
$script:Results | ForEach-Object {
  Write-Output ("{0}: {1}" -f $_.Id, $_.Status)
  if ($_.Details) { Write-Output $_.Details }
}
$failed = @($script:Results | Where-Object { $_.Status -ne 'PASS' })
if ($failed.Count -gt 0) { exit 1 }
exit 0
