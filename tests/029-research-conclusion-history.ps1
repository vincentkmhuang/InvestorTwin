$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$env:PYTHONIOENCODING = 'utf-8'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$FixturePath = Join-Path $PSScriptRoot 'fixtures\029-research-conclusion-history.json'
$ProdCasesPath = Join-Path $RepoRoot 'data\investment-cases.json'
$ProdQueuePath = Join-Path $RepoRoot 'data\research-queue.json'
$ProdBriefPath = Join-Path $RepoRoot 'data\morning-brief.json'
$LatestPath = Join-Path $RepoRoot 'data\morning-brief\latest.json'
$ProdIndexPath = Join-Path $RepoRoot 'data\knowledge-index.json'
$ServePath = Join-Path $RepoRoot 'serve.ps1'
$WorkflowPath = Join-Path $RepoRoot 'js\workflow-engine.js'
$AppPath = Join-Path $RepoRoot 'app.js'
$ThesesDir = Join-Path $RepoRoot 'data\theses'
$GlassCardPath = Join-Path $RepoRoot 'research\glass-bridge\card.json'
$HbmCardPath = Join-Path $RepoRoot 'research\hbm\card.json'
$CpoCardPath = Join-Path $RepoRoot 'research\cpo\card.json'
$FauCardPath = Join-Path $RepoRoot 'research\fau\card.json'

if (-not (Test-Path $FixturePath)) { throw "Missing fixture: $FixturePath" }

$Utf8 = New-Object System.Text.UTF8Encoding $false
$ProdHashBefore = @{
  cases = (Get-FileHash -Path $ProdCasesPath -Algorithm SHA256).Hash
  queue = (Get-FileHash -Path $ProdQueuePath -Algorithm SHA256).Hash
  brief = (Get-FileHash -Path $ProdBriefPath -Algorithm SHA256).Hash
  latest = (Get-FileHash -Path $LatestPath -Algorithm SHA256).Hash
  index = (Get-FileHash -Path $ProdIndexPath -Algorithm SHA256).Hash
  cpoThesis = (Get-FileHash -Path (Join-Path $ThesesDir 'cpo-glass-bridge.json') -Algorithm SHA256).Hash
  dram = (Get-FileHash -Path (Join-Path $ThesesDir 'ai-dram.json') -Algorithm SHA256).Hash
  glass = (Get-FileHash -Path $GlassCardPath -Algorithm SHA256).Hash
  hbm = (Get-FileHash -Path $HbmCardPath -Algorithm SHA256).Hash
  cpo = (Get-FileHash -Path $CpoCardPath -Algorithm SHA256).Hash
  fau = (Get-FileHash -Path $FauCardPath -Algorithm SHA256).Hash
}

$Contract = [System.IO.File]::ReadAllText($FixturePath, $Utf8) | ConvertFrom-Json
$script:Results = New-Object System.Collections.Generic.List[object]
$script:TempRoot = Join-Path $env:TEMP ('InvestorTwin-029-' + [guid]::NewGuid().ToString('N'))
$script:TempCardPath = $null
$script:TempNotesPath = $null
$script:TempThesisPath = $null
$script:TempQueuePath = $null
$script:TempCasesPath = $null
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
  if (-not $card) { return $list }
  $names = @($card.PSObject.Properties.Name)
  if ($names -notcontains 'researchConclusionHistory') { return $list }
  if ($null -eq $card.researchConclusionHistory) { return $list }
  foreach ($item in @($card.researchConclusionHistory)) {
    if ($null -ne $item) { [void]$list.Add($item) }
  }
  return ,$list
}

function Get-NoteTexts($notesObj) {
  $entries = @()
  if ($notesObj -is [System.Array]) { $entries = @($notesObj) }
  elseif ($notesObj -and $notesObj.PSObject.Properties['notes']) { $entries = @($notesObj.notes) }
  $texts = @()
  foreach ($entry in $entries) {
    if ($entry -and $entry.PSObject.Properties['text']) { $texts += [string]$entry.text }
    elseif ($entry) { $texts += [string]$entry }
  }
  return $texts
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
  $script:TempNotesPath = Join-Path $researchDir 'notes.json'
  $script:TempThesisPath = Join-Path $script:TempRoot ("data\theses\" + $Contract.thesisId + ".json")
  $script:TempQueuePath = Join-Path $script:TempRoot 'data\research-queue.json'
  $script:TempCasesPath = Join-Path $script:TempRoot 'data\investment-cases.json'

  Copy-Item (Join-Path $RepoRoot 'data\version.json') (Join-Path $script:TempRoot 'data\version.json') -ErrorAction SilentlyContinue
  Copy-Item (Join-Path $RepoRoot 'scripts\generate-knowledge-index.ps1') (Join-Path $script:TempRoot 'scripts\generate-knowledge-index.ps1')

  Write-JsonFile $script:TempCardPath ([ordered]@{
    id = $Contract.researchId
    thesisId = $Contract.thesisId
    title = 'Sprint 029 Re-Research'
    summary = '029 temp card'
    investmentThesis = '029 working thesis'
    questions = @()
    reason = 'Manual'
    tags = @()
    related = @()
    status = 'researching'
    updated = '2026-08-23'
  })
  Write-JsonFile (Join-Path $researchDir 'sources.json') @(@{
    title = '029 official source'
    url = 'https://example.test/029'
  })
  [System.IO.File]::WriteAllText((Join-Path $researchDir 'timeline.json'), '[]', $Utf8)
  [System.IO.File]::WriteAllText($script:TempNotesPath, '[]', $Utf8)
  Write-JsonFile $script:TempThesisPath ([ordered]@{
    thesisId = $Contract.thesisId
    type = 'industry'
    title = 'Sprint 029 Thesis'
    thesis = '029 placeholder thesis for Integrity Gate'
    status = 'under_review'
    linkedResearch = @(@{ researchId = $Contract.researchId })
    updatedAt = '2026-08-23'
  })
  Write-JsonFile $script:TempQueuePath @{ items = @() }
  Write-JsonFile $script:TempCasesPath @{
    schemaVersion = '1.0'
    updated = '2026-08-23'
    cases = @()
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
  $workflowSrc = [System.IO.File]::ReadAllText($WorkflowPath, $Utf8)
  $serveSrc = [System.IO.File]::ReadAllText($ServePath, $Utf8)
  $appSrc = [System.IO.File]::ReadAllText($AppPath, $Utf8)

  Start-TempServer
  $thesisBefore = Read-JsonFile $script:TempThesisPath
  $casesBefore = (Get-FileHash -Path $script:TempCasesPath -Algorithm SHA256).Hash

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
  if ([int]$save1.StatusCode -ne 200) {
    $fail1.Add("first conclusion HTTP $($save1.StatusCode): $($save1.Body)")
  }
  if (-not $card1.researchConclusion) {
    $fail1.Add('current researchConclusion missing after first save')
  } elseif ([string]$card1.researchConclusion.conclusion -ne $Contract.conclusion1) {
    $fail1.Add("current conclusion=$($card1.researchConclusion.conclusion)")
  } elseif ([string]$card1.researchConclusion.asOf -ne $Contract.asOf1) {
    $fail1.Add("current asOf=$($card1.researchConclusion.asOf)")
  }
  Add-TestResult 'TEST 1' ($fail1.Count -eq 0) ($fail1 -join "`n")

  $fail2 = New-Object System.Collections.Generic.List[string]
  $raw1 = [System.IO.File]::ReadAllText($script:TempCardPath, $Utf8)
  $save1Obj = $null
  if ([int]$save1.StatusCode -eq 200 -and $save1.Body) {
    $save1Obj = $save1.Body | ConvertFrom-Json
  }
  if ($save1Obj -and [int]$save1Obj.historyCount -lt 1) {
    $fail2.Add("API historyCount=$($save1Obj.historyCount)")
  }
  if ($raw1.IndexOf('"researchConclusionHistory":[{') -lt 0) {
    $fail2.Add('card.json missing researchConclusionHistory array after first save')
  }
  if ($hist1.Count -lt 1) {
    $fail2.Add('first conclusion did not enter researchConclusionHistory')
  } else {
    if ([string]$hist1[0].type -ne 'initial') { $fail2.Add("history[0].type=$($hist1[0].type)") }
    if ([string]$hist1[0].conclusion -ne $Contract.conclusion1) { $fail2.Add('history[0] conclusion mismatch') }
    if ([string]$hist1[0].asOf -ne $Contract.asOf1) { $fail2.Add("history[0].asOf=$($hist1[0].asOf)") }
  }
  if ($serveSrc -notlike '*researchConclusionHistory*') { $fail2.Add('serve.ps1 missing researchConclusionHistory') }
  Add-TestResult 'TEST 2' ($fail2.Count -eq 0) ($fail2 -join "`n")

  $trigger = Invoke-Post '/api/cases' @{
    monitoringTrigger = @{
      text = $Contract.triggerText
      researchId = $Contract.researchId
    }
  }
  $notes = Read-JsonFile $script:TempNotesPath
  $noteTexts = Get-NoteTexts $notes
  $expectedReason = 'needs re-research: ' + $Contract.triggerText
  $queue = Read-JsonFile $script:TempQueuePath
  $fail3 = New-Object System.Collections.Generic.List[string]
  if ([int]$trigger.StatusCode -ne 200) {
    $fail3.Add("trigger HTTP $($trigger.StatusCode): $($trigger.Body)")
  }
  if ($noteTexts -notcontains $expectedReason) {
    $fail3.Add("notes missing canonical reason: $expectedReason")
  }
  $hit = @($queue.items | Where-Object { $_.id -eq $Contract.researchId } | Select-Object -First 1)
  if (-not $hit) {
    $fail3.Add('trigger did not enqueue researchId')
  } elseif ([string]$hit.addedFrom -ne 'Monitoring') {
    $fail3.Add("addedFrom=$($hit.addedFrom)")
  }
  foreach ($item in @($queue.items)) {
    foreach ($name in @($item.PSObject.Properties.Name)) {
      if ($Contract.queueSchemaKeys -notcontains $name) { $fail3.Add("queue schema grew field $name") }
    }
  }
  if ($serveSrc -notlike '*needs re-research: *') { $fail3.Add('trigger no longer writes needs re-research') }
  Add-TestResult 'TEST 3' ($fail3.Count -eq 0) ($fail3 -join "`n")

  $save2 = Invoke-Post ("/api/research/" + $Contract.researchId) @{
    researchConclusion = @{
      conclusion = $Contract.conclusion2
      status = $Contract.status
      asOf = $Contract.asOf2
    }
  }
  $card2 = Read-JsonFile $script:TempCardPath
  $hist2 = Get-History $card2
  $fail4 = New-Object System.Collections.Generic.List[string]
  if ([int]$save2.StatusCode -ne 200) {
    $fail4.Add("second conclusion HTTP $($save2.StatusCode): $($save2.Body)")
  }
  if ($hist2.Count -lt 2) {
    $fail4.Add("history count=$($hist2.Count) after second save")
  } else {
    if ([string]$hist2[1].type -ne 're-research') { $fail4.Add("history[1].type=$($hist2[1].type)") }
    if ([string]$hist2[1].conclusion -ne $Contract.conclusion2) { $fail4.Add('history[1] conclusion mismatch') }
    if ([string]$hist2[1].asOf -ne $Contract.asOf2) { $fail4.Add("history[1].asOf=$($hist2[1].asOf)") }
    if ([string]$hist2[1].reason -ne $expectedReason) { $fail4.Add("history[1].reason=$($hist2[1].reason)") }
  }
  Add-TestResult 'TEST 4' ($fail4.Count -eq 0) ($fail4 -join "`n")

  $fail5 = New-Object System.Collections.Generic.List[string]
  if ($hist2.Count -lt 1) {
    $fail5.Add('history empty after second save')
  } elseif ([string]$hist2[0].conclusion -ne $Contract.conclusion1) {
    $fail5.Add('second save overwrote history[0]')
  } elseif ([string]$hist2[0].type -ne 'initial') {
    $fail5.Add("history[0].type changed to $($hist2[0].type)")
  } elseif ([string]$hist2[0].asOf -ne $Contract.asOf1) {
    $fail5.Add('history[0] asOf was overwritten')
  }
  Add-TestResult 'TEST 5' ($fail5.Count -eq 0) ($fail5 -join "`n")

  $fail6 = New-Object System.Collections.Generic.List[string]
  if (-not $card2.researchConclusion) {
    $fail6.Add('current researchConclusion missing after second save')
  } else {
    if ([string]$card2.researchConclusion.conclusion -ne $Contract.conclusion2) {
      $fail6.Add("current conclusion was not replaced: $($card2.researchConclusion.conclusion)")
    }
    if ([string]$card2.researchConclusion.asOf -ne $Contract.asOf2) {
      $fail6.Add("current asOf=$($card2.researchConclusion.asOf)")
    }
  }
  Add-TestResult 'TEST 6' ($fail6.Count -eq 0) ($fail6 -join "`n")

  $fail7 = New-Object System.Collections.Generic.List[string]
  $thesisAfter = Read-JsonFile $script:TempThesisPath
  $sources = Read-JsonFile (Join-Path $script:TempRoot ("research\" + $Contract.researchId + "\sources.json"))
  $sourceCount = @($sources).Count
  if (-not $card2.researchConclusion -or -not [string]$card2.researchConclusion.conclusion) {
    $fail7.Add('Integrity Gate cannot see current Research Conclusion')
  } elseif ([string]$card2.researchConclusion.conclusion -ne $Contract.conclusion2) {
    $fail7.Add('Integrity Gate still sees the first Conclusion')
  }
  if (-not $card2.thesisId) { $fail7.Add('card lost thesisId') }
  if ($sourceCount -lt 1) { $fail7.Add('sources missing for Integrity Gate') }
  if ([string]$thesisAfter.status -ne [string]$thesisBefore.status) {
    $fail7.Add("Thesis.status changed from $($thesisBefore.status) to $($thesisAfter.status)")
  }
  if ([string]$thesisAfter.status -eq 'confirmed' -or [string]$thesisAfter.status -eq 'rejected') {
    $fail7.Add('system auto-changed Thesis.status')
  }
  $casesAfter = (Get-FileHash -Path $script:TempCasesPath -Algorithm SHA256).Hash
  if ($casesAfter -ne $casesBefore) { $fail7.Add('saving Conclusion wrote Investment Cases / Decision') }
  $gateFn = [regex]::Match($workflowSrc, 'integrityGateView\(card, sources, thesis\) \{[\s\S]*?\n  \},')
  if (-not $gateFn.Success) {
    $fail7.Add('could not read integrityGateView')
  } else {
    if ($gateFn.Value -notlike '*researchConclusion?.conclusion*') {
      $fail7.Add('Integrity Gate no longer reads current researchConclusion')
    }
    if ($gateFn.Value -notlike '*Ready for Thesis Review*') { $fail7.Add('missing Ready for Thesis Review') }
    if ($gateFn.Value -like '*saveCaseDecision*') { $fail7.Add('Integrity Gate saves Decision') }
  }
  $saveFn = [regex]::Match($workflowSrc, 'saveResearchConclusion\([^\)]*\) \{[\s\S]*?\n  \},')
  if (-not $saveFn.Success) {
    $fail7.Add('saveResearchConclusion missing')
  } else {
    if ($saveFn.Value -like '*saveCaseDecision*') { $fail7.Add('saveResearchConclusion saves Decision') }
    if ($saveFn.Value -like '*saveCasePositionPlaybook*') { $fail7.Add('saveResearchConclusion saves Position Playbook') }
  }
  if ($workflowSrc -notlike '*Current Research Conclusion*') { $fail7.Add('UI missing Current Research Conclusion') }
  if ($workflowSrc -notlike '*Research History*') { $fail7.Add('UI missing Research History') }
  if ($workflowSrc -notlike '*data-integrity-gate*') { $fail7.Add('Integrity Gate is not rendered') }
  $ready = $card2.researchConclusion -and [string]$card2.researchConclusion.conclusion -and $sourceCount -gt 0 -and $card2.thesisId -and $thesisAfter.thesisId -eq $card2.thesisId
  if (-not $ready) { $fail7.Add('new Conclusion is not Ready for Thesis Review') }
  Add-TestResult 'TEST 7' ($fail7.Count -eq 0) ($fail7 -join "`n")
}
catch {
  $details = $_.Exception.Message
  Stop-TempServer
  $errLog = Join-Path $script:TempRoot 'serve.err.log'
  $outLog = Join-Path $script:TempRoot 'serve.out.log'
  try {
    if (Test-Path $errLog) { $details += "`nERR: " + [System.IO.File]::ReadAllText($errLog) }
  } catch { }
  try {
    if (Test-Path $outLog) { $details += "`nOUT: " + [System.IO.File]::ReadAllText($outLog) }
  } catch { }
  Add-TestResult 'SETUP' $false $details
}
finally {
  Stop-TempServer
}

$fail8 = New-Object System.Collections.Generic.List[string]
$workflowSrc8 = [System.IO.File]::ReadAllText($WorkflowPath, $Utf8)
foreach ($needle in @('createThesisFromResearch', 'createCaseFromResearch', 'linkResearchThesis', 'data-create-thesis', 'data-trace="research-conclusion"', 'data-trace="thesis"', 'data-trace="case"', 'data-trace="decision"', 'saveCaseDecision')) {
  if ($workflowSrc8 -notlike ("*" + $needle + "*")) { $fail8.Add("025 chain missing $needle") }
}
if ($workflowSrc8 -notmatch 'thesisId:\s*null') { $fail8.Add('createCaseFromResearch no longer keeps thesisId null') }
$basedOnFn = [regex]::Match($workflowSrc8, 'decisionBasedOnSnapshot\(caseObj\) \{[\s\S]*?\n  \},')
if ($basedOnFn.Success -and $basedOnFn.Value -like '*thesisId*') {
  $fail8.Add('Decision basedOn gained thesisId')
}
$reg025 = Invoke-SiblingTest '025-research-thesis-case.ps1'
if ($reg025.ExitCode -ne 0) { $fail8.Add($reg025.Text) }
Add-TestResult 'TEST 8' ($fail8.Count -eq 0) ($fail8 -join "`n")

$fail9 = New-Object System.Collections.Generic.List[string]
$appSrc9 = [System.IO.File]::ReadAllText($AppPath, $Utf8)
$workflowSrc9 = [System.IO.File]::ReadAllText($WorkflowPath, $Utf8)
if ($appSrc9 -notlike "*ensureInQueue(researchId, 'Morning Brief')*") {
  $fail9.Add('Brief click path no longer queues with Morning Brief')
}
if ($appSrc9 -notlike "*ensureInQueue(researchId, 'Opportunity Radar')*") {
  $fail9.Add('Opportunity Radar click path missing')
}
if ($workflowSrc9 -notlike '*this.queue.items.push({ id, addedFrom: source })*') {
  $fail9.Add('queue schema push missing')
}
if ($workflowSrc9 -notlike '*data-evidence-intake*') { $fail9.Add('Research Card missing Evidence Intake') }
$reg027 = Invoke-SiblingTest '027-research-intake.ps1'
if ($reg027.ExitCode -ne 0) { $fail9.Add($reg027.Text) }
Add-TestResult 'TEST 9' ($fail9.Count -eq 0) ($fail9 -join "`n")

$afterCases = (Get-FileHash -Path $ProdCasesPath -Algorithm SHA256).Hash
$afterQueue = (Get-FileHash -Path $ProdQueuePath -Algorithm SHA256).Hash
$afterBrief = (Get-FileHash -Path $ProdBriefPath -Algorithm SHA256).Hash
$afterLatest = (Get-FileHash -Path $LatestPath -Algorithm SHA256).Hash
$afterIndex = (Get-FileHash -Path $ProdIndexPath -Algorithm SHA256).Hash
$afterCpoThesis = (Get-FileHash -Path (Join-Path $ThesesDir 'cpo-glass-bridge.json') -Algorithm SHA256).Hash
$afterDram = (Get-FileHash -Path (Join-Path $ThesesDir 'ai-dram.json') -Algorithm SHA256).Hash
$afterGlass = (Get-FileHash -Path $GlassCardPath -Algorithm SHA256).Hash
$afterHbm = (Get-FileHash -Path $HbmCardPath -Algorithm SHA256).Hash
$afterCpo = (Get-FileHash -Path $CpoCardPath -Algorithm SHA256).Hash
$afterFau = (Get-FileHash -Path $FauCardPath -Algorithm SHA256).Hash
$guardOk = ($afterCases -eq $ProdHashBefore.cases) -and ($afterQueue -eq $ProdHashBefore.queue) -and ($afterBrief -eq $ProdHashBefore.brief) -and ($afterLatest -eq $ProdHashBefore.latest) -and ($afterIndex -eq $ProdHashBefore.index) -and ($afterCpoThesis -eq $ProdHashBefore.cpoThesis) -and ($afterDram -eq $ProdHashBefore.dram) -and ($afterGlass -eq $ProdHashBefore.glass) -and ($afterHbm -eq $ProdHashBefore.hbm) -and ($afterCpo -eq $ProdHashBefore.cpo) -and ($afterFau -eq $ProdHashBefore.fau)
Add-TestResult 'PRODUCTION_FILE_GUARD' $guardOk $(if ($guardOk) { '' } else { 'production data files were modified by tests' })

if (Test-Path $script:TempRoot) {
  Remove-Item -Recurse -Force $script:TempRoot -ErrorAction SilentlyContinue
}

$failed = @($script:Results | Where-Object { $_.Status -ne 'PASS' })
Write-Output ''
Write-Output '=== 029 SUMMARY ==='
foreach ($row in $script:Results) {
  Write-Output ("{0}: {1}" -f $row.Id, $row.Status)
  if ($row.Status -ne 'PASS' -and $row.Details) { Write-Output $row.Details }
}
if ($failed.Count -gt 0) { exit 1 }
exit 0
