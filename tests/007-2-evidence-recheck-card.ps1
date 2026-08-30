$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$RepoRoot = Split-Path -Parent $PSScriptRoot
$FixturePath = Join-Path $PSScriptRoot 'fixtures\007-2-evidence-recheck-card.json'
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
$ThesisPath = Join-Path $RepoRoot 'data\theses\ai-dram.json'
$GlassCardPath = Join-Path $RepoRoot 'research\glass-bridge\card.json'
$HbmCardPath = Join-Path $RepoRoot 'research\hbm\card.json'
$CpoCardPath = Join-Path $RepoRoot 'research\cpo\card.json'
$FauCardPath = Join-Path $RepoRoot 'research\fau\card.json'

if (-not (Test-Path $FixturePath)) { throw "Missing fixture: $FixturePath" }

$Utf8 = New-Object System.Text.UTF8Encoding $false
$Contract = [System.IO.File]::ReadAllText($FixturePath, $Utf8) | ConvertFrom-Json
$Workflow = [System.IO.File]::ReadAllText($WorkflowPath, $Utf8)
$ServeSrc = [System.IO.File]::ReadAllText($ServePath, $Utf8)
$CollectSrc = [System.IO.File]::ReadAllText($CollectPath, $Utf8)

$ProdHashBefore = @{
  brief = (Get-FileHash -Path $ProdBriefPath -Algorithm SHA256).Hash
  queue = (Get-FileHash -Path $ProdQueuePath -Algorithm SHA256).Hash
  index = (Get-FileHash -Path $ProdIndexPath -Algorithm SHA256).Hash
  radar = (Get-FileHash -Path $RadarPath -Algorithm SHA256).Hash
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
$script:TempRoot = Join-Path $env:TEMP ('InvestorTwin-0072-' + [guid]::NewGuid().ToString('N'))
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

function Write-Recheck($runId, $items) {
  $dir = Join-Path $script:TempRoot ("data\evidence\runs\" + $runId)
  New-Item -ItemType Directory -Path $dir -Force | Out-Null
  Write-JsonFile (Join-Path $dir 'recheck.json') ([ordered]@{
    runId = $runId
    writesBrief = $false
    writesResearch = $false
    items = @($items)
  })
}

function New-RecheckItem($researchId, $needsReview) {
  return [ordered]@{
    researchId = $researchId
    thesisId = $Contract.thesisId
    instrument = $Contract.instrument
    evidenceAsOf = $Contract.evidenceAsOf
    conclusionImpact = $Contract.conclusionImpact
    needsReview = $needsReview
  }
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
  Copy-Item $ThesisPath (Join-Path $script:TempRoot 'data\theses\ai-dram.json')
  Copy-Item $ProdQueuePath (Join-Path $script:TempRoot 'data\research-queue.json')
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

function Get-RecheckFromApi {
  $http = Invoke-Get '/api/evidence'
  if ([int]$http.StatusCode -ne 200) {
    throw "GET /api/evidence HTTP $($http.StatusCode): $($http.Body)"
  }
  return ($http.Body | ConvertFrom-Json)
}

$LoadFn = Get-MethodText $Workflow 'loadLatestEvidence'
$FilterFn = Get-MethodText $Workflow 'researchRecheckItems'
$RenderFn = Get-MethodText $Workflow 'renderEvidenceRecheck'
$ResearchFn = Get-MethodText $Workflow 'renderResearch'
$GetRecheckFn = Get-MethodText $ServeSrc 'Get-LatestRecheck'
if (-not $GetRecheckFn) {
  $idx = $ServeSrc.IndexOf('function Get-LatestRecheck(')
  if ($idx -ge 0) {
    $brace = $ServeSrc.IndexOf('{', $idx)
    $depth = 0
    for ($i = $brace; $i -lt $ServeSrc.Length; $i++) {
      if ($ServeSrc[$i] -eq '{') { $depth++ }
      elseif ($ServeSrc[$i] -eq '}') {
        $depth--
        if ($depth -eq 0) { $GetRecheckFn = $ServeSrc.Substring($idx, $i - $idx + 1); break }
      }
    }
  }
}

$failShow = New-Object System.Collections.Generic.List[string]
if ($RenderFn -notlike '*data-evidence-recheck*') { $failShow.Add('renderEvidenceRecheck missing data-evidence-recheck') }
if ($RenderFn -notlike '*Evidence Recheck*') { $failShow.Add('renderEvidenceRecheck missing Evidence Recheck heading') }
if ($RenderFn -notlike '*Needs Review*') { $failShow.Add('renderEvidenceRecheck missing Needs Review') }
if ($RenderFn -notlike '*Evidence As Of*') { $failShow.Add('renderEvidenceRecheck missing Evidence As Of') }
if ($RenderFn -notlike '*Instrument*') { $failShow.Add('renderEvidenceRecheck missing Instrument') }
if ($RenderFn -notlike '*conclusionImpact*') { $failShow.Add('renderEvidenceRecheck missing conclusionImpact') }
if ($FilterFn -notlike '*needsReview === true*') { $failShow.Add('researchRecheckItems does not require needsReview === true') }
if ($ResearchFn -notlike '*researchRecheckItems(card.id*') { $failShow.Add('renderResearch does not look up this card recheck') }
if ($ResearchFn -notlike '*renderEvidenceRecheck(recheckItems)*') { $failShow.Add('renderResearch does not render Evidence Recheck') }
if ($LoadFn -notlike '*recheck*') { $failShow.Add('loadLatestEvidence does not return recheck') }
if ($ServeSrc -notlike '*function Get-LatestRecheck*') { $failShow.Add('serve.ps1 missing Get-LatestRecheck') }
if ($ServeSrc -notlike '*,"recheck":*') { $failShow.Add('GET /api/evidence does not append recheck') }
if ($GetRecheckFn -notlike '*Sort-Object Name -Descending*') { $failShow.Add('Get-LatestRecheck does not walk latest run first') }
if ($GetRecheckFn -notlike '*recheck.json*') { $failShow.Add('Get-LatestRecheck does not read recheck.json') }
Add-TestResult 'TEST 1' ($failShow.Count -eq 0) ($failShow -join "`n")

$failHideFalse = New-Object System.Collections.Generic.List[string]
if ($FilterFn -notlike '*needsReview === true*') { $failHideFalse.Add('false needsReview is not filtered out') }
if ($RenderFn -notlike "*if (!list.length) return '';*") { $failHideFalse.Add('empty recheck list does not return empty markup') }
if ($RenderFn -like '*No Evidence Recheck*') { $failHideFalse.Add('placeholder text for missing recheck') }
Add-TestResult 'TEST 2' ($failHideFalse.Count -eq 0) ($failHideFalse -join "`n")

$failHideNone = New-Object System.Collections.Generic.List[string]
if ($LoadFn -notlike '*data?.recheck?.items*') { $failHideNone.Add('loadLatestEvidence does not read recheck.items') }
if ($RenderFn -notlike "*if (!list.length) return '';*") { $failHideNone.Add('no-recheck path still renders a block') }
if ($ResearchFn -like '*Evidence Recheck placeholder*') { $failHideNone.Add('renderResearch has a recheck placeholder') }
Add-TestResult 'TEST 3' ($failHideNone.Count -eq 0) ($failHideNone -join "`n")

$failNoWrite = New-Object System.Collections.Generic.List[string]
foreach ($fn in @($LoadFn, $FilterFn, $RenderFn)) {
  if ($fn -like '*saveResearchConclusion*') { $failNoWrite.Add('recheck path calls saveResearchConclusion') }
  if ($fn -like '*ensureInQueue*') { $failNoWrite.Add('recheck path calls ensureInQueue') }
  if ($fn -like '*persistCaseThesisId*') { $failNoWrite.Add('recheck path calls persistCaseThesisId') }
  if ($fn -like '*saveCaseDecision*') { $failNoWrite.Add('recheck path calls saveCaseDecision') }
  if ($fn -like '*researchConclusionHistory*') { $failNoWrite.Add('recheck path writes researchConclusionHistory') }
}
if ($CollectSrc -like '*researchConclusionHistory*') { $failNoWrite.Add('collector started writing researchConclusionHistory') }
if ($GetRecheckFn -like '*Write-ResearchCardJson*') { $failNoWrite.Add('Get-LatestRecheck writes Research Card') }
if ($GetRecheckFn -like '*Write-ResearchQueue*') { $failNoWrite.Add('Get-LatestRecheck writes Queue') }
if ($GetRecheckFn -like '*Write-ThesisFile*') { $failNoWrite.Add('Get-LatestRecheck writes Thesis') }
Add-TestResult 'TEST 4' ($failNoWrite.Count -eq 0) ($failNoWrite -join "`n")

try {
  Start-TempServer

  $tempCard = Join-Path $script:TempRoot 'research\hbm\card.json'
  $tempQueue = Join-Path $script:TempRoot 'data\research-queue.json'
  $tempThesis = Join-Path $script:TempRoot 'data\theses\ai-dram.json'
  $cardBefore = (Get-FileHash -Path $tempCard -Algorithm SHA256).Hash
  $queueBefore = (Get-FileHash -Path $tempQueue -Algorithm SHA256).Hash
  $thesisBefore = (Get-FileHash -Path $tempThesis -Algorithm SHA256).Hash
  $cardObjBefore = [System.IO.File]::ReadAllText($tempCard, $Utf8) | ConvertFrom-Json
  $historyBefore = @($cardObjBefore.PSObject.Properties.Name) -contains 'researchConclusionHistory'
  $conclusionBefore = $null
  if ($cardObjBefore.researchConclusion) { $conclusionBefore = [string]$cardObjBefore.researchConclusion.conclusion }

  $emptyApi = Get-RecheckFromApi
  $failEmptyApi = New-Object System.Collections.Generic.List[string]
  if ($emptyApi.writesBrief -ne $false) { $failEmptyApi.Add('Evidence API writesBrief is not false') }
  if ($emptyApi.PSObject.Properties.Name -notcontains 'recheck') { $failEmptyApi.Add('Evidence API missing recheck') }
  elseif (@($emptyApi.recheck.items).Count -ne 0) { $failEmptyApi.Add('no-recheck run still returned items') }
  Add-TestResult 'TEST 5' ($failEmptyApi.Count -eq 0) ($failEmptyApi -join "`n")

  $olderDir = Join-Path $script:TempRoot ("data\evidence\runs\" + $Contract.olderRunId)
  New-Item -ItemType Directory -Path $olderDir -Force | Out-Null
  Write-Recheck $Contract.olderRunId @(New-RecheckItem 'should-not-win' $true)
  $missingDir = Join-Path $script:TempRoot ("data\evidence\runs\" + $Contract.newerMissingRunId)
  New-Item -ItemType Directory -Path $missingDir -Force | Out-Null
  $corruptDir = Join-Path $script:TempRoot ("data\evidence\runs\" + $Contract.newerCorruptRunId)
  New-Item -ItemType Directory -Path $corruptDir -Force | Out-Null
  [System.IO.File]::WriteAllText((Join-Path $corruptDir 'recheck.json'), '{', $Utf8)
  Write-Recheck $Contract.validRunId @(
    (New-RecheckItem $Contract.researchId $true),
    (New-RecheckItem $Contract.otherResearchId $false)
  )

  $reviewApi = Get-RecheckFromApi
  $failReviewApi = New-Object System.Collections.Generic.List[string]
  if ([string]$reviewApi.recheck.runId -ne [string]$Contract.validRunId) {
    $failReviewApi.Add("runId=$($reviewApi.recheck.runId)")
  }
  $hbmHit = @($reviewApi.recheck.items | Where-Object { $_.researchId -eq $Contract.researchId })
  if ($hbmHit.Count -ne 1) { $failReviewApi.Add("expected 1 hbm recheck item, got $($hbmHit.Count)") }
  else {
    if ($hbmHit[0].needsReview -ne $true) { $failReviewApi.Add('hbm needsReview is not true') }
    if ([string]$hbmHit[0].instrument -ne [string]$Contract.instrument) { $failReviewApi.Add("instrument=$($hbmHit[0].instrument)") }
    if ([string]$hbmHit[0].evidenceAsOf -ne [string]$Contract.evidenceAsOf) { $failReviewApi.Add("evidenceAsOf=$($hbmHit[0].evidenceAsOf)") }
    if ([string]$hbmHit[0].conclusionImpact -ne [string]$Contract.conclusionImpact) { $failReviewApi.Add("conclusionImpact=$($hbmHit[0].conclusionImpact)") }
  }
  $otherHit = @($reviewApi.recheck.items | Where-Object { $_.researchId -eq $Contract.otherResearchId })
  if ($otherHit.Count -ne 1) { $failReviewApi.Add('glass-bridge recheck item missing from latest valid run') }
  elseif ($otherHit[0].needsReview -ne $false) { $failReviewApi.Add('needsReview=false item was dropped from API') }
  if (@($reviewApi.recheck.items | Where-Object { $_.researchId -eq 'should-not-win' }).Count -ne 0) {
    $failReviewApi.Add('older recheck run leaked into latest valid payload')
  }
  Add-TestResult 'TEST 6' ($failReviewApi.Count -eq 0) ($failReviewApi -join "`n")

  Write-Recheck $Contract.validRunId @(New-RecheckItem $Contract.researchId $false)
  $falseApi = Get-RecheckFromApi
  $failFalseApi = New-Object System.Collections.Generic.List[string]
  $falseHit = @($falseApi.recheck.items | Where-Object { $_.researchId -eq $Contract.researchId })
  if ($falseHit.Count -ne 1) { $failFalseApi.Add('needsReview=false item missing from API') }
  elseif ($falseHit[0].needsReview -ne $false) { $failFalseApi.Add('needsReview=false was coerced') }
  Add-TestResult 'TEST 7' ($failFalseApi.Count -eq 0) ($failFalseApi -join "`n")

  $cardAfter = [System.IO.File]::ReadAllText($tempCard, $Utf8) | ConvertFrom-Json
  $failMutate = New-Object System.Collections.Generic.List[string]
  if ((Get-FileHash -Path $tempCard -Algorithm SHA256).Hash -ne $cardBefore) { $failMutate.Add('recheck GET modified card.json') }
  if ((Get-FileHash -Path $tempQueue -Algorithm SHA256).Hash -ne $queueBefore) { $failMutate.Add('recheck GET modified Queue') }
  if ((Get-FileHash -Path $tempThesis -Algorithm SHA256).Hash -ne $thesisBefore) { $failMutate.Add('recheck GET modified Thesis') }
  $historyAfter = @($cardAfter.PSObject.Properties.Name) -contains 'researchConclusionHistory'
  if ($historyAfter -ne $historyBefore) { $failMutate.Add('recheck GET wrote researchConclusionHistory') }
  $conclusionAfter = $null
  if ($cardAfter.researchConclusion) { $conclusionAfter = [string]$cardAfter.researchConclusion.conclusion }
  if ($conclusionAfter -ne $conclusionBefore) { $failMutate.Add('recheck GET modified researchConclusion') }
  Add-TestResult 'TEST 8' ($failMutate.Count -eq 0) ($failMutate -join "`n")
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
Add-TestResult 'PRODUCTION_FILE_GUARD' $guardOk $(if ($guardOk) { '' } else { 'production files were modified' })

$failed = @($script:Results | Where-Object { $_.Status -ne 'PASS' })
Write-Output ''
Write-Output '=== 007-2 SUMMARY ==='
foreach ($row in $script:Results) {
  Write-Output ("{0}: {1}" -f $row.Id, $row.Status)
  if ($row.Status -ne 'PASS' -and $row.Details) { Write-Output $row.Details }
}
if ($failed.Count -gt 0) { exit 1 }
exit 0
