$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$env:PYTHONIOENCODING = 'utf-8'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$FixturePath = Join-Path $PSScriptRoot 'fixtures\007-1-evidence-recheck.json'
$CollectPy = Join-Path $RepoRoot 'scripts\collect-evidence.py'
$WorkflowPath = Join-Path $RepoRoot 'js\workflow-engine.js'
$EnginePath = Join-Path $RepoRoot 'js\data-engine.js'
$KnowledgePath = Join-Path $RepoRoot 'js\knowledge-engine.js'
$GeneratePath = Join-Path $RepoRoot 'scripts\generate-morning-brief.py'
$ServePath = Join-Path $RepoRoot 'serve.ps1'
$AppPath = Join-Path $RepoRoot 'app.js'
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
$CollectSrc = [System.IO.File]::ReadAllText($CollectPy, $Utf8)
$Python = if ($env:INVESTORTWIN_PYTHON) { $env:INVESTORTWIN_PYTHON } else { 'python' }

$ProdHashBefore = @{
  brief = (Get-FileHash -Path $ProdBriefPath -Algorithm SHA256).Hash
  queue = (Get-FileHash -Path $ProdQueuePath -Algorithm SHA256).Hash
  index = (Get-FileHash -Path $ProdIndexPath -Algorithm SHA256).Hash
  engine = (Get-FileHash -Path $EnginePath -Algorithm SHA256).Hash
  workflow = (Get-FileHash -Path $WorkflowPath -Algorithm SHA256).Hash
  knowledge = (Get-FileHash -Path $KnowledgePath -Algorithm SHA256).Hash
  generate = (Get-FileHash -Path $GeneratePath -Algorithm SHA256).Hash
  serve = (Get-FileHash -Path $ServePath -Algorithm SHA256).Hash
  app = (Get-FileHash -Path $AppPath -Algorithm SHA256).Hash
  glass = (Get-FileHash -Path $GlassCardPath -Algorithm SHA256).Hash
  hbm = (Get-FileHash -Path $HbmCardPath -Algorithm SHA256).Hash
  cpo = (Get-FileHash -Path $CpoCardPath -Algorithm SHA256).Hash
  fau = (Get-FileHash -Path $FauCardPath -Algorithm SHA256).Hash
}

$script:Results = New-Object System.Collections.Generic.List[object]
$script:TempRoot = Join-Path $env:TEMP ('InvestorTwin-0071-' + [guid]::NewGuid().ToString('N'))

function Add-TestResult($id, $passed, $details) {
  $status = if ($passed) { 'PASS' } else { 'FAIL' }
  $script:Results.Add([PSCustomObject]@{ Id = $id; Status = $status; Details = $details })
  Write-Output ("{0}: {1}" -f $id, $status)
  if ($details) { Write-Output $details }
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

function New-CollectRoot($name) {
  $path = Join-Path $script:TempRoot $name
  New-Item -ItemType Directory -Path (Join-Path $path 'data\theses') -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $path 'data\evidence') -Force | Out-Null
  return $path
}

function Write-Card($root, $id, $thesisId, $conclusionAsOf) {
  $dir = Join-Path $root ("research\" + $id)
  New-Item -ItemType Directory -Path $dir -Force | Out-Null
  $card = [ordered]@{
    id = $id
    thesisId = $thesisId
    title = $id
    status = 'researching'
    updated = $Contract.conclusionAsOf
  }
  if ($null -ne $conclusionAsOf) {
    $card.researchConclusion = [ordered]@{
      conclusion = 'fixture conclusion'
      status = 'uncertain'
      asOf = $conclusionAsOf
    }
  }
  Write-JsonFile (Join-Path $dir 'card.json') $card
  return (Join-Path $dir 'card.json')
}

function Write-Notes($root, $id, $asOf) {
  Write-JsonFile (Join-Path $root ("research\" + $id + "\notes.json")) @{
    notes = @(@{ date = $asOf; text = 'fixture note' })
  }
}

function Write-Thesis($root, $thesisId, $supporting, $contradicting, $linked) {
  Write-JsonFile (Join-Path $root ("data\theses\" + $thesisId + ".json")) ([ordered]@{
    thesisId = $thesisId
    supportingEvidence = @($supporting | ForEach-Object { @{ instrument = $_ } })
    contradictingEvidence = @($contradicting | ForEach-Object { @{ instrument = $_ } })
    linkedResearch = @($linked | ForEach-Object { @{ researchId = $_ } })
  })
}

function Write-Input($root, $raw) {
  $path = Join-Path $root 'input.json'
  Write-JsonFile $path ([ordered]@{
    capturedAt = $Contract.capturedAt
    expectedAsOf = $Contract.expectedAsOf
    raw = @($raw)
  })
  return $path
}

function Invoke-Collect($root, $inputPath) {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $out = & $Python $CollectPy --root $root --input $inputPath 2>&1
    return @{
      ExitCode = [int]$LASTEXITCODE
      Text = (($out | ForEach-Object { "$_" }) -join "`n")
    }
  } finally {
    $ErrorActionPreference = $prev
  }
}

function Get-RunDir($root, $text) {
  if ($text -match 'runDir=(.+)') { return $Matches[1].Trim() }
  $runs = Join-Path $root 'data\evidence\runs'
  $dirs = @(Get-ChildItem -Path $runs -Directory -ErrorAction SilentlyContinue | Sort-Object Name)
  if ($dirs.Count -lt 1) { return $null }
  return $dirs[-1].FullName
}

function Get-SoxRaw($asOf, $status) {
  if ($status -eq 'unavailable') {
    return @{ sourceId = 'us-index-sox'; status = 'unavailable'; error = 'fixture unavailable' }
  }
  return @{
    sourceId = 'us-index-sox'
    status = 'ok'
    payload = @{
      observations = @(
        @{ date = '2026-08-17'; value = 5100.00 }
        @{ date = $asOf; value = 5164.75 }
      )
    }
  }
}

$fail0 = New-Object System.Collections.Generic.List[string]
if ($CollectSrc -notlike '*def recheck_research(*') { $fail0.Add('recheck_research missing') }
if ($CollectSrc -notlike '*recheck.json*') { $fail0.Add('recheck.json write missing') }
if ($CollectSrc -notlike '*is_valued_record(*') { $fail0.Add('valued-instrument gate missing') }
if ($CollectSrc -notlike '*conclusionImpact*') { $fail0.Add('conclusionImpact missing') }
if ($CollectSrc -notlike '*UNKNOWN*') { $fail0.Add('UNKNOWN impact missing') }
if ($CollectSrc -like '*nextStatus(*') { $fail0.Add('collector started calling nextStatus') }
if ($CollectSrc -like '*researchConclusionHistory*') { $fail0.Add('collector writes researchConclusionHistory') }
Add-TestResult 'TEST 0' ($fail0.Count -eq 0) ($fail0 -join "`n")

try {
  New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null

  $newer = New-CollectRoot 'newer-sox'
  Write-Thesis $newer $Contract.thesisId @('SOX') @() @($Contract.researchId)
  $newerCard = Write-Card $newer $Contract.researchId $Contract.thesisId $Contract.conclusionAsOf
  Write-Notes $newer $Contract.researchId $Contract.notesAsOf
  $newerCardBefore = (Get-FileHash -Path $newerCard -Algorithm SHA256).Hash
  $newerNotesBefore = (Get-FileHash -Path (Join-Path $newer ("research\" + $Contract.researchId + "\notes.json")) -Algorithm SHA256).Hash
  $newerIn = Write-Input $newer @(Get-SoxRaw $Contract.newerAsOf 'ok')
  $newerCollect = Invoke-Collect $newer $newerIn
  $newerRun = Get-RunDir $newer $newerCollect.Text
  $fail1 = New-Object System.Collections.Generic.List[string]
  if ($newerCollect.ExitCode -ne 0) { $fail1.Add("newer SOX collect failed: $($newerCollect.Text)") }
  if (-not $newerRun) { $fail1.Add('newer SOX run missing') }
  else {
    $recheckPath = Join-Path $newerRun 'recheck.json'
    if (-not (Test-Path $recheckPath)) { $fail1.Add('recheck.json missing') }
    else {
      $recheck = Read-JsonFile $recheckPath
      if ($recheck.writesResearch -ne $false) { $fail1.Add('recheck writesResearch is not false') }
      if ($recheck.writesBrief -ne $false) { $fail1.Add('recheck writesBrief is not false') }
      $hit = @($recheck.items | Where-Object { $_.researchId -eq $Contract.researchId -and $_.instrument -eq 'SOX' })
      if ($hit.Count -ne 1) { $fail1.Add("expected 1 SOX recheck item, got $($hit.Count)") }
      else {
        $row = $hit[0]
        if ($row.needsReview -ne $true) { $fail1.Add('newer SOX did not set needsReview') }
        if ([string]$row.conclusionImpact -ne [string]$Contract.conclusionImpact) { $fail1.Add("conclusionImpact=$($row.conclusionImpact)") }
        if ([string]$row.relation -ne 'supporting') { $fail1.Add("relation=$($row.relation)") }
        if ([string]$row.evidenceAsOf -ne [string]$Contract.newerAsOf) { $fail1.Add("evidenceAsOf=$($row.evidenceAsOf)") }
        if ([string]$row.anchorKind -ne 'researchConclusion') { $fail1.Add("anchorKind=$($row.anchorKind)") }
      }
    }
    if ((Get-FileHash -Path $newerCard -Algorithm SHA256).Hash -ne $newerCardBefore) {
      $fail1.Add('recheck modified temp card.json')
    }
    if ((Get-FileHash -Path (Join-Path $newer ("research\" + $Contract.researchId + "\notes.json")) -Algorithm SHA256).Hash -ne $newerNotesBefore) {
      $fail1.Add('recheck modified temp notes.json')
    }
    $hist = Join-Path $newer ("research\" + $Contract.researchId + "\card.json")
    $cardAfter = Read-JsonFile $hist
    if (@($cardAfter.PSObject.Properties.Name) -contains 'researchConclusionHistory') {
      $fail1.Add('recheck wrote researchConclusionHistory onto the card')
    }
  }
  Add-TestResult 'TEST 1' ($fail1.Count -eq 0) ($fail1 -join "`n")

  $unrelated = New-CollectRoot 'unrelated-taiex'
  Write-Thesis $unrelated $Contract.thesisId @('SOX') @() @($Contract.researchId)
  Write-Card $unrelated $Contract.researchId $Contract.thesisId $Contract.conclusionAsOf | Out-Null
  $taiexIn = Write-Input $unrelated @(@{
    sourceId = 'twse-taiex'
    status = 'ok'
    payload = @{ observations = @(@{ date = $Contract.newerAsOf; value = 45224.29 }) }
  })
  $taiexCollect = Invoke-Collect $unrelated $taiexIn
  $taiexRun = Get-RunDir $unrelated $taiexCollect.Text
  $fail2 = New-Object System.Collections.Generic.List[string]
  if ($taiexCollect.ExitCode -ne 0) { $fail2.Add("TAIEX collect failed: $($taiexCollect.Text)") }
  elseif (-not $taiexRun) { $fail2.Add('TAIEX run missing') }
  else {
    $items = @((Read-JsonFile (Join-Path $taiexRun 'recheck.json')).items)
    if ($items.Count -ne 0) { $fail2.Add('unrelated TAIEX created a recheck item') }
  }
  Add-TestResult 'TEST 2' ($fail2.Count -eq 0) ($fail2 -join "`n")

  $unavail = New-CollectRoot 'unavailable-sox'
  Write-Thesis $unavail $Contract.thesisId @('SOX') @() @($Contract.researchId)
  Write-Card $unavail $Contract.researchId $Contract.thesisId $Contract.conclusionAsOf | Out-Null
  $unavailIn = Write-Input $unavail @(Get-SoxRaw $Contract.newerAsOf 'unavailable')
  $unavailCollect = Invoke-Collect $unavail $unavailIn
  $unavailRun = Get-RunDir $unavail $unavailCollect.Text
  $fail3 = New-Object System.Collections.Generic.List[string]
  if ($unavailCollect.ExitCode -ne 0) { $fail3.Add("unavailable collect failed: $($unavailCollect.Text)") }
  elseif (-not $unavailRun) { $fail3.Add('unavailable run missing') }
  else {
    $items = @((Read-JsonFile (Join-Path $unavailRun 'recheck.json')).items)
    if ($items.Count -ne 0) { $fail3.Add('unavailable SOX created a recheck item') }
  }
  Add-TestResult 'TEST 3' ($fail3.Count -eq 0) ($fail3 -join "`n")

  $older = New-CollectRoot 'older-sox'
  Write-Thesis $older $Contract.thesisId @('SOX') @() @($Contract.researchId)
  Write-Card $older $Contract.researchId $Contract.thesisId $Contract.conclusionAsOf | Out-Null
  $olderIn = Write-Input $older @(Get-SoxRaw $Contract.olderAsOf 'ok')
  $olderCollect = Invoke-Collect $older $olderIn
  $olderRun = Get-RunDir $older $olderCollect.Text
  $fail4 = New-Object System.Collections.Generic.List[string]
  if ($olderCollect.ExitCode -ne 0) { $fail4.Add("older SOX collect failed: $($olderCollect.Text)") }
  elseif (-not $olderRun) { $fail4.Add('older SOX run missing') }
  else {
    $items = @((Read-JsonFile (Join-Path $olderRun 'recheck.json')).items)
    if ($items.Count -ne 0) { $fail4.Add('older SOX created a recheck item') }
  }
  Add-TestResult 'TEST 4' ($fail4.Count -eq 0) ($fail4 -join "`n")

  $empty = New-CollectRoot 'empty-thesis'
  Write-Thesis $empty $Contract.emptyThesisId @() @() @($Contract.researchId)
  Write-Card $empty $Contract.researchId $Contract.emptyThesisId $Contract.conclusionAsOf | Out-Null
  $emptyIn = Write-Input $empty @(Get-SoxRaw $Contract.newerAsOf 'ok')
  $emptyCollect = Invoke-Collect $empty $emptyIn
  $emptyRun = Get-RunDir $empty $emptyCollect.Text
  $fail5 = New-Object System.Collections.Generic.List[string]
  if ($emptyCollect.ExitCode -ne 0) { $fail5.Add("empty-thesis collect failed: $($emptyCollect.Text)") }
  elseif (-not $emptyRun) { $fail5.Add('empty-thesis run missing') }
  else {
    $items = @((Read-JsonFile (Join-Path $emptyRun 'recheck.json')).items)
    if ($items.Count -ne 0) { $fail5.Add('empty supportingEvidence created a recheck item') }
  }
  Add-TestResult 'TEST 5' ($fail5.Count -eq 0) ($fail5 -join "`n")

  $counter = New-CollectRoot 'counter-sox'
  Write-Thesis $counter $Contract.counterThesisId @() @('SOX') @($Contract.researchId)
  Write-Card $counter $Contract.researchId $Contract.counterThesisId $Contract.conclusionAsOf | Out-Null
  $counterIn = Write-Input $counter @(Get-SoxRaw $Contract.newerAsOf 'ok')
  $counterCollect = Invoke-Collect $counter $counterIn
  $counterRun = Get-RunDir $counter $counterCollect.Text
  $fail6 = New-Object System.Collections.Generic.List[string]
  if ($counterCollect.ExitCode -ne 0) { $fail6.Add("counter collect failed: $($counterCollect.Text)") }
  elseif (-not $counterRun) { $fail6.Add('counter run missing') }
  else {
    $hit = @((Read-JsonFile (Join-Path $counterRun 'recheck.json')).items)
    if ($hit.Count -ne 1) { $fail6.Add("expected 1 contradicting item, got $($hit.Count)") }
    elseif ([string]$hit[0].relation -ne 'contradicting') { $fail6.Add("relation=$($hit[0].relation)") }
    elseif ([string]$hit[0].conclusionImpact -ne 'UNKNOWN') { $fail6.Add('contradicting ref inferred conclusion impact') }
  }
  Add-TestResult 'TEST 6' ($fail6.Count -eq 0) ($fail6 -join "`n")

  $notesOnly = New-CollectRoot 'notes-only'
  Write-Thesis $notesOnly $Contract.thesisId @('SOX') @() @($Contract.notesOnlyId)
  Write-Card $notesOnly $Contract.notesOnlyId $Contract.thesisId $null | Out-Null
  Write-Notes $notesOnly $Contract.notesOnlyId $Contract.notesAsOf
  $notesIn = Write-Input $notesOnly @(Get-SoxRaw $Contract.newerAsOf 'ok')
  $notesCollect = Invoke-Collect $notesOnly $notesIn
  $notesRun = Get-RunDir $notesOnly $notesCollect.Text
  $fail7 = New-Object System.Collections.Generic.List[string]
  if ($notesCollect.ExitCode -ne 0) { $fail7.Add("notes-only collect failed: $($notesCollect.Text)") }
  elseif (-not $notesRun) { $fail7.Add('notes-only run missing') }
  else {
    $hit = @((Read-JsonFile (Join-Path $notesRun 'recheck.json')).items | Where-Object { $_.researchId -eq $Contract.notesOnlyId })
    if ($hit.Count -ne 1) { $fail7.Add("expected 1 notes-only item, got $($hit.Count)") }
    elseif ([string]$hit[0].anchorKind -ne 'notes') { $fail7.Add("anchorKind=$($hit[0].anchorKind)") }
    elseif ($hit[0].needsReview -ne $true) { $fail7.Add('notes-only did not set needsReview') }
  }
  Add-TestResult 'TEST 7' ($fail7.Count -eq 0) ($fail7 -join "`n")

  $noAnchor = New-CollectRoot 'no-anchor'
  Write-Thesis $noAnchor $Contract.thesisId @('SOX') @() @($Contract.unlinkedId)
  Write-Card $noAnchor $Contract.unlinkedId $Contract.thesisId $null | Out-Null
  $noAnchorIn = Write-Input $noAnchor @(Get-SoxRaw $Contract.newerAsOf 'ok')
  $noAnchorCollect = Invoke-Collect $noAnchor $noAnchorIn
  $noAnchorRun = Get-RunDir $noAnchor $noAnchorCollect.Text
  $fail8 = New-Object System.Collections.Generic.List[string]
  if ($noAnchorCollect.ExitCode -ne 0) { $fail8.Add("no-anchor collect failed: $($noAnchorCollect.Text)") }
  elseif (-not $noAnchorRun) { $fail8.Add('no-anchor run missing') }
  else {
    $items = @((Read-JsonFile (Join-Path $noAnchorRun 'recheck.json')).items)
    if ($items.Count -ne 0) { $fail8.Add('card without conclusion/notes created a recheck item') }
  }
  Add-TestResult 'TEST 8' ($fail8.Count -eq 0) ($fail8 -join "`n")
}
finally {
  if (Test-Path $script:TempRoot) {
    Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}

$guardOk = (
  (Get-FileHash -Path $ProdBriefPath -Algorithm SHA256).Hash -eq $ProdHashBefore.brief -and
  (Get-FileHash -Path $ProdQueuePath -Algorithm SHA256).Hash -eq $ProdHashBefore.queue -and
  (Get-FileHash -Path $ProdIndexPath -Algorithm SHA256).Hash -eq $ProdHashBefore.index -and
  (Get-FileHash -Path $EnginePath -Algorithm SHA256).Hash -eq $ProdHashBefore.engine -and
  (Get-FileHash -Path $WorkflowPath -Algorithm SHA256).Hash -eq $ProdHashBefore.workflow -and
  (Get-FileHash -Path $KnowledgePath -Algorithm SHA256).Hash -eq $ProdHashBefore.knowledge -and
  (Get-FileHash -Path $GeneratePath -Algorithm SHA256).Hash -eq $ProdHashBefore.generate -and
  (Get-FileHash -Path $ServePath -Algorithm SHA256).Hash -eq $ProdHashBefore.serve -and
  (Get-FileHash -Path $AppPath -Algorithm SHA256).Hash -eq $ProdHashBefore.app -and
  (Get-FileHash -Path $GlassCardPath -Algorithm SHA256).Hash -eq $ProdHashBefore.glass -and
  (Get-FileHash -Path $HbmCardPath -Algorithm SHA256).Hash -eq $ProdHashBefore.hbm -and
  (Get-FileHash -Path $CpoCardPath -Algorithm SHA256).Hash -eq $ProdHashBefore.cpo -and
  (Get-FileHash -Path $FauCardPath -Algorithm SHA256).Hash -eq $ProdHashBefore.fau
)
Add-TestResult 'TEST 9' $guardOk $(if ($guardOk) { '' } else { 'production files were modified' })
Add-TestResult 'PRODUCTION_FILE_GUARD' $guardOk $(if ($guardOk) { '' } else { 'production files were modified' })

$failed = @($script:Results | Where-Object { $_.Status -ne 'PASS' })
Write-Output ''
Write-Output '=== 007-1 SUMMARY ==='
foreach ($row in $script:Results) {
  Write-Output ("{0}: {1}" -f $row.Id, $row.Status)
  if ($row.Status -ne 'PASS' -and $row.Details) { Write-Output $row.Details }
}
if ($failed.Count -gt 0) { exit 1 }
exit 0
