$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$RepoRoot = Split-Path -Parent $PSScriptRoot
$FixturePath = Join-Path $PSScriptRoot 'fixtures\008-1-first-investment-decision.json'
$ServePath = Join-Path $RepoRoot 'serve.ps1'
$WorkflowPath = Join-Path $RepoRoot 'js\workflow-engine.js'
$AppPath = Join-Path $RepoRoot 'app.js'
$IndexPath = Join-Path $RepoRoot 'index.html'
$EnginePath = Join-Path $RepoRoot 'js\data-engine.js'
$KnowledgePath = Join-Path $RepoRoot 'js\knowledge-engine.js'
$CollectPath = Join-Path $RepoRoot 'scripts\collect-evidence.py'
$GeneratePath = Join-Path $RepoRoot 'scripts\generate-morning-brief.py'
$ProdBriefPath = Join-Path $RepoRoot 'data\morning-brief.json'
$ProdQueuePath = Join-Path $RepoRoot 'data\research-queue.json'
$ProdIndexPath = Join-Path $RepoRoot 'data\knowledge-index.json'
$RadarPath = Join-Path $RepoRoot 'data\opportunity-radar.json'
$ProdCasesPath = Join-Path $RepoRoot 'data\investment-cases.json'
$ThesisPath = Join-Path $RepoRoot 'data\theses\cpo-glass-bridge.json'
$GlassCardPath = Join-Path $RepoRoot 'research\glass-bridge\card.json'
$HbmCardPath = Join-Path $RepoRoot 'research\hbm\card.json'
$CpoCardPath = Join-Path $RepoRoot 'research\cpo\card.json'
$FauCardPath = Join-Path $RepoRoot 'research\fau\card.json'

if (-not (Test-Path $FixturePath)) { throw "Missing fixture: $FixturePath" }

$Utf8 = New-Object System.Text.UTF8Encoding $false
$Contract = [System.IO.File]::ReadAllText($FixturePath, $Utf8) | ConvertFrom-Json
$Workflow = [System.IO.File]::ReadAllText($WorkflowPath, $Utf8)
$ServeSrc = [System.IO.File]::ReadAllText($ServePath, $Utf8)

$ProdHashBefore = @{
  brief = (Get-FileHash -Path $ProdBriefPath -Algorithm SHA256).Hash
  queue = (Get-FileHash -Path $ProdQueuePath -Algorithm SHA256).Hash
  index = (Get-FileHash -Path $ProdIndexPath -Algorithm SHA256).Hash
  radar = (Get-FileHash -Path $RadarPath -Algorithm SHA256).Hash
  cases = (Get-FileHash -Path $ProdCasesPath -Algorithm SHA256).Hash
  thesis = (Get-FileHash -Path $ThesisPath -Algorithm SHA256).Hash
  engine = (Get-FileHash -Path $EnginePath -Algorithm SHA256).Hash
  workflow = (Get-FileHash -Path $WorkflowPath -Algorithm SHA256).Hash
  knowledge = (Get-FileHash -Path $KnowledgePath -Algorithm SHA256).Hash
  collect = (Get-FileHash -Path $CollectPath -Algorithm SHA256).Hash
  generate = (Get-FileHash -Path $GeneratePath -Algorithm SHA256).Hash
  serve = (Get-FileHash -Path $ServePath -Algorithm SHA256).Hash
  app = (Get-FileHash -Path $AppPath -Algorithm SHA256).Hash
  html = (Get-FileHash -Path $IndexPath -Algorithm SHA256).Hash
  glass = (Get-FileHash -Path $GlassCardPath -Algorithm SHA256).Hash
  hbm = (Get-FileHash -Path $HbmCardPath -Algorithm SHA256).Hash
  cpo = (Get-FileHash -Path $CpoCardPath -Algorithm SHA256).Hash
  fau = (Get-FileHash -Path $FauCardPath -Algorithm SHA256).Hash
}

$script:Results = New-Object System.Collections.Generic.List[object]
$script:TempRoot = Join-Path $env:TEMP ('InvestorTwin-0081-' + [guid]::NewGuid().ToString('N'))
$script:TestPort = $null
$script:ServerProc = $null

function Add-TestResult($id, $passed, $details) {
  $status = if ($passed) { 'PASS' } else { 'FAIL' }
  $script:Results.Add([PSCustomObject]@{ Id = $id; Status = $status; Details = $details })
  Write-Output ("{0}: {1}" -f $id, $status)
  if ($details) { Write-Output $details }
}

function Get-MethodText($src, $name) {
  $needles = @("`n  $name(", "`n  async $name(")
  $start = -1
  foreach ($needle in $needles) {
    $idx = $src.IndexOf($needle)
    if ($idx -ge 0) { $start = $idx + 1; break }
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

function Read-JsonFile($path) {
  return ([System.IO.File]::ReadAllText($path, $Utf8) | ConvertFrom-Json)
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
  New-Item -ItemType Directory -Path (Join-Path $script:TempRoot 'data\evidence\runs') | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $script:TempRoot 'scripts') | Out-Null
  Copy-Item (Join-Path $RepoRoot 'data\version.json') (Join-Path $script:TempRoot 'data\version.json') -ErrorAction SilentlyContinue
  Copy-Item (Join-Path $RepoRoot 'scripts\generate-knowledge-index.ps1') (Join-Path $script:TempRoot 'scripts\generate-knowledge-index.ps1')
  Copy-Item $ProdBriefPath (Join-Path $script:TempRoot 'data\morning-brief.json')
  Copy-Item $RadarPath (Join-Path $script:TempRoot 'data\opportunity-radar.json')
  Copy-Item $ProdQueuePath (Join-Path $script:TempRoot 'data\research-queue.json')
  Copy-Item $ProdCasesPath (Join-Path $script:TempRoot 'data\investment-cases.json')
  Copy-Item $ThesisPath (Join-Path $script:TempRoot 'data\theses\cpo-glass-bridge.json')
  foreach ($id in @('glass-bridge', 'fau', 'cpo', 'hbm')) {
    $destDir = Join-Path $script:TempRoot ("research\" + $id)
    New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    Copy-Item (Join-Path $RepoRoot ("research\" + $id + "\card.json")) (Join-Path $destDir 'card.json')
  }
  New-PatchedServeScript $ServePath (Join-Path $script:TempRoot 'serve.ps1')
  foreach ($port in 18867, 18868, 18869) {
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
        $probe = Invoke-WebRequest -Uri ("http://localhost:{0}/data/investment-cases.json" -f $port) -UseBasicParsing
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

function Get-TempCase($id) {
  $store = Read-JsonFile (Join-Path $script:TempRoot 'data\investment-cases.json')
  return @($store.cases | Where-Object { $_.id -eq $id } | Select-Object -First 1)[0]
}

$SectionFn = Get-MethodText $Workflow 'renderDecisionSection'
$RecordFn = Get-MethodText $Workflow 'renderDecisionRecord'
$SaveFn = Get-MethodText $Workflow 'saveCaseDecision'
$BuildFn = Get-MethodText $Workflow 'buildDecision'
$CaseFn = Get-MethodText $Workflow 'renderInvestmentCase'
$ResearchFn = Get-MethodText $Workflow 'renderResearch'
$RecheckFn = Get-MethodText $Workflow 'renderEvidenceRecheck'
$LoadEvidenceFn = Get-MethodText $Workflow 'loadLatestEvidence'

$prodStore = Read-JsonFile $ProdCasesPath
$prodCase = @($prodStore.cases | Where-Object { $_.id -eq $Contract.caseId } | Select-Object -First 1)[0]
$fail1 = New-Object System.Collections.Generic.List[string]
if (-not $prodCase) { $fail1.Add('production 3363-glass-bridge missing') }
else {
  if ([string]$prodCase.company.ticker -ne [string]$Contract.ticker) { $fail1.Add("ticker=$($prodCase.company.ticker)") }
  if ([string]$prodCase.thesisId -ne [string]$Contract.thesisId) { $fail1.Add("thesisId=$($prodCase.thesisId)") }
  $rids = @($prodCase.researchIds)
  if ($rids -notcontains $Contract.researchId) { $fail1.Add('production case missing glass-bridge researchId') }
}
if ($Workflow -notlike '*renderInvestmentCase*') { $fail1.Add('Investment Case renderer missing') }
Add-TestResult 'TEST 1' ($fail1.Count -eq 0) ($fail1 -join "`n")

$fail2 = New-Object System.Collections.Generic.List[string]
if ($SectionFn -notlike ('*' + $Contract.emptyLabel + '*')) { $fail2.Add('empty Decision label missing') }
if ($SectionFn -notlike '*data-decision-empty*') { $fail2.Add('empty Decision marker missing') }
if ($SectionFn -notlike '*Investment Decision*') { $fail2.Add('Investment Decision heading missing') }
$decisionAt = $CaseFn.IndexOf('renderDecisionSection')
$valuationAt = $CaseFn.IndexOf('renderValuationProfile')
if ($decisionAt -lt 0 -or $valuationAt -lt 0 -or $decisionAt -gt $valuationAt) {
  $fail2.Add('Investment Decision is rendered below Valuation, so it is not visible')
}
Add-TestResult 'TEST 2' ($fail2.Count -eq 0) ($fail2 -join "`n")

$fail3 = New-Object System.Collections.Generic.List[string]
if ($SectionFn -notlike '*data-case-decision-text*') { $fail3.Add('Decision input missing') }
if ($SectionFn -notlike '*data-case-decision-reason*') { $fail3.Add('Reason input missing') }
if ($SectionFn -notlike '*data-case-decision-status*') { $fail3.Add('Status input missing') }
if ($SectionFn -notlike '*Save Decision*') { $fail3.Add('Save Decision button missing') }
if ($BuildFn -notlike '*status*') { $fail3.Add('buildDecision does not persist status') }
Add-TestResult 'TEST 3' ($fail3.Count -eq 0) ($fail3 -join "`n")

try {
  Start-TempServer

  $tempCases = Join-Path $script:TempRoot 'data\investment-cases.json'
  $tempCard = Join-Path $script:TempRoot 'research\glass-bridge\card.json'
  $tempQueue = Join-Path $script:TempRoot 'data\research-queue.json'
  $tempRadar = Join-Path $script:TempRoot 'data\opportunity-radar.json'
  $tempBrief = Join-Path $script:TempRoot 'data\morning-brief.json'
  $tempThesis = Join-Path $script:TempRoot 'data\theses\cpo-glass-bridge.json'
  $cardBefore = Read-JsonFile $tempCard
  $cardHashBefore = (Get-FileHash -Path $tempCard -Algorithm SHA256).Hash
  $queueHashBefore = (Get-FileHash -Path $tempQueue -Algorithm SHA256).Hash
  $radarHashBefore = (Get-FileHash -Path $tempRadar -Algorithm SHA256).Hash
  $briefHashBefore = (Get-FileHash -Path $tempBrief -Algorithm SHA256).Hash
  $thesisHashBefore = (Get-FileHash -Path $tempThesis -Algorithm SHA256).Hash
  $historyBefore = @($cardBefore.PSObject.Properties.Name) -contains 'researchConclusionHistory'

  $loaded = Get-TempCase $Contract.caseId
  if (-not $loaded) { throw 'temp 3363-glass-bridge missing' }
  if ($null -ne $loaded.decision -and $loaded.decision -ne '') {
    throw 'temp fixture already has a Decision; 008-1 tests require an empty starting case'
  }

  $payload = @{
    id = $Contract.caseId
    decision = @{
      decision = $Contract.decision
      reason = $Contract.reason
      status = $Contract.status
    }
  }
  $saveHttp = Invoke-Post '/api/cases' $payload
  $fail4 = New-Object System.Collections.Generic.List[string]
  if ([int]$saveHttp.StatusCode -ne 200) {
    $fail4.Add("Save Decision HTTP $($saveHttp.StatusCode): $($saveHttp.Body)")
  }
  Add-TestResult 'TEST 4' ($fail4.Count -eq 0) ($fail4 -join "`n")

  $reloaded = Get-TempCase $Contract.caseId
  $fail5 = New-Object System.Collections.Generic.List[string]
  if (-not $reloaded) { $fail5.Add('reloaded case missing') }
  elseif ($null -eq $reloaded.decision) { $fail5.Add('Decision missing after reload') }
  else {
    if ([string]$reloaded.decision.decision -ne [string]$Contract.decision) { $fail5.Add("decision=$($reloaded.decision.decision)") }
    if ([string]$reloaded.decision.reason -ne [string]$Contract.reason) { $fail5.Add("reason=$($reloaded.decision.reason)") }
    if ([string]$reloaded.decision.status -ne [string]$Contract.status) { $fail5.Add("status=$($reloaded.decision.status)") }
    if (-not $reloaded.decision.asOf) { $fail5.Add('asOf missing after save') }
  }
  Add-TestResult 'TEST 5' ($fail5.Count -eq 0) ($fail5 -join "`n")

  $cardAfter = Read-JsonFile $tempCard
  $fail6 = New-Object System.Collections.Generic.List[string]
  if ((Get-FileHash -Path $tempCard -Algorithm SHA256).Hash -ne $cardHashBefore) { $fail6.Add('Decision save modified Research Card') }
  $conclusionBefore = $null
  $conclusionAfter = $null
  if ($cardBefore.researchConclusion) { $conclusionBefore = [string]$cardBefore.researchConclusion.conclusion }
  if ($cardAfter.researchConclusion) { $conclusionAfter = [string]$cardAfter.researchConclusion.conclusion }
  if ($conclusionAfter -ne $conclusionBefore) { $fail6.Add('Decision save modified researchConclusion') }
  Add-TestResult 'TEST 6' ($fail6.Count -eq 0) ($fail6 -join "`n")

  $fail7 = New-Object System.Collections.Generic.List[string]
  $historyAfter = @($cardAfter.PSObject.Properties.Name) -contains 'researchConclusionHistory'
  if ($historyAfter -ne $historyBefore) { $fail7.Add('Decision save wrote researchConclusionHistory') }
  if ($SaveFn -like '*researchConclusionHistory*') { $fail7.Add('saveCaseDecision writes researchConclusionHistory') }
  Add-TestResult 'TEST 7' ($fail7.Count -eq 0) ($fail7 -join "`n")

  $fail8 = New-Object System.Collections.Generic.List[string]
  if ($SaveFn -like '*recheck.json*') { $fail8.Add('saveCaseDecision writes recheck.json') }
  if ($LoadEvidenceFn -like '*saveCaseDecision*') { $fail8.Add('loadLatestEvidence saves Decision') }
  if ($RecheckFn -like '*saveCaseDecision*') { $fail8.Add('Evidence Recheck saves Decision') }
  if ($ResearchFn -like '*saveCaseDecision*') { $fail8.Add('renderResearch saves Decision') }
  Add-TestResult 'TEST 8' ($fail8.Count -eq 0) ($fail8 -join "`n")

  $fail9 = New-Object System.Collections.Generic.List[string]
  if ((Get-FileHash -Path $tempQueue -Algorithm SHA256).Hash -ne $queueHashBefore) { $fail9.Add('Decision save modified Queue') }
  if ((Get-FileHash -Path $tempRadar -Algorithm SHA256).Hash -ne $radarHashBefore) { $fail9.Add('Decision save modified Radar') }
  if ((Get-FileHash -Path $tempBrief -Algorithm SHA256).Hash -ne $briefHashBefore) { $fail9.Add('Decision save modified Morning Brief / Today') }
  if ((Get-FileHash -Path $tempThesis -Algorithm SHA256).Hash -ne $thesisHashBefore) { $fail9.Add('Decision save modified Thesis') }
  Add-TestResult 'TEST 9' ($fail9.Count -eq 0) ($fail9 -join "`n")

  $fail10 = New-Object System.Collections.Generic.List[string]
  if ($SectionFn -like '*暫不建立部位*') { $fail10.Add('empty UI hardcodes a fake Decision') }
  if ($SectionFn -notlike '*data-decision-empty*') { $fail10.Add('empty state marker missing') }
  if ($RecordFn -notlike "*if (!this.isPersistedDecision(decision)) return '';*") { $fail10.Add('record renderer does not hide empty Decision') }
  if ($prodCase -and $null -ne $prodCase.decision -and $prodCase.decision -ne '') {
    $fail10.Add('production 3363 already has a Decision; 008-1 must not invent one in UI when none exists')
  }
  Add-TestResult 'TEST 10' ($fail10.Count -eq 0) ($fail10 -join "`n")
}
finally {
  Stop-TempServer
  if (Test-Path $script:TempRoot) {
    Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}

$guardOk = (
  (Get-FileHash -Path $ProdBriefPath -Algorithm SHA256).Hash -eq $ProdHashBefore.brief -and
  (Get-FileHash -Path $ProdQueuePath -Algorithm SHA256).Hash -eq $ProdHashBefore.queue -and
  (Get-FileHash -Path $ProdIndexPath -Algorithm SHA256).Hash -eq $ProdHashBefore.index -and
  (Get-FileHash -Path $RadarPath -Algorithm SHA256).Hash -eq $ProdHashBefore.radar -and
  (Get-FileHash -Path $ProdCasesPath -Algorithm SHA256).Hash -eq $ProdHashBefore.cases -and
  (Get-FileHash -Path $ThesisPath -Algorithm SHA256).Hash -eq $ProdHashBefore.thesis -and
  (Get-FileHash -Path $EnginePath -Algorithm SHA256).Hash -eq $ProdHashBefore.engine -and
  (Get-FileHash -Path $WorkflowPath -Algorithm SHA256).Hash -eq $ProdHashBefore.workflow -and
  (Get-FileHash -Path $KnowledgePath -Algorithm SHA256).Hash -eq $ProdHashBefore.knowledge -and
  (Get-FileHash -Path $CollectPath -Algorithm SHA256).Hash -eq $ProdHashBefore.collect -and
  (Get-FileHash -Path $GeneratePath -Algorithm SHA256).Hash -eq $ProdHashBefore.generate -and
  (Get-FileHash -Path $ServePath -Algorithm SHA256).Hash -eq $ProdHashBefore.serve -and
  (Get-FileHash -Path $AppPath -Algorithm SHA256).Hash -eq $ProdHashBefore.app -and
  (Get-FileHash -Path $IndexPath -Algorithm SHA256).Hash -eq $ProdHashBefore.html -and
  (Get-FileHash -Path $GlassCardPath -Algorithm SHA256).Hash -eq $ProdHashBefore.glass -and
  (Get-FileHash -Path $HbmCardPath -Algorithm SHA256).Hash -eq $ProdHashBefore.hbm -and
  (Get-FileHash -Path $CpoCardPath -Algorithm SHA256).Hash -eq $ProdHashBefore.cpo -and
  (Get-FileHash -Path $FauCardPath -Algorithm SHA256).Hash -eq $ProdHashBefore.fau
)
Add-TestResult 'TEST 11' $guardOk $(if ($guardOk) { '' } else { 'production files were modified' })
Add-TestResult 'PRODUCTION_FILE_GUARD' $guardOk $(if ($guardOk) { '' } else { 'production files were modified' })

$failed = @($script:Results | Where-Object { $_.Status -ne 'PASS' })
Write-Output ''
Write-Output '=== 008-1 SUMMARY ==='
foreach ($row in $script:Results) {
  Write-Output ("{0}: {1}" -f $row.Id, $row.Status)
  if ($row.Status -ne 'PASS' -and $row.Details) { Write-Output $row.Details }
}
if ($failed.Count -gt 0) { exit 1 }
exit 0
