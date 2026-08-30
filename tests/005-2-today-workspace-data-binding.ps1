$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$RepoRoot = Split-Path -Parent $PSScriptRoot
$FixturePath = Join-Path $PSScriptRoot 'fixtures\005-2-today-workspace-data-binding.json'
$IndexPath = Join-Path $RepoRoot 'index.html'
$AppPath = Join-Path $RepoRoot 'app.js'
$EnginePath = Join-Path $RepoRoot 'js\data-engine.js'
$WorkflowPath = Join-Path $RepoRoot 'js\workflow-engine.js'
$KnowledgePath = Join-Path $RepoRoot 'js\knowledge-engine.js'
$CollectPath = Join-Path $RepoRoot 'scripts\collect-evidence.py'
$GeneratePath = Join-Path $RepoRoot 'scripts\generate-morning-brief.py'
$ProdBriefPath = Join-Path $RepoRoot 'data\morning-brief.json'
$ProdQueuePath = Join-Path $RepoRoot 'data\research-queue.json'
$ProdCasesPath = Join-Path $RepoRoot 'data\investment-cases.json'
$ProdIndexPath = Join-Path $RepoRoot 'data\knowledge-index.json'

if (-not (Test-Path $FixturePath)) { throw "Missing fixture: $FixturePath" }

$Utf8 = New-Object System.Text.UTF8Encoding $false
$Contract = [System.IO.File]::ReadAllText($FixturePath, $Utf8) | ConvertFrom-Json
$Index = [System.IO.File]::ReadAllText($IndexPath, $Utf8)
$App = [System.IO.File]::ReadAllText($AppPath, $Utf8)
$Engine = [System.IO.File]::ReadAllText($EnginePath, $Utf8)
$TodayStart = $Index.IndexOf('id="today"')
$QueueStart = $Index.IndexOf('id="queue"')
if ($TodayStart -lt 0 -or $QueueStart -lt 0) { throw 'today/queue markup missing' }
$TodayBlock = $Index.Substring($TodayStart, $QueueStart - $TodayStart)
$Brief = [System.IO.File]::ReadAllText($ProdBriefPath, $Utf8) | ConvertFrom-Json

$ProdHashBefore = @{
  brief = (Get-FileHash -Path $ProdBriefPath -Algorithm SHA256).Hash
  queue = (Get-FileHash -Path $ProdQueuePath -Algorithm SHA256).Hash
  cases = (Get-FileHash -Path $ProdCasesPath -Algorithm SHA256).Hash
  index = (Get-FileHash -Path $ProdIndexPath -Algorithm SHA256).Hash
  engine = (Get-FileHash -Path $EnginePath -Algorithm SHA256).Hash
  workflow = (Get-FileHash -Path $WorkflowPath -Algorithm SHA256).Hash
  knowledge = (Get-FileHash -Path $KnowledgePath -Algorithm SHA256).Hash
  collect = (Get-FileHash -Path $CollectPath -Algorithm SHA256).Hash
  generate = (Get-FileHash -Path $GeneratePath -Algorithm SHA256).Hash
}

$script:Results = New-Object System.Collections.Generic.List[object]
function Add-TestResult($id, $passed, $details) {
  $status = if ($passed) { 'PASS' } else { 'FAIL' }
  $script:Results.Add([PSCustomObject]@{ Id = $id; Status = $status; Details = $details })
  Write-Output ("{0}: {1}" -f $id, $status)
  if ($details) { Write-Output $details }
}

$fail0 = New-Object System.Collections.Generic.List[string]
if ($App -notlike ('*function ' + $Contract.bindFunction + '*')) { $fail0.Add('bind function missing') }
if ($App -notlike '*bindTodayWorkspaceFromMorningBrief()*') { $fail0.Add('init does not bind Morning Brief to Today Workspace') }
if ($App -notlike '*DataEngine.loadMorningBrief()*') { $fail0.Add('loadMorningBrief missing') }
if ($App -notlike '*DataEngine.renderMorningBrief(openMorningBriefResearch)*') { $fail0.Add('renderMorningBrief path missing') }
if ($App -like '*function renderTodayQueue*') { $fail0.Add('Today Workspace still has renderTodayQueue') }
if ($App -like '*data/opportunity-radar.json*') { $fail0.Add('app.js binds opportunity-radar.json into Today') }
Add-TestResult 'TEST 0' ($fail0.Count -eq 0) ($fail0 -join "`n")

$fail1 = New-Object System.Collections.Generic.List[string]
if (-not $Brief.date) { $fail1.Add('canonical morning-brief.json missing date') }
if ($Brief.PSObject.Properties.Name -notcontains 'executiveSummary') { $fail1.Add('canonical brief missing executiveSummary') }
foreach ($row in @($Contract.fieldBindings)) {
  if ($Index -notlike ('*id="' + $row.elementId + '"*')) { $fail1.Add('Today missing ' + $row.elementId) }
}
if ($Engine -notlike "*data/morning-brief.json*") { $fail1.Add('Data Engine no longer loads morning-brief.json') }
Add-TestResult 'TEST 1' ($fail1.Count -eq 0) ($fail1 -join "`n")

$fail2 = New-Object System.Collections.Generic.List[string]
foreach ($needle in @($Contract.engineNeedles)) {
  if ($Engine -notlike ('*' + $needle + '*')) { $fail2.Add('renderer missing ' + $needle) }
}
Add-TestResult 'TEST 2' ($fail2.Count -eq 0) ($fail2 -join "`n")

$fail3 = New-Object System.Collections.Generic.List[string]
foreach ($heading in @($Contract.forbiddenTodayHeadings)) {
  if ($TodayBlock -like ('*' + $heading + '*')) { $fail3.Add("Today Workspace still shows $heading") }
}
if ($TodayBlock -like '*id="todayQueue"*') { $fail3.Add('todayQueue returned to Today Workspace') }
if ($TodayBlock -notlike '*id="morningAiHighlights"*') { $fail3.Add('hidden morningAiHighlights id missing') }
if ($TodayBlock -like '*<h2>AI*') { $fail3.Add('visible AI heading returned') }
Add-TestResult 'TEST 3' ($fail3.Count -eq 0) ($fail3 -join "`n")

$fail4 = New-Object System.Collections.Generic.List[string]
if ($Engine -notlike "*data.date || '--'*") { $fail4.Add('date fallback missing') }
if ($Engine -notlike '*emptyMorningBrief()*') { $fail4.Add('empty brief fallback missing') }
if ($Engine -notlike '*normalizeMorningBrief(*') { $fail4.Add('normalizeMorningBrief missing') }
if ($Index -like '*data/morning-brief/latest.json*') { $fail4.Add('Today Workspace points at latest.json') }
Add-TestResult 'TEST 4' ($fail4.Count -eq 0) ($fail4 -join "`n")

$guardOk = (
  (Get-FileHash -Path $ProdBriefPath -Algorithm SHA256).Hash -eq $ProdHashBefore.brief -and
  (Get-FileHash -Path $ProdQueuePath -Algorithm SHA256).Hash -eq $ProdHashBefore.queue -and
  (Get-FileHash -Path $ProdCasesPath -Algorithm SHA256).Hash -eq $ProdHashBefore.cases -and
  (Get-FileHash -Path $ProdIndexPath -Algorithm SHA256).Hash -eq $ProdHashBefore.index -and
  (Get-FileHash -Path $EnginePath -Algorithm SHA256).Hash -eq $ProdHashBefore.engine -and
  (Get-FileHash -Path $WorkflowPath -Algorithm SHA256).Hash -eq $ProdHashBefore.workflow -and
  (Get-FileHash -Path $KnowledgePath -Algorithm SHA256).Hash -eq $ProdHashBefore.knowledge -and
  (Get-FileHash -Path $CollectPath -Algorithm SHA256).Hash -eq $ProdHashBefore.collect -and
  (Get-FileHash -Path $GeneratePath -Algorithm SHA256).Hash -eq $ProdHashBefore.generate
)
Add-TestResult 'PRODUCTION_FILE_GUARD' $guardOk $(if ($guardOk) { '' } else { 'protected production or engine files were modified' })

$failed = @($script:Results | Where-Object { $_.Status -ne 'PASS' })
Write-Output ''
Write-Output '=== 005-2 SUMMARY ==='
foreach ($row in $script:Results) {
  Write-Output ("{0}: {1}" -f $row.Id, $row.Status)
}
if ($failed.Count -gt 0) { exit 1 }
exit 0
