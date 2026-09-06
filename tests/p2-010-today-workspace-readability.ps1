$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$env:PYTHONIOENCODING = 'utf-8'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$Sprint009Path = Join-Path $PSScriptRoot 'p2-009-research-candidate-handoff-publish.ps1'
$IndexPath = Join-Path $RepoRoot 'index.html'
$StylePath = Join-Path $RepoRoot 'style.css'
$DataEnginePath = Join-Path $RepoRoot 'js\data-engine.js'
$GateJsPath = Join-Path $RepoRoot 'js\candidate-gate.js'
$AppJsPath = Join-Path $RepoRoot 'app.js'
$GeneratePath = Join-Path $RepoRoot 'scripts\generate-morning-brief.py'
$PublishPath = Join-Path $RepoRoot 'scripts\publish-research-candidates-handoff.py'
$IntegratePath = Join-Path $RepoRoot 'scripts\integrate-news-event-evaluation.py'
$Spec010Path = Join-Path $RepoRoot 'docs\Phase 2 Sprint 010 Today Workspace Readability SPEC.md'
$Spec009Path = Join-Path $RepoRoot 'docs\Phase 2 Sprint 009 Research Candidate Handoff Publish SPEC.md'
$Spec008Path = Join-Path $RepoRoot 'docs\Phase 2 Sprint 008 News Intelligence Morning Brief Candidate Attention SPEC.md'
$HandbookPath = Join-Path $RepoRoot 'docs\Investor Twin Handbook V2.0.md'
$ProdBriefPath = Join-Path $RepoRoot 'data\morning-brief.json'
$ProdQueuePath = Join-Path $RepoRoot 'data\research-queue.json'
$ProdCasesPath = Join-Path $RepoRoot 'data\investment-cases.json'
$ProdIndexPath = Join-Path $RepoRoot 'data\knowledge-index.json'
$ProdGlassPath = Join-Path $RepoRoot 'research\glass-bridge\card.json'
$ProdCpoPath = Join-Path $RepoRoot 'research\cpo\card.json'
$ProdHandoffPath = Join-Path $RepoRoot 'data\research-candidates-handoff.json'
$ProdLedgerPath = Join-Path $RepoRoot 'data\candidate-gate.json'
$ForbiddenNewsDir = Join-Path $RepoRoot 'data\news'
$ForbiddenEventsDir = Join-Path $RepoRoot 'data\events'
$ServePath = Join-Path $RepoRoot 'serve.ps1'

foreach ($path in @(
  $Sprint009Path, $IndexPath, $StylePath, $DataEnginePath, $GateJsPath, $AppJsPath,
  $GeneratePath, $Spec010Path, $ProdBriefPath, $ProdQueuePath, $ProdCasesPath,
  $ProdIndexPath, $ProdGlassPath, $ProdCpoPath, $ServePath
)) {
  if (-not (Test-Path -LiteralPath $path)) { throw "Missing: $path" }
}

$Utf8 = New-Object System.Text.UTF8Encoding $false
$IndexSrc = [System.IO.File]::ReadAllText($IndexPath, $Utf8)
$StyleSrc = [System.IO.File]::ReadAllText($StylePath, $Utf8)
$DataEngineSrc = [System.IO.File]::ReadAllText($DataEnginePath, $Utf8)
$GateSrc = [System.IO.File]::ReadAllText($GateJsPath, $Utf8)
$AppSrc = [System.IO.File]::ReadAllText($AppJsPath, $Utf8)

$ProdHashBefore = @{
  brief = (Get-FileHash -Path $ProdBriefPath -Algorithm SHA256).Hash
  queue = (Get-FileHash -Path $ProdQueuePath -Algorithm SHA256).Hash
  cases = (Get-FileHash -Path $ProdCasesPath -Algorithm SHA256).Hash
  index = (Get-FileHash -Path $ProdIndexPath -Algorithm SHA256).Hash
  glass = (Get-FileHash -Path $ProdGlassPath -Algorithm SHA256).Hash
  cpo = (Get-FileHash -Path $ProdCpoPath -Algorithm SHA256).Hash
  generate = (Get-FileHash -Path $GeneratePath -Algorithm SHA256).Hash
  integrate = (Get-FileHash -Path $IntegratePath -Algorithm SHA256).Hash
  publish = if (Test-Path -LiteralPath $PublishPath) { (Get-FileHash -Path $PublishPath -Algorithm SHA256).Hash } else { $null }
  handbook = (Get-FileHash -Path $HandbookPath -Algorithm SHA256).Hash
  spec008 = (Get-FileHash -Path $Spec008Path -Algorithm SHA256).Hash
  spec009 = (Get-FileHash -Path $Spec009Path -Algorithm SHA256).Hash
}
if (Test-Path -LiteralPath $ProdHandoffPath) {
  $ProdHashBefore.handoff = (Get-FileHash -Path $ProdHandoffPath -Algorithm SHA256).Hash
}
if (Test-Path -LiteralPath $ProdLedgerPath) {
  $ProdHashBefore.ledger = (Get-FileHash -Path $ProdLedgerPath -Algorithm SHA256).Hash
}

$script:Results = New-Object System.Collections.Generic.List[object]

function Add-TestResult($id, $passed, $details) {
  $status = if ($passed) { 'PASS' } else { 'FAIL' }
  $script:Results.Add([PSCustomObject]@{ Id = $id; Status = $status; Details = $details })
  Write-Output ("{0}: {1}" -f $id, $status)
  if ($details) { Write-Output $details }
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
    generate = (Get-FileHash -Path $GeneratePath -Algorithm SHA256).Hash
    integrate = (Get-FileHash -Path $IntegratePath -Algorithm SHA256).Hash
    handbook = (Get-FileHash -Path $HandbookPath -Algorithm SHA256).Hash
    spec008 = (Get-FileHash -Path $Spec008Path -Algorithm SHA256).Hash
    spec009 = (Get-FileHash -Path $Spec009Path -Algorithm SHA256).Hash
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

function Get-SectionIndex([string]$src, [string]$id) {
  $needle = 'id="' + $id + '"'
  return $src.IndexOf($needle, [System.StringComparison]::Ordinal)
}

# --- Static acceptance ---

$fail112 = New-Object System.Collections.Generic.List[string]
$idsPrimary = @('todayExecutiveSummary', 'todayMarketTemperature', 'todayThreeThings', 'todayCandidateAttention')
$idsSupporting = @('todayGlobalMarket', 'todayTaiwanMarket', 'todayUpcomingEvents')
foreach ($id in ($idsPrimary + $idsSupporting)) {
  if ((Get-SectionIndex $IndexSrc $id) -lt 0) { $fail112.Add("Missing section id=$id") }
}
$idxExec = Get-SectionIndex $IndexSrc 'todayExecutiveSummary'
$idxTemp = Get-SectionIndex $IndexSrc 'todayMarketTemperature'
$idxThree = Get-SectionIndex $IndexSrc 'todayThreeThings'
$idxCand = Get-SectionIndex $IndexSrc 'todayCandidateAttention'
$idxGlobal = Get-SectionIndex $IndexSrc 'todayGlobalMarket'
$idxTaiwan = Get-SectionIndex $IndexSrc 'todayTaiwanMarket'
$idxUpcoming = Get-SectionIndex $IndexSrc 'todayUpcomingEvents'
if (-not ($idxExec -ge 0 -and $idxTemp -gt $idxExec -and $idxThree -gt $idxTemp -and $idxCand -gt $idxThree)) {
  $fail112.Add('Primary path order must be Yesterday -> Market Temperature -> Today 3 Things -> Candidates')
}
foreach ($pair in @(
  @{ Id = 'todayExecutiveSummary'; Needle = 'id="todayExecutiveSummary"' },
  @{ Id = 'todayMarketTemperature'; Needle = 'id="todayMarketTemperature"' },
  @{ Id = 'todayThreeThings'; Needle = 'id="todayThreeThings"' },
  @{ Id = 'todayCandidateAttention'; Needle = 'Research Candidates' }
)) {
  if ($IndexSrc -notlike ("*{0}*" -f $pair.Needle)) { $fail112.Add("Missing primary marker: $($pair.Id)") }
}
Add-TestResult 'TEST 112' ($fail112.Count -eq 0) ($fail112 -join "`n")

$fail113 = New-Object System.Collections.Generic.List[string]
if ($idxThree -gt $idxGlobal -and $idxGlobal -gt 0) {
  $fail113.Add('todayThreeThings still after todayGlobalMarket - primary path buried')
}
if ($idxCand -gt $idxGlobal -and $idxGlobal -gt 0) {
  $fail113.Add('Candidates still after todayGlobalMarket - primary path buried')
}
if ($idxThree -gt $idxTaiwan -and $idxTaiwan -gt 0) {
  $fail113.Add('todayThreeThings still after todayTaiwanMarket - primary path buried')
}
if ($idxCand -gt $idxUpcoming -and $idxUpcoming -gt 0) {
  $fail113.Add('Candidates still after todayUpcomingEvents - primary path buried')
}
if ($IndexSrc -notlike '*data-today-band="primary"*') { $fail113.Add('Missing primary band elevation marker') }
if ($IndexSrc -notlike '*data-today-primary-path="1"*') { $fail113.Add('Missing today primary-path marker') }
Add-TestResult 'TEST 113' ($fail113.Count -eq 0) ($fail113 -join "`n")

$fail114 = New-Object System.Collections.Generic.List[string]
if ($IndexSrc -notlike '*today-primary-band*') { $fail114.Add('primary band missing') }
if ($IndexSrc -notlike '*today-supporting-band*') { $fail114.Add('supporting band missing') }
if ($IndexSrc -notlike '*data-today-role="primary"*') { $fail114.Add('primary role markers missing') }
if ($IndexSrc -notlike '*data-today-role="supporting"*') { $fail114.Add('supporting role markers missing') }
if ($StyleSrc -notlike '*today-primary-band*') { $fail114.Add('CSS primary band missing') }
if ($StyleSrc -notlike '*today-supporting*') { $fail114.Add('CSS supporting hierarchy missing') }
if ($StyleSrc -notlike '*#today.today-workspace #todayThreeThings*') {
  $fail114.Add('CSS does not elevate todayThreeThings to full-width primary')
}
Add-TestResult 'TEST 114' ($fail114.Count -eq 0) ($fail114 -join "`n")

$fail115 = New-Object System.Collections.Generic.List[string]
# Must prove reorder happened vs HEAD conceptual order (Global before Today3Things).
if ($idxThree -lt $idxGlobal) {
  # good
} else {
  $fail115.Add('No DOM reorder: Today 3 Things not elevated above Global')
}
if ($DataEngineSrc -notlike '*keepResidual*') { $fail115.Add('Missing dedup-safety keepResidual — cosmetic-only risk') }
if ($DataEngineSrc -notlike '*briefShortenDisplay*') { $fail115.Add('Missing secondary shorten helper') }
if ($IndexSrc -notlike '*section-role*') { $fail115.Add('Missing section honesty labels') }
Add-TestResult 'TEST 115' ($fail115.Count -eq 0) ($fail115 -join "`n")

$fail116 = New-Object System.Collections.Generic.List[string]
if ($DataEngineSrc -notmatch 'briefShortenDisplay\(text, maxLen\)') {
  $fail116.Add('briefShortenDisplay missing')
}
if ($DataEngineSrc -notlike '*morning-brief-residual*') {
  $fail116.Add('residual presentation class missing')
}
# Must not invent News/Event DBs
if (Test-Path -LiteralPath $ForbiddenNewsDir) { $fail116.Add('data/news created') }
if (Test-Path -LiteralPath $ForbiddenEventsDir) { $fail116.Add('data/events created') }
Add-TestResult 'TEST 116' ($fail116.Count -eq 0) ($fail116 -join "`n")

$fail117 = New-Object System.Collections.Generic.List[string]
foreach ($needle in @(
  "renderTextList('morningTopThings'",
  "setText('morningGlobalMarket'",
  "setText('morningTaiwanMarket'",
  "renderNews('morningGlobalNews'",
  "renderNews('morningTaiwanNews'"
)) {
  if ($DataEngineSrc -notlike "*$needle*") { $fail117.Add("Missing call: $needle") }
}
# keepResidual must appear near supporting / topThings render path
$keepCount = ([regex]::Matches($DataEngineSrc, 'keepResidual:\s*true')).Count
if ($keepCount -lt 5) {
  $fail117.Add("Expected keepResidual:true on topThings + global/taiwan summary/items; found $keepCount")
}
# Empty-only-from-dedup without residual is forbidden pattern for news lists
if ($DataEngineSrc -match "renderNews\('morningGlobalNews'[\s\S]{0,120}?keepResidual:\s*false") {
  $fail117.Add('Global news explicitly disables keepResidual')
}
Add-TestResult 'TEST 117' ($fail117.Count -eq 0) ($fail117 -join "`n")

$fail118 = New-Object System.Collections.Generic.List[string]
if ($GateSrc -notlike '*async renderAttention*') { $fail118.Add('renderAttention missing') }
if ($GateSrc -notlike '*candidate-attention-question*') { $fail118.Add('question class missing') }
if ($GateSrc -notlike '*Research Question:*') { $fail118.Add('Research Question label missing (008 contract)') }
if ($GateSrc -notlike '*isAttentionStatus*') { $fail118.Add('attention status helper missing') }
if ($GateSrc -notlike "*'Pending'*") { $fail118.Add('Pending visibility missing') }
if ($GateSrc -notlike "*'Watching'*") { $fail118.Add('Watching visibility missing') }
if ($GateSrc -notlike '*candidate-attention-compact*') { $fail118.Add('compact attention card missing') }
if ($AppSrc -notlike '*renderAttention*') { $fail118.Add('app.js does not bind Attention') }
Add-TestResult 'TEST 118' ($fail118.Count -eq 0) ($fail118 -join "`n")

$fail119 = New-Object System.Collections.Generic.List[string]
if ($GateSrc -notlike "*showPage('queue')*") { $fail119.Add('Gate navigation missing') }
if ($GateSrc -notlike '*Human Gate*') { $fail119.Add('Human Gate CTA missing') }
$attentionMatch = [regex]::Match($GateSrc, 'async renderAttention\(container\) \{[\s\S]*?\n  \},')
if (-not $attentionMatch.Success) {
  $fail119.Add('Unable to isolate renderAttention body')
} elseif ($attentionMatch.Value -like '*postAction*') {
  $fail119.Add('renderAttention posts Gate actions')
}
Add-TestResult 'TEST 119' ($fail119.Count -eq 0) ($fail119 -join "`n")

$fail120 = New-Object System.Collections.Generic.List[string]
if ($DataEngineSrc -match 'renderMorningBrief[\s\S]*fetch\([^\)]*queue') {
  $fail120.Add('Brief render appears to write Queue')
}
if ($GateSrc -match 'async renderAttention[\s\S]*ensureInQueue') {
  $fail120.Add('Attention ensureInQueue')
}
foreach ($forbidden in @('data/news', 'data/events')) {
  if ($IndexSrc -like "*$forbidden*") { $fail120.Add("UI references $forbidden") }
}
Add-TestResult 'TEST 120' ($fail120.Count -eq 0) ($fail120 -join "`n")

$fail121 = New-Object System.Collections.Generic.List[string]
if ($DataEngineSrc -notlike '*morning-brief.json*') { $fail121.Add('canonical morning-brief.json path missing in data-engine') }
if ((Get-FileHash -Path $GeneratePath -Algorithm SHA256).Hash -ne $ProdHashBefore.generate) {
  $fail121.Add('generate-morning-brief.py was modified')
}
if ((Get-FileHash -Path $IntegratePath -Algorithm SHA256).Hash -ne $ProdHashBefore.integrate) {
  $fail121.Add('integrate-news-event-evaluation.py was modified')
}
if ($ProdHashBefore.publish -and ((Get-FileHash -Path $PublishPath -Algorithm SHA256).Hash -ne $ProdHashBefore.publish)) {
  $fail121.Add('publish-research-candidates-handoff.py was modified')
}
$briefObj = ([System.IO.File]::ReadAllText($ProdBriefPath, $Utf8) | ConvertFrom-Json)
foreach ($field in @(
  'date', 'executiveSummary', 'macroDecisionLens', 'marketTemperature',
  'globalMarketAndNews', 'taiwanMarketAndNews', 'upcomingEvents', 'today3Things'
)) {
  if (-not ($briefObj.PSObject.Properties.Name -contains $field)) {
    $fail121.Add("Brief missing canonical field: $field")
  }
}
# Highlights may be surfaced as supporting display-only
if ($IndexSrc -notlike '*morningAiHighlights*') { $fail121.Add('aiIndustryHighlights surface container missing') }
Add-TestResult 'TEST 121' ($fail121.Count -eq 0) ($fail121 -join "`n")

# Live DOM order via HTTP against repo files (does not kill production :8765).
$script:TestPort = Get-Random -Minimum 18700 -Maximum 18900
$script:ServerProc = $null
$script:TempServe = Join-Path $env:TEMP ('InvestorTwin-p2-010-serve-' + [guid]::NewGuid().ToString('N') + '.ps1')
try {
  $serveSrc = [System.IO.File]::ReadAllText($ServePath, $Utf8)
  $needle = 'Write-Output "Serving HTTP on http://localhost:$port/"'
  $idx = $serveSrc.IndexOf($needle)
  if ($idx -lt 0) { throw 'Unable to patch serve.ps1 header' }
  $end = $idx + $needle.Length
  if ($end -lt $serveSrc.Length -and $serveSrc[$end] -eq "`r") { $end++ }
  if ($end -lt $serveSrc.Length -and $serveSrc[$end] -eq "`n") { $end++ }
  $rootLiteral = $RepoRoot.Replace("'", "''")
  $header = @"
`$root = '$rootLiteral'
`$port = $($script:TestPort)
`$listener = New-Object System.Net.HttpListener
`$listener.Prefixes.Add("http://localhost:`$port/")
try { `$listener.Start() } catch { Write-Error "Port `$port is in use."; exit 1 }
Write-Output "Serving HTTP on http://localhost:`$port/"

"@
  [System.IO.File]::WriteAllText($script:TempServe, ($header + $serveSrc.Substring($end)), $Utf8)
  $script:ServerProc = Start-Process -FilePath 'powershell' -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:TempServe
  ) -WorkingDirectory $RepoRoot -PassThru -WindowStyle Hidden
  $ready = $false
  $liveHtml = ''
  for ($i = 0; $i -lt 50; $i++) {
    Start-Sleep -Milliseconds 300
    try {
      $resp = Invoke-WebRequest -Uri ("http://localhost:{0}/" -f $script:TestPort) -UseBasicParsing -TimeoutSec 2
      if ($resp.StatusCode -eq 200) { $ready = $true; $liveHtml = $resp.Content; break }
    } catch { }
  }
  $failLive = New-Object System.Collections.Generic.List[string]
  if (-not $ready) {
    $failLive.Add('Temp server failed to serve index for live order check')
  } else {
    $liveExec = Get-SectionIndex $liveHtml 'todayExecutiveSummary'
    $liveThree = Get-SectionIndex $liveHtml 'todayThreeThings'
    $liveCand = Get-SectionIndex $liveHtml 'todayCandidateAttention'
    $liveGlobal = Get-SectionIndex $liveHtml 'todayGlobalMarket'
    if (-not ($liveExec -ge 0 -and $liveThree -gt $liveExec -and $liveCand -gt $liveThree -and $liveThree -lt $liveGlobal)) {
      $failLive.Add('Live HTML primary path order failed')
    }
    if ($liveHtml -notlike '*data-today-band="primary"*') { $failLive.Add('Live HTML missing primary band') }
  }
  if ($failLive.Count -gt 0) {
    Add-TestResult 'TEST 112-LIVE' $false ($failLive -join "`n")
  } else {
    Add-TestResult 'TEST 112-LIVE' $true 'Live index primary path order OK'
  }
} finally {
  if ($script:ServerProc -and -not $script:ServerProc.HasExited) {
    try { Stop-Process -Id $script:ServerProc.Id -Force -ErrorAction SilentlyContinue } catch { }
  }
  if (Test-Path -LiteralPath $script:TempServe) {
    Remove-Item -LiteralPath $script:TempServe -Force -ErrorAction SilentlyContinue
  }
}

# Regression 001-009
$regOk = $false
$regOut = ''
try {
  $regOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $Sprint009Path 2>&1 | Out-String
  $regOk = ($LASTEXITCODE -eq 0)
} catch {
  $regOk = $false
  $regOut = [string]$_
}
Add-TestResult 'TEST 122-REG' $regOk $(if ($regOk) { 'Sprint 001-009 regression PASS' } else { $regOut.Substring(0, [Math]::Min(2000, $regOut.Length)) })
Add-TestResult 'TEST 122' $regOk 'Sprint 001-009 regression PASS'

$guardOk = Test-ProtectedHashes
Add-TestResult 'TEST 123' $guardOk $(if ($guardOk) { 'Production File Guard PASS' } else { 'Production protected files changed or forbidden dirs appeared' })

Write-Output ''
Write-Output '=== P2-010 SUMMARY ==='
$script:Results | ForEach-Object {
  Write-Output ("{0}: {1}" -f $_.Id, $_.Status)
  if ($_.Details) { Write-Output $_.Details }
}
$failed = @($script:Results | Where-Object { $_.Status -ne 'PASS' })
if ($failed.Count -gt 0) { exit 1 }
exit 0
