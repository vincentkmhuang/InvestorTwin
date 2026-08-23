$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$env:PYTHONIOENCODING = 'utf-8'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$FixturePath = Join-Path $PSScriptRoot 'fixtures\013-evidence-layer.json'
$CollectScript = Join-Path $RepoRoot 'scripts\collect-evidence.ps1'
$CollectPy = Join-Path $RepoRoot 'scripts\collect-evidence.py'
$ProdBriefPath = Join-Path $RepoRoot 'data\morning-brief.json'
$LatestPath = Join-Path $RepoRoot 'data\morning-brief\latest.json'
$ServePath = Join-Path $RepoRoot 'serve.ps1'
$QueuePath = Join-Path $RepoRoot 'data\research-queue.json'
$CasesPath = Join-Path $RepoRoot 'data\investment-cases.json'

if (-not (Test-Path $FixturePath)) { throw "Missing fixture: $FixturePath" }
if (-not (Test-Path $CollectScript)) { throw "Missing script: $CollectScript" }
if (-not (Test-Path $CollectPy)) { throw "Missing collector: $CollectPy" }

$Utf8 = New-Object System.Text.UTF8Encoding $false
$ProdHashBefore = @{
  brief = (Get-FileHash -Path $ProdBriefPath -Algorithm SHA256).Hash
  latest = (Get-FileHash -Path $LatestPath -Algorithm SHA256).Hash
  serve = (Get-FileHash -Path $ServePath -Algorithm SHA256).Hash
  queue = (Get-FileHash -Path $QueuePath -Algorithm SHA256).Hash
  cases = (Get-FileHash -Path $CasesPath -Algorithm SHA256).Hash
}

$script:Results = New-Object System.Collections.Generic.List[object]
$script:TempRoot = Join-Path $env:TEMP ('InvestorTwin-013-' + [guid]::NewGuid().ToString('N'))

function Add-TestResult($id, $passed, $details) {
  $status = if ($passed) { 'PASS' } else { 'FAIL' }
  $script:Results.Add([PSCustomObject]@{ Id = $id; Status = $status; Details = $details })
  Write-Output ("{0}: {1}" -f $id, $status)
  if ($details) { Write-Output $details }
}

function Read-Json($path) {
  return ([System.IO.File]::ReadAllText($path, $Utf8) | ConvertFrom-Json)
}

function Write-TempInput($name, $object) {
  $path = Join-Path $script:TempRoot $name
  $py = Join-Path $script:TempRoot 'write_json.py'
  $payloadPath = Join-Path $script:TempRoot ($name + '.src.json')
  [System.IO.File]::WriteAllText($payloadPath, ($object | ConvertTo-Json -Depth 40), $Utf8)
  [System.IO.File]::WriteAllText($py, "import json,sys`ndata=json.load(open(sys.argv[1],encoding='utf-8'))`njson.dump(data, open(sys.argv[2],'w',encoding='utf-8'), ensure_ascii=False, indent=2)`n", $Utf8)
  & python $py $payloadPath $path
  if ($LASTEXITCODE -ne 0) { throw 'write_json.py failed' }
  return $path
}

function Invoke-Collect($inputPath) {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $CollectScript -InputPath $inputPath -RootPath $script:TempRoot 2>&1
    return @{
      ExitCode = [int]$LASTEXITCODE
      Text = (($out | ForEach-Object { "$_" }) -join "`n")
    }
  } finally {
    $ErrorActionPreference = $prev
  }
}

function Get-RunDir($text) {
  if ($text -match 'runDir=(.+)') { return $Matches[1].Trim() }
  $runs = Join-Path $script:TempRoot 'data\evidence\runs'
  $dirs = @(Get-ChildItem -Path $runs -Directory -ErrorAction SilentlyContinue | Sort-Object Name)
  if ($dirs.Count -lt 1) { throw 'no evidence run directory' }
  return $dirs[-1].FullName
}

try {
  New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $script:TempRoot 'data\morning-brief') -Force | Out-Null
  Copy-Item $ProdBriefPath (Join-Path $script:TempRoot 'data\morning-brief.json')
  Copy-Item $LatestPath (Join-Path $script:TempRoot 'data\morning-brief\latest.json')

  $ok = Invoke-Collect $FixturePath
  $runDir = $null
  if ($ok.ExitCode -eq 0) { $runDir = Get-RunDir $ok.Text }
  $rawPath = if ($runDir) { Join-Path $runDir 'raw\fred-dgs10.json' } else { $null }
  $normPath = if ($runDir) { Join-Path $runDir 'normalized\US10Y.json' } else { $null }
  $fail1 = New-Object System.Collections.Generic.List[string]
  if ($ok.ExitCode -ne 0) { $fail1.Add("collect failed: $($ok.Text)") }
  if (-not $rawPath -or -not (Test-Path $rawPath)) { $fail1.Add('raw evidence file missing') }
  else {
    $raw = Read-Json $rawPath
    if (-not $raw.sourceId) { $fail1.Add('raw sourceId missing') }
    if (-not $raw.capturedAt) { $fail1.Add('raw capturedAt missing') }
    if (-not $raw.source) { $fail1.Add('raw source missing') }
    if ($null -eq $raw.payload -and -not $raw.fileRef) { $fail1.Add('raw payload/fileRef missing') }
  }
  Add-TestResult 'TEST 1' ($fail1.Count -eq 0) ($fail1 -join "`n")

  $fail2 = New-Object System.Collections.Generic.List[string]
  if (-not $normPath -or -not (Test-Path $normPath)) { $fail2.Add('normalized evidence file missing') }
  else {
    $norm = Read-Json $normPath
    if (-not $norm.instrument) { $fail2.Add('instrument missing') }
    if (-not $norm.sourceId) { $fail2.Add('normalized sourceId missing') }
    if (-not $norm.asOf) { $fail2.Add('asOf missing') }
    if ($norm.asOf -ne '2026-08-21') { $fail2.Add("asOf=$($norm.asOf) expected 2026-08-21") }
    if ($null -eq $norm.value) { $fail2.Add('value missing on fresh fixture') }
    if ($norm.status -ne 'fresh') { $fail2.Add("status=$($norm.status) expected fresh") }
  }
  Add-TestResult 'TEST 2' ($fail2.Count -eq 0) ($fail2 -join "`n")

  $fail3 = New-Object System.Collections.Generic.List[string]
  if ($normPath -and (Test-Path $normPath)) {
    $norm = Read-Json $normPath
    if ($norm.asOf -eq '2026-08-23') { $fail3.Add('weekend capture overwrote asOf with Sunday') }
    if ($norm.capturedAt -notlike '2026-08-23*') { $fail3.Add('capturedAt should stay Sunday fetch time') }
    if ($norm.asOf -ne '2026-08-21') { $fail3.Add('Friday close must keep Friday asOf') }
    if ($norm.expectedAsOf -ne '2026-08-21') { $fail3.Add('expectedAsOf should be Friday, not Sunday') }
  } else {
    $fail3.Add('normalized US10Y missing')
  }
  $src = [System.IO.File]::ReadAllText($CollectPy, $Utf8)
  $ps1 = [System.IO.File]::ReadAllText($CollectScript, $Utf8)
  if ($src -match 'asOf\s*=\s*datetime\.date\.today') { $fail3.Add('python overwrites asOf with date.today()') }
  if ($ps1 -match 'Get-Date.*asOf' -or $ps1 -match 'asOf.*Get-Date') { $fail3.Add('PowerShell overwrites asOf with Get-Date') }
  Add-TestResult 'TEST 3' ($fail3.Count -eq 0) ($fail3 -join "`n")

  $fail4 = New-Object System.Collections.Generic.List[string]
  if ($normPath -and (Test-Path $normPath)) {
    $fresh = Read-Json $normPath
    if ([double]$fresh.changeDoD -ne 0.03) { $fail4.Add("changeDoD=$($fresh.changeDoD) expected 0.03 from 4.70→4.73") }
    if ([double]$fresh.changeWoW -ne 0.13) { $fail4.Add("changeWoW=$($fresh.changeWoW) expected 0.13 from 4.60→4.73") }
    if ([double]$fresh.priorValue -ne 4.70) { $fail4.Add("priorValue=$($fresh.priorValue) expected 4.70") }
    if ($fresh.changeDoDStatus -ne 'ok') { $fail4.Add('changeDoDStatus should be ok') }
    if ($fresh.changeWoWStatus -ne 'ok') { $fail4.Add('changeWoWStatus should be ok') }
  } else {
    $fail4.Add('normalized US10Y missing')
  }
  Add-TestResult 'TEST 4' ($fail4.Count -eq 0) ($fail4 -join "`n")

  $staleFixture = Read-Json $FixturePath
  $staleFixture.raw = @(
    [PSCustomObject]@{
      sourceId = 'fred-dgs10'
      status = 'ok'
      payload = [PSCustomObject]@{
        observations = @(
          [PSCustomObject]@{ date = '2026-08-14'; value = 4.60 }
        )
      }
    }
  )
  $stalePath = Write-TempInput 'stale.json' $staleFixture
  $staleRootKeep = $script:TempRoot
  $staleAlt = Join-Path $env:TEMP ('InvestorTwin-013-stale-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $staleAlt -Force | Out-Null
  $script:TempRoot = $staleAlt
  $staleResult = Invoke-Collect $stalePath
  $staleRun = if ($staleResult.ExitCode -eq 0) { Get-RunDir $staleResult.Text } else { $null }
  $fail5 = New-Object System.Collections.Generic.List[string]
  if ($staleResult.ExitCode -ne 0) { $fail5.Add("stale collect failed: $($staleResult.Text)") }
  if ($staleRun) {
    $staleNorm = Read-Json (Join-Path $staleRun 'normalized\US10Y.json')
    if ($staleNorm.status -ne 'stale') { $fail5.Add("expected stale, got $($staleNorm.status)") }
    if ($staleNorm.asOf -ne '2026-08-14') { $fail5.Add('stale asOf must stay the real source date') }
    if ($staleNorm.asOf -eq '2026-08-21') { $fail5.Add('stale record must not pretend to be expectedAsOf') }
    if ($null -eq $staleNorm.value) { $fail5.Add('stale should keep the real older value') }
  }
  $script:TempRoot = $staleRootKeep
  Remove-Item -LiteralPath $staleAlt -Recurse -Force -ErrorAction SilentlyContinue
  Add-TestResult 'TEST 5' ($fail5.Count -eq 0) ($fail5 -join "`n")

  $missingFixture = Read-Json $FixturePath
  $missingFixture.raw = @(
    [PSCustomObject]@{
      sourceId = 'twse-taiex'
      status = 'ok'
      payload = [PSCustomObject]@{ observations = @() }
    }
  )
  $unavailFixture = Read-Json $FixturePath
  $unavailFixture.raw = @(
    [PSCustomObject]@{
      sourceId = 'us-index-sox'
      status = 'unavailable'
      payload = $null
      error = 'source not reachable'
    }
  )
  $thinFixture = Read-Json $FixturePath
  $thinFixture.raw = @(
    [PSCustomObject]@{
      sourceId = 'fred-dgs30'
      status = 'ok'
      payload = [PSCustomObject]@{
        observations = @(
          [PSCustomObject]@{ date = '2026-08-21'; value = 5.27 }
        )
      }
    }
  )
  $missingPath = Write-TempInput 'missing.json' $missingFixture
  $unavailPath = Write-TempInput 'unavailable.json' $unavailFixture
  $thinPath = Write-TempInput 'thin.json' $thinFixture

  function Invoke-IsolatedCollect($inputPath, $label) {
    $alt = Join-Path $env:TEMP ('InvestorTwin-013-' + $label + '-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $alt -Force | Out-Null
    $previous = $script:TempRoot
    $script:TempRoot = $alt
    try {
      $result = Invoke-Collect $inputPath
      $run = $null
      if ($result.ExitCode -eq 0) { $run = Get-RunDir $result.Text }
      return @{ ExitCode = $result.ExitCode; Text = $result.Text; Run = $run; Root = $alt }
    } finally {
      $script:TempRoot = $previous
    }
  }

  $missingPack = Invoke-IsolatedCollect $missingPath 'missing'
  $unavailPack = Invoke-IsolatedCollect $unavailPath 'unavailable'
  $thinPack = Invoke-IsolatedCollect $thinPath 'thin'

  $fail6 = New-Object System.Collections.Generic.List[string]
  if ($missingPack.ExitCode -ne 0) { $fail6.Add("missing collect failed: $($missingPack.Text)") }
  if ($unavailPack.ExitCode -ne 0) { $fail6.Add("unavailable collect failed: $($unavailPack.Text)") }
  if ($thinPack.ExitCode -ne 0) { $fail6.Add("thin collect failed: $($thinPack.Text)") }
  if ($missingPack.Run) {
    $missingNorm = Read-Json (Join-Path $missingPack.Run 'normalized\TAIEX.json')
    if ($missingNorm.status -ne 'missing') { $fail6.Add("expected missing, got $($missingNorm.status)") }
    if ($null -ne $missingNorm.value) { $fail6.Add('missing must not invent a value') }
    if ($null -ne $missingNorm.asOf) { $fail6.Add('missing must not invent asOf') }
    $missingHist = Join-Path $missingPack.Root 'data\evidence\history\TAIEX'
    if (Test-Path $missingHist) { $fail6.Add('missing must not write history') }
  }
  if ($unavailPack.Run) {
    $unavailNorm = Read-Json (Join-Path $unavailPack.Run 'normalized\SOX.json')
    $unavailRaw = Read-Json (Join-Path $unavailPack.Run 'raw\us-index-sox.json')
    if ($unavailNorm.status -ne 'unavailable') { $fail6.Add("expected unavailable, got $($unavailNorm.status)") }
    if ($null -ne $unavailNorm.value) { $fail6.Add('unavailable must not invent a value') }
    if ($unavailRaw.status -ne 'unavailable') { $fail6.Add('raw status should record unavailable') }
  }
  if ($thinPack.Run) {
    $thinNorm = Read-Json (Join-Path $thinPack.Run 'normalized\US30Y.json')
    if ($thinNorm.status -ne 'fresh') { $fail6.Add("thin series should still be fresh, got $($thinNorm.status)") }
    if ($null -ne $thinNorm.changeDoD) { $fail6.Add('DoD must be null without history') }
    if ($null -ne $thinNorm.changeWoW) { $fail6.Add('WoW must be null without history') }
    if ($thinNorm.changeDoDStatus -ne 'unavailable') { $fail6.Add('DoD status should be unavailable without history') }
    if ($thinNorm.changeWoWStatus -ne 'unavailable') { $fail6.Add('WoW status should be unavailable without history') }
  }
  Remove-Item -LiteralPath $missingPack.Root -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $unavailPack.Root -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $thinPack.Root -Recurse -Force -ErrorAction SilentlyContinue
  Add-TestResult 'TEST 6' ($fail6.Count -eq 0) ($fail6 -join "`n")

  $fail7 = New-Object System.Collections.Generic.List[string]
  $tempBrief = Get-FileHash -Path (Join-Path $script:TempRoot 'data\morning-brief.json') -Algorithm SHA256
  $tempLatest = Get-FileHash -Path (Join-Path $script:TempRoot 'data\morning-brief\latest.json') -Algorithm SHA256
  $prodBriefNow = Get-FileHash -Path $ProdBriefPath -Algorithm SHA256
  if ($tempBrief.Hash -ne $ProdHashBefore.brief) { $fail7.Add('temp collect changed copied morning-brief.json') }
  if ($tempLatest.Hash -ne $ProdHashBefore.latest) { $fail7.Add('temp collect changed copied latest.json') }
  if ($prodBriefNow.Hash -ne $ProdHashBefore.brief) { $fail7.Add('production morning-brief.json was modified') }
  if ((Get-FileHash -Path $LatestPath -Algorithm SHA256).Hash -ne $ProdHashBefore.latest) { $fail7.Add('production latest.json was modified') }
  Add-TestResult 'TEST 7' ($fail7.Count -eq 0) ($fail7 -join "`n")

  $fail8 = New-Object System.Collections.Generic.List[string]
  if ((Get-FileHash -Path $ServePath -Algorithm SHA256).Hash -ne $ProdHashBefore.serve) { $fail8.Add('serve.ps1 was modified') }
  if ((Get-FileHash -Path $QueuePath -Algorithm SHA256).Hash -ne $ProdHashBefore.queue) { $fail8.Add('research-queue.json was modified') }
  if ((Get-FileHash -Path $CasesPath -Algorithm SHA256).Hash -ne $ProdHashBefore.cases) { $fail8.Add('investment-cases.json was modified') }
  if ($src -match 'morning-brief\.json') {
    if ($src -notmatch 'FORBIDDEN_WRITES' -and $src -notmatch 'refusing to write') {
      $fail8.Add('collector should not write morning-brief.json')
    }
  }
  Add-TestResult 'TEST 8' ($fail8.Count -eq 0) ($fail8 -join "`n")

  $twseFixture = Join-Path $PSScriptRoot 'fixtures\013-twse-parser.json'
  $twsePack = Invoke-IsolatedCollect $twseFixture 'twse-parser'
  $fail9 = New-Object System.Collections.Generic.List[string]
  if ($twsePack.ExitCode -ne 0) { $fail9.Add("twse parser collect failed: $($twsePack.Text)") }
  if ($twsePack.Run) {
    $taiex = Read-Json (Join-Path $twsePack.Run 'normalized\TAIEX.json')
    if ([double]$taiex.value -ne 45224.29) { $fail9.Add("TAIEX=$($taiex.value) expected 45224.29") }
    if ($taiex.asOf -ne '2026-08-21') { $fail9.Add("TAIEX asOf=$($taiex.asOf) expected 2026-08-21") }
    if ($taiex.status -ne 'fresh') { $fail9.Add("TAIEX status=$($taiex.status) expected fresh") }
    if ([double]$taiex.value -eq 104381.91) { $fail9.Add('TAIEX incorrectly used return index') }
  } else {
    $fail9.Add('twse parser run missing')
  }
  Add-TestResult 'TEST 9' ($fail9.Count -eq 0) ($fail9 -join "`n")

  $fail10 = New-Object System.Collections.Generic.List[string]
  if ($twsePack.Run) {
    $foreign = Read-Json (Join-Path $twsePack.Run 'normalized\TW_FOREIGN_NET.json')
    $trust = Read-Json (Join-Path $twsePack.Run 'normalized\TW_TRUST_NET.json')
    $dealer = Read-Json (Join-Path $twsePack.Run 'normalized\TW_DEALER_NET.json')
    $rawInst = Read-Json (Join-Path $twsePack.Run 'raw\twse-institutional.json')
    $foreignVal = [double]$foreign.value
    $trustVal = [double]$trust.value
    $dealerVal = [double]$dealer.value
    if ([math]::Abs($foreignVal - 283.05421) -gt 0.00001) { $fail10.Add("FOREIGN=$foreignVal expected 283.05421") }
    if ([math]::Abs($trustVal - 21.014631) -gt 0.00001) { $fail10.Add("TRUST=$trustVal expected 21.014631") }
    if ([math]::Abs($dealerVal - 29.095414) -gt 0.00001) { $fail10.Add("DEALER=$dealerVal expected 29.095414") }
    if ($dealerVal -eq 0) { $fail10.Add('DEALER was overwritten by foreign dealer row') }
    $hundredMillion = 'TWD_hundred_million'
    if ([string]$foreign.unit -ne $hundredMillion) { $fail10.Add("FOREIGN unit=$([string]$foreign.unit)") }
    if ([string]$trust.unit -ne $hundredMillion) { $fail10.Add("TRUST unit=$([string]$trust.unit)") }
    if ([string]$dealer.unit -ne $hundredMillion) { $fail10.Add("DEALER unit=$([string]$dealer.unit)") }
    $rawPath = Join-Path $twsePack.Run 'raw\twse-institutional.json'
    $rawText = [System.IO.File]::ReadAllText($rawPath, $Utf8)
    if ($rawText.IndexOf('28,305,420,985') -lt 0) {
      $fail10.Add('raw institutional payload lost original TWD amount')
    }
  } else {
    $fail10.Add('twse parser run missing')
  }
  if ($twsePack.Root) {
    Remove-Item -LiteralPath $twsePack.Root -Recurse -Force -ErrorAction SilentlyContinue
  }
  Add-TestResult 'TEST 10' ($fail10.Count -eq 0) ($fail10 -join "`n")
}
finally {
  if (Test-Path $script:TempRoot) {
    Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}

$failed = @($script:Results | Where-Object { $_.Status -ne 'PASS' })
Write-Output ''
Write-Output '=== 013 SUMMARY ==='
foreach ($row in $script:Results) {
  Write-Output ("{0}: {1}" -f $row.Id, $row.Status)
}
if ($failed.Count -gt 0) { exit 1 }
exit 0
