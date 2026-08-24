$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$env:PYTHONIOENCODING = 'utf-8'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$FixturePath = Join-Path $PSScriptRoot 'fixtures\031-c-morning-brief-workspace.json'
$ProdBriefPath = Join-Path $RepoRoot 'data\morning-brief.json'
$LatestPath = Join-Path $RepoRoot 'data\morning-brief\latest.json'
$ProdCasesPath = Join-Path $RepoRoot 'data\investment-cases.json'
$ProdQueuePath = Join-Path $RepoRoot 'data\research-queue.json'
$ThesesDir = Join-Path $RepoRoot 'data\theses'
$GlassCardPath = Join-Path $RepoRoot 'research\glass-bridge\card.json'
$HbmCardPath = Join-Path $RepoRoot 'research\hbm\card.json'
$CpoCardPath = Join-Path $RepoRoot 'research\cpo\card.json'
$FauCardPath = Join-Path $RepoRoot 'research\fau\card.json'
$AppPath = Join-Path $RepoRoot 'app.js'
$DataEnginePath = Join-Path $RepoRoot 'js\data-engine.js'
$WorkflowPath = Join-Path $RepoRoot 'js\workflow-engine.js'
$IndexPath = Join-Path $RepoRoot 'index.html'
$StylePath = Join-Path $RepoRoot 'style.css'
$ServePath = Join-Path $RepoRoot 'serve.ps1'
$GeneratePy = Join-Path $RepoRoot 'scripts\generate-morning-brief.py'
$CollectPy = Join-Path $RepoRoot 'scripts\collect-evidence.py'

if (-not (Test-Path $FixturePath)) { throw "Missing fixture: $FixturePath" }

$Utf8 = New-Object System.Text.UTF8Encoding $false
$ProdHashBefore = @{
  brief = (Get-FileHash -Path $ProdBriefPath -Algorithm SHA256).Hash
  latest = (Get-FileHash -Path $LatestPath -Algorithm SHA256).Hash
  cases = (Get-FileHash -Path $ProdCasesPath -Algorithm SHA256).Hash
  queue = (Get-FileHash -Path $ProdQueuePath -Algorithm SHA256).Hash
  glass = (Get-FileHash -Path $GlassCardPath -Algorithm SHA256).Hash
  hbm = (Get-FileHash -Path $HbmCardPath -Algorithm SHA256).Hash
  cpo = (Get-FileHash -Path $CpoCardPath -Algorithm SHA256).Hash
  fau = (Get-FileHash -Path $FauCardPath -Algorithm SHA256).Hash
  dram = (Get-FileHash -Path (Join-Path $ThesesDir 'ai-dram.json') -Algorithm SHA256).Hash
  cpoThesis = (Get-FileHash -Path (Join-Path $ThesesDir 'cpo-glass-bridge.json') -Algorithm SHA256).Hash
  generate = (Get-FileHash -Path $GeneratePy -Algorithm SHA256).Hash
  collect = (Get-FileHash -Path $CollectPy -Algorithm SHA256).Hash
}

$Contract = [System.IO.File]::ReadAllText($FixturePath, $Utf8) | ConvertFrom-Json
$script:Results = New-Object System.Collections.Generic.List[object]
$script:TempRoot = Join-Path $env:TEMP ('InvestorTwin-031C-' + [guid]::NewGuid().ToString('N'))
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

function Get-FunctionText($src, $name) {
  $idx = $src.IndexOf($name)
  if ($idx -lt 0) { return '' }
  $end = [Math]::Min($src.Length, $idx + 9000)
  return $src.Substring($idx, $end - $idx)
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
  New-Item -ItemType Directory -Path (Join-Path $script:TempRoot 'data') | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $script:TempRoot 'scripts') | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $script:TempRoot 'js') | Out-Null
  Copy-Item $IndexPath (Join-Path $script:TempRoot 'index.html')
  Copy-Item $DataEnginePath (Join-Path $script:TempRoot 'js\data-engine.js')
  Copy-Item $ProdBriefPath (Join-Path $script:TempRoot 'data\morning-brief.json')
  Copy-Item (Join-Path $RepoRoot 'data\opportunity-radar.json') (Join-Path $script:TempRoot 'data\opportunity-radar.json')
  Copy-Item (Join-Path $RepoRoot 'data\version.json') (Join-Path $script:TempRoot 'data\version.json') -ErrorAction SilentlyContinue
  Copy-Item (Join-Path $RepoRoot 'scripts\generate-knowledge-index.ps1') (Join-Path $script:TempRoot 'scripts\generate-knowledge-index.ps1') -ErrorAction SilentlyContinue
  Write-JsonFile (Join-Path $script:TempRoot 'data\research-queue.json') @{
    items = @(
      @{ id = 'glass-bridge'; addedFrom = 'Morning Brief' }
      @{ id = 'fau'; addedFrom = 'Opportunity Radar' }
    )
  }
  Copy-Item $ProdCasesPath (Join-Path $script:TempRoot 'data\investment-cases.json')
  foreach ($id in @('glass-bridge', 'fau', 'cpo', 'hbm')) {
    $destDir = Join-Path $script:TempRoot ("research\" + $id)
    New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    Copy-Item (Join-Path $RepoRoot ("research\" + $id + "\card.json")) (Join-Path $destDir 'card.json')
  }
  New-PatchedServeScript $ServePath (Join-Path $script:TempRoot 'serve.ps1')
  foreach ($port in 18847, 18848, 18849) {
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
        $probe = Invoke-WebRequest -Uri ("http://localhost:{0}/data/morning-brief.json" -f $port) -UseBasicParsing
        if ($probe.StatusCode -eq 200) { return }
      } catch { }
    }
    if ($script:ServerProc -and -not $script:ServerProc.HasExited) {
      Stop-Process -Id $script:ServerProc.Id -Force -ErrorAction SilentlyContinue
    }
  }
  throw 'Temp serve.ps1 failed to start'
}

function Stop-TempServer {
  if ($script:ServerProc -and -not $script:ServerProc.HasExited) {
    Stop-Process -Id $script:ServerProc.Id -Force -ErrorAction SilentlyContinue
  }
}

function Invoke-Get($path) {
  $uri = "http://localhost:$($script:TestPort)$path"
  try {
    $resp = Invoke-WebRequest -Uri $uri -UseBasicParsing
    return @{ StatusCode = [int]$resp.StatusCode; Body = $resp.Content }
  } catch [System.Net.WebException] {
    $http = $_.Exception.Response
    if (-not $http) { throw }
    $reader = New-Object System.IO.StreamReader($http.GetResponseStream(), $Utf8)
    $content = $reader.ReadToEnd()
    $reader.Close()
    return @{ StatusCode = [int]$http.StatusCode; Body = $content }
  }
}

function Invoke-Post($path, $payload) {
  $json = $payload | ConvertTo-Json -Depth 10 -Compress
  $bytes = $Utf8.GetBytes($json)
  $uri = "http://localhost:$($script:TestPort)$path"
  try {
    $resp = Invoke-WebRequest -Uri $uri -Method POST -Body $bytes -ContentType 'application/json; charset=utf-8' -UseBasicParsing
    return @{ StatusCode = [int]$resp.StatusCode; Body = $resp.Content }
  } catch [System.Net.WebException] {
    $http = $_.Exception.Response
    if (-not $http) { throw }
    $reader = New-Object System.IO.StreamReader($http.GetResponseStream(), $Utf8)
    $content = $reader.ReadToEnd()
    $reader.Close()
    return @{ StatusCode = [int]$http.StatusCode; Body = $content }
  }
}

function Invoke-SiblingTest($relPath) {
  $path = Join-Path $PSScriptRoot $relPath
  $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $path 2>&1 | Out-String
  return @{ ExitCode = $LASTEXITCODE; Text = $out }
}

try {
  $brief = Read-JsonFile $ProdBriefPath
  $indexSrc = [System.IO.File]::ReadAllText($IndexPath, $Utf8)
  $appSrc = [System.IO.File]::ReadAllText($AppPath, $Utf8)
  $engineSrc = [System.IO.File]::ReadAllText($DataEnginePath, $Utf8)
  $workflowSrc = [System.IO.File]::ReadAllText($WorkflowPath, $Utf8)
  $styleSrc = [System.IO.File]::ReadAllText($StylePath, $Utf8)
  $renderFn = Get-FunctionText $engineSrc 'async renderMorningBrief(onItemClick)'
  $clickFn = Get-FunctionText $appSrc 'async function openMorningBriefResearch'
  $bindFn = Get-FunctionText $engineSrc 'const bindResearchClick'
  $threeFn = Get-FunctionText $engineSrc 'const renderThreeThings'

  Start-TempServer

  $fail1 = New-Object System.Collections.Generic.List[string]
  foreach ($hid in @($Contract.homepageIds)) {
    if ($indexSrc -notlike ('*id="' + $hid + '"*')) { $fail1.Add("homepage missing id $hid") }
  }
  if ($appSrc -notlike '*renderMorningBrief(openMorningBriefResearch)*') {
    $fail1.Add('today workbench no longer uses one-arg renderMorningBrief')
  }
  $briefHttp = Invoke-Get '/data/morning-brief.json'
  if ([int]$briefHttp.StatusCode -ne 200) { $fail1.Add('GET morning-brief.json failed') }
  else {
    $parsed = $briefHttp.Body | ConvertFrom-Json
    if (-not $parsed.date) { $fail1.Add('HTTP brief missing date') }
    if (-not $parsed.executiveSummary) { $fail1.Add('HTTP brief missing executiveSummary') }
    if (-not $parsed.today3Things) { $fail1.Add('HTTP brief missing today3Things') }
  }
  $indexHttp = Invoke-Get '/index.html'
  if ([int]$indexHttp.StatusCode -ne 200) { $fail1.Add('GET index.html failed') }
  if ($renderFn -notlike "*setText('morningBriefDate', data.date || '--')*") {
    $fail1.Add('renderer does not display Brief date from JSON')
  }
  if ($styleSrc -notlike '*#today.morning-brief{display:grid*') {
    $fail1.Add('today workbench is not a compact dashboard grid')
  }
  Add-TestResult 'TEST 1' ($fail1.Count -eq 0) ($fail1 -join "`n")

  $fail2 = New-Object System.Collections.Generic.List[string]
  if ($indexSrc -notlike '*id="morningExecutiveSummary"*') { $fail2.Add('executive summary element missing') }
  if ($renderFn -notlike "*setText('morningExecutiveSummary', data.executiveSummary || data.summary)*") {
    $fail2.Add('renderer does not render executiveSummary')
  }
  if ($clickFn -like '*morningExecutiveSummary*') { $fail2.Add('executive summary click path was added to openMorningBriefResearch') }
  Add-TestResult 'TEST 2' ($fail2.Count -eq 0) ($fail2 -join "`n")

  $fail3 = New-Object System.Collections.Generic.List[string]
  if ($indexSrc -notlike '*id="morningTodaysThreeThings"*') { $fail3.Add('Today 3 Things element missing') }
  if ($renderFn -notlike "*renderThreeThings('morningTodaysThreeThings', data.today3Things)*") {
    $fail3.Add('renderer does not render today3Things')
  }
  if ($threeFn -notlike '*whyItMatters*') { $fail3.Add('Today 3 Things does not render whyItMatters') }
  if ($threeFn -notlike '*morning-brief-evidence*') { $fail3.Add('Today 3 Things does not render Evidence/source') }
  if ($threeFn -notlike '*bindResearchClick*') { $fail3.Add('Today 3 Things items are not bindable Brief items') }
  Add-TestResult 'TEST 3' ($fail3.Count -eq 0) ($fail3 -join "`n")

  $fail4 = New-Object System.Collections.Generic.List[string]
  if ($clickFn -notlike '*openResearchCard*') { $fail4.Add('Brief click does not open Research Card') }
  if ($clickFn -like '*/api/research/*') { $fail4.Add('Brief click creates research via API') }
  $cardHttp = Invoke-Get ('/research/' + $Contract.briefResearchId + '/card.json')
  if ([int]$cardHttp.StatusCode -ne 200) {
    $fail4.Add("GET research/$($Contract.briefResearchId)/card.json HTTP $($cardHttp.StatusCode)")
  } else {
    $opened = $cardHttp.Body | ConvertFrom-Json
    if ([string]$opened.id -ne $Contract.briefResearchId) { $fail4.Add('opened card id mismatch') }
  }
  Add-TestResult 'TEST 4' ($fail4.Count -eq 0) ($fail4 -join "`n")

  $fail5 = New-Object System.Collections.Generic.List[string]
  if ($appSrc -notlike "*ensureInQueue(researchId, 'Morning Brief')*") {
    $fail5.Add('Brief click path no longer queues with Morning Brief')
  }
  $postBrief = Invoke-Post '/api/queue' @{ id = $Contract.briefResearchId; addedFrom = $Contract.addedFromBrief }
  if ([int]$postBrief.StatusCode -ne 200) {
    $fail5.Add("POST /api/queue HTTP $($postBrief.StatusCode): $($postBrief.Body)")
  } else {
    $queued = $postBrief.Body | ConvertFrom-Json
    $hit = @($queued.items | Where-Object { $_.id -eq $Contract.briefResearchId } | Select-Object -First 1)
    if (-not $hit) { $fail5.Add('Brief researchId did not enter Queue') }
    elseif ($hit.addedFrom -ne $Contract.addedFromBrief) { $fail5.Add("addedFrom=$($hit.addedFrom)") }
  }
  Add-TestResult 'TEST 5' ($fail5.Count -eq 0) ($fail5 -join "`n")

  $fail6 = New-Object System.Collections.Generic.List[string]
  if ($workflowSrc -notlike '*if (this.isInQueue(id)) return false*') {
    $fail6.Add('ensureInQueue no longer skips existing researchId')
  }
  $postAgain = Invoke-Post '/api/queue' @{ id = $Contract.briefResearchId; addedFrom = $Contract.addedFromBrief }
  if ([int]$postAgain.StatusCode -ne 200) {
    $fail6.Add("duplicate POST /api/queue HTTP $($postAgain.StatusCode)")
  } else {
    $again = $postAgain.Body | ConvertFrom-Json
    $hits = @($again.items | Where-Object { $_.id -eq $Contract.briefResearchId })
    if ($hits.Count -ne 1) { $fail6.Add("duplicate queue count=$($hits.Count)") }
    foreach ($item in @($again.items)) {
      $names = @($item.PSObject.Properties.Name)
      foreach ($name in $names) {
        if ($Contract.queueSchemaKeys -notcontains $name) { $fail6.Add("queue schema grew field $name") }
      }
    }
  }
  Add-TestResult 'TEST 6' ($fail6.Count -eq 0) ($fail6 -join "`n")

  $fail7 = New-Object System.Collections.Generic.List[string]
  if ($renderFn -like '*/api/queue*') { $fail7.Add('Brief render posts /api/queue') }
  if ($renderFn -like '*fetch(*') { $fail7.Add('Brief render performs fetch') }
  if ($engineSrc -like "*fetch('/api/queue'*" -or $engineSrc -like '*fetch("/api/queue"*') {
    $fail7.Add('data-engine fetches /api/queue')
  }
  Add-TestResult 'TEST 7' ($fail7.Count -eq 0) ($fail7 -join "`n")

  $fail8 = New-Object System.Collections.Generic.List[string]
  if ($bindFn -notlike '*morning-brief-static*') { $fail8.Add('missing researchId is not rendered as static') }
  if ($clickFn -like '*/api/research/*') { $fail8.Add('null researchId path creates a Card via API') }
  $missingCard = Join-Path $script:TempRoot 'research\does-not-exist-031c\card.json'
  if (Test-Path -LiteralPath $missingCard) { $fail8.Add('temp repo gained a new Research Card') }
  Add-TestResult 'TEST 8' ($fail8.Count -eq 0) ($fail8 -join "`n")

  $fail9 = New-Object System.Collections.Generic.List[string]
  if ($bindFn -notlike '*if (!researchId || typeof handler !== ''function'')*') {
    $fail9.Add('null researchId still binds a click handler')
  }
  $queueBeforeNull = Read-JsonFile (Join-Path $script:TempRoot 'data\research-queue.json')
  $nullPost = Invoke-Post '/api/queue' @{ id = $null; addedFrom = $Contract.addedFromBrief }
  $queueAfterNull = Read-JsonFile (Join-Path $script:TempRoot 'data\research-queue.json')
  if (@($queueAfterNull.items).Count -ne @($queueBeforeNull.items).Count) {
    $fail9.Add('null researchId POST created a Queue item')
  }
  Add-TestResult 'TEST 9' ($fail9.Count -eq 0) ($fail9 -join "`n")

  $radarPy = @'
import datetime, json, os, sys
src = open(os.path.join(sys.argv[1], "js", "data-engine.js"), encoding="utf-8").read()
fail = []

def js_weekday(date_str):
    year, month, day = map(int, date_str.split("-"))
    return int(datetime.datetime(year, month, day).strftime("%w"))

def show_radar(data):
    wd = js_weekday(data.get("date"))
    if wd == 1:
        return True
    if data.get("opportunityRadarException") is True and 2 <= wd <= 5:
        return True
    return False

if js_weekday("2026-08-10") != 1:
    fail.append("2026-08-10 should be Monday")
if not show_radar({"date": "2026-08-10", "opportunityRadarException": False}):
    fail.append("Monday radar should show")
if show_radar({"date": "2026-08-11", "opportunityRadarException": False}):
    fail.append("Tue-Fri radar should hide by default")
if "weekday === 1" not in src:
    fail.append("JS Monday radar rule missing")
if "shouldShowOpportunityRadar" not in src:
    fail.append("shouldShowOpportunityRadar missing")
json.dump({"fail": fail}, open(sys.argv[2], "w", encoding="utf-8"))
'@
  $radarPyPath = Join-Path $script:TempRoot 'radar_031c.py'
  $radarOut = Join-Path $script:TempRoot 'radar_031c.json'
  [System.IO.File]::WriteAllText($radarPyPath, $radarPy, $Utf8)
  & python $radarPyPath $RepoRoot $radarOut
  $radarFail = @()
  if ($LASTEXITCODE -eq 0 -and (Test-Path $radarOut)) {
    $radarFail = @((Read-JsonFile $radarOut).fail | Where-Object { $_ })
  } else {
    $radarFail = @('radar python helper failed')
  }
  Add-TestResult 'TEST 10' ($radarFail.Count -eq 0) ($radarFail -join "`n")

  $exPy = @'
import datetime, json, os, sys
src = open(os.path.join(sys.argv[1], "js", "data-engine.js"), encoding="utf-8").read()
fail = []

def js_weekday(date_str):
    year, month, day = map(int, date_str.split("-"))
    return int(datetime.datetime(year, month, day).strftime("%w"))

def show_radar(data):
    wd = js_weekday(data.get("date"))
    if wd == 1:
        return True
    if data.get("opportunityRadarException") is True and 2 <= wd <= 5:
        return True
    return False

if not show_radar({"date": "2026-08-11", "opportunityRadarException": True}):
    fail.append("exceptional Tue-Fri radar should show")
if show_radar({"date": "2026-08-15", "opportunityRadarException": True}):
    fail.append("weekend exception should not show radar")
if "opportunityRadarException === true" not in src:
    fail.append("JS exception radar rule missing")
if "openFromOpportunityRadar" not in src:
    fail.append("Radar click helper missing")
json.dump({"fail": fail}, open(sys.argv[2], "w", encoding="utf-8"))
'@
  $exPyPath = Join-Path $script:TempRoot 'radar_ex_031c.py'
  $exOut = Join-Path $script:TempRoot 'radar_ex_031c.json'
  [System.IO.File]::WriteAllText($exPyPath, $exPy, $Utf8)
  & python $exPyPath $RepoRoot $exOut
  $exFail = @()
  if ($LASTEXITCODE -eq 0 -and (Test-Path $exOut)) {
    $exFail = @((Read-JsonFile $exOut).fail | Where-Object { $_ })
  } else {
    $exFail = @('radar exception python helper failed')
  }
  if ($appSrc -notlike "*ensureInQueue(researchId, 'Opportunity Radar')*") {
    $exFail += @('Radar click no longer queues with Opportunity Radar')
  }
  $radarClick = Get-FunctionText $engineSrc 'const radarClick'
  if ($radarClick -like '*/api/queue*') { $exFail += @('Radar render posts /api/queue') }
  Add-TestResult 'TEST 11' ($exFail.Count -eq 0) ($exFail -join "`n")
}
catch {
  Add-TestResult 'SETUP' $false $_.Exception.Message
}
finally {
  Stop-TempServer
}

$fail12 = New-Object System.Collections.Generic.List[string]
$reg025 = Invoke-SiblingTest '025-research-thesis-case.ps1'
if ($reg025.ExitCode -ne 0) { $fail12.Add($reg025.Text) }
$reg027 = Invoke-SiblingTest '027-research-intake.ps1'
if ($reg027.ExitCode -ne 0) { $fail12.Add($reg027.Text) }
$reg029 = Invoke-SiblingTest '029-research-conclusion-history.ps1'
if ($reg029.ExitCode -ne 0) { $fail12.Add($reg029.Text) }
$reg031a = Invoke-SiblingTest '031-a-morning-brief-pipeline.ps1'
if ($reg031a.ExitCode -ne 0) { $fail12.Add($reg031a.Text) }
$reg031b = Invoke-SiblingTest '031-b-morning-brief-intelligence.ps1'
if ($reg031b.ExitCode -ne 0) { $fail12.Add($reg031b.Text) }
Add-TestResult 'TEST 12' ($fail12.Count -eq 0) ($fail12 -join "`n")

$fail13 = New-Object System.Collections.Generic.List[string]
$afterBrief = (Get-FileHash -Path $ProdBriefPath -Algorithm SHA256).Hash
$afterLatest = (Get-FileHash -Path $LatestPath -Algorithm SHA256).Hash
$afterCases = (Get-FileHash -Path $ProdCasesPath -Algorithm SHA256).Hash
$afterQueue = (Get-FileHash -Path $ProdQueuePath -Algorithm SHA256).Hash
$afterGlass = (Get-FileHash -Path $GlassCardPath -Algorithm SHA256).Hash
$afterHbm = (Get-FileHash -Path $HbmCardPath -Algorithm SHA256).Hash
$afterCpo = (Get-FileHash -Path $CpoCardPath -Algorithm SHA256).Hash
$afterFau = (Get-FileHash -Path $FauCardPath -Algorithm SHA256).Hash
$afterDram = (Get-FileHash -Path (Join-Path $ThesesDir 'ai-dram.json') -Algorithm SHA256).Hash
$afterCpoThesis = (Get-FileHash -Path (Join-Path $ThesesDir 'cpo-glass-bridge.json') -Algorithm SHA256).Hash
$afterGenerate = (Get-FileHash -Path $GeneratePy -Algorithm SHA256).Hash
$afterCollect = (Get-FileHash -Path $CollectPy -Algorithm SHA256).Hash
if ($afterBrief -ne $ProdHashBefore.brief) { $fail13.Add('production morning-brief.json changed') }
if ($afterLatest -ne $ProdHashBefore.latest) { $fail13.Add('production morning-brief/latest.json changed') }
if ($afterCases -ne $ProdHashBefore.cases) { $fail13.Add('production investment-cases.json changed') }
if ($afterQueue -ne $ProdHashBefore.queue) { $fail13.Add('production research-queue.json changed') }
if ($afterGlass -ne $ProdHashBefore.glass) { $fail13.Add('production glass-bridge card.json changed') }
if ($afterHbm -ne $ProdHashBefore.hbm) { $fail13.Add('production hbm card.json changed') }
if ($afterCpo -ne $ProdHashBefore.cpo) { $fail13.Add('production cpo card.json changed') }
if ($afterFau -ne $ProdHashBefore.fau) { $fail13.Add('production fau card.json changed') }
if ($afterDram -ne $ProdHashBefore.dram) { $fail13.Add('production ai-dram thesis changed') }
if ($afterCpoThesis -ne $ProdHashBefore.cpoThesis) { $fail13.Add('production cpo-glass-bridge thesis changed') }
if ($afterGenerate -ne $ProdHashBefore.generate) { $fail13.Add('Morning Brief generator was modified') }
if ($afterCollect -ne $ProdHashBefore.collect) { $fail13.Add('Evidence Collector was modified') }
Add-TestResult 'TEST 13' ($fail13.Count -eq 0) ($fail13 -join "`n")
Add-TestResult 'PRODUCTION_FILE_GUARD' ($fail13.Count -eq 0) ($fail13 -join "`n")

if (Test-Path $script:TempRoot) {
  Remove-Item -Recurse -Force $script:TempRoot -ErrorAction SilentlyContinue
}

$failed = @($script:Results | Where-Object { $_.Status -ne 'PASS' })
Write-Output ''
Write-Output '=== 031-C SUMMARY ==='
foreach ($row in $script:Results) {
  Write-Output ("{0}: {1}" -f $row.Id, $row.Status)
  if ($row.Status -ne 'PASS' -and $row.Details) { Write-Output $row.Details }
}
if ($failed.Count -gt 0) { exit 1 }
exit 0
