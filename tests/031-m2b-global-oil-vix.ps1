$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$env:PYTHONIOENCODING = 'utf-8'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$FixturePath = Join-Path $PSScriptRoot 'fixtures\031-m2b-global-oil-vix.json'
$GenerateScript = Join-Path $RepoRoot 'scripts\generate-morning-brief.ps1'
$GeneratePy = Join-Path $RepoRoot 'scripts\generate-morning-brief.py'
$CollectPy = Join-Path $RepoRoot 'scripts\collect-evidence.py'
$ProdBriefPath = Join-Path $RepoRoot 'data\morning-brief.json'
$LatestPath = Join-Path $RepoRoot 'data\morning-brief\latest.json'
$ProdCasesPath = Join-Path $RepoRoot 'data\investment-cases.json'
$ProdQueuePath = Join-Path $RepoRoot 'data\research-queue.json'
$ThesesDir = Join-Path $RepoRoot 'data\theses'
$GlassCardPath = Join-Path $RepoRoot 'research\glass-bridge\card.json'
$HbmCardPath = Join-Path $RepoRoot 'research\hbm\card.json'
$CpoCardPath = Join-Path $RepoRoot 'research\cpo\card.json'
$FauCardPath = Join-Path $RepoRoot 'research\fau\card.json'

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
  collect = (Get-FileHash -Path $CollectPy -Algorithm SHA256).Hash
}

$Contract = [System.IO.File]::ReadAllText($FixturePath, $Utf8) | ConvertFrom-Json
$NotLatestLabel = [System.Text.Encoding]::UTF8.GetString([byte[]](0xE9, 0x9D, 0x9E, 0xE6, 0x9C, 0x80, 0xE6, 0x96, 0xB0))
$script:Results = New-Object System.Collections.Generic.List[object]
$script:TempRoot = Join-Path $env:TEMP ('InvestorTwin-031M2B-' + [guid]::NewGuid().ToString('N'))

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
  [System.IO.File]::WriteAllText($path, (($obj | ConvertTo-Json -Depth 20) + "`n"), $Utf8)
}

function Invoke-Generate($root) {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $GenerateScript -RootPath $root 2>&1
    return @{ ExitCode = [int]$LASTEXITCODE; Text = (($out | ForEach-Object { "$_" }) -join "`n") }
  } finally {
    $ErrorActionPreference = $prev
  }
}

function New-GenRoot($name) {
  $path = Join-Path $script:TempRoot $name
  New-Item -ItemType Directory -Path (Join-Path $path 'data\morning-brief') -Force | Out-Null
  Copy-Item $ProdBriefPath (Join-Path $path 'data\morning-brief.json')
  Copy-Item $LatestPath (Join-Path $path 'data\morning-brief\latest.json')
  Copy-Item $ProdQueuePath (Join-Path $path 'data\research-queue.json')
  Copy-Item $ProdCasesPath (Join-Path $path 'data\investment-cases.json')
  Copy-Item (Join-Path $RepoRoot 'data\opportunity-radar.json') (Join-Path $path 'data\opportunity-radar.json')
  foreach ($id in @('glass-bridge', 'fau', 'cpo', 'hbm')) {
    $dir = Join-Path $path ("research\" + $id)
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Copy-Item (Join-Path $RepoRoot ("research\" + $id + "\card.json")) (Join-Path $dir 'card.json')
  }
  return $path
}

function Write-Run($root, $runId, $expectedAsOf) {
  $runDir = Join-Path $root ("data\evidence\runs\" + $runId)
  New-Item -ItemType Directory -Path (Join-Path $runDir 'normalized') -Force | Out-Null
  Write-JsonFile (Join-Path $runDir 'run.json') ([ordered]@{
    runId = $runId
    capturedAt = '2026-08-25T18:00:00Z'
    expectedAsOf = $expectedAsOf
    writesBrief = $false
  })
}

function Write-Normalized($root, $runId, $row) {
  $dir = Join-Path $root ("data\evidence\runs\" + $runId + '\normalized')
  New-Item -ItemType Directory -Path $dir -Force | Out-Null
  Write-JsonFile (Join-Path $dir ($row.instrument + '.json')) $row
}

function Write-Commodity($root, $runId, $instrument, $sourceId, $unit, $value, $asOf, $expectedAsOf, $status) {
  Write-Normalized $root $runId ([ordered]@{
    instrument = $instrument
    value = $value
    unit = $unit
    asOf = $asOf
    asOfKind = 'close'
    expectedAsOf = $expectedAsOf
    sourceId = $sourceId
    status = $status
  })
}

function Get-GlobalBlob($brief) {
  $titles = @($brief.globalMarketAndNews.items | ForEach-Object { [string]$_.title })
  return ([string]$brief.globalMarketAndNews.summary + ' | ' + ($titles -join ' | '))
}

try {
  New-Item -ItemType Directory -Path $script:TempRoot | Out-Null
  $generateSrc = [System.IO.File]::ReadAllText($GeneratePy, $Utf8)
  $fail0 = New-Object System.Collections.Generic.List[string]
  if ($generateSrc -notlike '*"Brent"*') { $fail0.Add('Brent INSTRUMENT_MAP missing') }
  if ($generateSrc -notlike '*"WTI"*') { $fail0.Add('WTI INSTRUMENT_MAP missing') }
  if ($generateSrc -notlike '*"VIX"*') { $fail0.Add('VIX INSTRUMENT_MAP missing') }
  if ($generateSrc -notlike '*theme": "commodity"*') { $fail0.Add('commodity theme missing') }
  if ($generateSrc -notlike '*oil*' -and $generateSrc -notlike '*commodity_hits*') { $fail0.Add('commodity global item missing') }
  Add-TestResult 'TEST 0' ($fail0.Count -eq 0) ($fail0 -join "`n")

  $runDate = [string]$Contract.runDate
  $freshRoot = New-GenRoot 'fresh-oil'
  $queueBefore = (Get-FileHash -Path (Join-Path $freshRoot 'data\research-queue.json') -Algorithm SHA256).Hash
  $casesBefore = (Get-FileHash -Path (Join-Path $freshRoot 'data\investment-cases.json') -Algorithm SHA256).Hash
  $hbmBefore = (Get-FileHash -Path (Join-Path $freshRoot 'research\hbm\card.json') -Algorithm SHA256).Hash
  Write-Run $freshRoot 'run-20260825T180000Z' $runDate
  Write-Commodity $freshRoot 'run-20260825T180000Z' 'Brent' 'fred-brent' 'USD_per_barrel' 91.11 $runDate $runDate 'fresh'
  Write-Commodity $freshRoot 'run-20260825T180000Z' 'WTI' 'fred-wti' 'USD_per_barrel' 86.22 $runDate $runDate 'fresh'
  Write-Commodity $freshRoot 'run-20260825T180000Z' 'VIX' 'fred-vix' 'index' 14.33 $runDate $runDate 'fresh'
  $freshGen = Invoke-Generate $freshRoot
  $freshBrief = Read-JsonFile (Join-Path $freshRoot 'data\morning-brief.json')
  $freshBlob = Get-GlobalBlob $freshBrief
  $freshTitles = @($freshBrief.globalMarketAndNews.items | ForEach-Object { [string]$_.title })
  $fail1 = New-Object System.Collections.Generic.List[string]
  if ($freshGen.ExitCode -ne 0) { $fail1.Add("fresh generator failed: $($freshGen.Text)") }
  if ($freshBlob -notlike '*Brent*') { $fail1.Add('Brent missing from Global') }
  if ($freshBlob -notlike '*91.11*') { $fail1.Add('Brent value missing from Global') }
  if ($freshBlob -notlike '*WTI*') { $fail1.Add('WTI missing from Global') }
  if ($freshBlob -notlike '*86.22*') { $fail1.Add('WTI value missing from Global') }
  if ($freshBlob -notlike '*VIX*') { $fail1.Add('VIX missing from Global') }
  if ($freshBlob -notlike '*14.33*') { $fail1.Add('VIX value missing from Global') }
  if ($freshBlob -like ('*' + $NotLatestLabel + '*')) { $fail1.Add('same-day oil/VIX labeled not-latest') }
  if (-not ($freshTitles | Where-Object { $_ -like '*91.11*' -and $_ -like '*86.22*' -and $_ -like '*14.33*' })) {
    $fail1.Add('oil/VIX not grouped into a Global item')
  }
  if ($freshTitles | Where-Object { $_ -like '*US10Y*' -and $_ -like '*91.11*' }) {
    $fail1.Add('oil was mixed into the yields Global item')
  }
  Add-TestResult 'TEST 1' ($fail1.Count -eq 0) ($fail1 -join "`n")

  $datedRoot = New-GenRoot 'dated-oil'
  $datedAsOf = [string]$Contract.datedAsOf
  Write-Run $datedRoot 'run-20260825T180100Z' $runDate
  Write-Commodity $datedRoot 'run-20260825T180100Z' 'Brent' 'fred-brent' 'USD_per_barrel' 91.11 $datedAsOf $runDate 'stale'
  Write-Commodity $datedRoot 'run-20260825T180100Z' 'WTI' 'fred-wti' 'USD_per_barrel' 86.22 $datedAsOf $runDate 'stale'
  Write-Commodity $datedRoot 'run-20260825T180100Z' 'VIX' 'fred-vix' 'index' 14.33 $datedAsOf $runDate 'stale'
  $datedGen = Invoke-Generate $datedRoot
  $datedBrief = Read-JsonFile (Join-Path $datedRoot 'data\morning-brief.json')
  $datedBlob = Get-GlobalBlob $datedBrief
  $fail2 = New-Object System.Collections.Generic.List[string]
  if ($datedGen.ExitCode -ne 0) { $fail2.Add("dated generator failed: $($datedGen.Text)") }
  if ($datedBlob -notlike '*91.11*') { $fail2.Add('dated Brent value dropped') }
  if ($datedBlob -notlike ('*' + $datedAsOf + '*')) { $fail2.Add('dated asOf was not preserved') }
  if ($datedBlob -notlike ('*' + $NotLatestLabel + '*')) { $fail2.Add('dated oil/VIX missing not-latest label') }
  if ($datedBlob -like ('*' + $runDate + '*') -and $datedBlob -like '*Brent*' ) {
    if ($datedBlob -like ('*Brent*' + $runDate + '*') -or $datedBlob -like ('*asOf ' + $runDate + '*')) {
      $fail2.Add('dated asOf was rewritten to runDate')
    }
  }
  Add-TestResult 'TEST 2' ($fail2.Count -eq 0) ($fail2 -join "`n")

  $unavailRoot = New-GenRoot 'unavailable-oil'
  $poison = Read-JsonFile (Join-Path $unavailRoot 'data\morning-brief.json')
  $poison.globalMarketAndNews = [ordered]@{
    summary = 'Brent 99.99 from previous Brief'
    items = @([ordered]@{ title = 'WTI 88.88 from tmp'; source = 'Global'; researchId = $null })
  }
  Write-JsonFile (Join-Path $unavailRoot 'data\morning-brief.json') $poison
  Write-Run $unavailRoot 'run-20260825T180200Z' $runDate
  Write-Normalized $unavailRoot 'run-20260825T180200Z' ([ordered]@{
    instrument = 'US10Y'
    value = 4.55
    unit = 'percent'
    asOf = $runDate
    asOfKind = 'close'
    expectedAsOf = $runDate
    sourceId = 'fred-dgs10'
    status = 'fresh'
  })
  foreach ($row in @(
    @{ instrument = 'Brent'; unit = 'USD_per_barrel'; sourceId = 'fred-brent' },
    @{ instrument = 'WTI'; unit = 'USD_per_barrel'; sourceId = 'fred-wti' },
    @{ instrument = 'VIX'; unit = 'index'; sourceId = 'fred-vix' }
  )) {
    Write-Normalized $unavailRoot 'run-20260825T180200Z' ([ordered]@{
      instrument = $row.instrument
      value = $null
      unit = $row.unit
      asOf = $null
      asOfKind = 'close'
      expectedAsOf = $runDate
      sourceId = $row.sourceId
      status = 'unavailable'
    })
  }
  $unavailGen = Invoke-Generate $unavailRoot
  $unavailBrief = Read-JsonFile (Join-Path $unavailRoot 'data\morning-brief.json')
  $unavailBlob = Get-GlobalBlob $unavailBrief
  $fail3 = New-Object System.Collections.Generic.List[string]
  if ($unavailGen.ExitCode -ne 0) { $fail3.Add("unavailable generator failed: $($unavailGen.Text)") }
  if ($unavailBlob -like '*99.99*') { $fail3.Add('unavailable carried previous Brief Brent') }
  if ($unavailBlob -like '*88.88*') { $fail3.Add('unavailable carried tmp WTI') }
  if ($unavailBlob -like '*91.11*') { $fail3.Add('unavailable invented fixture Brent') }
  if ($unavailBlob -like '*Brent 99*') { $fail3.Add('unavailable kept poison Brent line') }
  Add-TestResult 'TEST 3' ($fail3.Count -eq 0) ($fail3 -join "`n")

  $missingRoot = New-GenRoot 'missing-oil'
  Write-Run $missingRoot 'run-20260825T180300Z' $runDate
  Write-Normalized $missingRoot 'run-20260825T180300Z' ([ordered]@{
    instrument = 'US10Y'
    value = 4.55
    unit = 'percent'
    asOf = $runDate
    asOfKind = 'close'
    expectedAsOf = $runDate
    sourceId = 'fred-dgs10'
    status = 'fresh'
  })
  foreach ($row in @(
    @{ instrument = 'Brent'; unit = 'USD_per_barrel'; sourceId = 'fred-brent' },
    @{ instrument = 'WTI'; unit = 'USD_per_barrel'; sourceId = 'fred-wti' },
    @{ instrument = 'VIX'; unit = 'index'; sourceId = 'fred-vix' }
  )) {
    Write-Normalized $missingRoot 'run-20260825T180300Z' ([ordered]@{
      instrument = $row.instrument
      value = $null
      unit = $row.unit
      asOf = $null
      asOfKind = 'close'
      expectedAsOf = $runDate
      sourceId = $row.sourceId
      status = 'missing'
    })
  }
  $missingGen = Invoke-Generate $missingRoot
  $missingBrief = Read-JsonFile (Join-Path $missingRoot 'data\morning-brief.json')
  $missingBlob = Get-GlobalBlob $missingBrief
  $fail4 = New-Object System.Collections.Generic.List[string]
  if ($missingGen.ExitCode -ne 0) { $fail4.Add("missing generator failed: $($missingGen.Text)") }
  if ($missingBlob -like '*91.11*') { $fail4.Add('missing invented Brent') }
  if ($missingBlob -like '*86.22*') { $fail4.Add('missing invented WTI') }
  if ($missingBlob -like '*14.33*') { $fail4.Add('missing invented VIX') }
  Add-TestResult 'TEST 4' ($fail4.Count -eq 0) ($fail4 -join "`n")

  $fail5 = New-Object System.Collections.Generic.List[string]
  foreach ($key in @($Contract.canonicalFields)) {
    if (-not ($freshBrief.PSObject.Properties.Name -contains $key)) { $fail5.Add("canonical field missing: $key") }
  }
  $extra = @($freshBrief.PSObject.Properties.Name | Where-Object { @($Contract.canonicalFields) -notcontains $_ -and $_ -ne '_selection' })
  if ($extra.Count -gt 0) { $fail5.Add('new Brief schema keys: ' + ($extra -join ',')) }
  if ((Get-FileHash -Path (Join-Path $freshRoot 'data\research-queue.json') -Algorithm SHA256).Hash -ne $queueBefore) {
    $fail5.Add('generator wrote Queue')
  }
  if ((Get-FileHash -Path (Join-Path $freshRoot 'data\investment-cases.json') -Algorithm SHA256).Hash -ne $casesBefore) {
    $fail5.Add('generator wrote Case / Decision / Playbook')
  }
  if ((Get-FileHash -Path (Join-Path $freshRoot 'research\hbm\card.json') -Algorithm SHA256).Hash -ne $hbmBefore) {
    $fail5.Add('generator wrote Research Card')
  }
  Add-TestResult 'TEST 5' ($fail5.Count -eq 0) ($fail5 -join "`n")
}
catch {
  Add-TestResult 'SETUP' $false $_.Exception.Message
}

if (Test-Path $script:TempRoot) {
  Remove-Item -Recurse -Force $script:TempRoot -ErrorAction SilentlyContinue
}

$failGuard = New-Object System.Collections.Generic.List[string]
if ((Get-FileHash -Path $ProdBriefPath -Algorithm SHA256).Hash -ne $ProdHashBefore.brief) { $failGuard.Add('production morning-brief.json changed') }
if ((Get-FileHash -Path $LatestPath -Algorithm SHA256).Hash -ne $ProdHashBefore.latest) { $failGuard.Add('production latest.json changed') }
if ((Get-FileHash -Path $ProdQueuePath -Algorithm SHA256).Hash -ne $ProdHashBefore.queue) { $failGuard.Add('production research-queue.json changed') }
if ((Get-FileHash -Path $ProdCasesPath -Algorithm SHA256).Hash -ne $ProdHashBefore.cases) { $failGuard.Add('production investment-cases.json / Decision / Playbook changed') }
if ((Get-FileHash -Path $GlassCardPath -Algorithm SHA256).Hash -ne $ProdHashBefore.glass) { $failGuard.Add('production glass-bridge card.json changed') }
if ((Get-FileHash -Path $HbmCardPath -Algorithm SHA256).Hash -ne $ProdHashBefore.hbm) { $failGuard.Add('production hbm card.json changed') }
if ((Get-FileHash -Path $CpoCardPath -Algorithm SHA256).Hash -ne $ProdHashBefore.cpo) { $failGuard.Add('production cpo card.json changed') }
if ((Get-FileHash -Path $FauCardPath -Algorithm SHA256).Hash -ne $ProdHashBefore.fau) { $failGuard.Add('production fau card.json changed') }
if ((Get-FileHash -Path (Join-Path $ThesesDir 'ai-dram.json') -Algorithm SHA256).Hash -ne $ProdHashBefore.dram) { $failGuard.Add('production ai-dram thesis changed') }
if ((Get-FileHash -Path (Join-Path $ThesesDir 'cpo-glass-bridge.json') -Algorithm SHA256).Hash -ne $ProdHashBefore.cpoThesis) { $failGuard.Add('production cpo-glass-bridge thesis changed') }
if ((Get-FileHash -Path $CollectPy -Algorithm SHA256).Hash -ne $ProdHashBefore.collect) { $failGuard.Add('collector source was modified') }
Add-TestResult 'PRODUCTION_FILE_GUARD' ($failGuard.Count -eq 0) ($failGuard -join "`n")

$failed = @($script:Results | Where-Object { $_.Status -ne 'PASS' })
Write-Output ''
Write-Output '=== 031-M-2B SUMMARY ==='
foreach ($row in $script:Results) {
  Write-Output ("{0}: {1}" -f $row.Id, $row.Status)
  if ($row.Status -ne 'PASS' -and $row.Details) { Write-Output $row.Details }
}
if ($failed.Count -gt 0) { exit 1 }
exit 0
