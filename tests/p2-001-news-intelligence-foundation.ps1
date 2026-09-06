$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$env:PYTHONIOENCODING = 'utf-8'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$ContractPath = Join-Path $PSScriptRoot 'fixtures\p2-001-news-intelligence-foundation.json'
$CaseAPath = Join-Path $PSScriptRoot 'fixtures\p2-001-case-a-nvidia-huggingface.json'
$CaseBPath = Join-Path $PSScriptRoot 'fixtures\p2-001-case-b-ecb-rate-hike.json'
$CaseCPath = Join-Path $PSScriptRoot 'fixtures\p2-001-case-c-nasdaq-price-move.json'
$CaseDPath = Join-Path $PSScriptRoot 'fixtures\p2-001-case-d-ai-rumor.json'
$CaseEPath = Join-Path $PSScriptRoot 'fixtures\p2-001-case-e-ordinary-news.json'
$NewsPath = Join-Path $PSScriptRoot 'fixtures\p2-001-news-nvidia-huggingface.json'
$BadNewsPath = Join-Path $PSScriptRoot 'fixtures\p2-001-news-malformed-missing-title.json'
$SpecPath = Join-Path $RepoRoot 'docs\Phase 2 Sprint 001 News Intelligence Foundation SPEC.md'
$HandbookPath = Join-Path $RepoRoot 'docs\Investor Twin Handbook V2.0.md'
$EvalPath = Join-Path $RepoRoot 'scripts\evaluate-news-intelligence.py'
$GeneratePath = Join-Path $RepoRoot 'scripts\generate-morning-brief.py'
$CollectPath = Join-Path $RepoRoot 'scripts\collect-evidence.py'
$AppPath = Join-Path $RepoRoot 'app.js'
$EnginePath = Join-Path $RepoRoot 'js\data-engine.js'
$WorkflowPath = Join-Path $RepoRoot 'js\workflow-engine.js'
$IndexPath = Join-Path $RepoRoot 'index.html'
$ProdBriefPath = Join-Path $RepoRoot 'data\morning-brief.json'
$ProdQueuePath = Join-Path $RepoRoot 'data\research-queue.json'
$ProdCasesPath = Join-Path $RepoRoot 'data\investment-cases.json'
$ProdIndexPath = Join-Path $RepoRoot 'data\knowledge-index.json'

foreach ($path in @($ContractPath, $CaseAPath, $CaseBPath, $CaseCPath, $CaseDPath, $CaseEPath, $NewsPath, $BadNewsPath, $SpecPath, $HandbookPath, $EvalPath)) {
  if (-not (Test-Path -LiteralPath $path)) { throw "Missing: $path" }
}

$Utf8 = New-Object System.Text.UTF8Encoding $false
$Contract = [System.IO.File]::ReadAllText($ContractPath, $Utf8) | ConvertFrom-Json
$EvalSrc = [System.IO.File]::ReadAllText($EvalPath, $Utf8)
$GenerateSrc = [System.IO.File]::ReadAllText($GeneratePath, $Utf8)
$CollectSrc = [System.IO.File]::ReadAllText($CollectPath, $Utf8)
$AppSrc = [System.IO.File]::ReadAllText($AppPath, $Utf8)
$EngineSrc = [System.IO.File]::ReadAllText($EnginePath, $Utf8)
$WorkflowSrc = [System.IO.File]::ReadAllText($WorkflowPath, $Utf8)

$ProdHashBefore = @{
  brief = (Get-FileHash -Path $ProdBriefPath -Algorithm SHA256).Hash
  queue = (Get-FileHash -Path $ProdQueuePath -Algorithm SHA256).Hash
  cases = (Get-FileHash -Path $ProdCasesPath -Algorithm SHA256).Hash
  index = (Get-FileHash -Path $ProdIndexPath -Algorithm SHA256).Hash
  generate = (Get-FileHash -Path $GeneratePath -Algorithm SHA256).Hash
  collect = (Get-FileHash -Path $CollectPath -Algorithm SHA256).Hash
  app = (Get-FileHash -Path $AppPath -Algorithm SHA256).Hash
  engine = (Get-FileHash -Path $EnginePath -Algorithm SHA256).Hash
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

function Invoke-Eval($fixturePath) {
  $python = $env:INVESTORTWIN_PYTHON
  if (-not $python) { $python = 'python' }
  $out = & $python $EvalPath --input $fixturePath 2>&1
  $text = ($out | ForEach-Object { "$_" }) -join "`n"
  if ($LASTEXITCODE -ne 0) { throw "evaluate failed: $text" }
  return ($text | ConvertFrom-Json)
}

$NewsHashBefore = (Get-FileHash -Path $NewsPath -Algorithm SHA256).Hash
$NewsRaw = [System.IO.File]::ReadAllText($NewsPath, $Utf8) | ConvertFrom-Json
$CaseA = Invoke-Eval $CaseAPath
$CaseB = Invoke-Eval $CaseBPath
$CaseC = Invoke-Eval $CaseCPath
$CaseD = Invoke-Eval $CaseDPath
$CaseE = Invoke-Eval $CaseEPath
$NewsEval = Invoke-Eval $NewsPath
$NewsHashAfter = (Get-FileHash -Path $NewsPath -Algorithm SHA256).Hash

function Invoke-EvalFail($fixturePath) {
  $python = $env:INVESTORTWIN_PYTHON
  if (-not $python) { $python = 'python' }
  $stderrPath = Join-Path $env:TEMP ('p2-001-eval-fail-' + [guid]::NewGuid().ToString('N') + '.txt')
  $stdoutPath = Join-Path $env:TEMP ('p2-001-eval-out-' + [guid]::NewGuid().ToString('N') + '.txt')
  $proc = Start-Process -FilePath $python -ArgumentList @($EvalPath, '--input', $fixturePath) -Wait -PassThru -NoNewWindow -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
  $text = ''
  if (Test-Path -LiteralPath $stdoutPath) { $text += [System.IO.File]::ReadAllText($stdoutPath) }
  if (Test-Path -LiteralPath $stderrPath) { $text += [System.IO.File]::ReadAllText($stderrPath) }
  Remove-Item -LiteralPath $stdoutPath, $stderrPath -ErrorAction SilentlyContinue
  return [PSCustomObject]@{ ExitCode = $proc.ExitCode; Text = $text }
}

$fail1 = New-Object System.Collections.Generic.List[string]
foreach ($pair in @(@($CaseA, 'A'), @($CaseB, 'B'))) {
  $fx = $pair[0]
  $label = $pair[1]
  if ($null -eq $fx.importance) { $fail1.Add("Case $label missing importance") }
  if ($null -eq $fx.relevance) { $fail1.Add("Case $label missing relevance") }
  if ("$($fx.importance)" -eq "$($fx.relevance)") { $fail1.Add("Case $label importance and relevance collapsed") }
}
Add-TestResult 'TEST 1' ($fail1.Count -eq 0) ($fail1 -join "`n")

$fail2 = New-Object System.Collections.Generic.List[string]
if ([int]$CaseA.importance -ne 5) { $fail2.Add("Case A importance=$($CaseA.importance); expected 5") }
if ($CaseA.relevance -ne 'High') { $fail2.Add("Case A relevance=$($CaseA.relevance); expected High") }
if ($CaseA.researchCandidate.eligible -ne $true) { $fail2.Add('Case A Candidate is not YES') }
$q = [string]$CaseA.researchCandidate.researchQuestion
if ($q -notlike '*AI Compute Platform*' -or $q -notlike '*AI Developer*' -or $q -notlike '*Model Platform*') {
  $fail2.Add('Case A researchQuestion does not match the walkthrough')
}
Add-TestResult 'TEST 2' ($fail2.Count -eq 0) ($fail2 -join "`n")

$fail3 = New-Object System.Collections.Generic.List[string]
if ([int]$CaseB.importance -ne 4) { $fail3.Add("Case B importance=$($CaseB.importance); expected 4") }
if ($CaseB.relevance -ne 'Low / Medium-Low') { $fail3.Add("Case B relevance=$($CaseB.relevance); expected Low / Medium-Low") }
if ($CaseB.researchCandidate.eligible -ne $false) { $fail3.Add('Case B Candidate is not NO') }
if ($CaseB.researchCandidate.researchQuestion) { $fail3.Add('Case B invented a researchQuestion') }
$reason = [string]$CaseB.researchCandidate.reason
if ($reason -notlike '*Relevance*' -or $reason -notlike '*Research Question*') {
  $fail3.Add('Case B reason does not explain missing Relevance and Research Question')
}
Add-TestResult 'TEST 3' ($fail3.Count -eq 0) ($fail3 -join "`n")

$fail4 = New-Object System.Collections.Generic.List[string]
if ([int]$CaseB.importance -ge 4 -and $CaseB.researchCandidate.eligible -eq $true) {
  $fail4.Add('Case B would pass if Importance >= 4 implied Candidate = YES')
}
if ($EvalSrc -match 'importance\s*>=\s*4' -or $EvalSrc -match 'Importance\s*>=\s*4') {
  $fail4.Add('engine hard-codes Importance >= 4')
}
Add-TestResult 'TEST 4' ($fail4.Count -eq 0) ($fail4 -join "`n")

$fail5 = New-Object System.Collections.Generic.List[string]
$scanTargets = @(
  @{ Name = 'evaluate-news-intelligence.py'; Text = $EvalSrc },
  @{ Name = 'generate-morning-brief.py'; Text = $GenerateSrc },
  @{ Name = 'collect-evidence.py'; Text = $CollectSrc },
  @{ Name = 'app.js'; Text = $AppSrc },
  @{ Name = 'data-engine.js'; Text = $EngineSrc },
  @{ Name = 'workflow-engine.js'; Text = $WorkflowSrc }
)
foreach ($target in $scanTargets) {
  if ($target.Text -match 'Importance\s*[×x*]\s*Relevance') {
    $fail5.Add("$($target.Name) has Importance × Relevance scoring")
  }
}
Add-TestResult 'TEST 5' ($fail5.Count -eq 0) ($fail5 -join "`n")

$fail6 = New-Object System.Collections.Generic.List[string]
if ($EvalSrc -like '*/api/queue*') { $fail6.Add('evaluation engine references POST /api/queue') }
if ($EvalSrc -like '*research-queue.json*') { $fail6.Add('evaluation engine writes or loads research-queue.json') }
if ($EvalSrc -like '*write_json*' -or $EvalSrc -like '*open(*''w''*') { $fail6.Add('evaluation engine has a write helper') }
Add-TestResult 'TEST 6' ($fail6.Count -eq 0) ($fail6 -join "`n")

$fail7 = New-Object System.Collections.Generic.List[string]
if ($EvalSrc -like '*/api/research*') { $fail7.Add('evaluation engine references POST /api/research') }
if ($EvalSrc -like '*card.json*') { $fail7.Add('evaluation engine writes Research Card files') }
Add-TestResult 'TEST 7' ($fail7.Count -eq 0) ($fail7 -join "`n")

$fail8 = New-Object System.Collections.Generic.List[string]
foreach ($pair in @(@($CaseA, 'A'), @($CaseB, 'B'))) {
  $fx = $pair[0]
  $label = $pair[1]
  $blob = ($fx | ConvertTo-Json -Depth 8)
  foreach ($word in @('Buy', 'Sell')) {
    if ($blob -like ('*' + $word + '*')) { $fail8.Add("Case $label output contains $word") }
  }
  $dir = [string]$fx.impact.direction
  if (@('Positive', 'Negative', 'Mixed', 'Unclear') -notcontains $dir) {
    $fail8.Add("Case $label Impact.direction=$dir")
  }
}
Add-TestResult 'TEST 8' ($fail8.Count -eq 0) ($fail8 -join "`n")

$fail9 = New-Object System.Collections.Generic.List[string]
$sepKeys = @($Contract.evidenceSeparationKeys)
$freshness = @($Contract.forbiddenFreshnessLabels)
foreach ($pair in @(@($CaseA, 'A'), @($CaseB, 'B'))) {
  $fx = $pair[0]
  $label = $pair[1]
  $sep = $fx.impact.evidenceStatus
  foreach ($key in $sepKeys) {
    if ($null -eq $sep.PSObject.Properties[$key]) { $fail9.Add("Case $label missing evidenceStatus.$key") }
  }
  foreach ($prop in $sep.PSObject.Properties) {
    if ($freshness -contains $prop.Name) {
      $fail9.Add("Case $label mixes freshness label $($prop.Name) into evidenceStatus")
    }
  }
}
if ($EvalSrc -like '*fresh/stale/missing*' -and $EvalSrc -notlike '*FRESHNESS_LABELS*') {
  $fail9.Add('engine collapsed freshness into evidence status')
}
Add-TestResult 'TEST 9' ($fail9.Count -eq 0) ($fail9 -join "`n")

$guardOk = (
  (Get-FileHash -Path $ProdBriefPath -Algorithm SHA256).Hash -eq $ProdHashBefore.brief -and
  (Get-FileHash -Path $ProdQueuePath -Algorithm SHA256).Hash -eq $ProdHashBefore.queue -and
  (Get-FileHash -Path $ProdCasesPath -Algorithm SHA256).Hash -eq $ProdHashBefore.cases -and
  (Get-FileHash -Path $ProdIndexPath -Algorithm SHA256).Hash -eq $ProdHashBefore.index -and
  (Get-FileHash -Path $GeneratePath -Algorithm SHA256).Hash -eq $ProdHashBefore.generate -and
  (Get-FileHash -Path $CollectPath -Algorithm SHA256).Hash -eq $ProdHashBefore.collect -and
  (Get-FileHash -Path $AppPath -Algorithm SHA256).Hash -eq $ProdHashBefore.app -and
  (Get-FileHash -Path $EnginePath -Algorithm SHA256).Hash -eq $ProdHashBefore.engine -and
  (Get-FileHash -Path $WorkflowPath -Algorithm SHA256).Hash -eq $ProdHashBefore.workflow -and
  (Get-FileHash -Path $IndexPath -Algorithm SHA256).Hash -eq $ProdHashBefore.html
)
Add-TestResult 'TEST 10' $guardOk $(if ($guardOk) { '' } else { 'protected production or engine files were modified' })

$fail11 = New-Object System.Collections.Generic.List[string]
if ($CaseC.event.eventType -ne 'Price-move') { $fail11.Add("Case C eventType=$($CaseC.event.eventType)") }
if ([int]$CaseC.importance -lt 3) { $fail11.Add('Case C importance is too low to test the boundary') }
if ($CaseC.researchCandidate.eligible -ne $false) { $fail11.Add('Case C Candidate is not NO') }
Add-TestResult 'TEST 11' ($fail11.Count -eq 0) ($fail11 -join "`n")

$fail12 = New-Object System.Collections.Generic.List[string]
if ($CaseD.relevance -ne 'High') { $fail12.Add("Case D relevance=$($CaseD.relevance); expected High") }
if ($CaseD.researchCandidate.eligible -ne $false) { $fail12.Add('Case D Candidate is not NO') }
$stance = [string]$CaseD.researchCandidate.stance
if ($stance -ne 'Watch' -and $stance -ne 'UNKNOWN') { $fail12.Add("Case D stance=$stance; expected Watch or UNKNOWN") }
$facts = @($CaseD.impact.evidenceStatus.FACT)
if ($facts.Count -gt 0 -and ($facts | Where-Object { "$_".Trim() })) { $fail12.Add('Case D unexpectedly has FACT support') }
if ($EvalSrc -match 'relevance\s*==\s*[''\"]High[''\"]\s*:' ) { $fail12.Add('engine hard-codes Relevance = High as YES') }
Add-TestResult 'TEST 12' ($fail12.Count -eq 0) ($fail12 -join "`n")

$fail13 = New-Object System.Collections.Generic.List[string]
if ([int]$CaseE.importance -gt 2) { $fail13.Add("Case E importance=$($CaseE.importance); expected 1-2") }
if ($CaseE.relevance -ne 'Low') { $fail13.Add("Case E relevance=$($CaseE.relevance); expected Low") }
if ($CaseE.researchCandidate.eligible -ne $false) { $fail13.Add('Case E Candidate is not NO') }
Add-TestResult 'TEST 13' ($fail13.Count -eq 0) ($fail13 -join "`n")

$fail14 = New-Object System.Collections.Generic.List[string]
foreach ($field in @('source', 'title', 'publishedTime', 'summary')) {
  if (-not $NewsRaw.$field) { $fail14.Add("News Object missing $field") }
}
foreach ($field in @('news', 'event', 'importance', 'relevance', 'relevanceBasis', 'impact', 'researchCandidate')) {
  if ($null -eq $NewsEval.PSObject.Properties[$field]) { $fail14.Add("evaluation missing $field") }
}
Add-TestResult 'TEST 14' ($fail14.Count -eq 0) ($fail14 -join "`n")

$fail15 = New-Object System.Collections.Generic.List[string]
foreach ($field in @('importance', 'relevance', 'impact', 'researchCandidate', 'candidate')) {
  if ($null -ne $NewsRaw.PSObject.Properties[$field]) { $fail15.Add("News Object is polluted with $field") }
}
if ($NewsHashAfter -ne $NewsHashBefore) { $fail15.Add('evaluation wrote back into the News Object fixture') }
if ($null -eq $NewsEval.importance) { $fail15.Add('Evaluation Result missing importance') }
if ($null -eq $NewsEval.researchCandidate) { $fail15.Add('Evaluation Result missing researchCandidate') }
Add-TestResult 'TEST 15' ($fail15.Count -eq 0) ($fail15 -join "`n")

$fail16 = New-Object System.Collections.Generic.List[string]
$bad = Invoke-EvalFail $BadNewsPath
if ([int]$bad.ExitCode -eq 0) { $fail16.Add('malformed News Object was accepted') }
if ([string]$bad.Text -notlike '*missing required field*') { $fail16.Add('malformed News Object did not report validation FAIL') }
if ([string]$bad.Text -like '*"eligible": true*') { $fail16.Add('malformed News Object produced a Candidate') }
Add-TestResult 'TEST 16' ($fail16.Count -eq 0) ($fail16 -join "`n")

$fail17 = New-Object System.Collections.Generic.List[string]
if ($NewsEval.event.eventType -ne 'Corporate Action') { $fail17.Add("eventType=$($NewsEval.event.eventType)") }
if ([string]$NewsEval.event.when -ne '2026-09-03') { $fail17.Add("event.when=$($NewsEval.event.when)") }
if ([string]$NewsEval.event.subject -notlike '*NVIDIA*' -or [string]$NewsEval.event.subject -notlike '*Hugging Face*') {
  $fail17.Add("event.subject=$($NewsEval.event.subject)")
}
if ([string]$NewsEval.event.what -notlike '*NVIDIA*' -or [string]$NewsEval.event.what -notlike '*Hugging Face*') {
  $fail17.Add("event.what=$($NewsEval.event.what)")
}
Add-TestResult 'TEST 17' ($fail17.Count -eq 0) ($fail17 -join "`n")

$fail18 = New-Object System.Collections.Generic.List[string]
if ([int]$NewsEval.importance -ne 5) { $fail18.Add("importance=$($NewsEval.importance)") }
if ($NewsEval.relevance -ne 'High') { $fail18.Add("relevance=$($NewsEval.relevance)") }
if ([string]$NewsEval.impact.target -notlike '*NVIDIA*') { $fail18.Add("impact.target=$($NewsEval.impact.target)") }
if ($NewsEval.impact.direction -ne 'Mixed') { $fail18.Add("impact.direction=$($NewsEval.impact.direction)") }
if ($NewsEval.impact.strength -ne 'High') { $fail18.Add("impact.strength=$($NewsEval.impact.strength)") }
foreach ($key in @('FACT', 'INFERENCE', 'UNKNOWN')) {
  if ($null -eq $NewsEval.impact.evidenceStatus.PSObject.Properties[$key]) { $fail18.Add("missing evidenceStatus.$key") }
}
Add-TestResult 'TEST 18' ($fail18.Count -eq 0) ($fail18 -join "`n")

$fail19 = New-Object System.Collections.Generic.List[string]
if ($NewsEval.researchCandidate.eligible -ne $true) { $fail19.Add('valid News Object Candidate is not YES') }
if (-not $NewsEval.researchCandidate.reason) { $fail19.Add('Candidate missing reason') }
if (-not $NewsEval.researchCandidate.researchQuestion) { $fail19.Add('Candidate missing researchQuestion') }
if ($EvalSrc -like '*/api/queue*') { $fail19.Add('engine references /api/queue') }
if ($EvalSrc -like '*/api/research*') { $fail19.Add('engine references /api/research') }
Add-TestResult 'TEST 19' ($fail19.Count -eq 0) ($fail19 -join "`n")

Add-TestResult 'TEST 20' $guardOk $(if ($guardOk) { '' } else { 'protected production or engine files were modified' })
Add-TestResult 'PRODUCTION_FILE_GUARD' $guardOk $(if ($guardOk) { '' } else { 'protected production or engine files were modified' })

$failed = @($script:Results | Where-Object { $_.Status -ne 'PASS' })
Write-Output ''
Write-Output '=== P2-001 SUMMARY ==='
foreach ($row in $script:Results) {
  Write-Output ("{0}: {1}" -f $row.Id, $row.Status)
  if ($row.Status -ne 'PASS' -and $row.Details) { Write-Output $row.Details }
}
if ($failed.Count -gt 0) { exit 1 }
exit 0
