$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$env:PYTHONIOENCODING = 'utf-8'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$Sprint008Path = Join-Path $PSScriptRoot 'p2-008-morning-brief-candidate-attention.ps1'
$CaseA = Join-Path $PSScriptRoot 'fixtures\p2-005-case-a-nvidia-same-event.json'
$IntegratePath = Join-Path $RepoRoot 'scripts\integrate-news-event-evaluation.py'
$PublishPath = Join-Path $RepoRoot 'scripts\publish-research-candidates-handoff.py'
$ServePath = Join-Path $RepoRoot 'serve.ps1'
$GeneratePath = Join-Path $RepoRoot 'scripts\generate-morning-brief.py'
$CollectPath = Join-Path $RepoRoot 'scripts\collect-evidence.py'
$EvalPath = Join-Path $RepoRoot 'scripts\evaluate-news-intelligence.py'
$LinkPath = Join-Path $RepoRoot 'scripts\link-news-events.py'
$NvidiaAdapterPath = Join-Path $RepoRoot 'scripts\nvidia-official-adapter.py'
$FedAdapterPath = Join-Path $RepoRoot 'scripts\federal-reserve-official-adapter.py'
$Spec001Path = Join-Path $RepoRoot 'docs\Phase 2 Sprint 001 News Intelligence Foundation SPEC.md'
$Spec008Path = Join-Path $RepoRoot 'docs\Phase 2 Sprint 008 News Intelligence Morning Brief Candidate Attention SPEC.md'
$Spec009Path = Join-Path $RepoRoot 'docs\Phase 2 Sprint 009 Research Candidate Handoff Publish SPEC.md'
$HandbookPath = Join-Path $RepoRoot 'docs\Investor Twin Handbook V2.0.md'
$ProdBriefPath = Join-Path $RepoRoot 'data\morning-brief.json'
$ProdQueuePath = Join-Path $RepoRoot 'data\research-queue.json'
$ProdCasesPath = Join-Path $RepoRoot 'data\investment-cases.json'
$ProdIndexPath = Join-Path $RepoRoot 'data\knowledge-index.json'
$ProdHandoffPath = Join-Path $RepoRoot 'data\research-candidates-handoff.json'
$ProdLedgerPath = Join-Path $RepoRoot 'data\candidate-gate.json'
$ProdGlassPath = Join-Path $RepoRoot 'research\glass-bridge\card.json'
$ProdCpoPath = Join-Path $RepoRoot 'research\cpo\card.json'
$ProdHbmPath = Join-Path $RepoRoot 'research\hbm\card.json'
$ProdFauPath = Join-Path $RepoRoot 'research\fau\card.json'
$ForbiddenNewsDir = Join-Path $RepoRoot 'data\news'
$ForbiddenEventsDir = Join-Path $RepoRoot 'data\events'

foreach ($path in @(
  $Sprint008Path, $CaseA, $IntegratePath, $PublishPath, $ServePath, $Spec009Path,
  $ProdBriefPath, $ProdQueuePath, $ProdCasesPath, $ProdIndexPath, $ProdGlassPath, $ProdCpoPath
)) {
  if (-not (Test-Path -LiteralPath $path)) { throw "Missing: $path" }
}

$Utf8 = New-Object System.Text.UTF8Encoding $false
$IntegrateSrc = [System.IO.File]::ReadAllText($IntegratePath, $Utf8)
$PublishSrc = [System.IO.File]::ReadAllText($PublishPath, $Utf8)

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
  nvidia = (Get-FileHash -Path $NvidiaAdapterPath -Algorithm SHA256).Hash
  fed = (Get-FileHash -Path $FedAdapterPath -Algorithm SHA256).Hash
  handbook = (Get-FileHash -Path $HandbookPath -Algorithm SHA256).Hash
  spec001 = (Get-FileHash -Path $Spec001Path -Algorithm SHA256).Hash
  spec008 = (Get-FileHash -Path $Spec008Path -Algorithm SHA256).Hash
}
if (Test-Path -LiteralPath $ProdHbmPath) {
  $ProdHashBefore.hbm = (Get-FileHash -Path $ProdHbmPath -Algorithm SHA256).Hash
}
if (Test-Path -LiteralPath $ProdFauPath) {
  $ProdHashBefore.fau = (Get-FileHash -Path $ProdFauPath -Algorithm SHA256).Hash
}
if (Test-Path -LiteralPath $ProdHandoffPath) {
  $ProdHashBefore.handoff = (Get-FileHash -Path $ProdHandoffPath -Algorithm SHA256).Hash
}
if (Test-Path -LiteralPath $ProdLedgerPath) {
  $ProdHashBefore.ledger = (Get-FileHash -Path $ProdLedgerPath -Algorithm SHA256).Hash
}

# Capture conclusion/thesis text for TEST J.
function Get-CardConclusionThesis($path) {
  if (-not (Test-Path -LiteralPath $path)) { return $null }
  $raw = [System.IO.File]::ReadAllText($path, $Utf8)
  return [PSCustomObject]@{
    Hash = (Get-FileHash -Path $path -Algorithm SHA256).Hash
    Raw = $raw
  }
}
$CardSnapBefore = @{
  glass = Get-CardConclusionThesis $ProdGlassPath
  cpo = Get-CardConclusionThesis $ProdCpoPath
}

$script:Results = New-Object System.Collections.Generic.List[object]
$script:TempRoot = Join-Path $env:TEMP ('InvestorTwin-p2-009-' + [guid]::NewGuid().ToString('N'))
$script:TestPort = $null
$script:ServerProc = $null

function Add-TestResult($id, $passed, $details) {
  $status = if ($passed) { 'PASS' } else { 'FAIL' }
  $script:Results.Add([PSCustomObject]@{ Id = $id; Status = $status; Details = $details })
  Write-Output ("{0}: {1}" -f $id, $status)
  if ($details) { Write-Output $details }
}

function Get-Python {
  $python = $env:INVESTORTWIN_PYTHON
  if (-not $python) { $python = 'python' }
  return $python
}

function Read-JsonFile($path) {
  return ([System.IO.File]::ReadAllText($path, $Utf8) | ConvertFrom-Json)
}

function Write-JsonFile($path, $obj) {
  $dir = Split-Path -Parent $path
  if (-not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
  }
  [System.IO.File]::WriteAllText($path, ($obj | ConvertTo-Json -Depth 30), $Utf8)
}

function Get-AsArraySafe($value) {
  if ($null -eq $value) { return @() }
  if ($value -is [System.Array]) { return @($value) }
  return @($value)
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
  Write-JsonFile (Join-Path $script:TempRoot 'data\candidate-gate.json') @{ schemaVersion = '1.0'; dispositions = @() }
  Write-JsonFile (Join-Path $script:TempRoot 'data\research-queue.json') @{ items = @() }
  # Empty handoff — publish must populate (no manual copy).
  Write-JsonFile (Join-Path $script:TempRoot 'data\research-candidates-handoff.json') @{
    news = @()
    events = @()
    links = @()
    evaluations = @()
    researchCandidates = @()
  }

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

function Invoke-IntegratePublish($fixturePath, $handoffPath) {
  $python = Get-Python
  $args = @(
    $IntegratePath,
    '--input', $fixturePath,
    '--publish-handoff', $handoffPath
  )
  $out = & $python @args 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw ("integrate --publish-handoff failed: " + ($out | Out-String))
  }
  return ($out | Out-String)
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
    (Get-FileHash -Path $NvidiaAdapterPath -Algorithm SHA256).Hash -eq $ProdHashBefore.nvidia -and
    (Get-FileHash -Path $FedAdapterPath -Algorithm SHA256).Hash -eq $ProdHashBefore.fed -and
    (Get-FileHash -Path $HandbookPath -Algorithm SHA256).Hash -eq $ProdHashBefore.handbook -and
    (Get-FileHash -Path $Spec001Path -Algorithm SHA256).Hash -eq $ProdHashBefore.spec001 -and
    (Get-FileHash -Path $Spec008Path -Algorithm SHA256).Hash -eq $ProdHashBefore.spec008 -and
    -not (Test-Path -LiteralPath $ForbiddenNewsDir) -and
    -not (Test-Path -LiteralPath $ForbiddenEventsDir)
  )
  if ($ProdHashBefore.ContainsKey('hbm') -and (Test-Path -LiteralPath $ProdHbmPath)) {
    $ok = $ok -and ((Get-FileHash -Path $ProdHbmPath -Algorithm SHA256).Hash -eq $ProdHashBefore.hbm)
  }
  if ($ProdHashBefore.ContainsKey('fau') -and (Test-Path -LiteralPath $ProdFauPath)) {
    $ok = $ok -and ((Get-FileHash -Path $ProdFauPath -Algorithm SHA256).Hash -eq $ProdHashBefore.fau)
  }
  if ($ProdHashBefore.ContainsKey('handoff') -and (Test-Path -LiteralPath $ProdHandoffPath)) {
    $ok = $ok -and ((Get-FileHash -Path $ProdHandoffPath -Algorithm SHA256).Hash -eq $ProdHashBefore.handoff)
  }
  if ($ProdHashBefore.ContainsKey('ledger') -and (Test-Path -LiteralPath $ProdLedgerPath)) {
    $ok = $ok -and ((Get-FileHash -Path $ProdLedgerPath -Algorithm SHA256).Hash -eq $ProdHashBefore.ledger)
  }
  return $ok
}

try {
Write-Output '=== P2-008 REGRESSION (includes 001-007) ==='
$sprint008 = & powershell -NoProfile -File $Sprint008Path
$sprint008Text = ($sprint008 | ForEach-Object { "$_" }) -join "`n"
Add-TestResult 'TEST 109-REG' ($LASTEXITCODE -eq 0) $(if ($LASTEXITCODE -eq 0) { 'Sprint 001-008 regression PASS' } else { $sprint008Text })

Write-Output ''
Write-Output '=== P2-009 HANDOFF PUBLISH ==='

$failStatic = New-Object System.Collections.Generic.List[string]
if ($IntegrateSrc -notlike '*--publish-handoff*') { $failStatic.Add('integrate missing --publish-handoff opt-in') }
if ($PublishSrc -notlike '*publish_handoff*') { $failStatic.Add('publish script missing publish_handoff') }
if ($PublishSrc -notlike '*eventRef*') { $failStatic.Add('publish script missing eventRef identity') }
if ($PublishSrc -match 'difflib|SequenceMatcher' -or $PublishSrc -match 'title\.lower\(\).*==') {
  $failStatic.Add('publish must not use fuzzy title identity')
}
if ($PublishSrc -notlike '*candidate-gate*') { $failStatic.Add('publish should refuse ledger path') }

Initialize-TempRoot
$handoffPath = Join-Path $script:TempRoot 'data\research-candidates-handoff.json'
$ledgerPath = Join-Path $script:TempRoot 'data\candidate-gate.json'
$queuePath = Join-Path $script:TempRoot 'data\research-queue.json'
$cardPath = Join-Path $script:TempRoot 'research\cpo\card.json'

$ledgerHashBeforePublish = (Get-FileHash -Path $ledgerPath -Algorithm SHA256).Hash
$queueHashBefore = (Get-FileHash -Path $queuePath -Algorithm SHA256).Hash
$cardHashBefore = (Get-FileHash -Path $cardPath -Algorithm SHA256).Hash
$cardBefore = Read-JsonFile $cardPath

# A: integrate --publish-handoff
$fail102 = New-Object System.Collections.Generic.List[string]
if ($failStatic.Count -gt 0) { $fail102.AddRange($failStatic) }
try {
  $null = Invoke-IntegratePublish $CaseA $handoffPath
} catch {
  $fail102.Add([string]$_.Exception.Message)
}
$handoff = $null
if (Test-Path -LiteralPath $handoffPath) {
  $handoff = Read-JsonFile $handoffPath
  $candidates = @(Get-AsArraySafe $handoff.researchCandidates)
  if ($candidates.Count -lt 1) { $fail102.Add('handoff researchCandidates empty after publish') }
  else {
    $script:EventRef = [string]$candidates[0].eventRef
    if (-not $script:EventRef) { $fail102.Add('published Candidate missing eventRef') }
  }
  foreach ($field in @('news', 'events', 'evaluations', 'researchCandidates')) {
    if (-not ($handoff.PSObject.Properties.Name -contains $field)) {
      $fail102.Add("handoff missing $field")
    }
  }
} else {
  $fail102.Add('handoff file missing after publish')
}
if ((Get-FileHash -Path $ledgerPath -Algorithm SHA256).Hash -ne $ledgerHashBeforePublish) {
  $fail102.Add('publish must not write candidate-gate ledger')
}
Add-TestResult 'TEST 102' ($fail102.Count -eq 0) ($fail102 -join "`n")

Start-TempServer

# B: Attention path sees Pending
$view = Invoke-GateGet
$attention = @(Get-AttentionCandidates $view)
$pending = @($attention | Where-Object { $_.eventRef -eq $script:EventRef })[0]
$fail103 = New-Object System.Collections.Generic.List[string]
if (-not $pending) { $fail103.Add('Published Candidate not visible in Attention filter') }
elseif ([string]$pending.status -ne 'Pending') { $fail103.Add("expected Pending, got $($pending.status)") }
elseif (-not $pending.researchQuestion) { $fail103.Add('Attention row missing researchQuestion') }
Add-TestResult 'TEST 103' ($fail103.Count -eq 0) ($fail103 -join "`n")

# C: Watch preserved across republish
$watch = Invoke-GatePost @{ action = 'watch'; eventRef = $script:EventRef }
$ledgerAfterWatch = Read-JsonFile $ledgerPath
$watchDisp = @($ledgerAfterWatch.dispositions | Where-Object { $_.eventRef -eq $script:EventRef })[0]
$null = Invoke-IntegratePublish $CaseA $handoffPath
$ledgerAfterRepublishWatch = Read-JsonFile $ledgerPath
$watchDisp2 = @($ledgerAfterRepublishWatch.dispositions | Where-Object { $_.eventRef -eq $script:EventRef })[0]
$viewWatch = Invoke-GateGet
$attentionWatch = @(Get-AttentionCandidates $viewWatch)
$watchRow = @($attentionWatch | Where-Object { $_.eventRef -eq $script:EventRef })[0]
$fail104 = New-Object System.Collections.Generic.List[string]
if ($watch.StatusCode -ne 200) { $fail104.Add("watch failed status=$($watch.StatusCode)") }
if (-not $watchDisp -or [string]$watchDisp.status -ne 'Watching') { $fail104.Add('Watching disposition missing before republish') }
if (-not $watchDisp2 -or [string]$watchDisp2.status -ne 'Watching') { $fail104.Add('Watching disposition lost after republish') }
if (-not $watchRow -or [string]$watchRow.status -ne 'Watching') { $fail104.Add('Watching Candidate not in Attention after republish') }
Add-TestResult 'TEST 104' ($fail104.Count -eq 0) ($fail104 -join "`n")

# D: Ignored stays hidden after republish
$ignore = Invoke-GatePost @{ action = 'ignore'; eventRef = $script:EventRef }
$null = Invoke-IntegratePublish $CaseA $handoffPath
$ledgerIgnored = Read-JsonFile $ledgerPath
$ignoredDisp = @($ledgerIgnored.dispositions | Where-Object { $_.eventRef -eq $script:EventRef })[0]
$viewIgnored = Invoke-GateGet
$attentionIgnored = @(Get-AttentionCandidates $viewIgnored)
$fail105 = New-Object System.Collections.Generic.List[string]
if ($ignore.StatusCode -ne 200) { $fail105.Add("ignore failed status=$($ignore.StatusCode)") }
if (-not $ignoredDisp -or [string]$ignoredDisp.status -ne 'Ignored') { $fail105.Add('Ignored disposition not preserved') }
if (@($attentionIgnored | Where-Object { $_.eventRef -eq $script:EventRef }).Count -ne 0) {
  $fail105.Add('Ignored Candidate visible in Attention after republish')
}
Add-TestResult 'TEST 105' ($fail105.Count -eq 0) ($fail105 -join "`n")

# E: idempotent — single eventRef after repeated publish
$null = Invoke-IntegratePublish $CaseA $handoffPath
$null = Invoke-IntegratePublish $CaseA $handoffPath
$handoffAfter = Read-JsonFile $handoffPath
$sameRefs = @(@(Get-AsArraySafe $handoffAfter.researchCandidates) | Where-Object { $_.eventRef -eq $script:EventRef })
$fail106 = New-Object System.Collections.Generic.List[string]
if ($sameRefs.Count -ne 1) { $fail106.Add("expected 1 Candidate for eventRef, got $($sameRefs.Count)") }
$allRefs = @(@(Get-AsArraySafe $handoffAfter.researchCandidates) | ForEach-Object { [string]$_.eventRef })
$dup = @($allRefs | Group-Object | Where-Object { $_.Count -gt 1 })
if ($dup.Count -gt 0) { $fail106.Add('duplicate eventRefs in researchCandidates') }
Add-TestResult 'TEST 106' ($fail106.Count -eq 0) ($fail106 -join "`n")

# F: publish does not auto Gate — ledger only changed by explicit Watch/Ignore above
# After Ignore, status must remain Ignored (already checked). Ensure publish script never POSTs.
$fail107 = New-Object System.Collections.Generic.List[string]
if ($PublishSrc -match '/api/candidate-gate' -or $PublishSrc -match 'Invoke-CandidateGate') {
  $fail107.Add('publish script must not call Gate API')
}
if ([string]$ignoredDisp.status -ne 'Ignored') { $fail107.Add('unexpected auto Gate transition') }
Add-TestResult 'TEST 107' ($fail107.Count -eq 0) ($fail107 -join "`n")

# G: no Card/Queue/Conclusion writes from publish
$cardAfter = Read-JsonFile $cardPath
$queueAfter = Read-JsonFile $queuePath
$fail108 = New-Object System.Collections.Generic.List[string]
if ((Get-FileHash -Path $cardPath -Algorithm SHA256).Hash -ne $cardHashBefore) {
  $fail108.Add('temp Card changed by publish/Gate ignore path unexpectedly')
}
# Ignore/Watch may not touch card; queue should remain empty (no auto queue)
if (@(Get-AsArraySafe $queueAfter.items).Count -ne 0) {
  $fail108.Add('Queue was written without explicit queue action')
}
if ([string]$cardAfter.researchConclusion.conclusion -ne [string]$cardBefore.researchConclusion.conclusion) {
  $fail108.Add('researchConclusion changed')
}
if ([string]$cardAfter.investmentThesis -ne [string]$cardBefore.investmentThesis) {
  $fail108.Add('investmentThesis changed')
}
if ($cardAfter.PSObject.Properties.Name -contains 'candidateLinks' -and @($cardAfter.candidateLinks).Count -gt 0) {
  $fail108.Add('candidateLinks written without Link action')
}
# Default integrate without --publish-handoff must not write (spot-check source)
if ($IntegrateSrc -notmatch 'if publish_handoff_path') {
  # Python uses `if publish_handoff_path:`
  if ($IntegrateSrc -notlike '*if publish_handoff_path:*') {
    $fail108.Add('integrate publish must remain gated on opt-in flag')
  }
}
Add-TestResult 'TEST 108' ($fail108.Count -eq 0) ($fail108 -join "`n")

Add-TestResult 'TEST 109' (($script:Results | Where-Object { $_.Id -eq 'TEST 109-REG' }).Status -eq 'PASS') 'Sprint 001-008 regression PASS'

$guardOk = Test-ProtectedHashes
Add-TestResult 'TEST 110' $guardOk $(if ($guardOk) { 'Production File Guard PASS' } else { 'Production protected files changed or forbidden dirs appeared' })

$fail111 = New-Object System.Collections.Generic.List[string]
foreach ($key in @('glass', 'cpo')) {
  $path = if ($key -eq 'glass') { $ProdGlassPath } else { $ProdCpoPath }
  $now = Get-CardConclusionThesis $path
  if ($now.Hash -ne $CardSnapBefore[$key].Hash) {
    $fail111.Add("$key card.json hash changed")
  }
  if ($now.Raw -ne $CardSnapBefore[$key].Raw) {
    $fail111.Add("$key card.json content changed")
  }
}
Add-TestResult 'TEST 111' ($fail111.Count -eq 0) ($fail111 -join "`n")

Write-Output ''
Write-Output '=== P2-009 SUMMARY ==='
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
