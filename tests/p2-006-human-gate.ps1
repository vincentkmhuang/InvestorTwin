$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$env:PYTHONIOENCODING = 'utf-8'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$Sprint001Path = Join-Path $PSScriptRoot 'p2-001-news-intelligence-foundation.ps1'
$Sprint002Path = Join-Path $PSScriptRoot 'p2-002-nvidia-official-adapter.ps1'
$Sprint003Path = Join-Path $PSScriptRoot 'p2-003-federal-reserve-official-adapter.ps1'
$Sprint004Path = Join-Path $PSScriptRoot 'p2-004-news-dedup-event-linking.ps1'
$Sprint005Path = Join-Path $PSScriptRoot 'p2-005-news-event-evaluation-integration.ps1'
$HandoffFixture = Join-Path $PSScriptRoot 'fixtures\p2-006-handoff-case-a.json'
$ServePath = Join-Path $RepoRoot 'serve.ps1'
$AppPath = Join-Path $RepoRoot 'app.js'
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
$ProdLedgerPath = Join-Path $RepoRoot 'data\candidate-gate.json'
$ProdHandoffPath = Join-Path $RepoRoot 'data\research-candidates-handoff.json'
$ProdGlassPath = Join-Path $RepoRoot 'research\glass-bridge\card.json'
$ForbiddenNewsDir = Join-Path $RepoRoot 'data\news'
$ForbiddenEventsDir = Join-Path $RepoRoot 'data\events'

foreach ($path in @(
  $Sprint001Path, $Sprint002Path, $Sprint003Path, $Sprint004Path, $Sprint005Path,
  $HandoffFixture, $ServePath, $AppPath, $IndexPath, $GateJsPath, $IntegratePath,
  $ProdBriefPath, $ProdQueuePath, $ProdCasesPath, $ProdIndexPath, $ProdLedgerPath, $ProdHandoffPath, $ProdGlassPath
)) {
  if (-not (Test-Path -LiteralPath $path)) { throw "Missing: $path" }
}

$Utf8 = New-Object System.Text.UTF8Encoding $false
$IndexSrc = [System.IO.File]::ReadAllText($IndexPath, $Utf8)
$AppSrc = [System.IO.File]::ReadAllText($AppPath, $Utf8)
$GateSrc = [System.IO.File]::ReadAllText($GateJsPath, $Utf8)
$ServeSrc = [System.IO.File]::ReadAllText($ServePath, $Utf8)
$Handoff = [System.IO.File]::ReadAllText($HandoffFixture, $Utf8) | ConvertFrom-Json
$EventRef = [string]$Handoff.researchCandidates[0].eventRef
$ResearchQuestion = [string]$Handoff.researchCandidates[0].researchQuestion
$NewsHeadline = [string]$Handoff.news[0].title

$ProdHashBefore = @{
  brief = (Get-FileHash -Path $ProdBriefPath -Algorithm SHA256).Hash
  queue = (Get-FileHash -Path $ProdQueuePath -Algorithm SHA256).Hash
  cases = (Get-FileHash -Path $ProdCasesPath -Algorithm SHA256).Hash
  index = (Get-FileHash -Path $ProdIndexPath -Algorithm SHA256).Hash
  glass = (Get-FileHash -Path $ProdGlassPath -Algorithm SHA256).Hash
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
}

$script:Results = New-Object System.Collections.Generic.List[object]
$script:TempRoot = Join-Path $env:TEMP ('InvestorTwin-p2-006-' + [guid]::NewGuid().ToString('N'))
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

  $cardDir = Join-Path $script:TempRoot 'research\glass-bridge'
  New-Item -ItemType Directory -Path $cardDir -Force | Out-Null
  Write-JsonFile (Join-Path $cardDir 'card.json') @{
    id = 'glass-bridge'
    title = 'Glass Bridge'
    summary = ''
    questions = @('Existing research question')
    status = 'researching'
    updated = '2026-08-23'
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
  return (
    (Get-FileHash -Path $ProdBriefPath -Algorithm SHA256).Hash -eq $ProdHashBefore.brief -and
    (Get-FileHash -Path $ProdQueuePath -Algorithm SHA256).Hash -eq $ProdHashBefore.queue -and
    (Get-FileHash -Path $ProdCasesPath -Algorithm SHA256).Hash -eq $ProdHashBefore.cases -and
    (Get-FileHash -Path $ProdIndexPath -Algorithm SHA256).Hash -eq $ProdHashBefore.index -and
    (Get-FileHash -Path $ProdGlassPath -Algorithm SHA256).Hash -eq $ProdHashBefore.glass -and
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
    -not (Test-Path -LiteralPath $ForbiddenNewsDir) -and
    -not (Test-Path -LiteralPath $ForbiddenEventsDir)
  )
}

try {
Write-Output '=== P2-001..005 REGRESSION ==='
$sprint001 = & powershell -NoProfile -File $Sprint001Path
$sprint001Text = ($sprint001 | ForEach-Object { "$_" }) -join "`n"
Add-TestResult 'TEST 1-20' ($LASTEXITCODE -eq 0) $(if ($LASTEXITCODE -eq 0) { 'Sprint 001 PASS' } else { $sprint001Text })

$sprint002 = & powershell -NoProfile -File $Sprint002Path
$sprint002Text = ($sprint002 | ForEach-Object { "$_" }) -join "`n"
Add-TestResult 'TEST 21-30' ($LASTEXITCODE -eq 0) $(if ($LASTEXITCODE -eq 0) { 'Sprint 002 PASS' } else { $sprint002Text })

$sprint003 = & powershell -NoProfile -File $Sprint003Path
$sprint003Text = ($sprint003 | ForEach-Object { "$_" }) -join "`n"
Add-TestResult 'TEST 31-41' ($LASTEXITCODE -eq 0) $(if ($LASTEXITCODE -eq 0) { 'Sprint 003 PASS' } else { $sprint003Text })

$sprint004 = & powershell -NoProfile -File $Sprint004Path
$sprint004Text = ($sprint004 | ForEach-Object { "$_" }) -join "`n"
Add-TestResult 'TEST 42-52' ($LASTEXITCODE -eq 0) $(if ($LASTEXITCODE -eq 0) { 'Sprint 004 PASS' } else { $sprint004Text })

$sprint005 = & powershell -NoProfile -File $Sprint005Path
$sprint005Text = ($sprint005 | ForEach-Object { "$_" }) -join "`n"
Add-TestResult 'TEST 53-64' ($LASTEXITCODE -eq 0) $(if ($LASTEXITCODE -eq 0) { 'Sprint 005 PASS' } else { $sprint005Text })

Write-Output ''
Write-Output '=== P2-006 HUMAN GATE ==='
Initialize-TempRoot
Start-TempServer

$fail65 = New-Object System.Collections.Generic.List[string]
if ($IndexSrc -notlike '*Research Candidates*') { $fail65.Add('index.html missing Research Candidates section') }
if ($IndexSrc -notlike '*queueResearchCandidates*') { $fail65.Add('index.html missing queueResearchCandidates') }
if ($IndexSrc -notlike '*candidate-gate.js*') { $fail65.Add('index.html missing candidate-gate.js') }
if ($GateSrc -notlike '*Research Candidate*') { $fail65.Add('candidate-gate.js missing Candidate card label') }
$view = Invoke-GateGet
$pending = @($view.candidates | Where-Object { $_.eventRef -eq $EventRef })
if ($pending.Count -ne 1) { $fail65.Add('eligible Candidate missing from GET /api/candidate-gate') }
elseif ($pending[0].status -ne 'Pending') { $fail65.Add("status=$($pending[0].status); expected Pending") }
Add-TestResult 'TEST 65' ($fail65.Count -eq 0) ($fail65 -join "`n")

# Fresh root for Ignore path
Stop-TempServer
Initialize-TempRoot
Start-TempServer
$queueBefore = Read-JsonFile (Join-Path $script:TempRoot 'data\research-queue.json')
$cardBefore = Read-JsonFile (Join-Path $script:TempRoot 'research\glass-bridge\card.json')
$casesBefore = Get-FileHash -Path (Join-Path $script:TempRoot 'data\investment-cases.json') -Algorithm SHA256
$ignore = Invoke-GatePost @{ action = 'ignore'; eventRef = $EventRef }
$fail66 = New-Object System.Collections.Generic.List[string]
if ($ignore.StatusCode -ne 200) { $fail66.Add("ignore status=$($ignore.StatusCode)") }
$queueAfter = Read-JsonFile (Join-Path $script:TempRoot 'data\research-queue.json')
$cardAfter = Read-JsonFile (Join-Path $script:TempRoot 'research\glass-bridge\card.json')
$casesAfter = Get-FileHash -Path (Join-Path $script:TempRoot 'data\investment-cases.json') -Algorithm SHA256
if (@($queueAfter.items).Count -ne @($queueBefore.items).Count) { $fail66.Add('Ignore wrote Queue') }
if (($cardAfter | ConvertTo-Json -Depth 10) -ne ($cardBefore | ConvertTo-Json -Depth 10)) { $fail66.Add('Ignore modified Card') }
if ($casesAfter.Hash -ne $casesBefore.Hash) { $fail66.Add('Ignore modified Cases/Decision') }
$ledger = Read-JsonFile (Join-Path $script:TempRoot 'data\candidate-gate.json')
$disp = @($ledger.dispositions | Where-Object { $_.eventRef -eq $EventRef })[0]
if ($disp.status -ne 'Ignored') { $fail66.Add("disposition=$($disp.status)") }
$reload = Invoke-GateGet
$reStatus = @($reload.candidates | Where-Object { $_.eventRef -eq $EventRef })[0].status
if ($reStatus -ne 'Ignored') { $fail66.Add("reload status=$reStatus; expected Ignored") }
Add-TestResult 'TEST 66' ($fail66.Count -eq 0) ($fail66 -join "`n")

Stop-TempServer
Initialize-TempRoot
Start-TempServer
$queueBefore = Read-JsonFile (Join-Path $script:TempRoot 'data\research-queue.json')
$cardBeforeHash = (Get-FileHash -Path (Join-Path $script:TempRoot 'research\glass-bridge\card.json') -Algorithm SHA256).Hash
$casesBefore = Get-FileHash -Path (Join-Path $script:TempRoot 'data\investment-cases.json') -Algorithm SHA256
$watch = Invoke-GatePost @{ action = 'watch'; eventRef = $EventRef }
$fail67 = New-Object System.Collections.Generic.List[string]
if ($watch.StatusCode -ne 200) { $fail67.Add("watch status=$($watch.StatusCode)") }
$queueAfter = Read-JsonFile (Join-Path $script:TempRoot 'data\research-queue.json')
if (@($queueAfter.items).Count -ne @($queueBefore.items).Count) { $fail67.Add('Watch wrote Queue') }
$cardAfterHash = (Get-FileHash -Path (Join-Path $script:TempRoot 'research\glass-bridge\card.json') -Algorithm SHA256).Hash
if ($cardAfterHash -ne $cardBeforeHash) { $fail67.Add('Watch modified Card') }
$casesAfter = Get-FileHash -Path (Join-Path $script:TempRoot 'data\investment-cases.json') -Algorithm SHA256
if ($casesAfter.Hash -ne $casesBefore.Hash) { $fail67.Add('Watch modified Cases/Decision') }
$reload = Invoke-GateGet
$reStatus = @($reload.candidates | Where-Object { $_.eventRef -eq $EventRef })[0].status
if ($reStatus -ne 'Watching') { $fail67.Add("reload status=$reStatus; expected Watching") }
Add-TestResult 'TEST 67' ($fail67.Count -eq 0) ($fail67 -join "`n")

Stop-TempServer
Initialize-TempRoot
Start-TempServer
$researchRoot = Join-Path $script:TempRoot 'research'
$dirsBefore = @(Get-ChildItem -LiteralPath $researchRoot -Directory | Select-Object -ExpandProperty Name)
$link = Invoke-GatePost @{ action = 'link'; eventRef = $EventRef; cardId = 'glass-bridge' }
$fail68 = New-Object System.Collections.Generic.List[string]
if ($link.StatusCode -ne 200) { $fail68.Add("link status=$($link.StatusCode) $($link.Body.message)") }
$dirsAfter = @(Get-ChildItem -LiteralPath $researchRoot -Directory | Select-Object -ExpandProperty Name)
$newDirs = @($dirsAfter | Where-Object { $dirsBefore -notcontains $_ })
if ($newDirs.Count -gt 0) { $fail68.Add('Link created new research/{id}: ' + ($newDirs -join ',')) }
$card = Read-JsonFile (Join-Path $script:TempRoot 'research\glass-bridge\card.json')
$links = @($card.candidateLinks)
if ($links.Count -lt 1) { $fail68.Add('candidateLinks missing') }
elseif ($links[0].eventRef -ne $EventRef) { $fail68.Add('eventRef not on candidateLink') }
$link2 = Invoke-GatePost @{ action = 'link'; eventRef = $EventRef; cardId = 'glass-bridge' }
$card2 = Read-JsonFile (Join-Path $script:TempRoot 'research\glass-bridge\card.json')
if (@($card2.candidateLinks).Count -ne @($card.candidateLinks).Count) { $fail68.Add('duplicate candidateLink created') }
Add-TestResult 'TEST 68' ($fail68.Count -eq 0) ($fail68 -join "`n")

Stop-TempServer
Initialize-TempRoot
Start-TempServer
$queue1 = Invoke-GatePost @{ action = 'queue'; eventRef = $EventRef; cardId = 'glass-bridge' }
$fail69 = New-Object System.Collections.Generic.List[string]
if ($queue1.StatusCode -ne 200) { $fail69.Add("queue status=$($queue1.StatusCode) $($queue1.Body.message)") }
$queueFile = Read-JsonFile (Join-Path $script:TempRoot 'data\research-queue.json')
$items = @($queueFile.items | Where-Object { $_.id -eq 'glass-bridge' })
if ($items.Count -ne 1) { $fail69.Add("queue items for card=$($items.Count); expected 1") }
if ($items[0].addedFrom -ne 'Research Candidate') { $fail69.Add("addedFrom=$($items[0].addedFrom)") }
$queue2 = Invoke-GatePost @{ action = 'queue'; eventRef = $EventRef; cardId = 'glass-bridge' }
$queueFile2 = Read-JsonFile (Join-Path $script:TempRoot 'data\research-queue.json')
$items2 = @($queueFile2.items | Where-Object { $_.id -eq 'glass-bridge' })
if ($items2.Count -ne 1) { $fail69.Add("idempotent queue failed; count=$($items2.Count)") }
Add-TestResult 'TEST 69' ($fail69.Count -eq 0) ($fail69 -join "`n")

$fail70 = New-Object System.Collections.Generic.List[string]
$card = Read-JsonFile (Join-Path $script:TempRoot 'research\glass-bridge\card.json')
if (@($card.questions) -notcontains $ResearchQuestion) { $fail70.Add('researchQuestion not on Card.questions') }
if ($ResearchQuestion -eq $NewsHeadline) { $fail70.Add('researchQuestion unexpectedly equals news headline') }
if ($AppSrc -notlike '*queueDisplayLabel*' -and $GateSrc -notlike '*queueDisplayLabel*') {
  $fail70.Add('queue display helper missing')
}
if ($GateSrc -notlike '*researchQuestion*') { $fail70.Add('Gate UI does not emphasize researchQuestion') }
Add-TestResult 'TEST 70' ($fail70.Count -eq 0) ($fail70 -join "`n")

$fail71 = New-Object System.Collections.Generic.List[string]
$linkRow = @($card.candidateLinks | Where-Object { $_.eventRef -eq $EventRef })[0]
if (-not $linkRow) { $fail71.Add('candidateLink missing eventRef') }
$ledger = Read-JsonFile (Join-Path $script:TempRoot 'data\candidate-gate.json')
$disp = @($ledger.dispositions | Where-Object { $_.eventRef -eq $EventRef })[0]
if ($disp.eventRef -ne $EventRef) { $fail71.Add('ledger lost eventRef') }
if ($disp.status -ne 'Queued') { $fail71.Add("status=$($disp.status)") }
Add-TestResult 'TEST 71' ($fail71.Count -eq 0) ($fail71 -join "`n")

$fail72 = New-Object System.Collections.Generic.List[string]
$refs = @($linkRow.evidenceRefs)
if ($refs.Count -lt 1) { $fail72.Add('evidenceRefs missing on candidateLink') }
$sources = @($refs | ForEach-Object { $_.source } | Where-Object { $_ })
$newsRefs = @($refs | ForEach-Object { $_.newsRef } | Where-Object { $_ })
if ($sources.Count -lt 1) { $fail72.Add('source missing') }
if ($newsRefs.Count -lt 1) { $fail72.Add('newsRef missing') }
Add-TestResult 'TEST 72' ($fail72.Count -eq 0) ($fail72 -join "`n")

$fail73 = New-Object System.Collections.Generic.List[string]
if ($GateSrc -match '(?i)\bbuy\b' -or $GateSrc -match '(?i)\bsell\b' -or $GateSrc -like '*加碼*' -or $GateSrc -like '*減碼*') {
  $fail73.Add('candidate-gate.js contains recommendation language')
}
$gateFn = [regex]::Match($ServeSrc, 'function Invoke-CandidateGateAction[\s\S]*?\r?\nfunction ').Value
if (-not $gateFn) { $gateFn = [regex]::Match($ServeSrc, 'function Invoke-CandidateGateAction[\s\S]*?\r?\nwhile \(\$listener').Value }
if ($gateFn -and ($gateFn -like '*decisionHistory*' -or $gateFn -like '*positionPlaybook*' -or $gateFn -like '*investment-cases.json*')) {
  $fail73.Add('Candidate Gate action path writes Decision/Playbook/Cases')
}
if ($card.PSObject.Properties['decision']) { $fail73.Add('Card gained decision field') }
if ($card.PSObject.Properties['positionPlaybook']) { $fail73.Add('Card gained positionPlaybook field') }
$noCard = Invoke-GatePost @{ action = 'queue'; eventRef = $EventRef }
if ($noCard.StatusCode -eq 200) { $fail73.Add('queue without cardId unexpectedly succeeded') }
elseif ([string]$noCard.Body.message -notlike '*Research Card*' -and [string]$noCard.Body.error -ne 'missing_card') { $fail73.Add('missing card prompt incorrect') }
Add-TestResult 'TEST 73' ($fail73.Count -eq 0) ($fail73 -join "`n")

# TEST 74 already recorded as Sprint regressions above — summarize
$regFailed = @($script:Results | Where-Object { $_.Id -in @('TEST 1-20','TEST 21-30','TEST 31-41','TEST 42-52','TEST 53-64') -and $_.Status -ne 'PASS' })
Add-TestResult 'TEST 74' ($regFailed.Count -eq 0) $(if ($regFailed.Count -eq 0) { 'Sprint 001-005 regression PASS' } else { 'regression failures present' })

$guardOk = Test-ProtectedHashes
Add-TestResult 'TEST 75' $guardOk $(if ($guardOk) { 'Production File Guard PASS' } else { 'protected production files changed or data/news|events created' })

} finally {
  Stop-TempServer
}

$failed = @($script:Results | Where-Object { $_.Status -ne 'PASS' })
Write-Output ''
Write-Output '=== P2-006 SUMMARY ==='
foreach ($row in $script:Results) {
  Write-Output ("{0}: {1}" -f $row.Id, $row.Status)
  if ($row.Status -ne 'PASS' -and $row.Details) { Write-Output $row.Details }
}
if ($failed.Count -gt 0) { exit 1 }
exit 0
