$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$RepoRoot = Split-Path -Parent $PSScriptRoot
$FixturePath = Join-Path $PSScriptRoot 'fixtures\006-2-research-card-explorer.json'
$AppPath = Join-Path $RepoRoot 'app.js'
$IndexPath = Join-Path $RepoRoot 'index.html'
$GeneratorPath = Join-Path $RepoRoot 'scripts\generate-knowledge-index.ps1'
$EnginePath = Join-Path $RepoRoot 'js\data-engine.js'
$WorkflowPath = Join-Path $RepoRoot 'js\workflow-engine.js'
$KnowledgePath = Join-Path $RepoRoot 'js\knowledge-engine.js'
$CollectPath = Join-Path $RepoRoot 'scripts\collect-evidence.py'
$GeneratePath = Join-Path $RepoRoot 'scripts\generate-morning-brief.py'
$ProdBriefPath = Join-Path $RepoRoot 'data\morning-brief.json'
$ProdQueuePath = Join-Path $RepoRoot 'data\research-queue.json'
$ProdIndexPath = Join-Path $RepoRoot 'data\knowledge-index.json'
$GlassCardPath = Join-Path $RepoRoot 'research\glass-bridge\card.json'
$HbmCardPath = Join-Path $RepoRoot 'research\hbm\card.json'
$CpoCardPath = Join-Path $RepoRoot 'research\cpo\card.json'
$FauCardPath = Join-Path $RepoRoot 'research\fau\card.json'

if (-not (Test-Path $FixturePath)) { throw "Missing fixture: $FixturePath" }

$Utf8 = New-Object System.Text.UTF8Encoding $false
$Contract = [System.IO.File]::ReadAllText($FixturePath, $Utf8) | ConvertFrom-Json
$App = [System.IO.File]::ReadAllText($AppPath, $Utf8)
$Index = [System.IO.File]::ReadAllText($IndexPath, $Utf8)
$Knowledge = [System.IO.File]::ReadAllText($KnowledgePath, $Utf8)
$Generator = [System.IO.File]::ReadAllText($GeneratorPath, $Utf8)

$ProdHashBefore = @{
  brief = (Get-FileHash -Path $ProdBriefPath -Algorithm SHA256).Hash
  queue = (Get-FileHash -Path $ProdQueuePath -Algorithm SHA256).Hash
  index = (Get-FileHash -Path $ProdIndexPath -Algorithm SHA256).Hash
  engine = (Get-FileHash -Path $EnginePath -Algorithm SHA256).Hash
  workflow = (Get-FileHash -Path $WorkflowPath -Algorithm SHA256).Hash
  knowledge = (Get-FileHash -Path $KnowledgePath -Algorithm SHA256).Hash
  collect = (Get-FileHash -Path $CollectPath -Algorithm SHA256).Hash
  generate = (Get-FileHash -Path $GeneratePath -Algorithm SHA256).Hash
  glass = (Get-FileHash -Path $GlassCardPath -Algorithm SHA256).Hash
  hbm = (Get-FileHash -Path $HbmCardPath -Algorithm SHA256).Hash
  cpo = (Get-FileHash -Path $CpoCardPath -Algorithm SHA256).Hash
  fau = (Get-FileHash -Path $FauCardPath -Algorithm SHA256).Hash
}

$script:Results = New-Object System.Collections.Generic.List[object]
$script:TempRoot = Join-Path $env:TEMP ('InvestorTwin-0062-' + [guid]::NewGuid().ToString('N'))

function Add-TestResult($id, $passed, $details) {
  $status = if ($passed) { 'PASS' } else { 'FAIL' }
  $script:Results.Add([PSCustomObject]@{ Id = $id; Status = $status; Details = $details })
  Write-Output ("{0}: {1}" -f $id, $status)
  if ($details) { Write-Output $details }
}

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

function Write-JsonFile($path, $obj) {
  $dir = Split-Path -Parent $path
  if (-not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
  }
  [System.IO.File]::WriteAllText($path, ($obj | ConvertTo-Json -Depth 20), $Utf8)
}

$RenderFn = Get-FunctionText $App 'render'
$LoadFn = Get-FunctionText $App 'loadExplorerCardIds'
$ExistsFn = Get-FunctionText $App 'researchCardFileExists'
$OpenFn = Get-FunctionText $App $Contract.openFunction
$RadarFn = Get-FunctionText $App $Contract.radarFunction
$TodayFn = Get-FunctionText $App $Contract.todayFunction
$BackFn = Get-FunctionText $App 'navigationBack'
$ForwardFn = Get-FunctionText $App 'navigationForward'
$HashFn = Get-FunctionText $App 'setViewHash'
$PushFn = Get-FunctionText $App 'pushViewHash'
$RestoreFn = Get-FunctionText $App 'restoreViewFromHash'
$TodayStart = $Index.IndexOf('id="today"')
$QueueStart = $Index.IndexOf('id="queue"')
$CardsStart = $Index.IndexOf('id="cards"')
if ($TodayStart -lt 0 -or $QueueStart -lt 0 -or $CardsStart -lt 0) { throw 'today/queue/cards markup missing' }
$TodayBlock = $Index.Substring($TodayStart, $QueueStart - $TodayStart)
$QueueBlock = $Index.Substring($QueueStart, $CardsStart - $QueueStart)

$fail1 = New-Object System.Collections.Generic.List[string]
if ($RenderFn -notlike '*explorerCardIds*') { $fail1.Add('cardList no longer reads explorerCardIds') }
if ($RenderFn -notlike '*for (const id of explorerCardIds)*') { $fail1.Add('cardList is not iterated from cardIds') }
$queueForEach = [regex]::Match($RenderFn, 'getQueueIds\(\)\.forEach\(q => \{[\s\S]*?\}\);')
if ($queueForEach.Success -and $queueForEach.Value -like '*cardList.appendChild*') {
  $fail1.Add('cardList still uses getQueueIds as inventory')
}
if ($LoadFn -notlike '*cardIds*') { $fail1.Add('loadExplorerCardIds does not read cardIds') }
if ($LoadFn -notlike '*knowledge-index.json*') { $fail1.Add('explorer inventory is not knowledge-index cardIds') }
Add-TestResult 'TEST 1' ($fail1.Count -eq 0) ($fail1 -join "`n")

New-Item -ItemType Directory -Path (Join-Path $script:TempRoot 'data') | Out-Null
New-Item -ItemType Directory -Path (Join-Path $script:TempRoot 'research') | Out-Null
foreach ($id in @($Contract.expectedCardIds)) {
  $dir = Join-Path $script:TempRoot ("research\" + $id)
  New-Item -ItemType Directory -Path $dir | Out-Null
  $srcCard = Join-Path $RepoRoot ("research\" + $id + "\card.json")
  Copy-Item $srcCard (Join-Path $dir 'card.json')
}
Write-JsonFile (Join-Path $script:TempRoot 'data\research-queue.json') @{
  items = @($Contract.queueOnlyIds | ForEach-Object { @{ id = $_; addedFrom = 'Morning Brief' } })
}
. $GeneratorPath
$built = Update-KnowledgeIndex -RootPath $script:TempRoot
$builtIds = @($built.cardIds)
$queueObj = Get-Content (Join-Path $script:TempRoot 'data\research-queue.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$queueIds = @($queueObj.items | ForEach-Object { [string]$_.id })

$fail2 = New-Object System.Collections.Generic.List[string]
foreach ($id in @($Contract.expectedCardIds)) {
  if ($builtIds -notcontains $id) { $fail2.Add("cardIds missing $id") }
}
Add-TestResult 'TEST 2' ($fail2.Count -eq 0) ($fail2 -join "`n")

$fail3 = New-Object System.Collections.Generic.List[string]
if ($queueIds -contains 'cpo') { $fail3.Add('temp queue unexpectedly contains cpo') }
if ($queueIds -contains 'hbm') { $fail3.Add('temp queue unexpectedly contains hbm') }
if ($builtIds -notcontains 'cpo') { $fail3.Add('cpo missing from explorer cardIds while absent from queue') }
if ($builtIds -notcontains 'hbm') { $fail3.Add('hbm missing from explorer cardIds while absent from queue') }
Add-TestResult 'TEST 3' ($fail3.Count -eq 0) ($fail3 -join "`n")

$fail4 = New-Object System.Collections.Generic.List[string]
if ($RenderFn -notlike '*openResearchCard(id, undefined, { resetPath: true, fromPage: ''cards'' })*' -and $RenderFn -notlike '*fromPage: ''cards''*') {
  $fail4.Add('explorer click no longer opens existing Research Card with fromPage cards')
}
if (-not $OpenFn) { $fail4.Add('openResearchCard missing') }
if ($OpenFn -notlike '*pushViewHash(''cards'', researchId)*' -and $OpenFn -notlike '*setViewHash(''cards'', researchId)*') {
  $fail4.Add('card open no longer sets #cards/{id}')
}
Add-TestResult 'TEST 4' ($fail4.Count -eq 0) ($fail4 -join "`n")

$fail5 = New-Object System.Collections.Generic.List[string]
if ($RenderFn -notlike '*queueList.appendChild*') { $fail5.Add('queueList render missing') }
if ($RenderFn -notlike '*getQueueIds()*') { $fail5.Add('queue page no longer uses getQueueIds') }
if ($QueueBlock -notlike '*id="queueList"*') { $fail5.Add('queueList markup missing') }
if ($QueueBlock -like '*id="cardList"*') { $fail5.Add('cardList moved onto Queue page') }
Add-TestResult 'TEST 5' ($fail5.Count -eq 0) ($fail5 -join "`n")

$fail6 = New-Object System.Collections.Generic.List[string]
if ($RenderFn -notlike '*renderOpportunityRadar(radarEl, openFromOpportunityRadar)*') {
  $fail6.Add('Queue Radar render path changed')
}
if (-not $RadarFn) { $fail6.Add('openFromOpportunityRadar missing') }
if ($RadarFn -notlike "*ensureInQueue(researchId, 'Opportunity Radar')*") {
  $fail6.Add('Radar no longer queues with Opportunity Radar')
}
Add-TestResult 'TEST 6' ($fail6.Count -eq 0) ($fail6 -join "`n")

$fail7 = New-Object System.Collections.Generic.List[string]
if (-not $TodayFn) { $fail7.Add('openMorningBriefResearch missing') }
if ($TodayFn -notlike '*openResearchCard(*') { $fail7.Add('Today click no longer opens Research Card') }
if ($TodayFn -notlike "*fromPage: 'today'*") { $fail7.Add('Today click lost fromPage today') }
if ($TodayBlock -notlike '*today-workspace*') { $fail7.Add('Today Workspace markup missing') }
Add-TestResult 'TEST 7' ($fail7.Count -eq 0) ($fail7 -join "`n")

$fail8 = New-Object System.Collections.Generic.List[string]
if ($ExistsFn -notlike '*research/*' -or $ExistsFn -notlike '*card.json*') {
  $fail8.Add('missing existence check for research/{id}/card.json')
}
if ($RenderFn -notlike '*researchCardFileExists(id)*') { $fail8.Add('missing cardIds are not skipped') }
if ($RenderFn -like '*/api/research/*') { $fail8.Add('explorer creates cards via API') }
Add-TestResult 'TEST 8' ($fail8.Count -eq 0) ($fail8 -join "`n")

$fail9 = New-Object System.Collections.Generic.List[string]
if ($Generator -notlike '*if (-not $card.tags*' ) { $fail9.Add('untagged cards no longer skip tag index') }
$tempIndexPath = Join-Path $script:TempRoot 'data\knowledge-index.json'
$tempIndex = Get-Content -LiteralPath $tempIndexPath -Raw -Encoding UTF8 | ConvertFrom-Json
$tagNames = @($tempIndex.tags.PSObject.Properties.Name)
if ($tagNames -notcontains $Contract.taggedCardTag) { $fail9.Add('existing tags were dropped') }
$tagIds = @($tempIndex.tags.($Contract.taggedCardTag))
if ($tagIds -notcontains $Contract.taggedCardId) { $fail9.Add('tagged card missing from tags map') }
if ($Knowledge -notlike '*searchByTag(tag)*') { $fail9.Add('Knowledge Explorer searchByTag missing') }
if ($Knowledge -like '*cardIds*') { $fail9.Add('Knowledge Engine started consuming cardIds') }
Add-TestResult 'TEST 9' ($fail9.Count -eq 0) ($fail9 -join "`n")

$fail11 = New-Object System.Collections.Generic.List[string]
if ($RenderFn -notlike "*fromPage: 'cards'*") { $fail11.Add('explorer click does not set fromPage cards') }
if ($BackFn -notlike '*showPage(top.pageId)*') { $fail11.Add('Back does not return to fromPage') }
if ($App -notlike "*type: 'page'*") { $fail11.Add('page sentinel is not pushed onto backStack') }
Add-TestResult 'TEST 11' ($fail11.Count -eq 0) ($fail11 -join "`n")

$fail12 = New-Object System.Collections.Generic.List[string]
if ($RenderFn -notlike "*fromPage: 'queue'*") { $fail12.Add('queue click does not set fromPage queue') }
if ($RadarFn -notlike "*fromPage: fromPage || 'queue'*") { $fail12.Add('Radar lost queue fromPage contract') }
Add-TestResult 'TEST 12' ($fail12.Count -eq 0) ($fail12 -join "`n")

$fail13 = New-Object System.Collections.Generic.List[string]
$ShowFn = Get-FunctionText $App 'showPage'
if ($ShowFn -notlike '*setViewHash(id)*') { $fail13.Add('showPage does not sync URL to the page') }
if ($ShowFn -notlike '*pushViewHash(id)*') { $fail13.Add('real page navigation does not pushViewHash') }
if ($HashFn -like '*history.pushState*') { $fail13.Add('setViewHash creates extra history entries') }
if ($OpenFn -notlike '*setViewHash(''cards'', researchId)*') { $fail13.Add('replay no longer replaceStates #cards/{id}') }
if ($OpenFn -notlike '*pushViewHash(''cards'', researchId)*') { $fail13.Add('real card navigation does not push #cards/{id}') }
Add-TestResult 'TEST 13' ($fail13.Count -eq 0) ($fail13 -join "`n")

$fail14 = New-Object System.Collections.Generic.List[string]
if ($App -notlike '*function navigationForward*') { $fail14.Add('navigationForward missing') }
if ($BackFn -notlike '*type === ''page''*') { $fail14.Add('Back does not handle page sentinel') }
if ($BackFn -like '*forwardStack.push*' -and ($BackFn.IndexOf('type === ''page''') -gt $BackFn.IndexOf('forwardStack.push'))) {
  $fail14.Add('page Back pushes onto forwardStack')
}
Add-TestResult 'TEST 14' ($fail14.Count -eq 0) ($fail14 -join "`n")

$fail15 = New-Object System.Collections.Generic.List[string]
if ($HashFn -notlike '*history.replaceState*') { $fail15.Add('setViewHash does not use replaceState') }
if ($HashFn -like '*history.pushState*') { $fail15.Add('hash updates use pushState') }
Add-TestResult 'TEST 15' ($fail15.Count -eq 0) ($fail15 -join "`n")

# A. #cards → HBM → FAU → Back HBM → Back #cards → Forward HBM → Forward FAU
$fail16 = New-Object System.Collections.Generic.List[string]
if (-not $PushFn) { $fail16.Add('pushViewHash missing') }
if ($PushFn -notlike '*history.pushState*') { $fail16.Add('real navigation does not pushState') }
if ($OpenFn -match 'if \(options\?\.fromPage\)') {
  $fail16.Add('fromPage still resets backStack on every card open')
}
if ($OpenFn -notlike '*currentId == null && options?.fromPage*') {
  $fail16.Add('page sentinel is not limited to the first card from an entry')
}
if ($OpenFn -notlike '*currentId != null && navigationState.currentId !== researchId*') {
  $fail16.Add('sequential card open does not push the current card onto backStack')
}
if ($BackFn -notlike '*history.back()*') { $fail16.Add('Back does not replay existing history') }
if (-not $ForwardFn -or $ForwardFn -notlike '*history.forward()*') { $fail16.Add('Forward does not replay existing history') }
if ($RestoreFn -notlike '*fromNavigation: true*') { $fail16.Add('hash restore is treated as a new navigation') }
Add-TestResult 'TEST 16' ($fail16.Count -eq 0) ($fail16 -join "`n")

# B. #queue → HBM → FAU → Back HBM → Back #queue → Forward HBM → Forward FAU
$fail17 = New-Object System.Collections.Generic.List[string]
if ($RenderFn -notlike "*showPage('cards', { skipHash: true })*") {
  $fail17.Add('Queue → card inserts an intermediate #cards history entry')
}
if ($RenderFn -notlike "*fromPage: 'queue'*") { $fail17.Add('Queue lost fromPage queue') }
if ($OpenFn -notlike '*pushViewHash(''cards'', researchId)*') {
  $fail17.Add('Queue sequential cards do not push #cards/{id}')
}
Add-TestResult 'TEST 17' ($fail17.Count -eq 0) ($fail17 -join "`n")

# C. Radar → HBM → FAU → Back HBM → Back Radar/queue entry → Forward
$fail18 = New-Object System.Collections.Generic.List[string]
if ($RadarFn -notlike '*skipHash: true*') {
  $fail18.Add('Radar → card inserts an intermediate #cards history entry')
}
if ($RadarFn -notlike "*fromPage: fromPage || 'queue'*") {
  $fail18.Add('Radar lost fromPage contract')
}
if ($TodayFn -notlike '*skipHash: true*' -and $TodayFn -notlike '*skipNextViewHash*') {
  $fail18.Add('Today → card inserts an intermediate #cards history entry')
}
Add-TestResult 'TEST 18' ($fail18.Count -eq 0) ($fail18 -join "`n")

# D. Back / Forward replay must not pushState
$fail19 = New-Object System.Collections.Generic.List[string]
if ($PushFn -notlike '*applyingHistory*') { $fail19.Add('pushViewHash does not refuse replay') }
if ($OpenFn -notlike '*fromNavigation || applyingHistory*') {
  $fail19.Add('card replay is not distinguished from real navigation')
}
if ($App -notlike "*addEventListener('popstate'*") { $fail19.Add('popstate replay listener missing') }
if ($RestoreFn -notlike '*fromNavigation: true*') { $fail19.Add('restoreViewFromHash still pushStates card URLs') }
if ($HashFn -like '*history.pushState*') { $fail19.Add('setViewHash pushStates during replay') }
if ($BackFn -like '*pushViewHash*' ) { $fail19.Add('navigationBack pushStates') }
if ($ForwardFn -like '*pushViewHash*') { $fail19.Add('navigationForward pushStates') }
Add-TestResult 'TEST 19' ($fail19.Count -eq 0) ($fail19 -join "`n")

$guardOk = (
  (Get-FileHash -Path $ProdBriefPath -Algorithm SHA256).Hash -eq $ProdHashBefore.brief -and
  (Get-FileHash -Path $ProdQueuePath -Algorithm SHA256).Hash -eq $ProdHashBefore.queue -and
  (Get-FileHash -Path $ProdIndexPath -Algorithm SHA256).Hash -eq $ProdHashBefore.index -and
  (Get-FileHash -Path $EnginePath -Algorithm SHA256).Hash -eq $ProdHashBefore.engine -and
  (Get-FileHash -Path $WorkflowPath -Algorithm SHA256).Hash -eq $ProdHashBefore.workflow -and
  (Get-FileHash -Path $KnowledgePath -Algorithm SHA256).Hash -eq $ProdHashBefore.knowledge -and
  (Get-FileHash -Path $CollectPath -Algorithm SHA256).Hash -eq $ProdHashBefore.collect -and
  (Get-FileHash -Path $GeneratePath -Algorithm SHA256).Hash -eq $ProdHashBefore.generate -and
  (Get-FileHash -Path $GlassCardPath -Algorithm SHA256).Hash -eq $ProdHashBefore.glass -and
  (Get-FileHash -Path $HbmCardPath -Algorithm SHA256).Hash -eq $ProdHashBefore.hbm -and
  (Get-FileHash -Path $CpoCardPath -Algorithm SHA256).Hash -eq $ProdHashBefore.cpo -and
  (Get-FileHash -Path $FauCardPath -Algorithm SHA256).Hash -eq $ProdHashBefore.fau
)
Add-TestResult 'TEST 10' $guardOk $(if ($guardOk) { '' } else { 'production files were modified' })
Add-TestResult 'PRODUCTION_FILE_GUARD' $guardOk $(if ($guardOk) { '' } else { 'production files were modified' })

if (Test-Path $script:TempRoot) {
  Remove-Item -Recurse -Force $script:TempRoot -ErrorAction SilentlyContinue
}

$failed = @($script:Results | Where-Object { $_.Status -ne 'PASS' })
Write-Output ''
Write-Output '=== 006-2 SUMMARY ==='
foreach ($row in $script:Results) {
  Write-Output ("{0}: {1}" -f $row.Id, $row.Status)
  if ($row.Status -ne 'PASS' -and $row.Details) { Write-Output $row.Details }
}
if ($failed.Count -gt 0) { exit 1 }
exit 0
