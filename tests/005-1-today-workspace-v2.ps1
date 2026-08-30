$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$RepoRoot = Split-Path -Parent $PSScriptRoot
$FixturePath = Join-Path $PSScriptRoot 'fixtures\005-1-today-workspace-v2.json'
$IndexPath = Join-Path $RepoRoot 'index.html'
$AppPath = Join-Path $RepoRoot 'app.js'
$StylePath = Join-Path $RepoRoot 'style.css'
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
$Style = [System.IO.File]::ReadAllText($StylePath, $Utf8)
$Engine = [System.IO.File]::ReadAllText($EnginePath, $Utf8)
$TodayStart = $Index.IndexOf('id="today"')
$QueueStart = $Index.IndexOf('id="queue"')
$CardsStart = $Index.IndexOf('id="cards"')
if ($TodayStart -lt 0 -or $QueueStart -lt 0 -or $CardsStart -lt 0) { throw 'today/queue/cards markup missing' }
$TodayBlock = $Index.Substring($TodayStart, $QueueStart - $TodayStart)
$QueueBlock = $Index.Substring($QueueStart, $CardsStart - $QueueStart)

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
if ($TodayBlock -notlike '*today-workspace*') { $fail0.Add('today-workspace class missing') }
if ($Index -notlike ('*' + $Contract.todayPageTitle + '*')) { $fail0.Add('today page title missing') }
foreach ($heading in @($Contract.forbiddenTodayHeadings)) {
  if ($TodayBlock -like ('*' + $heading + '*')) { $fail0.Add("Today Workspace still shows $heading") }
}
if ($TodayBlock -like '*id="todayQueue"*') { $fail0.Add('todayQueue still inside #today') }
Add-TestResult 'TEST 0' ($fail0.Count -eq 0) ($fail0 -join "`n")

$fail1 = New-Object System.Collections.Generic.List[string]
$cursor = 0
foreach ($heading in @($Contract.sectionOrder)) {
  $needle = '<h2>' + $heading + '</h2>'
  $idx = $TodayBlock.IndexOf($needle, $cursor)
  if ($idx -lt 0) { $fail1.Add("missing or out of order: $heading") }
  else { $cursor = $idx + $needle.Length }
}
Add-TestResult 'TEST 1' ($fail1.Count -eq 0) ($fail1 -join "`n")

$fail2 = New-Object System.Collections.Generic.List[string]
foreach ($hid in @($Contract.requiredIds)) {
  if ($Index -notlike ('*id="' + $hid + '"*')) { $fail2.Add("missing id $hid") }
}
foreach ($hid in @($Contract.queuePageIds)) {
  if ($QueueBlock -notlike ('*id="' + $hid + '"*')) { $fail2.Add("queue page missing $hid") }
}
Add-TestResult 'TEST 2' ($fail2.Count -eq 0) ($fail2 -join "`n")

$fail3 = New-Object System.Collections.Generic.List[string]
if ($App -notlike '*renderMorningBrief(openMorningBriefResearch)*') { $fail3.Add('Morning Brief render path missing') }
if ($App -like '*function renderTodayQueue*') { $fail3.Add('Today Workspace still has renderTodayQueue') }
if ($Engine -notlike '*normalizeMorningBrief(*') { $fail3.Add('Data Engine Morning Brief path missing') }
if ($Style -notlike '*#today.morning-brief*') { $fail3.Add('existing Today visual language missing') }
Add-TestResult 'TEST 3' ($fail3.Count -eq 0) ($fail3 -join "`n")

$fail4 = New-Object System.Collections.Generic.List[string]
foreach ($rel in @($Contract.dataSources)) {
  $path = Join-Path $RepoRoot ($rel -replace '/', '\')
  if (-not (Test-Path $path)) { $fail4.Add("missing data source $rel") }
}
if ($Engine -notlike '*data/morning-brief.json*') { $fail4.Add('Data Engine no longer loads morning-brief.json') }
if ($Engine -notlike '*opportunity-radar.json*') { $fail4.Add('Data Engine no longer loads opportunity-radar.json') }
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
Write-Output '=== 005-1 SUMMARY ==='
foreach ($row in $script:Results) {
  Write-Output ("{0}: {1}" -f $row.Id, $row.Status)
}
if ($failed.Count -gt 0) { exit 1 }
exit 0
