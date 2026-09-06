$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$env:PYTHONIOENCODING = 'utf-8'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$Sprint007Path = Join-Path $PSScriptRoot 'p2-007-research-card-candidate-surface.ps1'
$HandoffFixture = Join-Path $PSScriptRoot 'fixtures\p2-006-handoff-case-a.json'
$ServePath = Join-Path $RepoRoot 'serve.ps1'
$GateJsPath = Join-Path $RepoRoot 'js\candidate-gate.js'
$AppJsPath = Join-Path $RepoRoot 'app.js'
$IndexPath = Join-Path $RepoRoot 'index.html'
$StylePath = Join-Path $RepoRoot 'style.css'
$DataEnginePath = Join-Path $RepoRoot 'js\data-engine.js'
$GeneratePath = Join-Path $RepoRoot 'scripts\generate-morning-brief.py'
$CollectPath = Join-Path $RepoRoot 'scripts\collect-evidence.py'
$IntegratePath = Join-Path $RepoRoot 'scripts\integrate-news-event-evaluation.py'
$EvalPath = Join-Path $RepoRoot 'scripts\evaluate-news-intelligence.py'
$LinkPath = Join-Path $RepoRoot 'scripts\link-news-events.py'
$NvidiaAdapterPath = Join-Path $RepoRoot 'scripts\nvidia-official-adapter.py'
$FedAdapterPath = Join-Path $RepoRoot 'scripts\federal-reserve-official-adapter.py'
$Spec001Path = Join-Path $RepoRoot 'docs\Phase 2 Sprint 001 News Intelligence Foundation SPEC.md'
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

foreach ($path in @(
  $Sprint007Path, $HandoffFixture, $ServePath, $GateJsPath, $AppJsPath, $IndexPath, $StylePath,
  $DataEnginePath, $Spec008Path, $ProdBriefPath, $ProdQueuePath, $ProdCasesPath, $ProdIndexPath,
  $ProdGlassPath, $ProdCpoPath
)) {
  if (-not (Test-Path -LiteralPath $path)) { throw "Missing: $path" }
}

$Utf8 = New-Object System.Text.UTF8Encoding $false
$GateSrc = [System.IO.File]::ReadAllText($GateJsPath, $Utf8)
$AppSrc = [System.IO.File]::ReadAllText($AppJsPath, $Utf8)
$IndexSrc = [System.IO.File]::ReadAllText($IndexPath, $Utf8)
$DataEngineSrc = [System.IO.File]::ReadAllText($DataEnginePath, $Utf8)
$Handoff = [System.IO.File]::ReadAllText($HandoffFixture, $Utf8) | ConvertFrom-Json
$EventRef = [string]$Handoff.researchCandidates[0].eventRef
$ResearchQuestion = [string]$Handoff.researchCandidates[0].researchQuestion
$Evaluation = @($Handoff.evaluations | Where-Object { $_.eventRef -eq $EventRef })[0]

$ProdHashBefore = @{
  brief = (Get-FileHash -Path $ProdBriefPath -Algorithm SHA256).Hash
  queue = (Get-FileHash -Path $ProdQueuePath -Algorithm SHA256).Hash
  cases = (Get-FileHash -Path $ProdCasesPath -Algorithm SHA256).Hash
  index = (Get-FileHash -Path $ProdIndexPath -Algorithm SHA256).Hash
  glass = (Get-FileHash -Path $ProdGlassPath -Algorithm SHA256).Hash
  cpo = (Get-FileHash -Path $ProdCpoPath -Algorithm SHA256).Hash
  generate = (Get-FileHash -Path $GeneratePath -Algorithm SHA256).Hash
  collect = (Get-FileHash -Path $CollectPath -Algorithm SHA256).Hash
  eval = (Get-FileHash -Path $EvalPath -Algorithm SHA256).Hash
  link = (Get-FileHash -Path $LinkPath -Algorithm SHA256).Hash
  integrate = (Get-FileHash -Path $IntegratePath -Algorithm SHA256).Hash
  nvidia = (Get-FileHash -Path $NvidiaAdapterPath -Algorithm SHA256).Hash
  fed = (Get-FileHash -Path $FedAdapterPath -Algorithm SHA256).Hash
  handbook = (Get-FileHash -Path $HandbookPath -Algorithm SHA256).Hash
  spec001 = (Get-FileHash -Path $Spec001Path -Algorithm SHA256).Hash
  dataEngine = (Get-FileHash -Path $DataEnginePath -Algorithm SHA256).Hash
}
if (Test-Path -LiteralPath $ProdHandoffPath) {
  $ProdHashBefore.handoff = (Get-FileHash -Path $ProdHandoffPath -Algorithm SHA256).Hash
}
if (Test-Path -LiteralPath $ProdLedgerPath) {
  $ProdHashBefore.ledger = (Get-FileHash -Path $ProdLedgerPath -Algorithm SHA256).Hash
}

$script:Results = New-Object System.Collections.Generic.List[object]
$script:TempRoot = Join-Path $env:TEMP ('InvestorTwin-p2-008-' + [guid]::NewGuid().ToString('N'))
$script:TestPort = $null
$script:ServerProc = $null

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

function Test-IsAttentionStatus($status) {
  $value = if ($status) { [string]$status } else { 'Pending' }
  return ($value -eq 'Pending' -or $value -eq 'Watching')
}

function Get-AttentionCandidates($gateView) {
  $rows = @()
  foreach ($item in @(Get-AsArraySafe $gateView.candidates)) {
    if (Test-IsAttentionStatus $item.status) { $rows += $item }
  }
  return $rows
}

function Get-AsArraySafe($value) {
  if ($null -eq $value) { return @() }
  if ($value -is [System.Array]) { return @($value) }
  return @($value)
}

function New-PatchedServeScript($sourcePath, $destPath) {
  $src = [System.IO.File]::ReadAllText($sourcePath, $Utf8)
  $needle = 'Write-Output "Serving HTTP on http://localhost:$port/"'
  $idx = $src.IndexOf($needle)
  if ($idx -lt 0) { throw 'Unable to patch temp serve.ps1 header' }
  $end = $idx + $needle.Length
  if ($end -lt $src.Length -and $src[$end] -eq "`r") { $end++ }
  if ($end -lt $src.Length -and $src[$end] -eq "`n") { $end++ }
  $header = @'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$port = [int]$env:INVESTORTWIN_TEST_PORT
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$port/")
try {
  $listener.Start()
} catch {
  Write-Error "Port $port is in use."
  exit 1
}
Write-Output "Serving HTTP on http://localhost:$port/"

'@
  [System.IO.File]::WriteAllText($destPath, ($header + $src.Substring($end)), $Utf8)
}

function Initialize-TempRoot {
  New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null
  foreach ($name in @('data', 'research', 'scripts', 'js', 'docs', 'tests')) {
    New-Item -ItemType Directory -Path (Join-Path $script:TempRoot $name) -Force | Out-Null
  }
  Copy-Item -LiteralPath $ServePath -Destination (Join-Path $script:TempRoot 'serve.ps1') -Force
  Copy-Item -LiteralPath $ProdBriefPath -Destination (Join-Path $script:TempRoot 'data\morning-brief.json') -Force
  Copy-Item -LiteralPath $ProdCasesPath -Destination (Join-Path $script:TempRoot 'data\investment-cases.json') -Force
  Copy-Item -LiteralPath $ProdIndexPath -Destination (Join-Path $script:TempRoot 'data\knowledge-index.json') -Force
  Copy-Item -LiteralPath (Join-Path $RepoRoot 'data\opportunity-radar.json') -Destination (Join-Path $script:TempRoot 'data\opportunity-radar.json') -Force -ErrorAction SilentlyContinue
  Copy-Item -LiteralPath (Join-Path $RepoRoot 'data\investment-thesis.json') -Destination (Join-Path $script:TempRoot 'data\investment-thesis.json') -Force -ErrorAction SilentlyContinue
  Copy-Item -LiteralPath $HandoffFixture -Destination (Join-Path $script:TempRoot 'data\research-candidates-handoff.json') -Force
  Write-JsonFile (Join-Path $script:TempRoot 'data\candidate-gate.json') @{ schemaVersion = '1.0'; dispositions = @() }
  Write-JsonFile (Join-Path $script:TempRoot 'data\research-queue.json') @{ items = @() }

  $cardDir = Join-Path $script:TempRoot 'research\cpo'
  New-Item -ItemType Directory -Path $cardDir -Force | Out-Null
  Write-JsonFile (Join-Path $cardDir 'card.json') @{
    id = 'cpo'
    title = 'CPO'
    summary = ''
    questions = @('Existing research question')
    status = 'researching'
    updated = '2026-08-23'
    investmentThesis = 'Existing thesis text'
    researchConclusion = @{
      conclusion = 'Existing conclusion must not change'
      status = 'uncertain'
      asOf = '2026-08-23'
    }
    researchConclusionHistory = @()
  }
  '[]' | Set-Content (Join-Path $cardDir 'notes.json') -Encoding UTF8
  '[]' | Set-Content (Join-Path $cardDir 'timeline.json') -Encoding UTF8
  '[]' | Set-Content (Join-Path $cardDir 'sources.json') -Encoding UTF8

  New-PatchedServeScript $ServePath (Join-Path $script:TempRoot 'serve.ps1')
}

function Start-TempServer {
  $script:TestPort = Get-Random -Minimum 18000 -Maximum 24000
  $env:INVESTORTWIN_TEST_PORT = [string]$script:TestPort
  $logOut = Join-Path $script:TempRoot 'serve-out.log'
  $logErr = Join-Path $script:TempRoot 'serve-err.log'
  $script:ServerProc = Start-Process -FilePath 'powershell.exe' -WorkingDirectory $script:TempRoot -PassThru -WindowStyle Hidden `
    -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', '.\serve.ps1') `
    -RedirectStandardOutput $logOut -RedirectStandardError $logErr
  for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 250
    try {
      $probe = Invoke-WebRequest -Uri ("http://localhost:{0}/api/candidate-gate" -f $script:TestPort) -UseBasicParsing
      if ($probe.StatusCode -eq 200) { return }
    } catch {}
  }
  $errText = ''
  if (Test-Path $logErr) { $errText = Get-Content $logErr -Raw }
  throw ("Temp serve.ps1 failed to start. $errText")
}

function Stop-TempServer {
  if ($script:ServerProc -and -not $script:ServerProc.HasExited) {
    Stop-Process -Id $script:ServerProc.Id -Force -ErrorAction SilentlyContinue
  }
  if (Test-Path -LiteralPath $script:TempRoot) {
    Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}

function Invoke-GateGet {
  $uri = "http://localhost:$($script:TestPort)/api/candidate-gate"
  $res = Invoke-WebRequest -Uri $uri -UseBasicParsing
  return ($res.Content | ConvertFrom-Json)
}

function Invoke-GatePost($body) {
  $uri = "http://localhost:$($script:TestPort)/api/candidate-gate"
  $json = $body | ConvertTo-Json -Depth 8 -Compress
  try {
    $res = Invoke-WebRequest -Uri $uri -Method POST -Body $json -ContentType 'application/json; charset=utf-8' -UseBasicParsing
    return @{ StatusCode = [int]$res.StatusCode; Body = ($res.Content | ConvertFrom-Json) }
  } catch {
    $resp = $_.Exception.Response
    if (-not $resp) { throw }
    $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
    $text = $reader.ReadToEnd()
    return @{ StatusCode = [int]$resp.StatusCode; Body = ($text | ConvertFrom-Json) }
  }
}

function Test-ProtectedHashes {
  $ok = (
    (Get-FileHash -Path $ProdBriefPath -Algorithm SHA256).Hash -eq $ProdHashBefore.brief -and
    (Get-FileHash -Path $ProdQueuePath -Algorithm SHA256).Hash -eq $ProdHashBefore.queue -and
    (Get-FileHash -Path $ProdCasesPath -Algorithm SHA256).Hash -eq $ProdHashBefore.cases -and
    (Get-FileHash -Path $ProdIndexPath -Algorithm SHA256).Hash -eq $ProdHashBefore.index -and
    (Get-FileHash -Path $ProdGlassPath -Algorithm SHA256).Hash -eq $ProdHashBefore.glass -and
    (Get-FileHash -Path $ProdCpoPath -Algorithm SHA256).Hash -eq $ProdHashBefore.cpo -and
    (Get-FileHash -Path $GeneratePath -Algorithm SHA256).Hash -eq $ProdHashBefore.generate -and
    (Get-FileHash -Path $CollectPath -Algorithm SHA256).Hash -eq $ProdHashBefore.collect -and
    (Get-FileHash -Path $EvalPath -Algorithm SHA256).Hash -eq $ProdHashBefore.eval -and
    (Get-FileHash -Path $LinkPath -Algorithm SHA256).Hash -eq $ProdHashBefore.link -and
    (Get-FileHash -Path $IntegratePath -Algorithm SHA256).Hash -eq $ProdHashBefore.integrate -and
    (Get-FileHash -Path $NvidiaAdapterPath -Algorithm SHA256).Hash -eq $ProdHashBefore.nvidia -and
    (Get-FileHash -Path $FedAdapterPath -Algorithm SHA256).Hash -eq $ProdHashBefore.fed -and
    (Get-FileHash -Path $HandbookPath -Algorithm SHA256).Hash -eq $ProdHashBefore.handbook -and
    (Get-FileHash -Path $Spec001Path -Algorithm SHA256).Hash -eq $ProdHashBefore.spec001 -and
    (Get-FileHash -Path $DataEnginePath -Algorithm SHA256).Hash -eq $ProdHashBefore.dataEngine -and
    -not (Test-Path -LiteralPath $ForbiddenNewsDir) -and
    -not (Test-Path -LiteralPath $ForbiddenEventsDir)
  )
  if ($ProdHashBefore.ContainsKey('handoff') -and (Test-Path -LiteralPath $ProdHandoffPath)) {
    $ok = $ok -and ((Get-FileHash -Path $ProdHandoffPath -Algorithm SHA256).Hash -eq $ProdHashBefore.handoff)
  }
  if ($ProdHashBefore.ContainsKey('ledger') -and (Test-Path -LiteralPath $ProdLedgerPath)) {
    $ok = $ok -and ((Get-FileHash -Path $ProdLedgerPath -Algorithm SHA256).Hash -eq $ProdHashBefore.ledger)
  }
  return $ok
}

try {
Write-Output '=== P2-007 REGRESSION (includes 001-006) ==='
$sprint007 = & powershell -NoProfile -File $Sprint007Path
$sprint007Text = ($sprint007 | ForEach-Object { "$_" }) -join "`n"
Add-TestResult 'TEST 100-REG' ($LASTEXITCODE -eq 0) $(if ($LASTEXITCODE -eq 0) { 'Sprint 001-007 regression PASS' } else { $sprint007Text })

Write-Output ''
Write-Output '=== P2-008 CANDIDATE ATTENTION ==='

$failUi = New-Object System.Collections.Generic.List[string]
if ($IndexSrc -notlike '*todayCandidateAttention*') { $failUi.Add('index.html missing Attention section') }
if ($IndexSrc -notlike '*morningCandidateAttention*') { $failUi.Add('index.html missing Attention container') }
if ($IndexSrc -notlike '*data-candidate-attention="1"*') { $failUi.Add('index.html missing Attention marker') }
if ($IndexSrc -notlike '*Research Candidates*') { $failUi.Add('index.html missing Attention label') }
if ($GateSrc -notlike '*isAttentionStatus*') { $failUi.Add('candidate-gate.js missing isAttentionStatus') }
if ($GateSrc -notlike '*attentionCandidates*') { $failUi.Add('candidate-gate.js missing attentionCandidates') }
if ($GateSrc -notlike '*renderAttention*') { $failUi.Add('candidate-gate.js missing renderAttention') }
if ($GateSrc -notlike '*goToHumanGate*') { $failUi.Add('candidate-gate.js missing goToHumanGate') }
if ($GateSrc -notlike "*showPage('queue')*") { $failUi.Add('goToHumanGate does not navigate to queue') }
if ($AppSrc -notlike '*renderAttention*') { $failUi.Add('app.js does not wire renderAttention into Today') }
if ($AppSrc -notlike '*morningCandidateAttention*') { $failUi.Add('app.js missing Attention container hook') }
if ($GateSrc -notlike '*data-attention-research-question*') { $failUi.Add('Attention UI missing researchQuestion marker') }
if ($GateSrc -notlike '*data-goto-queue*') { $failUi.Add('Attention UI missing queue navigation marker') }
# Ensure renderAttention does not POST dispositions.
$attentionFn = [regex]::Match($GateSrc, 'async renderAttention\(container\) \{[\s\S]*?\n  \},')
if (-not $attentionFn.Success) { $failUi.Add('Unable to isolate renderAttention function') }
elseif ($attentionFn.Value -like '*postAction*' -or $attentionFn.Value -like '*method: ''POST''*' -or $attentionFn.Value -like '*method: "POST"*') {
  $failUi.Add('renderAttention must not POST Gate actions')
}
if ($DataEngineSrc -like '*researchCandidateAttention*' -or $DataEngineSrc -like '*renderAttention*') {
  $failUi.Add('data-engine.js should not own Candidate Attention persistence in Sprint 008 derived path')
}
if ($IndexSrc -like '*globalMarketAndNews*researchCandidate*') {
  $failUi.Add('Must not stuff Candidates into globalMarketAndNews')
}

Initialize-TempRoot
Start-TempServer

$queueBefore = Read-JsonFile (Join-Path $script:TempRoot 'data\research-queue.json')
$cardBefore = Read-JsonFile (Join-Path $script:TempRoot 'research\cpo\card.json')
$briefBefore = Read-JsonFile (Join-Path $script:TempRoot 'data\morning-brief.json')
$briefHashBefore = (Get-FileHash -Path (Join-Path $script:TempRoot 'data\morning-brief.json') -Algorithm SHA256).Hash

$viewPending = Invoke-GateGet
$attentionPending = @(Get-AttentionCandidates $viewPending)
$pendingRow = @($attentionPending | Where-Object { $_.eventRef -eq $EventRef })[0]

$fail89 = New-Object System.Collections.Generic.List[string]
if ($failUi.Count -gt 0) { $fail89.AddRange($failUi) }
if (-not $pendingRow) { $fail89.Add('Pending Candidate missing from Attention filter') }
elseif ([string]$pendingRow.status -ne 'Pending') { $fail89.Add("expected Pending, got $($pendingRow.status)") }
Add-TestResult 'TEST 89' ($fail89.Count -eq 0) ($fail89 -join "`n")

$watch = Invoke-GatePost @{ action = 'watch'; eventRef = $EventRef }
$viewWatch = Invoke-GateGet
$attentionWatch = @(Get-AttentionCandidates $viewWatch)
$watchRow = @($attentionWatch | Where-Object { $_.eventRef -eq $EventRef })[0]
$fail90 = New-Object System.Collections.Generic.List[string]
if ($watch.StatusCode -ne 200) { $fail90.Add("watch status=$($watch.StatusCode)") }
if (-not $watchRow) { $fail90.Add('Watching Candidate missing from Attention') }
elseif ([string]$watchRow.status -ne 'Watching') { $fail90.Add("expected Watching, got $($watchRow.status)") }
Add-TestResult 'TEST 90' ($fail90.Count -eq 0) ($fail90 -join "`n")

# Reset to Pending via empty ledger rewrite is not supported; use a fresh event path:
# Ignore the watched candidate and verify exclusion; then use second fixture candidate if present,
# otherwise re-seed ledger/handoff for ignore/link/queue cases on copies.
$ignore = Invoke-GatePost @{ action = 'ignore'; eventRef = $EventRef }
$viewIgnored = Invoke-GateGet
$attentionIgnored = @(Get-AttentionCandidates $viewIgnored)
$fail91 = New-Object System.Collections.Generic.List[string]
if ($ignore.StatusCode -ne 200) { $fail91.Add("ignore status=$($ignore.StatusCode)") }
if (@($attentionIgnored | Where-Object { $_.eventRef -eq $EventRef }).Count -ne 0) {
  $fail91.Add('Ignored Candidate still appears in Attention')
}
Add-TestResult 'TEST 91' ($fail91.Count -eq 0) ($fail91 -join "`n")

# Seed a second eligible candidate for Linked / Queued tests without conflicting with Ignored state.
$handoffPath = Join-Path $script:TempRoot 'data\research-candidates-handoff.json'
$handoffObj = Read-JsonFile $handoffPath
$secondRef = 'evt:test/sprint-008/second-candidate'
$secondQuestion = 'Does Sprint 008 second Candidate remain linkable after first Ignored?'
$handoffObj.researchCandidates = @(
  $handoffObj.researchCandidates[0],
  [PSCustomObject]@{
    eventRef = $secondRef
    eligible = $true
    reason = 'Test second candidate'
    researchQuestion = $secondQuestion
    stance = $null
  }
)
$handoffObj.evaluations = @(
  $handoffObj.evaluations[0],
  [PSCustomObject]@{
    eventRef = $secondRef
    importance = [int]$Evaluation.importance
    relevance = [string]$Evaluation.relevance
    relevanceBasis = 'Sprint 008 test'
    impact = $Evaluation.impact
    evidenceRefs = $Evaluation.evidenceRefs
    researchCandidate = [PSCustomObject]@{
      eligible = $true
      reason = 'Test'
      researchQuestion = $secondQuestion
      stance = $null
      eventRef = $secondRef
    }
  }
)
Write-JsonFile $handoffPath $handoffObj

$link = Invoke-GatePost @{ action = 'link'; eventRef = $secondRef; cardId = 'cpo' }
$viewLinked = Invoke-GateGet
$attentionLinked = @(Get-AttentionCandidates $viewLinked)
$fail92 = New-Object System.Collections.Generic.List[string]
if ($link.StatusCode -ne 200) { $fail92.Add("link status=$($link.StatusCode) $($link.Body.message)") }
if (@($attentionLinked | Where-Object { $_.eventRef -eq $secondRef }).Count -ne 0) {
  $fail92.Add('Linked Candidate still appears as pending Attention')
}
Add-TestResult 'TEST 92' ($fail92.Count -eq 0) ($fail92 -join "`n")

# Third candidate for Queue exclusion.
$thirdRef = 'evt:test/sprint-008/third-candidate'
$thirdQuestion = 'Does Sprint 008 Queued Candidate leave Attention?'
$handoffObj = Read-JsonFile $handoffPath
$handoffObj.researchCandidates = @(
  @(Get-AsArraySafe $handoffObj.researchCandidates) + @(
    [PSCustomObject]@{
      eventRef = $thirdRef
      eligible = $true
      reason = 'Test third candidate'
      researchQuestion = $thirdQuestion
      stance = $null
    }
  )
)
$handoffObj.evaluations = @(
  @(Get-AsArraySafe $handoffObj.evaluations) + @(
    [PSCustomObject]@{
      eventRef = $thirdRef
      importance = [int]$Evaluation.importance
      relevance = [string]$Evaluation.relevance
      relevanceBasis = 'Sprint 008 queue test'
      impact = $Evaluation.impact
      evidenceRefs = $Evaluation.evidenceRefs
      researchCandidate = [PSCustomObject]@{
        eligible = $true
        reason = 'Test'
        researchQuestion = $thirdQuestion
        stance = $null
        eventRef = $thirdRef
      }
    }
  )
)
Write-JsonFile $handoffPath $handoffObj

$queue = Invoke-GatePost @{ action = 'queue'; eventRef = $thirdRef; cardId = 'cpo' }
$viewQueued = Invoke-GateGet
$attentionQueued = @(Get-AttentionCandidates $viewQueued)
$fail93 = New-Object System.Collections.Generic.List[string]
if ($queue.StatusCode -ne 200) { $fail93.Add("queue status=$($queue.StatusCode) $($queue.Body.message)") }
if (@($attentionQueued | Where-Object { $_.eventRef -eq $thirdRef }).Count -ne 0) {
  $fail93.Add('Queued Candidate still appears as pending Attention')
}
Add-TestResult 'TEST 93' ($fail93.Count -eq 0) ($fail93 -join "`n")

$fail94 = New-Object System.Collections.Generic.List[string]
if ($GateSrc -notmatch 'candidate-attention-question') { $fail94.Add('Attention UI missing primary question class') }
if ($GateSrc -notlike '*Research Question:*') { $fail94.Add('Attention UI missing Research Question label') }
# Headline must not be primary attention text marker.
if ($GateSrc -match 'async renderAttention\(container\) \{[\s\S]*?<h3>.*title') {
  $fail94.Add('Attention appears to prioritize headline/title over researchQuestion')
}
if (-not $ResearchQuestion) { $fail94.Add('fixture researchQuestion missing') }
Add-TestResult 'TEST 94' ($fail94.Count -eq 0) ($fail94 -join "`n")

$fail95 = New-Object System.Collections.Generic.List[string]
foreach ($needle in @('Importance:', 'Relevance:', 'Impact:')) {
  if ($GateSrc -notlike "*$needle*") { $fail95.Add("Attention UI missing $needle") }
}
if ($null -eq $Evaluation.importance) { $fail95.Add('fixture importance missing') }
Add-TestResult 'TEST 95' ($fail95.Count -eq 0) ($fail95 -join "`n")

$fail96 = New-Object System.Collections.Generic.List[string]
if ($GateSrc -notlike '*data-attention-event-ref*') { $fail96.Add('Attention UI missing eventRef attribute') }
if ($GateSrc -notlike '*data-attention-event-ref-text*') { $fail96.Add('Attention UI missing eventRef text marker') }
if (-not $EventRef) { $fail96.Add('fixture eventRef missing') }
Add-TestResult 'TEST 96' ($fail96.Count -eq 0) ($fail96 -join "`n")

$fail97 = New-Object System.Collections.Generic.List[string]
if ($GateSrc -notlike "*showPage('queue')*") { $fail97.Add('Attention navigation missing showPage(queue)') }
if ($IndexSrc -notlike '*id="queue"*') { $fail97.Add('queue page missing') }
if ($IndexSrc -notlike '*queueResearchCandidates*') { $fail97.Add('Human Gate container missing') }
if ($GateSrc -notlike '*queueResearchCandidates*') { $fail97.Add('goToHumanGate does not target Gate container') }
Add-TestResult 'TEST 97' ($fail97.Count -eq 0) ($fail97 -join "`n")

$cardAfter = Read-JsonFile (Join-Path $script:TempRoot 'research\cpo\card.json')
$queueAfter = Read-JsonFile (Join-Path $script:TempRoot 'data\research-queue.json')
$briefAfter = Read-JsonFile (Join-Path $script:TempRoot 'data\morning-brief.json')
$fail98 = New-Object System.Collections.Generic.List[string]
# Attention path itself must not auto-write; explicit Gate Link/Queue in this suite may write.
# Verify Attention helpers do not POST, and Brief/Conclusion unchanged by Attention rendering source.
if ($attentionFn.Success -and ($attentionFn.Value -like '*postAction*' -or $attentionFn.Value -like '*Ensure-Queue*' )) {
  $fail98.Add('Attention render path mutates Gate/Queue')
}
if ([string]$cardAfter.researchConclusion.conclusion -ne [string]$cardBefore.researchConclusion.conclusion) {
  $fail98.Add('researchConclusion changed unexpectedly beyond explicit Link content checks')
}
# Conclusion text must remain the same string even after Link (Sprint 006/007 contract).
if ([string]$cardAfter.researchConclusion.conclusion -ne 'Existing conclusion must not change') {
  $fail98.Add('Conclusion rewritten')
}
if ([string]$cardAfter.investmentThesis -ne [string]$cardBefore.investmentThesis) {
  $fail98.Add('investmentThesis changed')
}
# Brief Evidence payload must not be rewritten by Gate/Attention tests.
$briefHashAfter = (Get-FileHash -Path (Join-Path $script:TempRoot 'data\morning-brief.json') -Algorithm SHA256).Hash
if ($briefHashBefore -ne $briefHashAfter) { $fail98.Add('morning-brief.json mutated by Attention/Gate tests') }
# Attention-only: queue before any Gate queue action had 0 items; after explicit queue action items may exist.
# Ensure renderAttention source does not call ensureInQueue / queue API.
if ($GateSrc -match 'async renderAttention[\s\S]*ensureInQueue') { $fail98.Add('renderAttention touches Queue') }
Add-TestResult 'TEST 98' ($fail98.Count -eq 0) ($fail98 -join "`n")

$fail99 = New-Object System.Collections.Generic.List[string]
foreach ($field in @(
  'date', 'executiveSummary', 'macroDecisionLens', 'marketTemperature',
  'globalMarketAndNews', 'taiwanMarketAndNews', 'upcomingEvents', 'today3Things'
)) {
  if (-not ($briefBefore.PSObject.Properties.Name -contains $field)) {
    $fail99.Add("Brief missing canonical field: $field")
  }
}
if ($IndexSrc -notlike '*morningMarketTemperature*') { $fail99.Add('Market Temperature UI missing') }
if ($IndexSrc -notlike '*morningGlobalNews*') { $fail99.Add('Global Market UI missing') }
if ($IndexSrc -notlike '*morningTaiwanNews*') { $fail99.Add('Taiwan Market UI missing') }
if ($IndexSrc -notlike '*morningUpcomingEvents*') { $fail99.Add('Upcoming Events UI missing') }
if ($IndexSrc -notlike '*morningTodaysThreeThings*') { $fail99.Add("Today's 3 Things UI missing") }
if ((Get-FileHash -Path $GeneratePath -Algorithm SHA256).Hash -ne $ProdHashBefore.generate) {
  $fail99.Add('generate-morning-brief.py was modified')
}
Add-TestResult 'TEST 99' ($fail99.Count -eq 0) ($fail99 -join "`n")

Add-TestResult 'TEST 100' (($script:Results | Where-Object { $_.Id -eq 'TEST 100-REG' }).Status -eq 'PASS') 'Sprint 001-007 regression PASS'

$guardOk = Test-ProtectedHashes
Add-TestResult 'TEST 101' $guardOk $(if ($guardOk) { 'Production File Guard PASS' } else { 'Production protected files changed or forbidden dirs appeared' })

Write-Output ''
Write-Output '=== P2-008 SUMMARY ==='
$script:Results | ForEach-Object {
  Write-Output ("{0}: {1}" -f $_.Id, $_.Status)
  if ($_.Details) { Write-Output $_.Details }
}
$failed = @($script:Results | Where-Object { $_.Status -ne 'PASS' })
if ($failed.Count -gt 0) { exit 1 }
exit 0
}
finally {
  Stop-TempServer
}
