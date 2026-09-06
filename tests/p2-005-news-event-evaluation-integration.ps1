$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$env:PYTHONIOENCODING = 'utf-8'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$Sprint001Path = Join-Path $PSScriptRoot 'p2-001-news-intelligence-foundation.ps1'
$Sprint002Path = Join-Path $PSScriptRoot 'p2-002-nvidia-official-adapter.ps1'
$Sprint003Path = Join-Path $PSScriptRoot 'p2-003-federal-reserve-official-adapter.ps1'
$Sprint004Path = Join-Path $PSScriptRoot 'p2-004-news-dedup-event-linking.ps1'
$IntegratePath = Join-Path $RepoRoot 'scripts\integrate-news-event-evaluation.py'
$EvalPath = Join-Path $RepoRoot 'scripts\evaluate-news-intelligence.py'
$LinkPath = Join-Path $RepoRoot 'scripts\link-news-events.py'
$NvidiaAdapterPath = Join-Path $RepoRoot 'scripts\nvidia-official-adapter.py'
$FedAdapterPath = Join-Path $RepoRoot 'scripts\federal-reserve-official-adapter.py'
$CaseA = Join-Path $PSScriptRoot 'fixtures\p2-005-case-a-nvidia-same-event.json'
$CaseB = Join-Path $PSScriptRoot 'fixtures\p2-005-case-b-ecb-importance-relevance.json'
$CaseC = Join-Path $PSScriptRoot 'fixtures\p2-005-case-c-same-event-new-evidence.json'
$CaseD = Join-Path $PSScriptRoot 'fixtures\p2-005-case-d-related-events.json'
$NvidiaNews = Join-Path $PSScriptRoot 'fixtures\p2-002-news-nvidia-huggingface.json'
$Spec001Path = Join-Path $RepoRoot 'docs\Phase 2 Sprint 001 News Intelligence Foundation SPEC.md'
$Spec004Path = Join-Path $RepoRoot 'docs\Phase 2 Sprint 004 News Dedup & Event Linking SPEC.md'
$Spec005Path = Join-Path $RepoRoot 'docs\Phase 2 Sprint 005 News Event Evaluation Integration SPEC.md'
$HandbookPath = Join-Path $RepoRoot 'docs\Investor Twin Handbook V2.0.md'
$DesignPath = Join-Path $RepoRoot 'docs\Phase 2 Event Evaluation Integration Design.md'
$AuditPath = Join-Path $RepoRoot 'docs\Phase 2 Event Evaluation Governance Audit.md'
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

foreach ($path in @(
  $Sprint001Path, $Sprint002Path, $Sprint003Path, $Sprint004Path,
  $IntegratePath, $EvalPath, $LinkPath, $NvidiaAdapterPath, $FedAdapterPath,
  $CaseA, $CaseB, $CaseC, $CaseD, $NvidiaNews,
  $Spec001Path, $Spec004Path, $Spec005Path, $HandbookPath, $DesignPath, $AuditPath,
  $GeneratePath, $CollectPath, $BriefDedupSrc, $AppPath, $WorkflowPath, $IndexPath,
  $ProdBriefPath, $ProdQueuePath, $ProdCasesPath, $ProdIndexPath
)) {
  if (-not (Test-Path -LiteralPath $path)) { throw "Missing: $path" }
}

$Utf8 = New-Object System.Text.UTF8Encoding $false
$IntegrateSrc = [System.IO.File]::ReadAllText($IntegratePath, $Utf8)
$EvalSrc = [System.IO.File]::ReadAllText($EvalPath, $Utf8)
$LinkSrc = [System.IO.File]::ReadAllText($LinkPath, $Utf8)
$CaseARaw = [System.IO.File]::ReadAllText($CaseA, $Utf8) | ConvertFrom-Json
$CaseCRaw = [System.IO.File]::ReadAllText($CaseC, $Utf8) | ConvertFrom-Json
$CaseDRaw = [System.IO.File]::ReadAllText($CaseD, $Utf8) | ConvertFrom-Json
$NvidiaNewsRaw = [System.IO.File]::ReadAllText($NvidiaNews, $Utf8) | ConvertFrom-Json

$ProdHashBefore = @{
  brief = (Get-FileHash -Path $ProdBriefPath -Algorithm SHA256).Hash
  queue = (Get-FileHash -Path $ProdQueuePath -Algorithm SHA256).Hash
  cases = (Get-FileHash -Path $ProdCasesPath -Algorithm SHA256).Hash
  index = (Get-FileHash -Path $ProdIndexPath -Algorithm SHA256).Hash
  generate = (Get-FileHash -Path $GeneratePath -Algorithm SHA256).Hash
  collect = (Get-FileHash -Path $CollectPath -Algorithm SHA256).Hash
  eval = (Get-FileHash -Path $EvalPath -Algorithm SHA256).Hash
  link = (Get-FileHash -Path $LinkPath -Algorithm SHA256).Hash
  nvidia = (Get-FileHash -Path $NvidiaAdapterPath -Algorithm SHA256).Hash
  fed = (Get-FileHash -Path $FedAdapterPath -Algorithm SHA256).Hash
  sprint001 = (Get-FileHash -Path $Sprint001Path -Algorithm SHA256).Hash
  sprint002 = (Get-FileHash -Path $Sprint002Path -Algorithm SHA256).Hash
  sprint003 = (Get-FileHash -Path $Sprint003Path -Algorithm SHA256).Hash
  sprint004 = (Get-FileHash -Path $Sprint004Path -Algorithm SHA256).Hash
  spec001 = (Get-FileHash -Path $Spec001Path -Algorithm SHA256).Hash
  spec004 = (Get-FileHash -Path $Spec004Path -Algorithm SHA256).Hash
  spec005 = (Get-FileHash -Path $Spec005Path -Algorithm SHA256).Hash
  handbook = (Get-FileHash -Path $HandbookPath -Algorithm SHA256).Hash
  design = (Get-FileHash -Path $DesignPath -Algorithm SHA256).Hash
  audit = (Get-FileHash -Path $AuditPath -Algorithm SHA256).Hash
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

function Invoke-Integrate($fixturePath) {
  $python = Get-Python
  $out = & $python $IntegratePath --input $fixturePath 2>&1
  $text = ($out | ForEach-Object { "$_" }) -join "`n"
  if ($LASTEXITCODE -ne 0) { throw "integrate failed: $text" }
  return ($text | ConvertFrom-Json)
}

function Invoke-IntegrateJson($jsonText) {
  $python = Get-Python
  $out = $jsonText | & $python $IntegratePath 2>&1
  $text = ($out | ForEach-Object { "$_" }) -join "`n"
  if ($LASTEXITCODE -ne 0) { throw "integrate stdin failed: $text" }
  return ($text | ConvertFrom-Json)
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
    (Get-FileHash -Path $LinkPath -Algorithm SHA256).Hash -eq $ProdHashBefore.link -and
    (Get-FileHash -Path $NvidiaAdapterPath -Algorithm SHA256).Hash -eq $ProdHashBefore.nvidia -and
    (Get-FileHash -Path $FedAdapterPath -Algorithm SHA256).Hash -eq $ProdHashBefore.fed -and
    (Get-FileHash -Path $Sprint001Path -Algorithm SHA256).Hash -eq $ProdHashBefore.sprint001 -and
    (Get-FileHash -Path $Sprint002Path -Algorithm SHA256).Hash -eq $ProdHashBefore.sprint002 -and
    (Get-FileHash -Path $Sprint003Path -Algorithm SHA256).Hash -eq $ProdHashBefore.sprint003 -and
    (Get-FileHash -Path $Sprint004Path -Algorithm SHA256).Hash -eq $ProdHashBefore.sprint004 -and
    (Get-FileHash -Path $Spec001Path -Algorithm SHA256).Hash -eq $ProdHashBefore.spec001 -and
    (Get-FileHash -Path $Spec004Path -Algorithm SHA256).Hash -eq $ProdHashBefore.spec004 -and
    (Get-FileHash -Path $Spec005Path -Algorithm SHA256).Hash -eq $ProdHashBefore.spec005 -and
    (Get-FileHash -Path $HandbookPath -Algorithm SHA256).Hash -eq $ProdHashBefore.handbook -and
    (Get-FileHash -Path $DesignPath -Algorithm SHA256).Hash -eq $ProdHashBefore.design -and
    (Get-FileHash -Path $AuditPath -Algorithm SHA256).Hash -eq $ProdHashBefore.audit -and
    (Get-FileHash -Path $AppPath -Algorithm SHA256).Hash -eq $ProdHashBefore.app -and
    (Get-FileHash -Path $BriefDedupSrc -Algorithm SHA256).Hash -eq $ProdHashBefore.engine -and
    (Get-FileHash -Path $WorkflowPath -Algorithm SHA256).Hash -eq $ProdHashBefore.workflow -and
    (Get-FileHash -Path $IndexPath -Algorithm SHA256).Hash -eq $ProdHashBefore.html -and
    -not (Test-Path -LiteralPath $ForbiddenNewsDir) -and
    -not (Test-Path -LiteralPath $ForbiddenEventsDir)
  )
}

Write-Output '=== P2-001 / P2-002 / P2-003 / P2-004 REGRESSION ==='
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

$sprint004 = & powershell -NoProfile -File $Sprint004Path
$sprint004Text = ($sprint004 | ForEach-Object { "$_" }) -join "`n"
Write-Output $sprint004Text
Add-TestResult 'TEST 42-52' ($LASTEXITCODE -eq 0) $(if ($LASTEXITCODE -eq 0) { 'Sprint 004 TEST 42-52 still PASS' } else { $sprint004Text })

Write-Output ''
Write-Output '=== P2-005 INTEGRATION ==='
$resA = Invoke-Integrate $CaseA
$resB = Invoke-Integrate $CaseB
$resC = Invoke-Integrate $CaseC
$resD = Invoke-Integrate $CaseD

$fail53 = New-Object System.Collections.Generic.List[string]
if (@($resA.events).Count -ne 1) { $fail53.Add("Case A events=$(@($resA.events).Count); expected 1") }
if (@($resA.evaluations).Count -ne 1) { $fail53.Add("Case A evaluations=$(@($resA.evaluations).Count); expected 1") }
if (@($resA.news).Count -ne 2) { $fail53.Add('Case A did not keep two News') }
if (@($resC.events).Count -ne 1) { $fail53.Add("Case C events=$(@($resC.events).Count); expected 1") }
if (@($resC.evaluations).Count -ne 1) { $fail53.Add("Case C evaluations=$(@($resC.evaluations).Count); expected 1") }
Add-TestResult 'TEST 53' ($fail53.Count -eq 0) ($fail53 -join "`n")

$fail54 = New-Object System.Collections.Generic.List[string]
if (@($resA.researchCandidates).Count -ne 1) { $fail54.Add("Case A candidates=$(@($resA.researchCandidates).Count); expected 1") }
if (@($resA.researchCandidates).Count -gt 1) { $fail54.Add('Case A emitted more than one Candidate') }
if (@($resC.researchCandidates).Count -gt 1) { $fail54.Add('Case C emitted more than one Candidate') }
Add-TestResult 'TEST 54' ($fail54.Count -eq 0) ($fail54 -join "`n")

$fail55 = New-Object System.Collections.Generic.List[string]
$eventIdA = [string]$resA.events[0].eventId
$evalA = @($resA.evaluations)[0]
if ([string]$evalA.eventRef -ne $eventIdA) { $fail55.Add("Evaluation.eventRef=$($evalA.eventRef); expected $eventIdA") }
if ($null -ne $evalA.PSObject.Properties['newsRef'] -and $evalA.newsRef) {
  $fail55.Add('Evaluation uses newsRef as identity')
}
foreach ($item in @($resA.news)) {
  if ([string]$item.eventRef -ne $eventIdA) { $fail55.Add("News $($item.id) eventRef mismatch") }
}
Add-TestResult 'TEST 55' ($fail55.Count -eq 0) ($fail55 -join "`n")

$fail56 = New-Object System.Collections.Generic.List[string]
$candA = @($resA.researchCandidates)[0]
if ([string]$candA.eventRef -ne $eventIdA) { $fail56.Add("Candidate.eventRef=$($candA.eventRef); expected $eventIdA") }
if ([string]$evalA.researchCandidate.eventRef -ne $eventIdA) {
  $fail56.Add("embedded Candidate.eventRef=$($evalA.researchCandidate.eventRef)")
}
Add-TestResult 'TEST 56' ($fail56.Count -eq 0) ($fail56 -join "`n")

$fail57 = New-Object System.Collections.Generic.List[string]
$official = $resA.news | Where-Object { $_.source -eq 'NVIDIA Official Blog' }
$reuters = $resA.news | Where-Object { $_.source -eq 'Reuters' }
if (-not $official) { $fail57.Add('Official source missing') }
if (-not $reuters) { $fail57.Add('Reuters source missing') }
if ($official.url -ne $CaseARaw.newsA.url) { $fail57.Add('Official URL rewritten') }
if ($null -eq $reuters.PSObject.Properties['url']) { $fail57.Add('Reuters url field dropped') }
if ($official.publishedTime -ne $CaseARaw.newsA.publishedTime) { $fail57.Add('Official publishedTime lost') }
if ($reuters.publishedTime -ne $CaseARaw.newsB.publishedTime) { $fail57.Add('Reuters publishedTime lost') }
Add-TestResult 'TEST 57' ($fail57.Count -eq 0) ($fail57 -join "`n")

$fail58 = New-Object System.Collections.Generic.List[string]
if (@($resC.news).Count -ne 2) { $fail58.Add('Case C dropped a News object') }
$newsA = $resC.news | Where-Object { $_.id -eq 'news-a' }
$newsB = $resC.news | Where-Object { $_.id -eq 'news-b' }
if (-not $newsA) { $fail58.Add('News A missing') }
if (-not $newsB) { $fail58.Add('News B missing') }
$evalC = @($resC.evaluations)[0]
$refs = @($evalC.evidenceRefs)
$refA = @($refs | Where-Object { $_.newsRef -eq 'news-a' })
$refB = @($refs | Where-Object { $_.newsRef -eq 'news-b' })
if ($refA.Count -lt 1) { $fail58.Add('Evidence from News A missing') }
if ($refB.Count -lt 1) { $fail58.Add('Evidence from News B missing') }
$concern = @($refs | Where-Object {
  $_.newsRef -eq 'news-b' -and (
    [string]$_.claim -like '*concern*' -or
    [string]$_.claim -like '*疑慮*' -or
    $_.class -eq 'ESTIMATE'
  )
})
if ($concern.Count -lt 1) { $fail58.Add('News B concern evidence was destructively merged away') }
foreach ($item in $refs) {
  if (-not $item.newsRef) { $fail58.Add('evidence item missing newsRef') }
  if (-not $item.source) { $fail58.Add('evidence item missing source') }
}
Add-TestResult 'TEST 58' ($fail58.Count -eq 0) ($fail58 -join "`n")

$fail59 = New-Object System.Collections.Generic.List[string]
$evalB = @($resB.evaluations)[0]
if ([int]$evalB.importance -ne 4) { $fail59.Add("Case B importance=$($evalB.importance); expected 4") }
if ($evalB.relevance -ne 'Low / Medium-Low') { $fail59.Add("Case B relevance=$($evalB.relevance)") }
if ($evalB.researchCandidate.eligible -ne $false) { $fail59.Add('Case B Candidate is not NO') }
if (@($resB.researchCandidates).Count -ne 0) { $fail59.Add('Case B emitted a top-level Candidate') }
if ([int]$evalB.importance -ge 4 -and $evalB.researchCandidate.eligible -eq $true) {
  $fail59.Add('Importance >= 4 incorrectly forced Candidate YES')
}
if ($IntegrateSrc -match 'importance\s*>=\s*4' -or $IntegrateSrc -match 'Importance\s*>=\s*4') {
  $fail59.Add('integration hard-codes Importance >= 4')
}
Add-TestResult 'TEST 59' ($fail59.Count -eq 0) ($fail59 -join "`n")

$fail60 = New-Object System.Collections.Generic.List[string]
$queueBefore = (Get-FileHash -Path $ProdQueuePath -Algorithm SHA256).Hash
foreach ($src in @($IntegrateSrc, $EvalSrc, $LinkSrc)) {
  if ($src -like '*/api/queue*') { $fail60.Add('source references POST /api/queue') }
  if ($src -like '*research-queue.json*') { $fail60.Add('source references research-queue.json') }
}
if ((Get-FileHash -Path $ProdQueuePath -Algorithm SHA256).Hash -ne $queueBefore) {
  $fail60.Add('research-queue.json changed during tests')
}
if ((Get-FileHash -Path $ProdQueuePath -Algorithm SHA256).Hash -ne $ProdHashBefore.queue) {
  $fail60.Add('production queue hash changed')
}
Add-TestResult 'TEST 60' ($fail60.Count -eq 0) ($fail60 -join "`n")

$fail61 = New-Object System.Collections.Generic.List[string]
foreach ($src in @($IntegrateSrc, $EvalSrc, $LinkSrc)) {
  if ($src -like '*/api/research*') { $fail61.Add('source references research API write') }
  if ($src -like '*card.json*') { $fail61.Add('source writes Research Card files') }
  if ($src -like '*investment-cases.json*') { $fail61.Add('source touches investment-cases.json') }
  if ($src -like '*position*playbook*') { $fail61.Add('source references Position Playbook') }
}
$blob = (($resA, $resB, $resC, $resD) | ConvertTo-Json -Depth 10)
foreach ($word in @('Buy', 'Sell', '加碼', '減碼')) {
  if ($blob -like ('*' + $word + '*')) { $fail61.Add("output contains $word") }
}
if ((Get-FileHash -Path $ProdCasesPath -Algorithm SHA256).Hash -ne $ProdHashBefore.cases) {
  $fail61.Add('investment-cases.json changed')
}
Add-TestResult 'TEST 61' ($fail61.Count -eq 0) ($fail61 -join "`n")

$fail62 = New-Object System.Collections.Generic.List[string]
$linkD = @($resD.links)[0]
if ($linkD.relation -ne 'Related Event') { $fail62.Add("Case D relation=$($linkD.relation)") }
if ($linkD.eventRefA -eq $linkD.eventRefB) { $fail62.Add('Case D merged Events') }
if (@($resD.events).Count -ne 2) { $fail62.Add("Case D events=$(@($resD.events).Count); expected 2") }
if (@($resD.evaluations).Count -ne 2) { $fail62.Add("Case D evaluations=$(@($resD.evaluations).Count); expected 2") }
$evalRefs = @($resD.evaluations | ForEach-Object { [string]$_.eventRef } | Sort-Object -Unique)
if ($evalRefs.Count -ne 2) { $fail62.Add('Case D Evaluations do not bind to two distinct Events') }
Add-TestResult 'TEST 62' ($fail62.Count -eq 0) ($fail62 -join "`n")

$fail63 = New-Object System.Collections.Generic.List[string]
$realPayload = @{
  newsA = @{
    id = 'news-nvidia-official'
    source = [string]$NvidiaNewsRaw.source
    title = [string]$NvidiaNewsRaw.title
    publishedTime = [string]$NvidiaNewsRaw.publishedTime
    url = [string]$NvidiaNewsRaw.url
    summary = [string]$NvidiaNewsRaw.summary
    subject = [string]$NvidiaNewsRaw.subject
  }
  newsB = @{
    id = 'news-reuters-paper'
    source = [string]$CaseARaw.newsB.source
    title = [string]$CaseARaw.newsB.title
    publishedTime = [string]$CaseARaw.newsB.publishedTime
    url = $CaseARaw.newsB.url
    summary = [string]$CaseARaw.newsB.summary
    subject = [string]$CaseARaw.newsB.subject
  }
} | ConvertTo-Json -Depth 6
$resReal = Invoke-IntegrateJson $realPayload
if (@($resReal.events).Count -ne 1) { $fail63.Add("NVIDIA real case events=$(@($resReal.events).Count)") }
if (@($resReal.evaluations).Count -ne 1) { $fail63.Add("NVIDIA real case evaluations=$(@($resReal.evaluations).Count)") }
if (@($resReal.researchCandidates).Count -ne 1) { $fail63.Add("NVIDIA real case candidates=$(@($resReal.researchCandidates).Count)") }
$evalReal = @($resReal.evaluations)[0]
if ([int]$evalReal.importance -ne 5) { $fail63.Add("importance=$($evalReal.importance)") }
if ($evalReal.relevance -ne 'High') { $fail63.Add("relevance=$($evalReal.relevance)") }
if ($evalReal.impact.direction -ne 'Mixed') { $fail63.Add("direction=$($evalReal.impact.direction)") }
if ($evalReal.impact.strength -ne 'High') { $fail63.Add("strength=$($evalReal.impact.strength)") }
$sources = @($resReal.news | ForEach-Object { $_.source })
if ($sources -notcontains 'NVIDIA Official Blog') { $fail63.Add('lost NVIDIA Official Blog') }
if ($sources -notcontains 'Reuters') { $fail63.Add('lost Reuters') }
Add-TestResult 'TEST 63' ($fail63.Count -eq 0) ($fail63 -join "`n")

$guardOk = Test-ProtectedHashes
Add-TestResult 'TEST 64' $guardOk $(if ($guardOk) { 'Production File Guard PASS' } else { 'protected production, SPEC, Handbook, adapter, or engine files were modified; or data/news|events created' })

$failed = @($script:Results | Where-Object { $_.Status -ne 'PASS' })
Write-Output ''
Write-Output '=== P2-005 SUMMARY ==='
foreach ($row in $script:Results) {
  Write-Output ("{0}: {1}" -f $row.Id, $row.Status)
  if ($row.Status -ne 'PASS' -and $row.Details) { Write-Output $row.Details }
}
if ($failed.Count -gt 0) { exit 1 }
exit 0
