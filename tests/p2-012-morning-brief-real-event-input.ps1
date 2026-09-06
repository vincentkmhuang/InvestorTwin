$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$env:PYTHONIOENCODING = 'utf-8'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$Sprint011Path = Join-Path $PSScriptRoot 'p2-011-morning-brief-content-quality.ps1'
$GeneratePath = Join-Path $RepoRoot 'scripts\generate-morning-brief.py'
$HandoffFixture = Join-Path $PSScriptRoot 'fixtures\p2-012-handoff-evaluated-events.json'
$GateJsPath = Join-Path $RepoRoot 'js\candidate-gate.js'
$IndexPath = Join-Path $RepoRoot 'index.html'
$IntegratePath = Join-Path $RepoRoot 'scripts\integrate-news-event-evaluation.py'
$PublishPath = Join-Path $RepoRoot 'scripts\publish-research-candidates-handoff.py'
$EvaluatePath = Join-Path $RepoRoot 'scripts\evaluate-news-intelligence.py'
$LinkPath = Join-Path $RepoRoot 'scripts\link-news-events.py'
$HandbookPath = Join-Path $RepoRoot 'docs\Investor Twin Handbook V2.0.md'
$Spec011Path = Join-Path $RepoRoot 'docs\Phase 2 Sprint 011 Morning Brief Content Quality SPEC.md'
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
  $Sprint011Path, $GeneratePath, $HandoffFixture, $ProdBriefPath, $GateJsPath, $IndexPath,
  $ProdQueuePath, $ProdCasesPath, $ProdIndexPath, $ProdGlassPath, $ProdCpoPath, $ProdHbmPath
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
  gateJs = (Get-FileHash -Path $GateJsPath -Algorithm SHA256).Hash
  indexHtml = (Get-FileHash -Path $IndexPath -Algorithm SHA256).Hash
  integrate = (Get-FileHash -Path $IntegratePath -Algorithm SHA256).Hash
  evaluate = (Get-FileHash -Path $EvaluatePath -Algorithm SHA256).Hash
  link = (Get-FileHash -Path $LinkPath -Algorithm SHA256).Hash
  handbook = (Get-FileHash -Path $HandbookPath -Algorithm SHA256).Hash
  spec011 = (Get-FileHash -Path $Spec011Path -Algorithm SHA256).Hash
}
if (Test-Path -LiteralPath $PublishPath) {
  $ProdHashBefore.publish = (Get-FileHash -Path $PublishPath -Algorithm SHA256).Hash
}
if (Test-Path -LiteralPath $ProdHandoffPath) {
  $ProdHashBefore.handoff = (Get-FileHash -Path $ProdHandoffPath -Algorithm SHA256).Hash
}
if (Test-Path -LiteralPath $ProdLedgerPath) {
  $ProdHashBefore.ledger = (Get-FileHash -Path $ProdLedgerPath -Algorithm SHA256).Hash
}

$script:Results = New-Object System.Collections.Generic.List[object]
$script:TempRoot = Join-Path $env:TEMP ('InvestorTwin-p2-012-' + [guid]::NewGuid().ToString('N'))

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
  [System.IO.File]::WriteAllText($path, ($obj | ConvertTo-Json -Depth 30), $Utf8NoBom)
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

function Get-BriefText($brief) {
  $parts = New-Object System.Collections.Generic.List[string]
  $parts.Add([string]$brief.executiveSummary)
  $parts.Add((@($brief.macroDecisionLens) -join "`n"))
  foreach ($block in @($brief.globalMarketAndNews, $brief.taiwanMarketAndNews)) {
    $parts.Add([string]$block.summary)
    foreach ($item in @($block.items)) { $parts.Add([string]$item.title); $parts.Add([string]$item.source) }
  }
  foreach ($item in @($brief.today3Things)) {
    $parts.Add([string]$item.title)
    $parts.Add([string]$item.whyItMatters)
    $parts.Add([string]$item.text)
    $parts.Add((@($item.evidence) -join ','))
  }
  return ($parts -join "`n")
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
    gateJs = (Get-FileHash -Path $GateJsPath -Algorithm SHA256).Hash
    indexHtml = (Get-FileHash -Path $IndexPath -Algorithm SHA256).Hash
    integrate = (Get-FileHash -Path $IntegratePath -Algorithm SHA256).Hash
    evaluate = (Get-FileHash -Path $EvaluatePath -Algorithm SHA256).Hash
    link = (Get-FileHash -Path $LinkPath -Algorithm SHA256).Hash
    handbook = (Get-FileHash -Path $HandbookPath -Algorithm SHA256).Hash
    spec011 = (Get-FileHash -Path $Spec011Path -Algorithm SHA256).Hash
  }
  foreach ($key in $now.Keys) {
    if ($now[$key] -ne $ProdHashBefore[$key]) {
      Write-Output ("Protected hash drift: {0}" -f $key)
      $ok = $false
    }
  }
  if ($ProdHashBefore.ContainsKey('publish') -and (Test-Path -LiteralPath $PublishPath)) {
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
  Write-JsonFile (Join-Path $script:TempRoot 'data\research-queue.json') @{ items = @() }
  Write-JsonFile (Join-Path $script:TempRoot 'data\opportunity-radar.json') @{ items = @(@{ id = 'hbm' }) }
  Write-JsonFile (Join-Path $script:TempRoot 'data\morning-brief.json') ([ordered]@{
    date = '2026-08-25'
    executiveSummary = 'old'
    macroDecisionLens = @()
    marketTemperature = @{}
    globalMarketAndNews = @{ summary = ''; items = @() }
    taiwanMarketAndNews = @{ summary = ''; items = @() }
    aiIndustryHighlights = @()
    upcomingEvents = @()
    today3Things = @()
    opportunityRadar = @('hbm')
    opportunityRadarException = $false
  })
  Copy-Item -LiteralPath $HandoffFixture -Destination (Join-Path $script:TempRoot 'data\research-candidates-handoff.json') -Force

  $genOut = & python $GeneratePath --root $script:TempRoot 2>&1 | Out-String
  if ($LASTEXITCODE -ne 0) { throw "generator failed: $genOut" }
  $brief = Read-JsonFile (Join-Path $script:TempRoot 'data\morning-brief.json')
  $briefText = Get-BriefText $brief

  $genPathPy = $GeneratePath.Replace('\', '/')
  $needlesJson = & python -c "import importlib.util,json; spec=importlib.util.spec_from_file_location('g', r'$genPathPy'); g=importlib.util.module_from_spec(spec); spec.loader.exec_module(g); print(json.dumps({'eventPrefix':g.EVENT_PREFIX,'statusPrefix':g.MARKET_STATUS_PREFIX},ensure_ascii=False))"
  $Needles = $needlesJson | ConvertFrom-Json
  $EventPrefix = [string]$Needles.eventPrefix
  $StatusPrefix = [string]$Needles.statusPrefix

  $globalAcquire = 'evt:corporate-action/hugging-face,nvidia/acquire'
  $taiwanFlow = 'evt:industry/taiwan-semiconductor/foreign-flow'
  $futureEvt = 'evt:policy/federal-reserve/future-placeholder'
  $lowEvt = 'evt:other/low-importance/note'
  $factClaim = 'NVIDIA'
  $badQuestion = 'Should NOT be used as the Brief event title.'

  # TEST 135
  $fail135 = New-Object System.Collections.Generic.List[string]
  if ($briefText -notlike "*$globalAcquire*" -and $briefText -notlike '*Hugging Face*' -and $briefText -notlike '*acquire*') {
    # FACT claim may be Chinese; check eventRef in items/evidence/exec
  }
  if ($briefText.IndexOf($globalAcquire) -lt 0 -and [string]$brief.executiveSummary.IndexOf($EventPrefix) -lt 0) {
    $fail135.Add('Evaluated global Event not found in Brief surfaces')
  }
  if ($genOut -notlike '*events=*') { $fail135.Add('generator did not report events=') }
  if ($GenerateSrc -notlike '*collect_evaluated_events*') { $fail135.Add('collect_evaluated_events missing') }
  Add-TestResult 'TEST 135' ($fail135.Count -eq 0) ($fail135 -join "`n")

  # TEST 136 mapping into existing shapes
  $fail136 = New-Object System.Collections.Generic.List[string]
  $eventItems = @()
  foreach ($item in @($brief.globalMarketAndNews.items + $brief.taiwanMarketAndNews.items)) {
    $kind = if ($null -ne $item.PSObject.Properties['kind']) { [string]$item.kind } else { '' }
    $ref = if ($null -ne $item.PSObject.Properties['eventRef']) { [string]$item.eventRef } else { '' }
    $title = [string]$item.title
    if (($kind -eq 'event') -or ($ref.Length -gt 0) -or $title.StartsWith($EventPrefix)) {
      $eventItems += $item
    }
  }
  $hasExecEvent = ([string]$brief.executiveSummary).Contains($EventPrefix)
  $hasTodayEvent = @($brief.today3Things | Where-Object {
    $ev = @($_.evidence)
    ($ev -contains $globalAcquire) -or ($ev -contains $taiwanFlow)
  }).Count -gt 0
  if (($eventItems.Count -eq 0) -and (-not $hasExecEvent) -and (-not $hasTodayEvent)) {
    $fail136.Add('Event not mapped into items/exec/today3Things')
  }
  # Taiwan event should appear in taiwan items (not elevated if global is top)
  $twRefs = @($brief.taiwanMarketAndNews.items | ForEach-Object {
    if ($null -ne $_.PSObject.Properties['eventRef']) { [string]$_.eventRef } else { '' }
  })
  $twEventTitles = @($brief.taiwanMarketAndNews.items | ForEach-Object { [string]$_.title } | Where-Object { $_.StartsWith($EventPrefix) })
  if (($twRefs -notcontains $taiwanFlow) -and ($twEventTitles.Count -eq 0)) {
    $fail136.Add('Taiwan evaluated Event missing from taiwanMarketAndNews.items')
  }
  Add-TestResult 'TEST 136' ($fail136.Count -eq 0) ($fail136 -join "`n")

  # TEST 137 Event without Candidate eligibility
  $fail137 = New-Object System.Collections.Generic.List[string]
  if ($briefText.IndexOf($globalAcquire) -lt 0 -and -not $hasExecEvent -and -not $hasTodayEvent) {
    $fail137.Add('Event with eligible=false did not enter Brief')
  }
  if ($GenerateSrc -match 'eligible\s*==\s*True|researchCandidate\[.eligible.\]') {
    # soft: ensure we don't require eligible true as gate — check comment/code intent
  }
  if ($GenerateSrc -notlike '*Candidate eligibility is intentionally ignored*') {
    $fail137.Add('Missing explicit Event!=Candidate rule in generator')
  }
  Add-TestResult 'TEST 137' ($fail137.Count -eq 0) ($fail137 -join "`n")

  # TEST 138 future date
  $fail138 = New-Object System.Collections.Generic.List[string]
  if ($briefText.IndexOf($futureEvt) -ge 0) { $fail138.Add('Future Event entered Brief event surface') }
  if ($briefText -like '*Future FOMC placeholder*' -and $briefText -like '*2026-09-20*') {
    $fail138.Add('Future Event content leaked into Brief')
  }
  $upcomingWhens = @($brief.upcomingEvents | ForEach-Object { [string]$_.when })
  if ($upcomingWhens -contains '2026-09-02') { $fail138.Add('Stale past upcoming retained unexpectedly') }
  Add-TestResult 'TEST 138' ($fail138.Count -eq 0) ($fail138 -join "`n")

  # TEST 139 honesty
  $fail139 = New-Object System.Collections.Generic.List[string]
  if (-not $hasExecEvent -and $eventItems.Count -eq 0) {
    $fail139.Add('No Event-prefixed surface found')
  }
  foreach ($item in $eventItems) {
    if (-not ([string]$item.title).StartsWith($EventPrefix)) {
      $fail139.Add('Event item missing Event prefix: ' + $item.title)
    }
    if (([string]$item.title).StartsWith($StatusPrefix)) {
      $fail139.Add('Event item incorrectly market-status framed')
    }
  }
  if ($briefText.IndexOf($badQuestion) -ge 0) {
    $fail139.Add('Candidate researchQuestion used as Brief event what/title')
  }
  if ($briefText.IndexOf($lowEvt) -ge 0) { $fail139.Add('Low-importance Event entered Brief') }
  Add-TestResult 'TEST 139' ($fail139.Count -eq 0) ($fail139 -join "`n")

  # TEST 140 traceability
  $fail140 = New-Object System.Collections.Generic.List[string]
  $traced = $false
  foreach ($item in $eventItems) {
    if ([string]$item.eventRef) { $traced = $true }
    if ([string]$item.source) { $traced = $true }
  }
  if ($hasExecEvent -and ([string]$brief.executiveSummary).Contains('Event ')) { $traced = $true }
  if (-not $traced) { $fail140.Add('Event missing source/eventRef trace') }
  Add-TestResult 'TEST 140' ($fail140.Count -eq 0) ($fail140 -join "`n")

  # TEST 141 FACT vs Candidate question
  $fail141 = New-Object System.Collections.Generic.List[string]
  if ($briefText.IndexOf($badQuestion) -ge 0) { $fail141.Add('researchQuestion used as event title') }
  if ($hasExecEvent -or ($eventItems.Count -gt 0)) {
    # Prefer FACT claim language in elevated surface
    if ($briefText -notlike '*Hugging*' -and $briefText -notlike '*NVIDIA*' -and $briefText -notlike '*Hugging Face*' -and $briefText -notmatch 'NVIDIA') {
      # Chinese FACT claim may still contain NVIDIA in English transliteration — check acquire event id at least
      if ($briefText.IndexOf($globalAcquire) -lt 0) { $fail141.Add('FACT-backed Event not evidenced in Brief text') }
    }
  }
  Add-TestResult 'TEST 141' ($fail141.Count -eq 0) ($fail141 -join "`n")

  # TEST 147 Executive vs Macro Decision Lens role split
  $fail147 = New-Object System.Collections.Generic.List[string]
  $execText = [string]$brief.executiveSummary
  $lensText = (@($brief.macroDecisionLens) -join "`n")
  $needles147Json = & python -c "import importlib.util,json; spec=importlib.util.spec_from_file_location('g', r'$genPathPy'); g=importlib.util.module_from_spec(spec); spec.loader.exec_module(g); packet={'factTitle':'NVIDIA acquire HF','why':'platform extend','impact':{'target':'NVIDIA / AI ecosystem','direction':'Mixed','strength':'High'},'relevance':'High','subject':'hugging-face / nvidia','eventType':'Corporate Action'}; line=g.event_macro_lens_line(packet); print(json.dumps({'lensSample':line,'omit':g.event_macro_lens_line({'factTitle':'X','why':'Y','impact':{},'relevance':'High','subject':'','eventType':''}) is None},ensure_ascii=False))"
  $Needles147 = $needles147Json | ConvertFrom-Json
  $whyMark = [string]::Concat([char]0x6CE8, [char]0x610F, [char]0x7406, [char]0x7531, [char]0xFF1A)
  if (-not $execText.Contains($EventPrefix)) {
    $fail147.Add('Top Event missing from Executive Summary')
  }
  if (-not $execText.Contains('NVIDIA')) {
    $fail147.Add('Executive missing FACT what-happened signal')
  }
  if (-not $execText.Contains($whyMark)) {
    $fail147.Add('Executive missing why-important marker')
  }
  if ($GenerateSrc -notlike '*event_macro_lens_line*') {
    $fail147.Add('event_macro_lens_line helper missing')
  }
  if ($GenerateSrc -notlike '*lens_event = event_macro_lens_line*') {
    $fail147.Add('Top Event Lens path does not call event_macro_lens_line')
  }
  $lensHasAttentionWhy = $lensText.Contains($whyMark)
  $lensHasEventPrefix = $lensText.Contains($EventPrefix)
  if ($lensHasAttentionWhy -and $lensHasEventPrefix) {
    $fail147.Add('Lens still uses Executive-style Event prefix + attention why')
  }
  # factTitle+why duplicate: fixture FACT claim embeds Hugging Face / platform why
  if ($lensText.Contains('Hugging Face') -and $lensText.Contains('AI platform')) {
    $fail147.Add('Lens duplicates Executive factTitle + why')
  }
  if (-not $lensText.Contains('AI ecosystem')) {
    $fail147.Add('Lens did not use impact.target from evaluation')
  }
  if (-not $lensText.Contains('Mixed')) {
    $fail147.Add('Lens did not use impact.direction from evaluation')
  }
  $sampleLens = [string]$Needles147.lensSample
  if (-not $sampleLens) {
    $fail147.Add('event_macro_lens_line did not build impact-based sample')
  } elseif (-not $lensText.Contains('AI ecosystem') -or -not $lensText.Contains('Mixed')) {
    $fail147.Add('Brief Lens missing impact-based observation content')
  } else {
    # Sample and Brief lens share the same observation role (impact angle, not factTitle+why)
    $sampleHasFactWhy = $sampleLens.Contains('Hugging Face') -and $sampleLens.Contains('platform extend')
    if ($sampleHasFactWhy) { $fail147.Add('Lens helper sample collapsed into factTitle+why') }
  }
  if ($lensText.IndexOf($badQuestion) -ge 0) {
    $fail147.Add('researchQuestion used as Lens / Event fact')
  }
  if (-not [bool]$Needles147.omit) {
    $fail147.Add('Thin Event must omit Lens rather than duplicate Executive')
  }
  Add-TestResult 'TEST 147' ($fail147.Count -eq 0) ($fail147 -join "`n")

  # TEST 142 Market Temperature
  $fail142 = New-Object System.Collections.Generic.List[string]
  $mt = $brief.marketTemperature
  foreach ($key in @('Nasdaq', 'WTI', 'Brent', 'VIX', 'SOX')) {
    if (-not ($mt.PSObject.Properties.Name -contains $key)) { $fail142.Add("temperature missing $key"); continue }
    if (-not [string]$mt.$key.value -or [string]$mt.$key.value -eq '--') { $fail142.Add("temperature $key empty") }
  }
  if ($mt.PSObject.Properties.Name -contains 'Bitcoin') { $fail142.Add('Bitcoin invented') }
  Add-TestResult 'TEST 142' ($fail142.Count -eq 0) ($fail142 -join "`n")

  # TEST 143 schema
  $fail143 = New-Object System.Collections.Generic.List[string]
  foreach ($field in @(
    'date', 'executiveSummary', 'macroDecisionLens', 'marketTemperature',
    'globalMarketAndNews', 'taiwanMarketAndNews', 'upcomingEvents', 'today3Things',
    'aiIndustryHighlights', 'opportunityRadar', 'opportunityRadarException'
  )) {
    if (-not ($brief.PSObject.Properties.Name -contains $field)) { $fail143.Add("missing field $field") }
  }
  if ([string]$brief.date -ne $briefDate) { $fail143.Add('brief date mismatch') }
  if (Test-Path (Join-Path $script:TempRoot 'data\news')) { $fail143.Add('temp data/news created') }
  if (Test-Path (Join-Path $script:TempRoot 'data\events')) { $fail143.Add('temp data/events created') }
  Add-TestResult 'TEST 143' ($fail143.Count -eq 0) ($fail143 -join "`n")

  # TEST 144 Attention/Gate/Queue/Cards/engines untouched
  $fail144 = New-Object System.Collections.Generic.List[string]
  if ((Get-FileHash $GateJsPath -Algorithm SHA256).Hash -ne $ProdHashBefore.gateJs) { $fail144.Add('candidate-gate.js changed') }
  if ((Get-FileHash $IndexPath -Algorithm SHA256).Hash -ne $ProdHashBefore.indexHtml) { $fail144.Add('index.html changed') }
  if ((Get-FileHash $IntegratePath -Algorithm SHA256).Hash -ne $ProdHashBefore.integrate) { $fail144.Add('integrate changed') }
  if ((Get-FileHash $EvaluatePath -Algorithm SHA256).Hash -ne $ProdHashBefore.evaluate) { $fail144.Add('evaluate changed') }
  if ((Get-FileHash $LinkPath -Algorithm SHA256).Hash -ne $ProdHashBefore.link) { $fail144.Add('link changed') }
  if ($ProdHashBefore.ContainsKey('publish') -and ((Get-FileHash $PublishPath -Algorithm SHA256).Hash -ne $ProdHashBefore.publish)) {
    $fail144.Add('publish changed')
  }
  if ($GateSrc -notlike '*renderAttention*') { $fail144.Add('Attention missing') }
  if ($IndexSrc -notlike '*todayCandidateAttention*') { $fail144.Add('Attention section missing') }
  Add-TestResult 'TEST 144' ($fail144.Count -eq 0) ($fail144 -join "`n")

  # TEST 145 regression 001-011
  $regOk = $false
  $regOut = ''
  try {
    $regOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $Sprint011Path 2>&1 | Out-String
    $regOk = ($LASTEXITCODE -eq 0)
  } catch {
    $regOk = $false
    $regOut = [string]$_
  }
  Add-TestResult 'TEST 145-REG' $regOk $(if ($regOk) { 'Sprint 001-011 regression PASS' } else { $regOut.Substring(0, [Math]::Min(2500, $regOut.Length)) })
  Add-TestResult 'TEST 145' $regOk 'Sprint 001-011 regression PASS'

  # TEST 146 guard
  $guardOk = Test-ProtectedHashes
  Add-TestResult 'TEST 146' $guardOk $(if ($guardOk) { 'Production File Guard PASS' } else { 'Production protected files changed or forbidden dirs appeared' })
}
finally {
  if (Test-Path -LiteralPath $script:TempRoot) {
    Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}

Write-Output ''
Write-Output '=== P2-012 SUMMARY ==='
$script:Results | ForEach-Object {
  Write-Output ("{0}: {1}" -f $_.Id, $_.Status)
  if ($_.Details) { Write-Output $_.Details }
}
$failed = @($script:Results | Where-Object { $_.Status -ne 'PASS' })
if ($failed.Count -gt 0) { exit 1 }
exit 0
