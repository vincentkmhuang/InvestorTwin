$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$env:PYTHONIOENCODING = 'utf-8'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$CollectScript = Join-Path $RepoRoot 'scripts\collect-evidence.ps1'
$CollectPy = Join-Path $RepoRoot 'scripts\collect-evidence.py'
$ProdBriefPath = Join-Path $RepoRoot 'data\morning-brief.json'
$LatestPath = Join-Path $RepoRoot 'data\morning-brief\latest.json'
$ServePath = Join-Path $RepoRoot 'serve.ps1'
$QueuePath = Join-Path $RepoRoot 'data\research-queue.json'
$CasesPath = Join-Path $RepoRoot 'data\investment-cases.json'
$FixtureDir = Join-Path $PSScriptRoot 'fixtures'

$RequiredFixtures = @(
  '014-fred-observation-date.json',
  '014-fred-stale.json',
  '014-fred-trim.json',
  '014-twse-parser.json',
  '014-stooq-unavailable.json',
  '014-missing.json'
)
foreach ($name in $RequiredFixtures) {
  $path = Join-Path $FixtureDir $name
  if (-not (Test-Path $path)) { throw "Missing fixture: $path" }
}

$Utf8 = New-Object System.Text.UTF8Encoding $false
$ProdHashBefore = @{
  brief = (Get-FileHash -Path $ProdBriefPath -Algorithm SHA256).Hash
  latest = (Get-FileHash -Path $LatestPath -Algorithm SHA256).Hash
  serve = (Get-FileHash -Path $ServePath -Algorithm SHA256).Hash
  queue = (Get-FileHash -Path $QueuePath -Algorithm SHA256).Hash
  cases = (Get-FileHash -Path $CasesPath -Algorithm SHA256).Hash
}

$script:Results = New-Object System.Collections.Generic.List[object]
$script:TempRoot = Join-Path $env:TEMP ('InvestorTwin-014-' + [guid]::NewGuid().ToString('N'))

function Add-TestResult($id, $passed, $details) {
  $status = if ($passed) { 'PASS' } else { 'FAIL' }
  $script:Results.Add([PSCustomObject]@{ Id = $id; Status = $status; Details = $details })
  Write-Output ("{0}: {1}" -f $id, $status)
  if ($details) { Write-Output $details }
}

function Read-Json($path) {
  return ([System.IO.File]::ReadAllText($path, $Utf8) | ConvertFrom-Json)
}

function Invoke-Collect($inputPath, $rootPath, $expectedAsOf, $capturedAt) {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    if ($inputPath) {
      $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $CollectScript -InputPath $inputPath -RootPath $rootPath 2>&1
    } else {
      $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $CollectScript -RootPath $rootPath 2>&1
    }
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
  if ($dirs.Count -lt 1) { throw 'no evidence run directory' }
  return $dirs[-1].FullName
}

function New-SeedRoot($path) {
  New-Item -ItemType Directory -Path (Join-Path $path 'data\morning-brief') -Force | Out-Null
  Copy-Item $ProdBriefPath (Join-Path $path 'data\morning-brief.json')
  Copy-Item $LatestPath (Join-Path $path 'data\morning-brief\latest.json')
  Copy-Item $QueuePath (Join-Path $path 'data\research-queue.json')
  Copy-Item $CasesPath (Join-Path $path 'data\investment-cases.json')
}

function Invoke-IsolatedCollect($fixtureName) {
  $alt = Join-Path $env:TEMP ('InvestorTwin-014-' + $fixtureName + '-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $alt -Force | Out-Null
  New-SeedRoot $alt
  $beforeFiles = @(Get-ChildItem -Path $alt -Recurse -File | ForEach-Object { $_.FullName.Substring($alt.Length).TrimStart('\') })
  $result = Invoke-Collect (Join-Path $FixtureDir $fixtureName) $alt
  $run = $null
  if ($result.ExitCode -eq 0) { $run = Get-RunDir $alt $result.Text }
  $afterFiles = @(Get-ChildItem -Path $alt -Recurse -File | ForEach-Object { $_.FullName.Substring($alt.Length).TrimStart('\') })
  $newFiles = @($afterFiles | Where-Object { $beforeFiles -notcontains $_ })
  return @{
    ExitCode = $result.ExitCode
    Text = $result.Text
    Run = $run
    Root = $alt
    NewFiles = $newFiles
  }
}

function Assert-ProtectedHashes($failList) {
  if ((Get-FileHash -Path $ProdBriefPath -Algorithm SHA256).Hash -ne $ProdHashBefore.brief) {
    $failList.Add('production morning-brief.json was modified')
  }
  if ((Get-FileHash -Path $LatestPath -Algorithm SHA256).Hash -ne $ProdHashBefore.latest) {
    $failList.Add('production latest.json was modified')
  }
  if ((Get-FileHash -Path $QueuePath -Algorithm SHA256).Hash -ne $ProdHashBefore.queue) {
    $failList.Add('production research-queue.json was modified')
  }
  if ((Get-FileHash -Path $CasesPath -Algorithm SHA256).Hash -ne $ProdHashBefore.cases) {
    $failList.Add('production investment-cases.json was modified')
  }
  if ((Get-FileHash -Path $ServePath -Algorithm SHA256).Hash -ne $ProdHashBefore.serve) {
    $failList.Add('serve.ps1 was modified')
  }
}

function Assert-EvidenceOnlyWrites($pack, $failList) {
  foreach ($rel in $pack.NewFiles) {
    $unix = $rel -replace '\\', '/'
    if ($unix -notlike 'data/evidence/*') {
      $failList.Add('wrote outside data/evidence/: ' + $rel)
    }
  }
}

$datePack = $null
$stalePack = $null
$twsePack = $null
$unavailPack = $null
$missingPack = $null
$trimPack = $null

try {
  New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null

  $fail1 = New-Object System.Collections.Generic.List[string]
  $xorNone = Invoke-Collect $null $script:TempRoot
  if ($xorNone.ExitCode -eq 0) { $fail1.Add('missing both -InputPath and -Live should fail') }
  if ($xorNone.Text -notmatch 'InputPath|Live') { $fail1.Add('XOR neither-arg error text missing') }
  $bothPrev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  $bothOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $CollectScript -InputPath (Join-Path $FixtureDir '014-fred-observation-date.json') -Live -RootPath $script:TempRoot 2>&1
  $bothCode = [int]$LASTEXITCODE
  $ErrorActionPreference = $bothPrev
  $bothText = (($bothOut | ForEach-Object { "$_" }) -join "`n")
  if ($bothCode -eq 0) { $fail1.Add('-InputPath and -Live together should fail') }
  if ($bothText -notmatch 'either' -and $bothText -notmatch 'not both') { $fail1.Add('XOR both-arg error text missing') }
  Add-TestResult 'TEST 1' ($fail1.Count -eq 0) ($fail1 -join "`n")

  $datePack = Invoke-IsolatedCollect '014-fred-observation-date.json'
  $fail2 = New-Object System.Collections.Generic.List[string]
  if ($datePack.ExitCode -ne 0) { $fail2.Add("observation-date collect failed: $($datePack.Text)") }
  if ($datePack.Run) {
    $summary = Read-Json (Join-Path $datePack.Run 'run.json')
    $norm = Read-Json (Join-Path $datePack.Run 'normalized\US10Y.json')
    if ($summary.expectedAsOf -ne '2026-08-23') { $fail2.Add("expectedAsOf=$($summary.expectedAsOf) expected Sunday capturedAt calendar date 2026-08-23") }
    if ($summary.runId -ne 'run-20260823T062052Z') { $fail2.Add("runId=$($summary.runId) must come from capturedAt") }
    if ($summary.writesBrief -ne $false) { $fail2.Add('writesBrief must be false') }
    if ($norm.asOf -ne '2026-08-21') { $fail2.Add("asOf=$($norm.asOf) expected 2026-08-21 from observation_date") }
    if ($norm.asOf -eq '2026-08-23') { $fail2.Add('weekend capturedAt overwrote asOf') }
    if ($norm.status -ne 'stale') { $fail2.Add("status=$($norm.status) expected stale vs Sunday expectedAsOf") }
    if ([double]$norm.value -ne 4.73) { $fail2.Add("value=$($norm.value) expected 4.73") }
    if ([double]$norm.changeDoD -ne 0.03) { $fail2.Add("changeDoD=$($norm.changeDoD) expected 0.03") }
    if ([double]$norm.changeWoW -ne 0.13) { $fail2.Add("changeWoW=$($norm.changeWoW) expected 0.13") }
    if ([double]$norm.priorValue -ne 4.70) { $fail2.Add("priorValue=$($norm.priorValue) expected 4.70") }
  } else {
    $fail2.Add('observation-date run missing')
  }
  Add-TestResult 'TEST 2' ($fail2.Count -eq 0) ($fail2 -join "`n")

  $stalePack = Invoke-IsolatedCollect '014-fred-stale.json'
  $fail3 = New-Object System.Collections.Generic.List[string]
  if ($stalePack.ExitCode -ne 0) { $fail3.Add("stale collect failed: $($stalePack.Text)") }
  if ($stalePack.Run) {
    $stale = Read-Json (Join-Path $stalePack.Run 'normalized\US10Y.json')
    $staleRun = Read-Json (Join-Path $stalePack.Run 'run.json')
    if ($staleRun.expectedAsOf -ne '2026-08-23') { $fail3.Add('stale run expectedAsOf should be Sunday capturedAt calendar date') }
    if ($stale.status -ne 'stale') { $fail3.Add("expected stale, got $($stale.status)") }
    if ($stale.asOf -ne '2026-08-20') { $fail3.Add("stale asOf=$($stale.asOf) must stay 2026-08-20") }
    if ($stale.asOf -eq '2026-08-21') { $fail3.Add('stale asOf must not be rewritten to expectedAsOf') }
    if ([double]$stale.value -ne 4.69) { $fail3.Add("stale value=$($stale.value) expected 4.69") }
  } else {
    $fail3.Add('stale run missing')
  }
  Add-TestResult 'TEST 3' ($fail3.Count -eq 0) ($fail3 -join "`n")

  $twsePack = Invoke-IsolatedCollect '014-twse-parser.json'
  $fail4 = New-Object System.Collections.Generic.List[string]
  if ($twsePack.ExitCode -ne 0) { $fail4.Add("twse collect failed: $($twsePack.Text)") }
  if ($twsePack.Run) {
    $taiex = Read-Json (Join-Path $twsePack.Run 'normalized\TAIEX.json')
    if ([double]$taiex.value -ne 45224.29) { $fail4.Add("TAIEX=$($taiex.value) expected 45224.29") }
    if ($taiex.asOf -ne '2026-08-21') { $fail4.Add("TAIEX asOf=$($taiex.asOf)") }
    if ($taiex.status -ne 'stale') { $fail4.Add("TAIEX status=$($taiex.status) expected stale vs Sunday expectedAsOf") }
    if ([double]$taiex.value -eq 104381.91) { $fail4.Add('TAIEX used return index') }
  } else {
    $fail4.Add('twse run missing')
  }
  Add-TestResult 'TEST 4' ($fail4.Count -eq 0) ($fail4 -join "`n")

  $fail5 = New-Object System.Collections.Generic.List[string]
  if ($twsePack.Run) {
    $foreign = Read-Json (Join-Path $twsePack.Run 'normalized\TW_FOREIGN_NET.json')
    $trust = Read-Json (Join-Path $twsePack.Run 'normalized\TW_TRUST_NET.json')
    $dealer = Read-Json (Join-Path $twsePack.Run 'normalized\TW_DEALER_NET.json')
    if ([math]::Abs([double]$foreign.value - 283.05421) -gt 0.00001) { $fail5.Add("FOREIGN=$($foreign.value)") }
    if ([math]::Abs([double]$trust.value - 21.014631) -gt 0.00001) { $fail5.Add("TRUST=$($trust.value)") }
    if ([math]::Abs([double]$dealer.value - 29.095414) -gt 0.00001) { $fail5.Add("DEALER=$($dealer.value)") }
    if ([double]$dealer.value -eq 0) { $fail5.Add('DEALER used foreign-dealer row') }
    if ([string]$foreign.unit -ne 'TWD_hundred_million') { $fail5.Add('FOREIGN unit') }
    $rawText = [System.IO.File]::ReadAllText((Join-Path $twsePack.Run 'raw\twse-institutional.json'), $Utf8)
    if ($rawText.IndexOf('28,305,420,985') -lt 0) { $fail5.Add('raw lost original TWD') }
  } else {
    $fail5.Add('institutional run missing')
  }
  Add-TestResult 'TEST 5' ($fail5.Count -eq 0) ($fail5 -join "`n")

  $unavailPack = Invoke-IsolatedCollect '014-stooq-unavailable.json'
  $fail6 = New-Object System.Collections.Generic.List[string]
  if ($unavailPack.ExitCode -ne 0) { $fail6.Add("stooq collect failed: $($unavailPack.Text)") }
  if ($unavailPack.Run) {
    foreach ($name in @('Nasdaq', 'SPX', 'DJI', 'SOX')) {
      $norm = Read-Json (Join-Path $unavailPack.Run ("normalized\$name.json"))
      if ($norm.status -ne 'unavailable') { $fail6.Add("$name status=$($norm.status)") }
      if ($null -ne $norm.value) { $fail6.Add("$name invented value") }
      if ($null -ne $norm.asOf) { $fail6.Add("$name invented asOf") }
      $hist = Join-Path $unavailPack.Root ("data\evidence\history\$name")
      if (Test-Path $hist) { $fail6.Add("$name history written for unavailable") }
    }
    $raw = Read-Json (Join-Path $unavailPack.Run 'raw\us-index-nasdaq.json')
    if ($raw.status -ne 'unavailable') { $fail6.Add('raw nasdaq should be unavailable') }
    if ("$($raw.error)" -notmatch 'HTML challenge') { $fail6.Add('raw should record Stooq HTML challenge') }
  } else {
    $fail6.Add('stooq run missing')
  }
  Add-TestResult 'TEST 6' ($fail6.Count -eq 0) ($fail6 -join "`n")

  $missingPack = Invoke-IsolatedCollect '014-missing.json'
  $fail7 = New-Object System.Collections.Generic.List[string]
  if ($missingPack.ExitCode -ne 0) { $fail7.Add("missing collect failed: $($missingPack.Text)") }
  if ($missingPack.Run) {
    $missing = Read-Json (Join-Path $missingPack.Run 'normalized\TAIEX.json')
    if ($missing.status -ne 'missing') { $fail7.Add("expected missing, got $($missing.status)") }
    if ($null -ne $missing.value) { $fail7.Add('missing invented value') }
    if ($null -ne $missing.asOf) { $fail7.Add('missing invented asOf') }
    $missingHist = Join-Path $missingPack.Root 'data\evidence\history\TAIEX'
    if (Test-Path $missingHist) { $fail7.Add('missing wrote history') }
  } else {
    $fail7.Add('missing run missing')
  }
  Add-TestResult 'TEST 7' ($fail7.Count -eq 0) ($fail7 -join "`n")

  $trimPack = Invoke-IsolatedCollect '014-fred-trim.json'
  $fail8 = New-Object System.Collections.Generic.List[string]
  if ($trimPack.ExitCode -ne 0) { $fail8.Add("trim collect failed: $($trimPack.Text)") }
  if ($trimPack.Run) {
    $raw = Read-Json (Join-Path $trimPack.Run 'raw\fred-dgs10.json')
    $obs = @($raw.payload.observations)
    if ($obs.Count -ne 30) { $fail8.Add("raw observations=$($obs.Count) expected 30") }
    if ($obs[0].observation_date -eq '2026-07-06') { $fail8.Add('raw kept 1962-style full history start') }
    if ($obs[0].observation_date -ne '2026-07-11') { $fail8.Add("first kept=$($obs[0].observation_date) expected 2026-07-11") }
    $norm = Read-Json (Join-Path $trimPack.Run 'normalized\US10Y.json')
    if ($norm.asOf -ne '2026-08-09') { $fail8.Add("trim asOf=$($norm.asOf)") }
    if ($null -eq $norm.changeDoD) { $fail8.Add('trimmed payload should still compute DoD') }
    if ($null -eq $norm.changeWoW) { $fail8.Add('trimmed payload should still compute WoW') }
  } else {
    $fail8.Add('trim run missing')
  }
  Add-TestResult 'TEST 8' ($fail8.Count -eq 0) ($fail8 -join "`n")

  $fail9 = New-Object System.Collections.Generic.List[string]
  foreach ($pack in @($datePack, $stalePack, $twsePack, $unavailPack, $missingPack, $trimPack)) {
    if (-not $pack.Root) { continue }
    $briefNow = Get-FileHash -Path (Join-Path $pack.Root 'data\morning-brief.json') -Algorithm SHA256
    $latestNow = Get-FileHash -Path (Join-Path $pack.Root 'data\morning-brief\latest.json') -Algorithm SHA256
    $queueNow = Get-FileHash -Path (Join-Path $pack.Root 'data\research-queue.json') -Algorithm SHA256
    $casesNow = Get-FileHash -Path (Join-Path $pack.Root 'data\investment-cases.json') -Algorithm SHA256
    if ($briefNow.Hash -ne $ProdHashBefore.brief) { $fail9.Add('temp collect changed morning-brief.json') }
    if ($latestNow.Hash -ne $ProdHashBefore.latest) { $fail9.Add('temp collect changed latest.json') }
    if ($queueNow.Hash -ne $ProdHashBefore.queue) { $fail9.Add('temp collect changed research-queue.json') }
    if ($casesNow.Hash -ne $ProdHashBefore.cases) { $fail9.Add('temp collect changed investment-cases.json') }
    Assert-EvidenceOnlyWrites $pack $fail9
  }
  Assert-ProtectedHashes $fail9
  $src = [System.IO.File]::ReadAllText($CollectPy, $Utf8)
  if ($src -notmatch 'FORBIDDEN_WRITES') { $fail9.Add('collector missing FORBIDDEN_WRITES') }
  if ($src -notmatch 'refusing to write') { $fail9.Add('collector missing write refusal') }
  if ($src -notmatch 'writesBrief": False' -and $src -notmatch '"writesBrief": False') { $fail9.Add('writesBrief false missing') }
  Add-TestResult 'TEST 9' ($fail9.Count -eq 0) ($fail9 -join "`n")

  $fail10 = New-Object System.Collections.Generic.List[string]
  $briefRoot = Join-Path $env:TEMP ('InvestorTwin-014-brief-input-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $briefRoot -Force | Out-Null
  New-SeedRoot $briefRoot
  $briefInput = Invoke-Collect $ProdBriefPath $briefRoot
  if ($briefInput.ExitCode -eq 0) { $fail10.Add('InputPath=morning-brief.json must fail') }
  if ($briefInput.Text -notmatch 'Brief' -and $briefInput.Text -notmatch 'refusing to read') {
    $fail10.Add('Brief-as-input refusal text missing')
  }
  $briefAfter = Get-FileHash -Path $ProdBriefPath -Algorithm SHA256
  if ($briefAfter.Hash -ne $ProdHashBefore.brief) { $fail10.Add('Brief-as-input attempt changed production brief') }
  Assert-ProtectedHashes $fail10
  if (Test-Path $briefRoot) {
    Remove-Item -LiteralPath $briefRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
  Add-TestResult 'TEST 10' ($fail10.Count -eq 0) ($fail10 -join "`n")
}
finally {
  foreach ($pack in @($datePack, $stalePack, $twsePack, $unavailPack, $missingPack, $trimPack)) {
    if ($pack -and $pack.Root -and (Test-Path $pack.Root)) {
      Remove-Item -LiteralPath $pack.Root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
  if (Test-Path $script:TempRoot) {
    Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}

$failed = @($script:Results | Where-Object { $_.Status -ne 'PASS' })
Write-Output ''
Write-Output '=== 014 SUMMARY ==='
foreach ($row in $script:Results) {
  Write-Output ("{0}: {1}" -f $row.Id, $row.Status)
}
if ($failed.Count -gt 0) { exit 1 }
exit 0
