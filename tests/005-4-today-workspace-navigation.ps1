$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$RepoRoot = Split-Path -Parent $PSScriptRoot
$FixturePath = Join-Path $PSScriptRoot 'fixtures\005-4-today-workspace-navigation.json'
$IndexPath = Join-Path $RepoRoot 'index.html'
$AppPath = Join-Path $RepoRoot 'app.js'
$EnginePath = Join-Path $RepoRoot 'js\data-engine.js'
$WorkflowPath = Join-Path $RepoRoot 'js\workflow-engine.js'
$KnowledgePath = Join-Path $RepoRoot 'js\knowledge-engine.js'
$CollectPath = Join-Path $RepoRoot 'scripts\collect-evidence.py'
$GeneratePath = Join-Path $RepoRoot 'scripts\generate-morning-brief.py'
$HbmCardPath = Join-Path $RepoRoot 'research\hbm\card.json'
$ProdBriefPath = Join-Path $RepoRoot 'data\morning-brief.json'
$ProdQueuePath = Join-Path $RepoRoot 'data\research-queue.json'
$ProdCasesPath = Join-Path $RepoRoot 'data\investment-cases.json'
$ProdIndexPath = Join-Path $RepoRoot 'data\knowledge-index.json'

if (-not (Test-Path $FixturePath)) { throw "Missing fixture: $FixturePath" }

$Utf8 = New-Object System.Text.UTF8Encoding $false
$Contract = [System.IO.File]::ReadAllText($FixturePath, $Utf8) | ConvertFrom-Json
$Index = [System.IO.File]::ReadAllText($IndexPath, $Utf8)
$App = [System.IO.File]::ReadAllText($AppPath, $Utf8)
$TodayStart = $Index.IndexOf('id="today"')
$QueueStart = $Index.IndexOf('id="queue"')
$CardsStart = $Index.IndexOf('id="cards"')
if ($TodayStart -lt 0 -or $QueueStart -lt 0 -or $CardsStart -lt 0) { throw 'today/queue/cards markup missing' }
$TodayBlock = $Index.Substring($TodayStart, $QueueStart - $TodayStart)
$QueueBlock = $Index.Substring($QueueStart, $CardsStart - $QueueStart)

function Get-FunctionText($src, $name) {
  $needles = @("function $name(", "async function $name(")
  $start = -1
  foreach ($needle in $needles) {
    $idx = $src.IndexOf($needle)
    if ($idx -ge 0) { $start = $idx; break }
  }
  if ($start -lt 0) { return '' }
  $brace = $src.IndexOf('{', $start)
  $depth = 0
  for ($i = $brace; $i -lt $src.Length; $i++) {
    $ch = $src[$i]
    if ($ch -eq '{') { $depth++ }
    elseif ($ch -eq '}') {
      $depth--
      if ($depth -eq 0) { return $src.Substring($start, $i - $start + 1) }
    }
  }
  return $src.Substring($start)
}

$OpenFn = Get-FunctionText $App $Contract.openFunction
$BackFn = Get-FunctionText $App $Contract.backFunction
$HashFn = Get-FunctionText $App 'setViewHash'
$RestoreFn = Get-FunctionText $App $Contract.restoreFunction

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
  app = (Get-FileHash -Path $AppPath -Algorithm SHA256).Hash
}

$script:Results = New-Object System.Collections.Generic.List[object]
function Add-TestResult($id, $passed, $details) {
  $status = if ($passed) { 'PASS' } else { 'FAIL' }
  $script:Results.Add([PSCustomObject]@{ Id = $id; Status = $status; Details = $details })
  Write-Output ("{0}: {1}" -f $id, $status)
  if ($details) { Write-Output $details }
}

$fail0 = New-Object System.Collections.Generic.List[string]
if (-not $OpenFn) { $fail0.Add('openMorningBriefResearch missing') }
if ($OpenFn -notlike '*showPage(''cards'')*' -and $OpenFn -notlike '*showPage("cards")*') { $fail0.Add('Today click does not open cards page') }
if ($OpenFn -notlike ("*fromPage: '" + $Contract.fromPage + "'*") -and $OpenFn -notlike ('*fromPage: "' + $Contract.fromPage + '"*')) {
  $fail0.Add('Today click does not set fromPage today')
}
if ($OpenFn -notlike '*openResearchCard(*') { $fail0.Add('Today click does not open Research Card') }
if ($OpenFn -notlike ("*ensureInQueue(researchId, '" + $Contract.queueSource + "')*")) { $fail0.Add('Today click queue source is not Morning Brief') }
if ($OpenFn -like '*/api/research/*') { $fail0.Add('Today click creates a Research Card via API') }
if (-not (Test-Path $HbmCardPath)) { $fail0.Add('existing hbm Research Card missing') }
Add-TestResult 'TEST 0' ($fail0.Count -eq 0) ($fail0 -join "`n")

$fail1 = New-Object System.Collections.Generic.List[string]
if (-not $BackFn) { $fail1.Add('navigationBack missing') }
if ($BackFn -notlike '*type === ''page''*' -and $BackFn -notlike '*type === "page"*') { $fail1.Add('Back does not handle page sentinel') }
if ($BackFn -notlike '*showPage(top.pageId)*') { $fail1.Add('Back does not return to fromPage') }
if ($App -notlike '*type: ''page''*' -and $App -notlike '*type: "page"*') { $fail1.Add('page sentinel is not pushed onto backStack') }
Add-TestResult 'TEST 1' ($fail1.Count -eq 0) ($fail1 -join "`n")

$fail2 = New-Object System.Collections.Generic.List[string]
if ($HashFn -notlike '*history.replaceState*') { $fail2.Add('setViewHash does not use replaceState') }
if ($HashFn -like '*history.pushState*') { $fail2.Add('setViewHash creates extra history entries') }
if (-not $RestoreFn) { $fail2.Add('restoreViewFromHash missing') }
if ($RestoreFn -notlike '*showPage(view.page || ''today'')*' -and $RestoreFn -notlike '*showPage(view.page || "today")*') {
  $fail2.Add('refresh does not restore Today Workspace')
}
if ($App -notlike '*function parseViewHash*') { $fail2.Add('parseViewHash missing') }
if ($App -notlike "*raw === 'today'*") { $fail2.Add('hash today is not recognized') }
Add-TestResult 'TEST 2' ($fail2.Count -eq 0) ($fail2 -join "`n")

$fail3 = New-Object System.Collections.Generic.List[string]
foreach ($heading in @($Contract.forbiddenTodayHeadings)) {
  if ($TodayBlock -like ('*' + $heading + '*')) { $fail3.Add("Today Workspace still shows $heading") }
}
if ($TodayBlock -like '*id="todayQueue"*') { $fail3.Add('todayQueue returned') }
if ($QueueBlock -notlike '*id="queueList"*') { $fail3.Add('Research Queue page list missing') }
if ($App -like '*function renderTodayQueue*') { $fail3.Add('Today Workspace still renders queue preview') }
Add-TestResult 'TEST 3' ($fail3.Count -eq 0) ($fail3 -join "`n")

$fail4 = New-Object System.Collections.Generic.List[string]
if ($App -notlike '*bindTodayWorkspaceFromMorningBrief()*') { $fail4.Add('005-2 bind path missing') }
if ($App -notlike '*function navigationForward*') { $fail4.Add('navigationForward missing') }
if ($App -notlike '*navigationState.breadcrumb*') { $fail4.Add('breadcrumb state missing') }
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
  (Get-FileHash -Path $GeneratePath -Algorithm SHA256).Hash -eq $ProdHashBefore.generate -and
  (Get-FileHash -Path $AppPath -Algorithm SHA256).Hash -eq $ProdHashBefore.app
)
Add-TestResult 'PRODUCTION_FILE_GUARD' $guardOk $(if ($guardOk) { '' } else { 'protected files or app.js were modified' })

$failed = @($script:Results | Where-Object { $_.Status -ne 'PASS' })
Write-Output ''
Write-Output '=== 005-4 SUMMARY ==='
foreach ($row in $script:Results) {
  Write-Output ("{0}: {1}" -f $row.Id, $row.Status)
}
if ($failed.Count -gt 0) { exit 1 }
exit 0
