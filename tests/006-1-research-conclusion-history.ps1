$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$env:PYTHONIOENCODING = 'utf-8'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$FixturePath = Join-Path $PSScriptRoot 'fixtures\006-1-research-conclusion-history.json'
$ProdCasesPath = Join-Path $RepoRoot 'data\investment-cases.json'
$ProdQueuePath = Join-Path $RepoRoot 'data\research-queue.json'
$ProdBriefPath = Join-Path $RepoRoot 'data\morning-brief.json'
$ProdIndexPath = Join-Path $RepoRoot 'data\knowledge-index.json'
$ServePath = Join-Path $RepoRoot 'serve.ps1'
$WorkflowPath = Join-Path $RepoRoot 'js\workflow-engine.js'
$AppPath = Join-Path $RepoRoot 'app.js'
$IndexPath = Join-Path $RepoRoot 'index.html'
$EnginePath = Join-Path $RepoRoot 'js\data-engine.js'
$KnowledgePath = Join-Path $RepoRoot 'js\knowledge-engine.js'
$CollectPath = Join-Path $RepoRoot 'scripts\collect-evidence.py'
$GeneratePath = Join-Path $RepoRoot 'scripts\generate-morning-brief.py'
$GlassCardPath = Join-Path $RepoRoot 'research\glass-bridge\card.json'
$HbmCardPath = Join-Path $RepoRoot 'research\hbm\card.json'
$CpoCardPath = Join-Path $RepoRoot 'research\cpo\card.json'
$FauCardPath = Join-Path $RepoRoot 'research\fau\card.json'

if (-not (Test-Path $FixturePath)) { throw "Missing fixture: $FixturePath" }

$Utf8 = New-Object System.Text.UTF8Encoding $false
$Contract = [System.IO.File]::ReadAllText($FixturePath, $Utf8) | ConvertFrom-Json
$Workflow = [System.IO.File]::ReadAllText($WorkflowPath, $Utf8)
$App = [System.IO.File]::ReadAllText($AppPath, $Utf8)
$Index = [System.IO.File]::ReadAllText($IndexPath, $Utf8)

$ProdHashBefore = @{
  cases = (Get-FileHash -Path $ProdCasesPath -Algorithm SHA256).Hash
  queue = (Get-FileHash -Path $ProdQueuePath -Algorithm SHA256).Hash
  brief = (Get-FileHash -Path $ProdBriefPath -Algorithm SHA256).Hash
  index = (Get-FileHash -Path $ProdIndexPath -Algorithm SHA256).Hash
  engine = (Get-FileHash -Path $EnginePath -Algorithm SHA256).Hash
  knowledge = (Get-FileHash -Path $KnowledgePath -Algorithm SHA256).Hash
  collect = (Get-FileHash -Path $CollectPath -Algorithm SHA256).Hash
  generate = (Get-FileHash -Path $GeneratePath -Algorithm SHA256).Hash
  app = (Get-FileHash -Path $AppPath -Algorithm SHA256).Hash
  serve = (Get-FileHash -Path $ServePath -Algorithm SHA256).Hash
  glass = (Get-FileHash -Path $GlassCardPath -Algorithm SHA256).Hash
  hbm = (Get-FileHash -Path $HbmCardPath -Algorithm SHA256).Hash
  cpo = (Get-FileHash -Path $CpoCardPath -Algorithm SHA256).Hash
  fau = (Get-FileHash -Path $FauCardPath -Algorithm SHA256).Hash
}

$script:Results = New-Object System.Collections.Generic.List[object]
$script:TempRoot = Join-Path $env:TEMP ('InvestorTwin-0061-' + [guid]::NewGuid().ToString('N'))
$script:TempCardPath = $null
$script:TempQueuePath = $null
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

function Get-History($card) {
  $list = New-Object System.Collections.Generic.List[object]
  if (-not $card) { return ,$list }
  $names = @($card.PSObject.Properties.Name)
  if ($names -notcontains 'researchConclusionHistory') { return ,$list }
  if ($null -eq $card.researchConclusionHistory) { return ,$list }
  foreach ($item in @($card.researchConclusionHistory)) {
    if ($null -ne $item) { [void]$list.Add($item) }
  }
  return ,$list
}

function Get-MethodText($src, $name) {
  $needles = @("  async $name(", "  $name(", "`n  async $name(", "`n  $name(")
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

function Start-TempServer {
  New-Item -ItemType Directory -Path $script:TempRoot | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $script:TempRoot 'data\theses') | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $script:TempRoot 'scripts') | Out-Null
  $researchDir = Join-Path $script:TempRoot ("research\" + $Contract.researchId)
  New-Item -ItemType Directory -Path $researchDir -Force | Out-Null
  $script:TempCardPath = Join-Path $researchDir 'card.json'
  $script:TempQueuePath = Join-Path $script:TempRoot 'data\research-queue.json'

  Copy-Item (Join-Path $RepoRoot 'data\version.json') (Join-Path $script:TempRoot 'data\version.json') -ErrorAction SilentlyContinue
  Copy-Item (Join-Path $RepoRoot 'scripts\generate-knowledge-index.ps1') (Join-Path $script:TempRoot 'scripts\generate-knowledge-index.ps1') -ErrorAction SilentlyContinue

  Write-JsonFile $script:TempCardPath ([ordered]@{
    id = $Contract.researchId
    thesisId = $Contract.thesisId
    title = 'Sprint 006-1 History'
    summary = '006-1 temp card'
    investmentThesis = '006-1 working thesis'
    questions = @()
    reason = 'Manual'
    tags = @()
    related = @()
    status = 'researching'
    updated = '2026-08-23'
  })
  Write-JsonFile (Join-Path $researchDir 'sources.json') @(@{
    title = '006-1 official source'
    url = 'https://example.test/006-1'
  })
  [System.IO.File]::WriteAllText((Join-Path $researchDir 'timeline.json'), '[]', $Utf8)
  [System.IO.File]::WriteAllText((Join-Path $researchDir 'notes.json'), '[]', $Utf8)
  Write-JsonFile (Join-Path $script:TempRoot ("data\theses\" + $Contract.thesisId + ".json")) ([ordered]@{
    thesisId = $Contract.thesisId
    type = 'industry'
    title = 'Sprint 006-1 Thesis'
    thesis = '006-1 placeholder thesis'
    status = 'under_review'
    linkedResearch = @(@{ researchId = $Contract.researchId })
    updatedAt = '2026-08-23'
  })
  Write-JsonFile $script:TempQueuePath @{ items = @() }
  Write-JsonFile (Join-Path $script:TempRoot 'data\investment-cases.json') @{
    schemaVersion = '1.0'
    updated = '2026-08-23'
    cases = @()
  }
  New-PatchedServeScript $ServePath (Join-Path $script:TempRoot 'serve.ps1')
  foreach ($port in 18861, 18862, 18863) {
    $script:TestPort = $port
    $env:INVESTORTWIN_TEST_PORT = [string]$port
    $outLog = Join-Path $script:TempRoot 'serve.out.log'
    $errLog = Join-Path $script:TempRoot 'serve.err.log'
    $script:ServerProc = Start-Process -FilePath 'powershell.exe' -WorkingDirectory $script:TempRoot -PassThru -WindowStyle Hidden `
      -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', '.\serve.ps1') `
      -RedirectStandardOutput $outLog -RedirectStandardError $errLog
    for ($i = 0; $i -lt 25; $i++) {
      Start-Sleep -Milliseconds 200
      if ($script:ServerProc.HasExited) { break }
      try {
        $probe = Invoke-WebRequest -Uri ("http://localhost:{0}/research/{1}/card.json" -f $port, $Contract.researchId) -UseBasicParsing
        if ($probe.StatusCode -eq 200) { return }
      } catch { }
    }
    if ($script:ServerProc -and -not $script:ServerProc.HasExited) {
      Stop-Process -Id $script:ServerProc.Id -Force -ErrorAction SilentlyContinue
    }
  }
  $errText = ''
  $errLog = Join-Path $script:TempRoot 'serve.err.log'
  if (Test-Path $errLog) { $errText = [System.IO.File]::ReadAllText($errLog) }
  throw ("Temp serve.ps1 failed to start. $errText")
}

function Stop-TempServer {
  if ($script:ServerProc -and -not $script:ServerProc.HasExited) {
    Stop-Process -Id $script:ServerProc.Id -Force -ErrorAction SilentlyContinue
  }
}

function Invoke-Post($path, $body) {
  $uri = "http://localhost:$($script:TestPort)$path"
  $json = $body | ConvertTo-Json -Depth 20 -Compress
  try {
    $res = Invoke-WebRequest -Uri $uri -Method POST -Body $json -ContentType 'application/json; charset=utf-8' -UseBasicParsing
    return @{ StatusCode = [int]$res.StatusCode; Body = $res.Content }
  } catch {
    $resp = $_.Exception.Response
    $code = 0
    $text = $_.Exception.Message
    if ($resp) {
      $code = [int]$resp.StatusCode
      $stream = $resp.GetResponseStream()
      if ($stream) {
        $reader = New-Object System.IO.StreamReader($stream)
        $text = $reader.ReadToEnd()
      }
    }
    return @{ StatusCode = $code; Body = $text }
  }
}

$TodayStart = $Index.IndexOf('id="today"')
$QueueStart = $Index.IndexOf('id="queue"')
$CardsStart = $Index.IndexOf('id="cards"')
if ($TodayStart -lt 0 -or $QueueStart -lt 0 -or $CardsStart -lt 0) { throw 'today/queue/cards markup missing' }
$TodayBlock = $Index.Substring($TodayStart, $QueueStart - $TodayStart)
$QueueBlock = $Index.Substring($QueueStart, $CardsStart - $QueueStart)
$RenderFn = Get-MethodText $Workflow 'renderResearch'
$HistoryFn = Get-MethodText $Workflow 'renderResearchConclusionHistory'

try {
  Start-TempServer

  $save1 = Invoke-Post ("/api/research/" + $Contract.researchId) @{
    researchConclusion = @{
      conclusion = $Contract.conclusion1
      status = $Contract.status
      asOf = $Contract.asOf1
    }
  }
  $card1 = Read-JsonFile $script:TempCardPath
  $hist1 = Get-History $card1
  $fail1 = New-Object System.Collections.Generic.List[string]
  if ([int]$save1.StatusCode -ne 200) { $fail1.Add("first save HTTP $($save1.StatusCode): $($save1.Body)") }
  if (-not $card1.researchConclusion) {
    $fail1.Add('current researchConclusion missing after first save')
  } elseif ([string]$card1.researchConclusion.conclusion -ne $Contract.conclusion1) {
    $fail1.Add("current conclusion=$($card1.researchConclusion.conclusion)")
  }
  if ($hist1.Count -lt 1) {
    $fail1.Add('first official save did not create initial history')
  } else {
    if ([string]$hist1[0].type -ne 'initial') { $fail1.Add("history[0].type=$($hist1[0].type)") }
    if ([string]$hist1[0].conclusion -ne $Contract.conclusion1) { $fail1.Add('history[0] conclusion mismatch') }
    if ([string]$hist1[0].asOf -ne $Contract.asOf1) { $fail1.Add("history[0].asOf=$($hist1[0].asOf)") }
  }
  Add-TestResult 'TEST 1' ($fail1.Count -eq 0) ($fail1 -join "`n")

  $save2 = Invoke-Post ("/api/research/" + $Contract.researchId) @{
    researchConclusion = @{
      conclusion = $Contract.conclusion2
      status = $Contract.status
      asOf = $Contract.asOf2
    }
  }
  $card2 = Read-JsonFile $script:TempCardPath
  $hist2 = Get-History $card2
  $fail2 = New-Object System.Collections.Generic.List[string]
  if ([int]$save2.StatusCode -ne 200) { $fail2.Add("second save HTTP $($save2.StatusCode): $($save2.Body)") }
  if ($hist2.Count -lt 2) {
    $fail2.Add("history count=$($hist2.Count) after different conclusion")
  } elseif ([string]$hist2[1].conclusion -ne $Contract.conclusion2) {
    $fail2.Add('second history entry is not the new conclusion')
  } elseif ([string]$hist2[1].type -ne 're-research') {
    $fail2.Add("history[1].type=$($hist2[1].type)")
  }
  Add-TestResult 'TEST 2' ($fail2.Count -eq 0) ($fail2 -join "`n")

  $saveDup = Invoke-Post ("/api/research/" + $Contract.researchId) @{
    researchConclusion = @{
      conclusion = $Contract.conclusion2
      status = $Contract.status
      asOf = $Contract.asOf2
    }
  }
  $cardDup = Read-JsonFile $script:TempCardPath
  $histDup = Get-History $cardDup
  $fail3 = New-Object System.Collections.Generic.List[string]
  if ([int]$saveDup.StatusCode -ne 200) { $fail3.Add("dup save HTTP $($saveDup.StatusCode): $($saveDup.Body)") }
  if ($histDup.Count -ne $hist2.Count) {
    $fail3.Add("same conclusion+asOf changed history count from $($hist2.Count) to $($histDup.Count)")
  }
  Add-TestResult 'TEST 3' ($fail3.Count -eq 0) ($fail3 -join "`n")

  $fail4 = New-Object System.Collections.Generic.List[string]
  if (-not $cardDup.researchConclusion) {
    $fail4.Add('current researchConclusion missing')
  } elseif ([string]$cardDup.researchConclusion.conclusion -ne $Contract.conclusion2) {
    $fail4.Add("current is not latest: $($cardDup.researchConclusion.conclusion)")
  } elseif ([string]$cardDup.researchConclusion.asOf -ne $Contract.asOf2) {
    $fail4.Add("current asOf=$($cardDup.researchConclusion.asOf)")
  }
  Add-TestResult 'TEST 4' ($fail4.Count -eq 0) ($fail4 -join "`n")

  $fail5 = New-Object System.Collections.Generic.List[string]
  if ($histDup.Count -lt 2) {
    $fail5.Add('history too short to prove append-only')
  } else {
    if ([string]$histDup[0].conclusion -ne $Contract.conclusion1) { $fail5.Add('history[0] was overwritten') }
    if ([string]$histDup[0].type -ne 'initial') { $fail5.Add('history[0].type was changed') }
    if ([string]$histDup[0].asOf -ne $Contract.asOf1) { $fail5.Add('history[0].asOf was overwritten') }
  }
  Add-TestResult 'TEST 5' ($fail5.Count -eq 0) ($fail5 -join "`n")
}
catch {
  Add-TestResult 'SETUP' $false $_.Exception.Message
}
finally {
  Stop-TempServer
}

$fail6 = New-Object System.Collections.Generic.List[string]
if ($Workflow -notlike '*Research History*') { $fail6.Add('029 Research History heading missing') }
if ($Workflow -notlike '*data-research-history*') { $fail6.Add('data-research-history contract missing') }
if ($HistoryFn -notlike '*<ul data-research-history>*') { $fail6.Add('history list selector missing') }
if ($RenderFn -notlike '*historyList.length*') { $fail6.Add('Research Card no longer gates history on length') }
if ($RenderFn -notlike '*<p><b>Research History</b></p>*') { $fail6.Add('Research History heading not rendered when history exists') }
if ($RenderFn -notlike '*renderResearchConclusionHistory(historyList)*') { $fail6.Add('history renderer not called with existing history') }
if ($RenderFn -notlike '*Current Research Conclusion*') { $fail6.Add('Current Research Conclusion missing') }
Add-TestResult 'TEST 6' ($fail6.Count -eq 0) ($fail6 -join "`n")

$fail7 = New-Object System.Collections.Generic.List[string]
if ($HistoryFn -like '*data-research-history>--</p>*') { $fail7.Add('empty history still renders a placeholder block') }
if ($RenderFn -notlike '*if (historyList.length)*') { $fail7.Add('empty history is not skipped in renderResearch') }
$unconditional = [regex]::Match($RenderFn, 'html \+= ''<p><b>Research History</b></p>'';\s*html \+= this\.renderResearchConclusionHistory\(card\.researchConclusionHistory\)')
if ($unconditional.Success) { $fail7.Add('Research History heading is still unconditional') }
Add-TestResult 'TEST 7' ($fail7.Count -eq 0) ($fail7 -join "`n")

$fail8 = New-Object System.Collections.Generic.List[string]
foreach ($cardPath in @($GlassCardPath, $CpoCardPath, $FauCardPath, $HbmCardPath)) {
  $card = Read-JsonFile $cardPath
  $names = @($card.PSObject.Properties.Name)
  if ($names -contains 'researchConclusionHistory') {
    $fail8.Add((Split-Path -Leaf (Split-Path -Parent $cardPath)) + ' was backfilled with researchConclusionHistory')
  }
}
Add-TestResult 'TEST 8' ($fail8.Count -eq 0) ($fail8 -join "`n")

$fail9 = New-Object System.Collections.Generic.List[string]
if ($QueueBlock -notlike '*id="queueList"*') { $fail9.Add('Research Queue page list missing') }
if ($TodayBlock -like '*id="todayQueue"*') { $fail9.Add('Today Workspace gained a queue preview') }
if ($App -like '*function renderTodayQueue*') { $fail9.Add('Today Workspace still renders queue preview') }
Add-TestResult 'TEST 9' ($fail9.Count -eq 0) ($fail9 -join "`n")

$fail10 = New-Object System.Collections.Generic.List[string]
if ($TodayBlock -notlike '*today-workspace*') { $fail10.Add('Today Workspace class missing') }
if ($App -notlike '*bindTodayWorkspaceFromMorningBrief()*') { $fail10.Add('Today Workspace bind path missing') }
foreach ($sectionId in @('todayExecutiveSummary', 'todayMarketTemperature', 'todayGlobalMarket', 'todayTaiwanMarket', 'todayUpcomingEvents', 'todayThreeThings')) {
  if ($TodayBlock -notlike ('*id="' + $sectionId + '"*')) { $fail10.Add("Today section missing: $sectionId") }
}
if ($TodayBlock -like '*id="todayQueue"*') { $fail10.Add('Today Workspace regained todayQueue') }
Add-TestResult 'TEST 10' ($fail10.Count -eq 0) ($fail10 -join "`n")

$guardOk = (
  (Get-FileHash -Path $ProdCasesPath -Algorithm SHA256).Hash -eq $ProdHashBefore.cases -and
  (Get-FileHash -Path $ProdQueuePath -Algorithm SHA256).Hash -eq $ProdHashBefore.queue -and
  (Get-FileHash -Path $ProdBriefPath -Algorithm SHA256).Hash -eq $ProdHashBefore.brief -and
  (Get-FileHash -Path $ProdIndexPath -Algorithm SHA256).Hash -eq $ProdHashBefore.index -and
  (Get-FileHash -Path $EnginePath -Algorithm SHA256).Hash -eq $ProdHashBefore.engine -and
  (Get-FileHash -Path $KnowledgePath -Algorithm SHA256).Hash -eq $ProdHashBefore.knowledge -and
  (Get-FileHash -Path $CollectPath -Algorithm SHA256).Hash -eq $ProdHashBefore.collect -and
  (Get-FileHash -Path $GeneratePath -Algorithm SHA256).Hash -eq $ProdHashBefore.generate -and
  (Get-FileHash -Path $AppPath -Algorithm SHA256).Hash -eq $ProdHashBefore.app -and
  (Get-FileHash -Path $ServePath -Algorithm SHA256).Hash -eq $ProdHashBefore.serve -and
  (Get-FileHash -Path $GlassCardPath -Algorithm SHA256).Hash -eq $ProdHashBefore.glass -and
  (Get-FileHash -Path $HbmCardPath -Algorithm SHA256).Hash -eq $ProdHashBefore.hbm -and
  (Get-FileHash -Path $CpoCardPath -Algorithm SHA256).Hash -eq $ProdHashBefore.cpo -and
  (Get-FileHash -Path $FauCardPath -Algorithm SHA256).Hash -eq $ProdHashBefore.fau
)
Add-TestResult 'PRODUCTION_FILE_GUARD' $guardOk $(if ($guardOk) { '' } else { 'protected production files were modified' })

if (Test-Path $script:TempRoot) {
  Remove-Item -Recurse -Force $script:TempRoot -ErrorAction SilentlyContinue
}

$failed = @($script:Results | Where-Object { $_.Status -ne 'PASS' })
Write-Output ''
Write-Output '=== 006-1 SUMMARY ==='
foreach ($row in $script:Results) {
  Write-Output ("{0}: {1}" -f $row.Id, $row.Status)
  if ($row.Status -ne 'PASS' -and $row.Details) { Write-Output $row.Details }
}
if ($failed.Count -gt 0) { exit 1 }
exit 0
