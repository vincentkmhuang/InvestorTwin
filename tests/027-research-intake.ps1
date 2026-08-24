$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$env:PYTHONIOENCODING = 'utf-8'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$FixturePath = Join-Path $PSScriptRoot 'fixtures\027-research-intake.json'
$ProdCasesPath = Join-Path $RepoRoot 'data\investment-cases.json'
$ProdQueuePath = Join-Path $RepoRoot 'data\research-queue.json'
$ProdBriefPath = Join-Path $RepoRoot 'data\morning-brief.json'
$LatestPath = Join-Path $RepoRoot 'data\morning-brief\latest.json'
$ProdIndexPath = Join-Path $RepoRoot 'data\knowledge-index.json'
$RadarPath = Join-Path $RepoRoot 'data\opportunity-radar.json'
$ServePath = Join-Path $RepoRoot 'serve.ps1'
$AppPath = Join-Path $RepoRoot 'app.js'
$WorkflowPath = Join-Path $RepoRoot 'js\workflow-engine.js'
$DataEnginePath = Join-Path $RepoRoot 'js\data-engine.js'
$IndexPath = Join-Path $RepoRoot 'index.html'
$CollectPy = Join-Path $RepoRoot 'scripts\collect-evidence.py'
$ThesesDir = Join-Path $RepoRoot 'data\theses'
$HbmCardPath = Join-Path $RepoRoot 'research\hbm\card.json'
$GlassCardPath = Join-Path $RepoRoot 'research\glass-bridge\card.json'
$CpoCardPath = Join-Path $RepoRoot 'research\cpo\card.json'

if (-not (Test-Path $FixturePath)) { throw "Missing fixture: $FixturePath" }

$Utf8 = New-Object System.Text.UTF8Encoding $false
$ProdHashBefore = @{
  cases = (Get-FileHash -Path $ProdCasesPath -Algorithm SHA256).Hash
  queue = (Get-FileHash -Path $ProdQueuePath -Algorithm SHA256).Hash
  brief = (Get-FileHash -Path $ProdBriefPath -Algorithm SHA256).Hash
  latest = (Get-FileHash -Path $LatestPath -Algorithm SHA256).Hash
  index = (Get-FileHash -Path $ProdIndexPath -Algorithm SHA256).Hash
  dram = (Get-FileHash -Path (Join-Path $ThesesDir 'ai-dram.json') -Algorithm SHA256).Hash
  glass = (Get-FileHash -Path $GlassCardPath -Algorithm SHA256).Hash
  hbm = (Get-FileHash -Path $HbmCardPath -Algorithm SHA256).Hash
}

$Contract = [System.IO.File]::ReadAllText($FixturePath, $Utf8) | ConvertFrom-Json
$script:Results = New-Object System.Collections.Generic.List[object]
$script:TempRoot = Join-Path $env:TEMP ('InvestorTwin-027-' + [guid]::NewGuid().ToString('N'))
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

function Get-BriefResearchIds($brief) {
  $ids = New-Object System.Collections.Generic.List[string]
  $seen = @{}
  function Add-Id($raw) {
    $rid = $null
    if ($raw -is [string]) { $rid = $raw.Trim() }
    elseif ($raw -and $raw.researchId) { $rid = ([string]$raw.researchId).Trim() }
    elseif ($raw -and $raw.cardRef) { $rid = ([string]$raw.cardRef).Trim() }
    if ($rid -and -not $seen.ContainsKey($rid)) {
      $seen[$rid] = $true
      [void]$ids.Add($rid)
    }
  }
  foreach ($block in @($brief.globalMarketAndNews, $brief.taiwanMarketAndNews)) {
    foreach ($item in @($block.items)) { Add-Id $item }
  }
  foreach ($key in @('aiIndustryHighlights', 'upcomingEvents', 'today3Things', 'opportunityRadar')) {
    foreach ($item in @($brief.$key)) { Add-Id $item }
  }
  return @($ids)
}

function Get-NullResearchCount($brief) {
  $count = 0
  foreach ($block in @($brief.globalMarketAndNews, $brief.taiwanMarketAndNews)) {
    foreach ($item in @($block.items)) {
      if ($item -and ($item.PSObject.Properties.Name -contains 'researchId') -and -not $item.researchId) { $count++ }
    }
  }
  foreach ($item in @($brief.today3Things)) {
    if ($item -and ($item.PSObject.Properties.Name -contains 'researchId') -and -not $item.researchId) { $count++ }
  }
  return $count
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
  New-Item -ItemType Directory -Path (Join-Path $script:TempRoot 'data\evidence\history\US10Y') | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $script:TempRoot 'data\evidence\history\SOX') | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $script:TempRoot 'scripts') | Out-Null
  Copy-Item (Join-Path $RepoRoot 'data\version.json') (Join-Path $script:TempRoot 'data\version.json') -ErrorAction SilentlyContinue
  Copy-Item (Join-Path $RepoRoot 'scripts\generate-knowledge-index.ps1') (Join-Path $script:TempRoot 'scripts\generate-knowledge-index.ps1')
  Copy-Item $ProdBriefPath (Join-Path $script:TempRoot 'data\morning-brief.json')
  Copy-Item $RadarPath (Join-Path $script:TempRoot 'data\opportunity-radar.json')
  Write-JsonFile (Join-Path $script:TempRoot 'data\research-queue.json') @{
    items = @(
      @{ id = 'glass-bridge'; addedFrom = 'Morning Brief' }
      @{ id = 'fau'; addedFrom = 'Opportunity Radar' }
    )
  }
  Write-JsonFile (Join-Path $script:TempRoot 'data\investment-cases.json') @{
    schemaVersion = '1.0'
    updated = '2026-08-23'
    cases = @()
  }
  foreach ($id in @('glass-bridge', 'fau', 'cpo', 'hbm')) {
    $destDir = Join-Path $script:TempRoot ("research\" + $id)
    New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    Copy-Item (Join-Path $RepoRoot ("research\" + $id + "\card.json")) (Join-Path $destDir 'card.json')
  }
  Copy-Item (Join-Path $RepoRoot 'data\evidence\history\US10Y\2026-08-20.json') (Join-Path $script:TempRoot 'data\evidence\history\US10Y\2026-08-20.json')
  Write-JsonFile (Join-Path $script:TempRoot 'data\evidence\history\SOX\2026-08-21.json') @{
    instrument = 'SOX'
    asOf = '2026-08-21'
    status = 'unavailable'
    sourceId = 'us-index-sox'
  }
  New-PatchedServeScript $ServePath (Join-Path $script:TempRoot 'serve.ps1')
  foreach ($port in 18837, 18838, 18839) {
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
  $appSrc = [System.IO.File]::ReadAllText($AppPath, $Utf8)
  $workflowSrc = [System.IO.File]::ReadAllText($WorkflowPath, $Utf8)
  $engineSrc = [System.IO.File]::ReadAllText($DataEnginePath, $Utf8)
  $serveSrc = [System.IO.File]::ReadAllText($ServePath, $Utf8)
  $indexSrc = [System.IO.File]::ReadAllText($IndexPath, $Utf8)
  $collectSrc = [System.IO.File]::ReadAllText($CollectPy, $Utf8)
  $hbmCard = Read-JsonFile $HbmCardPath
  $radar = Read-JsonFile $RadarPath
  $queue = Read-JsonFile $ProdQueuePath

  Start-TempServer

  $ids = Get-BriefResearchIds $brief
  $fail1 = New-Object System.Collections.Generic.List[string]
  if ($ids -notcontains $Contract.briefResearchId) { $fail1.Add('canonical Brief has no research-worthy hbm researchId') }
  foreach ($rid in $ids) {
    $cardPath = Join-Path $RepoRoot ("research\" + $rid + "\card.json")
    if (-not (Test-Path -LiteralPath $cardPath)) {
      $fail1.Add("researchId has no card: $rid")
    } else {
      $card = Read-JsonFile $cardPath
      if ([string]$card.id -ne $rid) { $fail1.Add("card id mismatch for $rid") }
    }
  }
  if ((Get-NullResearchCount $brief) -lt 1) { $fail1.Add('all Brief items were auto-linked; null researchId must remain') }
  $nvidia = @($brief.aiIndustryHighlights | Where-Object { $_.title -like '*NVIDIA*' -and $_.researchId -eq 'hbm' })
  if ($nvidia.Count -lt 1) { $fail1.Add('NVIDIA research-worthy highlight was not linked to hbm') }
  Add-TestResult 'TEST 1' ($fail1.Count -eq 0) ($fail1 -join "`n")

  $fail2 = New-Object System.Collections.Generic.List[string]
  if ($appSrc -notlike "*ensureInQueue(researchId, 'Morning Brief')*") {
    $fail2.Add('Brief click path no longer queues with Morning Brief')
  }
  $postBrief = Invoke-Post '/api/queue' @{ id = $Contract.briefResearchId; addedFrom = 'Morning Brief' }
  if ([int]$postBrief.StatusCode -ne 200) {
    $fail2.Add("POST /api/queue HTTP $($postBrief.StatusCode): $($postBrief.Body)")
  } else {
    $queued = $postBrief.Body | ConvertFrom-Json
    $hit = @($queued.items | Where-Object { $_.id -eq $Contract.briefResearchId } | Select-Object -First 1)
    if (-not $hit) { $fail2.Add('Brief researchId did not enter Queue') }
    elseif ($hit.addedFrom -ne 'Morning Brief') { $fail2.Add("addedFrom=$($hit.addedFrom)") }
    foreach ($item in @($queued.items)) {
      $names = @($item.PSObject.Properties.Name)
      foreach ($name in $names) {
        if ($Contract.queueSchemaKeys -notcontains $name) { $fail2.Add("queue schema grew field $name") }
      }
    }
  }
  Add-TestResult 'TEST 2' ($fail2.Count -eq 0) ($fail2 -join "`n")

  $fail3 = New-Object System.Collections.Generic.List[string]
  $cardHttp = Invoke-Get ("/research/" + $Contract.briefResearchId + "/card.json")
  if ([int]$cardHttp.StatusCode -ne 200) {
    $fail3.Add("GET research/$($Contract.briefResearchId)/card.json HTTP $($cardHttp.StatusCode)")
  } else {
    $opened = $cardHttp.Body | ConvertFrom-Json
    if ([string]$opened.id -ne $Contract.briefResearchId) { $fail3.Add('opened card id mismatch') }
  }
  if ($appSrc -notlike '*openResearchCard(q, document.getElementById(''card'')*') {
    $fail3.Add('Queue click no longer opens Research Card')
  }
  Add-TestResult 'TEST 3' ($fail3.Count -eq 0) ($fail3 -join "`n")

  $fail4 = New-Object System.Collections.Generic.List[string]
  if ([string]$hbmCard.id -ne $Contract.briefResearchId) { $fail4.Add('hbm card id is not canonical researchId') }
  $linkedItems = @($brief.aiIndustryHighlights | Where-Object { $_.researchId -eq $Contract.briefResearchId })
  if ($linkedItems.Count -lt 1) { $fail4.Add('Brief item and Research Card do not share hbm') }
  Add-TestResult 'TEST 4' ($fail4.Count -eq 0) ($fail4 -join "`n")

  $fail5 = New-Object System.Collections.Generic.List[string]
  $briefHashBeforeGet = (Get-FileHash -Path (Join-Path $script:TempRoot 'data\morning-brief.json') -Algorithm SHA256).Hash
  $evidenceHttp = Invoke-Get '/api/evidence'
  if ([int]$evidenceHttp.StatusCode -ne 200) {
    $fail5.Add("GET /api/evidence HTTP $($evidenceHttp.StatusCode): $($evidenceHttp.Body)")
  } else {
    $evidence = $evidenceHttp.Body | ConvertFrom-Json
    if ($evidence.writesBrief -ne $false) { $fail5.Add('Evidence API writesBrief is not false') }
    if ([string]$evidence.layer -ne 'evidence') { $fail5.Add('Evidence API layer is not evidence') }
    if ($evidence.PSObject.Properties.Name -contains 'executiveSummary') { $fail5.Add('Evidence API looks like Morning Brief') }
    $instruments = @($evidence.items | ForEach-Object { [string]$_.instrument })
    foreach ($need in @($Contract.evidenceInstruments)) {
      if ($instruments -notcontains $need) { $fail5.Add("Evidence intake missing $need") }
    }
    foreach ($item in @($evidence.items)) {
      if ($item.writesBrief -ne $false) { $fail5.Add("$($item.instrument) writesBrief is not false") }
      if ([string]$item.path -notlike 'data/evidence/*') { $fail5.Add("$($item.instrument) path is not under data/evidence") }
    }
  }
  $briefHashAfterGet = (Get-FileHash -Path (Join-Path $script:TempRoot 'data\morning-brief.json') -Algorithm SHA256).Hash
  if ($briefHashBeforeGet -ne $briefHashAfterGet) { $fail5.Add('GET /api/evidence mutated Morning Brief') }
  if ($collectSrc -notlike '*"writesBrief": False*') { $fail5.Add('collector no longer declares writesBrief False') }
  if ($workflowSrc -notlike '*Evidence is not Morning Brief*') { $fail5.Add('Research Card missing Evidence-is-not-Brief label') }
  if ($workflowSrc -notlike '*data-evidence-intake*') { $fail5.Add('Research Card missing Evidence Intake') }
  if ($serveSrc -notlike "*localPath -eq '/api/evidence'*") { $fail5.Add('GET /api/evidence missing') }
  Add-TestResult 'TEST 5' ($fail5.Count -eq 0) ($fail5 -join "`n")

  $fail6 = New-Object System.Collections.Generic.List[string]
  $radarIds = @($radar.items | ForEach-Object { [string]$_.id })
  if ($radarIds -notcontains $Contract.radarResearchId) { $fail6.Add('Opportunity Radar missing cpo') }
  if ($indexSrc -notlike '*id="queueOpportunityRadar"*') { $fail6.Add('queue page missing Opportunity Radar list') }
  if ($appSrc -notlike '*renderOpportunityRadar*') { $fail6.Add('render() does not call renderOpportunityRadar') }
  if ($appSrc -notlike "*ensureInQueue(researchId, 'Opportunity Radar')*") {
    $fail6.Add('Opportunity Radar click path missing')
  }
  $postRadar = Invoke-Post '/api/queue' @{ id = $Contract.radarResearchId; addedFrom = 'Opportunity Radar' }
  if ([int]$postRadar.StatusCode -ne 200) {
    $fail6.Add("Radar POST /api/queue HTTP $($postRadar.StatusCode)")
  } else {
    $queuedRadar = $postRadar.Body | ConvertFrom-Json
    $radarHit = @($queuedRadar.items | Where-Object { $_.id -eq $Contract.radarResearchId } | Select-Object -First 1)
    if (-not $radarHit) { $fail6.Add('Opportunity Radar item did not enter Queue') }
    elseif ($radarHit.addedFrom -ne 'Opportunity Radar') { $fail6.Add("radar addedFrom=$($radarHit.addedFrom)") }
  }
  $radarCard = Invoke-Get ("/research/" + $Contract.radarResearchId + "/card.json")
  if ([int]$radarCard.StatusCode -ne 200) { $fail6.Add('Opportunity Radar card missing') }
  else {
    $radarCardObj = $radarCard.Body | ConvertFrom-Json
    if ([string]$radarCardObj.id -ne $Contract.radarResearchId) { $fail6.Add('Radar card id mismatch') }
  }
  foreach ($rid in @($Contract.radarIds)) {
    if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot ("research\" + $rid + "\card.json")))) {
      $fail6.Add("radar id missing card: $rid")
    }
  }
  Add-TestResult 'TEST 6' ($fail6.Count -eq 0) ($fail6 -join "`n")

  $fail7 = New-Object System.Collections.Generic.List[string]
  if ($workflowSrc -notlike '*this.queue.items.push({ id, addedFrom: source })*') {
    $fail7.Add('queue schema push missing')
  }
  $existing = @($queue.items | Where-Object { $_.id -eq $Contract.existingQueueId } | Select-Object -First 1)
  if (-not $existing) { $fail7.Add('production Queue lost glass-bridge') }
  $existingCard = Invoke-Get ("/research/" + $Contract.existingQueueId + "/card.json")
  if ([int]$existingCard.StatusCode -ne 200) { $fail7.Add('existing Queue item cannot open Research Card') }
  if ($appSrc -notlike '*fromPage: ''queue''*') { $fail7.Add('Queue → Card fromPage missing') }
  Add-TestResult 'TEST 7' ($fail7.Count -eq 0) ($fail7 -join "`n")

  $fail8 = New-Object System.Collections.Generic.List[string]
  foreach ($needle in @('createThesisFromResearch', 'createCaseFromResearch', 'linkResearchThesis', 'data-create-thesis', 'data-trace="research-conclusion"', 'data-trace="thesis"', 'data-trace="case"', 'data-trace="decision"')) {
    if ($workflowSrc -notlike ("*" + $needle + "*")) { $fail8.Add("025 chain missing $needle") }
  }
  if ($workflowSrc -notmatch 'thesisId:\s*null') { $fail8.Add('createCaseFromResearch no longer keeps thesisId null') }
  $intakeFn = [regex]::Match($workflowSrc, 'loadLatestEvidence\([^\)]*\) \{[\s\S]*?\n  \},')
  if ($intakeFn.Success) {
    if ($intakeFn.Value -like '*saveCaseDecision*') { $fail8.Add('Evidence intake saves Decision') }
    if ($intakeFn.Value -like '*saveCasePositionPlaybook*') { $fail8.Add('Evidence intake saves Position Playbook') }
  }
  Add-TestResult 'TEST 8' ($fail8.Count -eq 0) ($fail8 -join "`n")
}
catch {
  $details = $_.Exception.Message
  $errLog = Join-Path $script:TempRoot 'serve.err.log'
  $outLog = Join-Path $script:TempRoot 'serve.out.log'
  if (Test-Path $errLog) { $details += "`nERR: " + [System.IO.File]::ReadAllText($errLog) }
  if (Test-Path $outLog) { $details += "`nOUT: " + [System.IO.File]::ReadAllText($outLog) }
  Add-TestResult 'SETUP' $false $details
}
finally {
  Stop-TempServer
}

$reg012a = Invoke-SiblingTest '012-a-morning-brief.ps1'
Add-TestResult 'REGRESSION 012-a' ($reg012a.ExitCode -eq 0) $(if ($reg012a.ExitCode -ne 0) { $reg012a.Text } else { '' })

$reg012c = Invoke-SiblingTest '012-c-daily-brief.ps1'
Add-TestResult 'REGRESSION 012-c' ($reg012c.ExitCode -eq 0) $(if ($reg012c.ExitCode -ne 0) { $reg012c.Text } else { '' })

$reg025 = Invoke-SiblingTest '025-research-thesis-case.ps1'
Add-TestResult 'REGRESSION 025' ($reg025.ExitCode -eq 0) $(if ($reg025.ExitCode -ne 0) { $reg025.Text } else { '' })

$afterCases = (Get-FileHash -Path $ProdCasesPath -Algorithm SHA256).Hash
$afterQueue = (Get-FileHash -Path $ProdQueuePath -Algorithm SHA256).Hash
$afterBrief = (Get-FileHash -Path $ProdBriefPath -Algorithm SHA256).Hash
$afterLatest = (Get-FileHash -Path $LatestPath -Algorithm SHA256).Hash
$afterIndex = (Get-FileHash -Path $ProdIndexPath -Algorithm SHA256).Hash
$afterDram = (Get-FileHash -Path (Join-Path $ThesesDir 'ai-dram.json') -Algorithm SHA256).Hash
$afterGlass = (Get-FileHash -Path $GlassCardPath -Algorithm SHA256).Hash
$afterHbm = (Get-FileHash -Path $HbmCardPath -Algorithm SHA256).Hash
$guardOk = ($afterCases -eq $ProdHashBefore.cases) -and ($afterQueue -eq $ProdHashBefore.queue) -and ($afterBrief -eq $ProdHashBefore.brief) -and ($afterLatest -eq $ProdHashBefore.latest) -and ($afterIndex -eq $ProdHashBefore.index) -and ($afterDram -eq $ProdHashBefore.dram) -and ($afterGlass -eq $ProdHashBefore.glass) -and ($afterHbm -eq $ProdHashBefore.hbm)
Add-TestResult 'PRODUCTION_FILE_GUARD' $guardOk $(if ($guardOk) { '' } else { 'production data files were modified by tests' })

if (Test-Path $script:TempRoot) {
  Remove-Item -Recurse -Force $script:TempRoot -ErrorAction SilentlyContinue
}

$failed = @($script:Results | Where-Object { $_.Status -ne 'PASS' })
Write-Output ''
Write-Output '=== 027 SUMMARY ==='
foreach ($row in $script:Results) {
  Write-Output ("{0}: {1}" -f $row.Id, $row.Status)
  if ($row.Status -ne 'PASS' -and $row.Details) { Write-Output $row.Details }
}
if ($failed.Count -gt 0) { exit 1 }
exit 0
