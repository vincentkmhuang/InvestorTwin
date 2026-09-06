$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$env:PYTHONIOENCODING = 'utf-8'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$Sprint006Path = Join-Path $PSScriptRoot 'p2-006-human-gate.ps1'
$HandoffFixture = Join-Path $PSScriptRoot 'fixtures\p2-006-handoff-case-a.json'
$ServePath = Join-Path $RepoRoot 'serve.ps1'
$WorkflowPath = Join-Path $RepoRoot 'js\workflow-engine.js'
$IndexPath = Join-Path $RepoRoot 'index.html'
$GateJsPath = Join-Path $RepoRoot 'js\candidate-gate.js'
$IntegratePath = Join-Path $RepoRoot 'scripts\integrate-news-event-evaluation.py'
$EvalPath = Join-Path $RepoRoot 'scripts\evaluate-news-intelligence.py'
$LinkPath = Join-Path $RepoRoot 'scripts\link-news-events.py'
$NvidiaAdapterPath = Join-Path $RepoRoot 'scripts\nvidia-official-adapter.py'
$FedAdapterPath = Join-Path $RepoRoot 'scripts\federal-reserve-official-adapter.py'
$Spec001Path = Join-Path $RepoRoot 'docs\Phase 2 Sprint 001 News Intelligence Foundation SPEC.md'
$Spec004Path = Join-Path $RepoRoot 'docs\Phase 2 Sprint 004 News Dedup & Event Linking SPEC.md'
$Spec005Path = Join-Path $RepoRoot 'docs\Phase 2 Sprint 005 News Event Evaluation Integration SPEC.md'
$HandbookPath = Join-Path $RepoRoot 'docs\Investor Twin Handbook V2.0.md'
$GeneratePath = Join-Path $RepoRoot 'scripts\generate-morning-brief.py'
$CollectPath = Join-Path $RepoRoot 'scripts\collect-evidence.py'
$ProdBriefPath = Join-Path $RepoRoot 'data\morning-brief.json'
$ProdQueuePath = Join-Path $RepoRoot 'data\research-queue.json'
$ProdCasesPath = Join-Path $RepoRoot 'data\investment-cases.json'
$ProdIndexPath = Join-Path $RepoRoot 'data\knowledge-index.json'
$ProdGlassPath = Join-Path $RepoRoot 'research\glass-bridge\card.json'
$ProdCpoPath = Join-Path $RepoRoot 'research\cpo\card.json'
$ForbiddenNewsDir = Join-Path $RepoRoot 'data\news'
$ForbiddenEventsDir = Join-Path $RepoRoot 'data\events'

foreach ($path in @(
  $Sprint006Path, $HandoffFixture, $ServePath, $WorkflowPath, $IndexPath, $GateJsPath,
  $ProdBriefPath, $ProdQueuePath, $ProdCasesPath, $ProdIndexPath, $ProdGlassPath, $ProdCpoPath
)) {
  if (-not (Test-Path -LiteralPath $path)) { throw "Missing: $path" }
}

$Utf8 = New-Object System.Text.UTF8Encoding $false
$WorkflowSrc = [System.IO.File]::ReadAllText($WorkflowPath, $Utf8)
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
  spec004 = (Get-FileHash -Path $Spec004Path -Algorithm SHA256).Hash
  spec005 = (Get-FileHash -Path $Spec005Path -Algorithm SHA256).Hash
  sprint006 = (Get-FileHash -Path $Sprint006Path -Algorithm SHA256).Hash
}

$script:Results = New-Object System.Collections.Generic.List[object]
$script:TempRoot = Join-Path $env:TEMP ('InvestorTwin-p2-007-' + [guid]::NewGuid().ToString('N'))
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
  if (Test-Path -LiteralPath $script:TempRoot) {
    Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
  New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null
  foreach ($name in @('data', 'research', 'scripts', 'js')) {
    New-Item -ItemType Directory -Path (Join-Path $script:TempRoot $name) -Force | Out-Null
  }
  Copy-Item -LiteralPath $ServePath -Destination (Join-Path $script:TempRoot 'serve.ps1') -Force
  Copy-Item -LiteralPath $ProdBriefPath -Destination (Join-Path $script:TempRoot 'data\morning-brief.json') -Force
  Copy-Item -LiteralPath $ProdCasesPath -Destination (Join-Path $script:TempRoot 'data\investment-cases.json') -Force
  Copy-Item -LiteralPath $ProdIndexPath -Destination (Join-Path $script:TempRoot 'data\knowledge-index.json') -Force
  Copy-Item -LiteralPath $HandoffFixture -Destination (Join-Path $script:TempRoot 'data\research-candidates-handoff.json') -Force
  Write-JsonFile (Join-Path $script:TempRoot 'data\candidate-gate.json') @{ schemaVersion = '1.0'; dispositions = @() }
  Write-JsonFile (Join-Path $script:TempRoot 'data\research-queue.json') @{ items = @() }

  $cardDir = Join-Path $script:TempRoot 'research\cpo'
  New-Item -ItemType Directory -Path $cardDir -Force | Out-Null
  Write-JsonFile (Join-Path $cardDir 'card.json') @{
    id = 'cpo'
    title = 'CPO'
    summary = ''
    investmentThesis = 'Preserve this thesis text for TEST 82'
    thesisId = 'cpo-glass-bridge'
    questions = @('Existing CPO research question')
    status = 'researching'
    updated = '2026-08-23'
    researchConclusion = @{
      conclusion = 'Preserve this conclusion for TEST 81'
      status = 'uncertain'
      asOf = '2026-08-23'
    }
    researchConclusionHistory = @(
      @{
        type = 'initial'
        conclusion = 'History entry must remain'
        status = 'uncertain'
        asOf = '2026-08-01'
      }
    )
  }
  '[]' | Set-Content (Join-Path $cardDir 'notes.json') -Encoding UTF8
  '[]' | Set-Content (Join-Path $cardDir 'timeline.json') -Encoding UTF8
  '{"sources":[]}' | Set-Content (Join-Path $cardDir 'sources.json') -Encoding UTF8

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

function Get-TempCard {
  return (Read-JsonFile (Join-Path $script:TempRoot 'research\cpo\card.json'))
}

function Test-ProtectedHashes {
  return (
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
    (Get-FileHash -Path $Spec004Path -Algorithm SHA256).Hash -eq $ProdHashBefore.spec004 -and
    (Get-FileHash -Path $Spec005Path -Algorithm SHA256).Hash -eq $ProdHashBefore.spec005 -and
    (Get-FileHash -Path $Sprint006Path -Algorithm SHA256).Hash -eq $ProdHashBefore.sprint006 -and
    -not (Test-Path -LiteralPath $ForbiddenNewsDir) -and
    -not (Test-Path -LiteralPath $ForbiddenEventsDir)
  )
}

try {
Write-Output '=== P2-006 REGRESSION (includes 001-005) ==='
$sprint006 = & powershell -NoProfile -File $Sprint006Path
$sprint006Text = ($sprint006 | ForEach-Object { "$_" }) -join "`n"
Add-TestResult 'TEST 87-REG' ($LASTEXITCODE -eq 0) $(if ($LASTEXITCODE -eq 0) { 'Sprint 001-006 regression PASS' } else { $sprint006Text })

Write-Output ''
Write-Output '=== P2-007 CARD SURFACE ==='
Initialize-TempRoot
Start-TempServer

$cardBefore = Get-TempCard
$conclusionBefore = [string]$cardBefore.researchConclusion.conclusion
$thesisBefore = [string]$cardBefore.investmentThesis
$historyBefore = @($cardBefore.researchConclusionHistory).Count
$dirsBefore = @(Get-ChildItem -LiteralPath (Join-Path $script:TempRoot 'research') -Directory | Select-Object -ExpandProperty Name)

$link = Invoke-GatePost @{ action = 'link'; eventRef = $EventRef; cardId = 'cpo' }
$card = Get-TempCard
$links = @($card.candidateLinks)

$fail76 = New-Object System.Collections.Generic.List[string]
if ($link.StatusCode -ne 200) { $fail76.Add("link status=$($link.StatusCode) $($link.Body.message)") }
if ($links.Count -lt 1) { $fail76.Add('candidateLinks missing after Link') }
Add-TestResult 'TEST 76' ($fail76.Count -eq 0) ($fail76 -join "`n")

$fail77 = New-Object System.Collections.Generic.List[string]
if ($links[0].researchQuestion -ne $ResearchQuestion) { $fail77.Add('researchQuestion not preserved on candidateLink') }
if (@($card.questions) -notcontains $ResearchQuestion) { $fail77.Add('researchQuestion not in Card.questions') }
if ($WorkflowSrc -notlike '*Linked Research Candidates*') { $fail77.Add('Card UI missing Linked Research Candidates section') }
if ($WorkflowSrc -notlike '*Research Question:*') { $fail77.Add('Card UI does not emphasize Research Question') }
Add-TestResult 'TEST 77' ($fail77.Count -eq 0) ($fail77 -join "`n")

$fail78 = New-Object System.Collections.Generic.List[string]
if ([string]$links[0].eventRef -ne $EventRef) { $fail78.Add('eventRef not preserved') }
if ($WorkflowSrc -notlike '*data-candidate-event-ref*') { $fail78.Add('Card UI missing eventRef marker') }
Add-TestResult 'TEST 78' ($fail78.Count -eq 0) ($fail78 -join "`n")

$fail79 = New-Object System.Collections.Generic.List[string]
$refs = @($links[0].evidenceRefs)
if ($refs.Count -lt 1) { $fail79.Add('evidenceRefs missing') }
$sources = @($refs | ForEach-Object { $_.source } | Where-Object { $_ })
$newsRefs = @($refs | ForEach-Object { $_.newsRef } | Where-Object { $_ })
if ($sources.Count -lt 1) { $fail79.Add('source missing in evidenceRefs') }
if ($newsRefs.Count -lt 1) { $fail79.Add('newsRef missing in evidenceRefs') }
if ($WorkflowSrc -notlike '*data-candidate-evidence-refs*') { $fail79.Add('Card UI missing evidenceRefs render') }
Add-TestResult 'TEST 79' ($fail79.Count -eq 0) ($fail79 -join "`n")

$fail80 = New-Object System.Collections.Generic.List[string]
if ([int]$links[0].importance -ne [int]$Evaluation.importance) { $fail80.Add("importance=$($links[0].importance)") }
if ([string]$links[0].relevance -ne [string]$Evaluation.relevance) { $fail80.Add("relevance=$($links[0].relevance)") }
if ([string]$links[0].impact.direction -ne [string]$Evaluation.impact.direction) { $fail80.Add('impact.direction lost') }
if ([string]$links[0].impact.strength -ne [string]$Evaluation.impact.strength) { $fail80.Add('impact.strength lost') }
if ($WorkflowSrc -notlike '*Importance:*' -or $WorkflowSrc -notlike '*Relevance:*' -or $WorkflowSrc -notlike '*Impact:*') {
  $fail80.Add('Card UI missing Imp/Rel/Impact labels')
}
Add-TestResult 'TEST 80' ($fail80.Count -eq 0) ($fail80 -join "`n")

$fail81 = New-Object System.Collections.Generic.List[string]
if ([string]$card.researchConclusion.conclusion -ne $conclusionBefore) { $fail81.Add('researchConclusion changed by Link') }
Add-TestResult 'TEST 81' ($fail81.Count -eq 0) ($fail81 -join "`n")

$fail82 = New-Object System.Collections.Generic.List[string]
if ([string]$card.investmentThesis -ne $thesisBefore) { $fail82.Add('investmentThesis changed by Link') }
if (@($card.researchConclusionHistory).Count -ne $historyBefore) { $fail82.Add('researchConclusionHistory changed by Link') }
if ([string]$card.thesisId -ne 'cpo-glass-bridge') { $fail82.Add('thesisId changed by Link') }
Add-TestResult 'TEST 82' ($fail82.Count -eq 0) ($fail82 -join "`n")

$fail83 = New-Object System.Collections.Generic.List[string]
$reloaded = Get-TempCard
if (@($reloaded.candidateLinks).Count -lt 1) { $fail83.Add('reload lost candidateLinks') }
elseif ([string]$reloaded.candidateLinks[0].eventRef -ne $EventRef) { $fail83.Add('reload lost eventRef') }
elseif ([string]$reloaded.candidateLinks[0].researchQuestion -ne $ResearchQuestion) { $fail83.Add('reload lost researchQuestion') }
if ($WorkflowSrc -notlike '*renderLinkedResearchCandidates*') { $fail83.Add('renderer helper missing') }
Add-TestResult 'TEST 83' ($fail83.Count -eq 0) ($fail83 -join "`n")

$fail84 = New-Object System.Collections.Generic.List[string]
$dirsAfter = @(Get-ChildItem -LiteralPath (Join-Path $script:TempRoot 'research') -Directory | Select-Object -ExpandProperty Name)
$newDirs = @($dirsAfter | Where-Object { $dirsBefore -notcontains $_ })
if ($newDirs.Count -gt 0) { $fail84.Add('new research/{id} created: ' + ($newDirs -join ',')) }
Add-TestResult 'TEST 84' ($fail84.Count -eq 0) ($fail84 -join "`n")

$fail85 = New-Object System.Collections.Generic.List[string]
$queueAfterLink = Read-JsonFile (Join-Path $script:TempRoot 'data\research-queue.json')
if (@($queueAfterLink.items).Count -ne 0) { $fail85.Add('Link alone wrote Queue') }
if ($card.PSObject.Properties['decision']) { $fail85.Add('Card gained decision') }
if ($WorkflowSrc -match 'renderLinkedResearchCandidates[\s\S]{0,800}buy' -and $WorkflowSrc -match 'renderLinkedResearchCandidates[\s\S]{0,800}sell') {
  $fail85.Add('Candidate surface contains Buy/Sell language')
}
Add-TestResult 'TEST 85' ($fail85.Count -eq 0) ($fail85 -join "`n")

# Fresh root for Queue path
Stop-TempServer
Initialize-TempRoot
Start-TempServer
$queue = Invoke-GatePost @{ action = 'queue'; eventRef = $EventRef; cardId = 'cpo' }
$fail86 = New-Object System.Collections.Generic.List[string]
if ($queue.StatusCode -ne 200) { $fail86.Add("queue status=$($queue.StatusCode) $($queue.Body.message)") }
$queueFile = Read-JsonFile (Join-Path $script:TempRoot 'data\research-queue.json')
$items = @($queueFile.items | Where-Object { $_.id -eq 'cpo' })
if ($items.Count -ne 1) { $fail86.Add("queue items=$($items.Count)") }
if ($items[0].addedFrom -ne 'Research Candidate') { $fail86.Add("addedFrom=$($items[0].addedFrom)") }
$cardQ = Get-TempCard
if (@($cardQ.candidateLinks).Count -lt 1) { $fail86.Add('Queue path did not receive candidateLinks on Card') }
elseif ([string]$cardQ.candidateLinks[0].eventRef -ne $EventRef) { $fail86.Add('Queue path lost eventRef on Card') }
Add-TestResult 'TEST 86' ($fail86.Count -eq 0) ($fail86 -join "`n")

$regOk = (@($script:Results | Where-Object { $_.Id -eq 'TEST 87-REG' -and $_.Status -eq 'PASS' }).Count -eq 1)
Add-TestResult 'TEST 87' $regOk $(if ($regOk) { 'Sprint 001-006 regression PASS' } else { 'regression failed' })

$guardOk = Test-ProtectedHashes
Add-TestResult 'TEST 88' $guardOk $(if ($guardOk) { 'Production File Guard PASS' } else { 'protected production files changed or data/news|events created' })

} finally {
  Stop-TempServer
}

$failed = @($script:Results | Where-Object { $_.Status -ne 'PASS' })
Write-Output ''
Write-Output '=== P2-007 SUMMARY ==='
foreach ($row in $script:Results) {
  Write-Output ("{0}: {1}" -f $row.Id, $row.Status)
  if ($row.Status -ne 'PASS' -and $row.Details) { Write-Output $row.Details }
}
if ($failed.Count -gt 0) { exit 1 }
exit 0
