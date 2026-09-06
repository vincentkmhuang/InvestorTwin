$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$env:PYTHONIOENCODING = 'utf-8'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$Sprint001Path = Join-Path $PSScriptRoot 'p2-001-news-intelligence-foundation.ps1'
$Sprint002Path = Join-Path $PSScriptRoot 'p2-002-nvidia-official-adapter.ps1'
$Sprint003Path = Join-Path $PSScriptRoot 'p2-003-federal-reserve-official-adapter.ps1'
$EnginePathPy = Join-Path $RepoRoot 'scripts\link-news-events.py'
$EvalPath = Join-Path $RepoRoot 'scripts\evaluate-news-intelligence.py'
$NvidiaAdapterPath = Join-Path $RepoRoot 'scripts\nvidia-official-adapter.py'
$FedAdapterPath = Join-Path $RepoRoot 'scripts\federal-reserve-official-adapter.py'
$CaseA = Join-Path $PSScriptRoot 'fixtures\p2-004-case-a-same-event.json'
$CaseB = Join-Path $PSScriptRoot 'fixtures\p2-004-case-b-related-event.json'
$CaseC = Join-Path $PSScriptRoot 'fixtures\p2-004-case-c-separate-event.json'
$CaseD = Join-Path $PSScriptRoot 'fixtures\p2-004-case-d-same-subject-different-event.json'
$CaseE = Join-Path $PSScriptRoot 'fixtures\p2-004-case-e-same-event-different-wording.json'
$CaseF = Join-Path $PSScriptRoot 'fixtures\p2-004-case-f-same-subject-new-information.json'
$Spec001Path = Join-Path $RepoRoot 'docs\Phase 2 Sprint 001 News Intelligence Foundation SPEC.md'
$Spec004Path = Join-Path $RepoRoot 'docs\Phase 2 Sprint 004 News Dedup & Event Linking SPEC.md'
$HandbookPath = Join-Path $RepoRoot 'docs\Investor Twin Handbook V2.0.md'
$GeneratePath = Join-Path $RepoRoot 'scripts\generate-morning-brief.py'
$CollectPath = Join-Path $RepoRoot 'scripts\collect-evidence.py'
$BriefDedupSrc = Join-Path $RepoRoot 'js\data-engine.js'
$AppPath = Join-Path $RepoRoot 'app.js'
$WorkflowPath = Join-Path $RepoRoot 'js\workflow-engine.js'
$IndexPath = Join-Path $RepoRoot 'index.html'
$ProdBriefPath = Join-Path $RepoRoot 'data\morning-brief.json'
$ProdQueuePath = Join-Path $RepoRoot 'data\research-queue.json'
$ProdCasesPath = Join-Path $RepoRoot 'data\investment-cases.json'
$ProdIndexPath = Join-Path $RepoRoot 'data\knowledge-index.json'
$ForbiddenNewsDir = Join-Path $RepoRoot 'data\news'
$ForbiddenEventsDir = Join-Path $RepoRoot 'data\events'

foreach ($path in @($Sprint001Path, $Sprint002Path, $Sprint003Path, $EnginePathPy, $EvalPath, $CaseA, $CaseB, $CaseC, $CaseD, $CaseE, $CaseF, $Spec001Path, $Spec004Path, $HandbookPath, $BriefDedupSrc)) {
  if (-not (Test-Path -LiteralPath $path)) { throw "Missing: $path" }
}

$Utf8 = New-Object System.Text.UTF8Encoding $false
$EngineSrc = [System.IO.File]::ReadAllText($EnginePathPy, $Utf8)
$EvalSrc = [System.IO.File]::ReadAllText($EvalPath, $Utf8)
$DataEngineSrc = [System.IO.File]::ReadAllText($BriefDedupSrc, $Utf8)
$CaseARaw = [System.IO.File]::ReadAllText($CaseA, $Utf8) | ConvertFrom-Json
$CaseERaw = [System.IO.File]::ReadAllText($CaseE, $Utf8) | ConvertFrom-Json

$ProdHashBefore = @{
  brief = (Get-FileHash -Path $ProdBriefPath -Algorithm SHA256).Hash
  queue = (Get-FileHash -Path $ProdQueuePath -Algorithm SHA256).Hash
  cases = (Get-FileHash -Path $ProdCasesPath -Algorithm SHA256).Hash
  index = (Get-FileHash -Path $ProdIndexPath -Algorithm SHA256).Hash
  generate = (Get-FileHash -Path $GeneratePath -Algorithm SHA256).Hash
  collect = (Get-FileHash -Path $CollectPath -Algorithm SHA256).Hash
  eval = (Get-FileHash -Path $EvalPath -Algorithm SHA256).Hash
  nvidia = (Get-FileHash -Path $NvidiaAdapterPath -Algorithm SHA256).Hash
  fed = (Get-FileHash -Path $FedAdapterPath -Algorithm SHA256).Hash
  sprint001 = (Get-FileHash -Path $Sprint001Path -Algorithm SHA256).Hash
  sprint002 = (Get-FileHash -Path $Sprint002Path -Algorithm SHA256).Hash
  sprint003 = (Get-FileHash -Path $Sprint003Path -Algorithm SHA256).Hash
  spec001 = (Get-FileHash -Path $Spec001Path -Algorithm SHA256).Hash
  spec004 = (Get-FileHash -Path $Spec004Path -Algorithm SHA256).Hash
  handbook = (Get-FileHash -Path $HandbookPath -Algorithm SHA256).Hash
  app = (Get-FileHash -Path $AppPath -Algorithm SHA256).Hash
  engine = (Get-FileHash -Path $BriefDedupSrc -Algorithm SHA256).Hash
  workflow = (Get-FileHash -Path $WorkflowPath -Algorithm SHA256).Hash
  html = (Get-FileHash -Path $IndexPath -Algorithm SHA256).Hash
}

$script:Results = New-Object System.Collections.Generic.List[object]
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

function Invoke-Dedup($fixturePath) {
  $python = Get-Python
  $out = & $python $EnginePathPy --input $fixturePath 2>&1
  $text = ($out | ForEach-Object { "$_" }) -join "`n"
  if ($LASTEXITCODE -ne 0) { throw "dedup failed: $text" }
  return ($text | ConvertFrom-Json)
}

function Invoke-DedupJson($jsonText) {
  $python = Get-Python
  $out = $jsonText | & $python $EnginePathPy 2>&1
  $text = ($out | ForEach-Object { "$_" }) -join "`n"
  if ($LASTEXITCODE -ne 0) { throw "dedup stdin failed: $text" }
  return ($text | ConvertFrom-Json)
}

function Get-Link($result) {
  return @($result.links)[0]
}

function Test-ProtectedHashes {
  return (
    (Get-FileHash -Path $ProdBriefPath -Algorithm SHA256).Hash -eq $ProdHashBefore.brief -and
    (Get-FileHash -Path $ProdQueuePath -Algorithm SHA256).Hash -eq $ProdHashBefore.queue -and
    (Get-FileHash -Path $ProdCasesPath -Algorithm SHA256).Hash -eq $ProdHashBefore.cases -and
    (Get-FileHash -Path $ProdIndexPath -Algorithm SHA256).Hash -eq $ProdHashBefore.index -and
    (Get-FileHash -Path $GeneratePath -Algorithm SHA256).Hash -eq $ProdHashBefore.generate -and
    (Get-FileHash -Path $CollectPath -Algorithm SHA256).Hash -eq $ProdHashBefore.collect -and
    (Get-FileHash -Path $EvalPath -Algorithm SHA256).Hash -eq $ProdHashBefore.eval -and
    (Get-FileHash -Path $NvidiaAdapterPath -Algorithm SHA256).Hash -eq $ProdHashBefore.nvidia -and
    (Get-FileHash -Path $FedAdapterPath -Algorithm SHA256).Hash -eq $ProdHashBefore.fed -and
    (Get-FileHash -Path $Sprint001Path -Algorithm SHA256).Hash -eq $ProdHashBefore.sprint001 -and
    (Get-FileHash -Path $Sprint002Path -Algorithm SHA256).Hash -eq $ProdHashBefore.sprint002 -and
    (Get-FileHash -Path $Sprint003Path -Algorithm SHA256).Hash -eq $ProdHashBefore.sprint003 -and
    (Get-FileHash -Path $Spec001Path -Algorithm SHA256).Hash -eq $ProdHashBefore.spec001 -and
    (Get-FileHash -Path $Spec004Path -Algorithm SHA256).Hash -eq $ProdHashBefore.spec004 -and
    (Get-FileHash -Path $HandbookPath -Algorithm SHA256).Hash -eq $ProdHashBefore.handbook -and
    (Get-FileHash -Path $AppPath -Algorithm SHA256).Hash -eq $ProdHashBefore.app -and
    (Get-FileHash -Path $BriefDedupSrc -Algorithm SHA256).Hash -eq $ProdHashBefore.engine -and
    (Get-FileHash -Path $WorkflowPath -Algorithm SHA256).Hash -eq $ProdHashBefore.workflow -and
    (Get-FileHash -Path $IndexPath -Algorithm SHA256).Hash -eq $ProdHashBefore.html -and
    -not (Test-Path -LiteralPath $ForbiddenNewsDir) -and
    -not (Test-Path -LiteralPath $ForbiddenEventsDir)
  )
}

Write-Output '=== P2-001 / P2-002 / P2-003 REGRESSION ==='
$sprint001 = & powershell -NoProfile -File $Sprint001Path
$sprint001Text = ($sprint001 | ForEach-Object { "$_" }) -join "`n"
Write-Output $sprint001Text
Add-TestResult 'TEST 1-20' ($LASTEXITCODE -eq 0) $(if ($LASTEXITCODE -eq 0) { 'Sprint 001 TEST 1-20 still PASS' } else { $sprint001Text })

$sprint002 = & powershell -NoProfile -File $Sprint002Path
$sprint002Text = ($sprint002 | ForEach-Object { "$_" }) -join "`n"
Write-Output $sprint002Text
Add-TestResult 'TEST 21-30' ($LASTEXITCODE -eq 0) $(if ($LASTEXITCODE -eq 0) { 'Sprint 002 TEST 21-30 still PASS' } else { $sprint002Text })

$sprint003 = & powershell -NoProfile -File $Sprint003Path
$sprint003Text = ($sprint003 | ForEach-Object { "$_" }) -join "`n"
Write-Output $sprint003Text
Add-TestResult 'TEST 31-41' ($LASTEXITCODE -eq 0) $(if ($LASTEXITCODE -eq 0) { 'Sprint 003 TEST 31-41 still PASS' } else { $sprint003Text })

$resA = Invoke-Dedup $CaseA
$resB = Invoke-Dedup $CaseB
$resC = Invoke-Dedup $CaseC
$resD = Invoke-Dedup $CaseD
$resE = Invoke-Dedup $CaseE
$resF = Invoke-Dedup $CaseF
$linkA = Get-Link $resA
$linkB = Get-Link $resB
$linkC = Get-Link $resC
$linkD = Get-Link $resD
$linkE = Get-Link $resE
$linkF = Get-Link $resF

$fail42 = New-Object System.Collections.Generic.List[string]
if ($linkA.relation -ne 'Same Event') { $fail42.Add("Case A relation=$($linkA.relation)") }
if ($linkA.eventRefA -ne $linkA.eventRefB) { $fail42.Add('Case A eventRefs differ') }
if (@($resA.news).Count -ne 2) { $fail42.Add('Case A did not keep two News') }
if (@($resA.events).Count -ne 1) { $fail42.Add('Case A did not collapse to one Event') }
Add-TestResult 'TEST 42' ($fail42.Count -eq 0) ($fail42 -join "`n")

$fail43 = New-Object System.Collections.Generic.List[string]
foreach ($pair in @(@($resA, $CaseARaw), @($resE, $CaseERaw))) {
  $result = $pair[0]
  $raw = $pair[1]
  $sources = @($result.news | ForEach-Object { $_.source })
  if ($sources -notcontains $raw.newsA.source) { $fail43.Add("lost source $($raw.newsA.source)") }
  if ($sources -notcontains $raw.newsB.source) { $fail43.Add("lost source $($raw.newsB.source)") }
  if (-not ($result.news | Where-Object { $_.title -eq $raw.newsA.title })) { $fail43.Add('News A title was dropped') }
  if (-not ($result.news | Where-Object { $_.title -eq $raw.newsB.title })) { $fail43.Add('News B title was dropped') }
}
Add-TestResult 'TEST 43' ($fail43.Count -eq 0) ($fail43 -join "`n")

$fail44 = New-Object System.Collections.Generic.List[string]
if ($linkB.relation -ne 'Related Event') { $fail44.Add("Case B relation=$($linkB.relation)") }
if ($linkB.eventRefA -eq $linkB.eventRefB) { $fail44.Add('Case B merged Events') }
if (@($resB.events).Count -lt 2) { $fail44.Add('Case B does not keep two Events') }
if ($linkF.relation -ne 'Related Event') { $fail44.Add("Case F relation=$($linkF.relation)") }
if ($linkF.eventRefA -eq $linkF.eventRefB) { $fail44.Add('Case F merged Events') }
Add-TestResult 'TEST 44' ($fail44.Count -eq 0) ($fail44 -join "`n")

$fail45 = New-Object System.Collections.Generic.List[string]
if ($linkC.relation -ne 'Separate Event') { $fail45.Add("Case C relation=$($linkC.relation)") }
if ($linkC.eventRefA -eq $linkC.eventRefB) { $fail45.Add('Case C merged Events') }
if ($linkD.relation -ne 'Separate Event') { $fail45.Add("Case D relation=$($linkD.relation)") }
if ($linkD.eventRefA -eq $linkD.eventRefB) { $fail45.Add('Case D merged Events') }
Add-TestResult 'TEST 45' ($fail45.Count -eq 0) ($fail45 -join "`n")

$fail46 = New-Object System.Collections.Generic.List[string]
if ($linkE.relation -ne 'Same Event') { $fail46.Add("Case E relation=$($linkE.relation)") }
if ($CaseERaw.newsA.title -eq $CaseERaw.newsB.title) { $fail46.Add('Case E titles unexpectedly match') }
if ($EngineSrc -match 'SequenceMatcher|similarity\s*=' ) { $fail46.Add('engine uses title similarity scoring') }
$titleOnly = @{
  newsA = @{
    source = 'Acceptance Fixture'
    title = 'NVIDIA announces major deal'
    publishedTime = '2026-09-03'
    summary = 'NVIDIA announced a manufacturing partnership with another company.'
    subject = 'NVIDIA'
  }
  newsB = @{
    source = 'Acceptance Fixture'
    title = 'NVIDIA announces major deal today'
    publishedTime = '2026-09-03'
    summary = 'NVIDIA has agreed to acquire Hugging Face.'
    subject = 'NVIDIA / Hugging Face'
  }
} | ConvertTo-Json -Depth 6
$titleOnlyResult = Invoke-DedupJson $titleOnly
$titleOnlyLink = Get-Link $titleOnlyResult
if ($titleOnlyLink.relation -eq 'Same Event') { $fail46.Add('similar titles were treated as Same Event') }
Add-TestResult 'TEST 46' ($fail46.Count -eq 0) ($fail46 -join "`n")

$fail47 = New-Object System.Collections.Generic.List[string]
if ($linkD.relation -ne 'Separate Event') { $fail47.Add("Case D relation=$($linkD.relation)") }
if ($linkD.reason.coreFact -notlike '*partnership*') { $fail47.Add('Case D reason does not cite different core fact') }
if ($EngineSrc -match 'same subject \+ same date = Same Event') { $fail47.Add('engine hard-codes subject+date merge') }
Add-TestResult 'TEST 47' ($fail47.Count -eq 0) ($fail47 -join "`n")

$fail48 = New-Object System.Collections.Generic.List[string]
$official = $resA.news | Where-Object { $_.source -eq 'NVIDIA Official Blog' }
$reuters = $resA.news | Where-Object { $_.source -eq 'Reuters' }
if (-not $official) { $fail48.Add('Official source missing after Same Event') }
if (-not $reuters) { $fail48.Add('Reuters source missing after Same Event') }
if ($official.url -ne $CaseARaw.newsA.url) { $fail48.Add('Official URL was rewritten') }
if ($null -eq $reuters.PSObject.Properties['url']) { $fail48.Add('Reuters url field dropped') }
Add-TestResult 'TEST 48' ($fail48.Count -eq 0) ($fail48 -join "`n")

$fail49 = New-Object System.Collections.Generic.List[string]
if ($DataEngineSrc -notlike '*briefDedupText*') { $fail49.Add('briefDedupText is missing') }
if ($EngineSrc -like '*briefDedupText*') { $fail49.Add('News Dedup engine calls Presentation Dedup') }
if ((Get-FileHash -Path $BriefDedupSrc -Algorithm SHA256).Hash -ne $ProdHashBefore.engine) { $fail49.Add('data-engine.js changed') }
Add-TestResult 'TEST 49' ($fail49.Count -eq 0) ($fail49 -join "`n")

$fail50 = New-Object System.Collections.Generic.List[string]
if ((Get-FileHash -Path $GeneratePath -Algorithm SHA256).Hash -ne $ProdHashBefore.generate) { $fail50.Add('031-B generator changed') }
if ((Get-FileHash -Path $AppPath -Algorithm SHA256).Hash -ne $ProdHashBefore.app) { $fail50.Add('app.js changed') }
if ((Get-FileHash -Path $IndexPath -Algorithm SHA256).Hash -ne $ProdHashBefore.html) { $fail50.Add('index.html changed') }
Add-TestResult 'TEST 50' ($fail50.Count -eq 0) ($fail50 -join "`n")

$fail51 = New-Object System.Collections.Generic.List[string]
foreach ($src in @($EngineSrc, $EvalSrc)) {
  if ($src -like '*/api/queue*') { $fail51.Add('source references POST /api/queue') }
  if ($src -like '*/api/research*') { $fail51.Add('source references POST /api/research') }
  if ($src -like '*research-queue.json*') { $fail51.Add('source writes or loads research-queue.json') }
  if ($src -like '*card.json*') { $fail51.Add('source writes Research Card files') }
}
if ($EngineSrc -like '*morning-brief.json*') { $fail51.Add('dedup engine references morning-brief.json') }
Add-TestResult 'TEST 51' ($fail51.Count -eq 0) ($fail51 -join "`n")

$fail52 = New-Object System.Collections.Generic.List[string]
$blob = (($resA, $resB, $resC, $resD, $resE, $resF) | ConvertTo-Json -Depth 8)
foreach ($word in @('Buy', 'Sell', '加碼', '減碼')) {
  if ($blob -like ('*' + $word + '*')) { $fail52.Add("output contains $word") }
}
Add-TestResult 'TEST 52' ($fail52.Count -eq 0) ($fail52 -join "`n")

$guardOk = Test-ProtectedHashes
Add-TestResult 'PRODUCTION_FILE_GUARD' $guardOk $(if ($guardOk) { '' } else { 'protected production, SPEC, adapter, or engine files were modified' })

$failed = @($script:Results | Where-Object { $_.Status -ne 'PASS' })
Write-Output ''
Write-Output '=== P2-004 SUMMARY ==='
foreach ($row in $script:Results) {
  Write-Output ("{0}: {1}" -f $row.Id, $row.Status)
  if ($row.Status -ne 'PASS' -and $row.Details) { Write-Output $row.Details }
}
if ($failed.Count -gt 0) { exit 1 }
exit 0
