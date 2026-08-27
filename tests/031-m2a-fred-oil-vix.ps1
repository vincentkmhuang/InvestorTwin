$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$env:PYTHONIOENCODING = 'utf-8'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$CollectScript = Join-Path $RepoRoot 'scripts\collect-evidence.ps1'
$CollectPy = Join-Path $RepoRoot 'scripts\collect-evidence.py'
$UnitPy = Join-Path $PSScriptRoot '031-m2a-fred-oil-vix.py'
$FixtureDir = Join-Path $PSScriptRoot 'fixtures'
$ProdBriefPath = Join-Path $RepoRoot 'data\morning-brief.json'
$LatestPath = Join-Path $RepoRoot 'data\morning-brief\latest.json'
$QueuePath = Join-Path $RepoRoot 'data\research-queue.json'
$CasesPath = Join-Path $RepoRoot 'data\investment-cases.json'
$ThesesDir = Join-Path $RepoRoot 'data\theses'
$GlassCardPath = Join-Path $RepoRoot 'research\glass-bridge\card.json'
$HbmCardPath = Join-Path $RepoRoot 'research\hbm\card.json'
$CpoCardPath = Join-Path $RepoRoot 'research\cpo\card.json'
$FauCardPath = Join-Path $RepoRoot 'research\fau\card.json'
$GeneratePy = Join-Path $RepoRoot 'scripts\generate-morning-brief.py'
$UpdateScript = Join-Path $RepoRoot 'scripts\update-morning-brief.ps1'
$AppPath = Join-Path $RepoRoot 'app.js'
$IndexPath = Join-Path $RepoRoot 'index.html'

$RequiredFixtures = @(
  '031-m2a-fred-oil-vix-fresh.json',
  '031-m2a-fred-oil-vix-stale.json',
  '031-m2a-fred-oil-vix-unavailable.json'
)
foreach ($name in $RequiredFixtures) {
  $path = Join-Path $FixtureDir $name
  if (-not (Test-Path $path)) { throw "Missing fixture: $path" }
}
if (-not (Test-Path $UnitPy)) { throw "Missing unit test: $UnitPy" }

$Utf8 = New-Object System.Text.UTF8Encoding $false
$ProdHashBefore = @{
  brief = (Get-FileHash -Path $ProdBriefPath -Algorithm SHA256).Hash
  latest = (Get-FileHash -Path $LatestPath -Algorithm SHA256).Hash
  queue = (Get-FileHash -Path $QueuePath -Algorithm SHA256).Hash
  cases = (Get-FileHash -Path $CasesPath -Algorithm SHA256).Hash
  glass = (Get-FileHash -Path $GlassCardPath -Algorithm SHA256).Hash
  hbm = (Get-FileHash -Path $HbmCardPath -Algorithm SHA256).Hash
  cpo = (Get-FileHash -Path $CpoCardPath -Algorithm SHA256).Hash
  fau = (Get-FileHash -Path $FauCardPath -Algorithm SHA256).Hash
  dram = (Get-FileHash -Path (Join-Path $ThesesDir 'ai-dram.json') -Algorithm SHA256).Hash
  cpoThesis = (Get-FileHash -Path (Join-Path $ThesesDir 'cpo-glass-bridge.json') -Algorithm SHA256).Hash
  generate = (Get-FileHash -Path $GeneratePy -Algorithm SHA256).Hash
  update = (Get-FileHash -Path $UpdateScript -Algorithm SHA256).Hash
  app = (Get-FileHash -Path $AppPath -Algorithm SHA256).Hash
  index = (Get-FileHash -Path $IndexPath -Algorithm SHA256).Hash
}

$script:Results = New-Object System.Collections.Generic.List[object]
$script:TempRoot = Join-Path $env:TEMP ('InvestorTwin-031M2A-' + [guid]::NewGuid().ToString('N'))
$Names = @('Brent', 'WTI', 'VIX')
$SourceIds = @{
  Brent = 'fred-brent'
  WTI = 'fred-wti'
  VIX = 'fred-vix'
}
$FreshValues = @{
  Brent = 90.25
  WTI = 85.40
  VIX = 15.80
}

function Add-TestResult($id, $passed, $details) {
  $status = if ($passed) { 'PASS' } else { 'FAIL' }
  $script:Results.Add([PSCustomObject]@{ Id = $id; Status = $status; Details = $details })
  Write-Output ("{0}: {1}" -f $id, $status)
  if ($details) { Write-Output $details }
}

function Read-Json($path) {
  return ([System.IO.File]::ReadAllText($path, $Utf8) | ConvertFrom-Json)
}

function New-SeedRoot($path) {
  New-Item -ItemType Directory -Path (Join-Path $path 'data\morning-brief') -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $path 'data\theses') -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $path 'research\hbm') -Force | Out-Null
  Copy-Item $ProdBriefPath (Join-Path $path 'data\morning-brief.json')
  Copy-Item $LatestPath (Join-Path $path 'data\morning-brief\latest.json')
  Copy-Item $QueuePath (Join-Path $path 'data\research-queue.json')
  Copy-Item $CasesPath (Join-Path $path 'data\investment-cases.json')
  Copy-Item (Join-Path $ThesesDir 'ai-dram.json') (Join-Path $path 'data\theses\ai-dram.json')
  Copy-Item $HbmCardPath (Join-Path $path 'research\hbm\card.json')
}

function Invoke-Collect($inputPath, $rootPath) {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $CollectScript -InputPath $inputPath -RootPath $rootPath 2>&1
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

function Invoke-IsolatedCollect($fixtureName) {
  $alt = Join-Path $script:TempRoot ($fixtureName + '-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $alt -Force | Out-Null
  New-SeedRoot $alt
  $beforeFiles = @(Get-ChildItem -Path $alt -Recurse -File | ForEach-Object { $_.FullName.Substring($alt.Length).TrimStart('\') })
  $hashesBefore = @{
    brief = (Get-FileHash -Path (Join-Path $alt 'data\morning-brief.json') -Algorithm SHA256).Hash
    latest = (Get-FileHash -Path (Join-Path $alt 'data\morning-brief\latest.json') -Algorithm SHA256).Hash
    queue = (Get-FileHash -Path (Join-Path $alt 'data\research-queue.json') -Algorithm SHA256).Hash
    cases = (Get-FileHash -Path (Join-Path $alt 'data\investment-cases.json') -Algorithm SHA256).Hash
    thesis = (Get-FileHash -Path (Join-Path $alt 'data\theses\ai-dram.json') -Algorithm SHA256).Hash
    card = (Get-FileHash -Path (Join-Path $alt 'research\hbm\card.json') -Algorithm SHA256).Hash
  }
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
    HashesBefore = $hashesBefore
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

function Assert-NoLayerPollution($pack, $failList) {
  $root = $pack.Root
  $before = $pack.HashesBefore
  if ((Get-FileHash -Path (Join-Path $root 'data\morning-brief.json') -Algorithm SHA256).Hash -ne $before.brief) {
    $failList.Add('collect wrote morning-brief.json')
  }
  if ((Get-FileHash -Path (Join-Path $root 'data\morning-brief\latest.json') -Algorithm SHA256).Hash -ne $before.latest) {
    $failList.Add('collect wrote latest.json')
  }
  if ((Get-FileHash -Path (Join-Path $root 'data\research-queue.json') -Algorithm SHA256).Hash -ne $before.queue) {
    $failList.Add('collect wrote Queue')
  }
  if ((Get-FileHash -Path (Join-Path $root 'data\investment-cases.json') -Algorithm SHA256).Hash -ne $before.cases) {
    $failList.Add('collect wrote Case / Decision / Playbook')
  }
  if ((Get-FileHash -Path (Join-Path $root 'data\theses\ai-dram.json') -Algorithm SHA256).Hash -ne $before.thesis) {
    $failList.Add('collect wrote Thesis')
  }
  if ((Get-FileHash -Path (Join-Path $root 'research\hbm\card.json') -Algorithm SHA256).Hash -ne $before.card) {
    $failList.Add('collect wrote Research Card')
  }
}

$freshPack = $null
$stalePack = $null
$unavailPack = $null

try {
  New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null

  $freshPack = Invoke-IsolatedCollect '031-m2a-fred-oil-vix-fresh.json'
  $fail1 = New-Object System.Collections.Generic.List[string]
  if ($freshPack.ExitCode -ne 0) { $fail1.Add("fresh collect failed: $($freshPack.Text)") }
  if ($freshPack.Run) {
    $summary = Read-Json (Join-Path $freshPack.Run 'run.json')
    if ($summary.expectedAsOf -ne '2026-08-25') { $fail1.Add("expectedAsOf=$($summary.expectedAsOf)") }
    if ($summary.runId -ne 'run-20260825T180000Z') { $fail1.Add("runId=$($summary.runId)") }
    if ($summary.writesBrief -ne $false) { $fail1.Add('writesBrief must stay false') }
    $briefText = [System.IO.File]::ReadAllText((Join-Path $freshPack.Root 'data\morning-brief.json'), $Utf8)
    foreach ($name in $Names) {
      $norm = Read-Json (Join-Path $freshPack.Run ("normalized\$name.json"))
      $raw = Read-Json (Join-Path $freshPack.Run ("raw\$($SourceIds[$name]).json"))
      if ($norm.instrument -ne $name) { $fail1.Add("$name instrument=$($norm.instrument)") }
      if ($norm.status -ne 'fresh') { $fail1.Add("$name status=$($norm.status) expected fresh") }
      if ($norm.asOf -ne '2026-08-25') { $fail1.Add("$name asOf=$($norm.asOf)") }
      if ($norm.asOf -eq '2026-08-27') { $fail1.Add("$name asOf rewritten to a later runDate") }
      if ([double]$norm.value -ne [double]$FreshValues[$name]) { $fail1.Add("$name value=$($norm.value)") }
      if ($norm.sourceId -ne $SourceIds[$name]) { $fail1.Add("$name sourceId=$($norm.sourceId)") }
      if ($raw.source -ne 'fred') { $fail1.Add("$name raw source=$($raw.source)") }
      $hist = Join-Path $freshPack.Root ("data\evidence\history\$name\2026-08-25.json")
      if (-not (Test-Path $hist)) { $fail1.Add("$name history missing") }
      if ($briefText -like ("*$($FreshValues[$name])*") -and $name -eq 'Brent') {
        # fixture 90.25 must not have been copied into the seeded production Brief
      }
    }
    if ($briefText -like '*90.25*') { $fail1.Add('fresh collect wrote fixture Brent into Brief') }
    Assert-EvidenceOnlyWrites $freshPack $fail1
    Assert-NoLayerPollution $freshPack $fail1
  } else {
    $fail1.Add('fresh run missing')
  }
  Add-TestResult 'TEST 1' ($fail1.Count -eq 0) ($fail1 -join "`n")

  $fail2 = New-Object System.Collections.Generic.List[string]
  $py = $env:INVESTORTWIN_PYTHON
  if (-not $py) { $py = 'python' }
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $unitOut = & $py $UnitPy 2>&1
    $unitCode = [int]$LASTEXITCODE
  } finally {
    $ErrorActionPreference = $prev
  }
  $unitText = (($unitOut | ForEach-Object { "$_" }) -join "`n")
  if ($unitCode -ne 0) { $fail2.Add("unit failed: $unitText") }
  $src = [System.IO.File]::ReadAllText($CollectPy, $Utf8)
  if ($src -notmatch 'fredId": "DCOILBRENTEU"') { $fail2.Add('Brent FRED series missing') }
  if ($src -notmatch 'fredId": "DCOILWTICO"') { $fail2.Add('WTI FRED series missing') }
  if ($src -notmatch 'fredId": "VIXCLS"') { $fail2.Add('VIX FRED series missing') }
  if ($src -notmatch 'def live_fred') { $fail2.Add('live_fred missing') }
  Add-TestResult 'TEST 2' ($fail2.Count -eq 0) ($fail2 -join "`n")

  $stalePack = Invoke-IsolatedCollect '031-m2a-fred-oil-vix-stale.json'
  $fail3 = New-Object System.Collections.Generic.List[string]
  if ($stalePack.ExitCode -ne 0) { $fail3.Add("stale collect failed: $($stalePack.Text)") }
  if ($stalePack.Run) {
    foreach ($name in $Names) {
      $norm = Read-Json (Join-Path $stalePack.Run ("normalized\$name.json"))
      if ($norm.status -ne 'stale') { $fail3.Add("$name status=$($norm.status) expected stale") }
      if ($norm.status -eq 'fresh') { $fail3.Add("$name marked stale observation as fresh") }
      if ($norm.asOf -ne '2026-08-21') { $fail3.Add("$name asOf=$($norm.asOf)") }
      if ($norm.asOf -eq '2026-08-25') { $fail3.Add("$name asOf rewritten to expectedAsOf") }
      if ($null -eq $norm.value) { $fail3.Add("$name stale dropped real value") }
      $hist = Join-Path $stalePack.Root ("data\evidence\history\$name\2026-08-21.json")
      if (-not (Test-Path $hist)) { $fail3.Add("$name stale history missing") }
      $fake = Join-Path $stalePack.Root ("data\evidence\history\$name\2026-08-25.json")
      if (Test-Path $fake) { $fail3.Add("$name invented expectedAsOf history") }
    }
    Assert-EvidenceOnlyWrites $stalePack $fail3
    Assert-NoLayerPollution $stalePack $fail3
  } else {
    $fail3.Add('stale run missing')
  }
  Add-TestResult 'TEST 3' ($fail3.Count -eq 0) ($fail3 -join "`n")

  $unavailPack = Invoke-IsolatedCollect '031-m2a-fred-oil-vix-unavailable.json'
  $fail4 = New-Object System.Collections.Generic.List[string]
  if ($unavailPack.ExitCode -ne 0) { $fail4.Add("unavailable collect failed: $($unavailPack.Text)") }
  if ($unavailPack.Run) {
    foreach ($name in $Names) {
      $norm = Read-Json (Join-Path $unavailPack.Run ("normalized\$name.json"))
      if ($norm.status -ne 'unavailable') { $fail4.Add("$name status=$($norm.status)") }
      if ($null -ne $norm.value) { $fail4.Add("$name invented value") }
      if ($null -ne $norm.asOf) { $fail4.Add("$name invented asOf") }
      $hist = Join-Path $unavailPack.Root ("data\evidence\history\$name")
      if (Test-Path $hist) { $fail4.Add("$name history written for unavailable") }
    }
    $raw = Read-Json (Join-Path $unavailPack.Run 'raw\fred-brent.json')
    if ("$($raw.error)" -notmatch 'unavailable') { $fail4.Add('raw should record fred unavailable') }
    Assert-EvidenceOnlyWrites $unavailPack $fail4
    Assert-NoLayerPollution $unavailPack $fail4
  } else {
    $fail4.Add('unavailable run missing')
  }
  Add-TestResult 'TEST 4' ($fail4.Count -eq 0) ($fail4 -join "`n")

  $fail5 = New-Object System.Collections.Generic.List[string]
  foreach ($pack in @($freshPack, $stalePack, $unavailPack)) {
    if (-not $pack) { continue }
    Assert-NoLayerPollution $pack $fail5
    Assert-EvidenceOnlyWrites $pack $fail5
  }
  Add-TestResult 'TEST 5' ($fail5.Count -eq 0) ($fail5 -join "`n")
}
catch {
  Add-TestResult 'SETUP' $false $_.Exception.Message
}
finally {
  if (Test-Path $script:TempRoot) {
    Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}

$failGuard = New-Object System.Collections.Generic.List[string]
if ((Get-FileHash -Path $ProdBriefPath -Algorithm SHA256).Hash -ne $ProdHashBefore.brief) { $failGuard.Add('production morning-brief.json changed') }
if ((Get-FileHash -Path $LatestPath -Algorithm SHA256).Hash -ne $ProdHashBefore.latest) { $failGuard.Add('production latest.json changed') }
if ((Get-FileHash -Path $QueuePath -Algorithm SHA256).Hash -ne $ProdHashBefore.queue) { $failGuard.Add('production research-queue.json changed') }
if ((Get-FileHash -Path $CasesPath -Algorithm SHA256).Hash -ne $ProdHashBefore.cases) { $failGuard.Add('production investment-cases.json / Decision / Playbook changed') }
if ((Get-FileHash -Path $GlassCardPath -Algorithm SHA256).Hash -ne $ProdHashBefore.glass) { $failGuard.Add('production glass-bridge card.json changed') }
if ((Get-FileHash -Path $HbmCardPath -Algorithm SHA256).Hash -ne $ProdHashBefore.hbm) { $failGuard.Add('production hbm card.json changed') }
if ((Get-FileHash -Path $CpoCardPath -Algorithm SHA256).Hash -ne $ProdHashBefore.cpo) { $failGuard.Add('production cpo card.json changed') }
if ((Get-FileHash -Path $FauCardPath -Algorithm SHA256).Hash -ne $ProdHashBefore.fau) { $failGuard.Add('production fau card.json changed') }
if ((Get-FileHash -Path (Join-Path $ThesesDir 'ai-dram.json') -Algorithm SHA256).Hash -ne $ProdHashBefore.dram) { $failGuard.Add('production ai-dram thesis changed') }
if ((Get-FileHash -Path (Join-Path $ThesesDir 'cpo-glass-bridge.json') -Algorithm SHA256).Hash -ne $ProdHashBefore.cpoThesis) { $failGuard.Add('production cpo-glass-bridge thesis changed') }
if ((Get-FileHash -Path $GeneratePy -Algorithm SHA256).Hash -ne $ProdHashBefore.generate) { $failGuard.Add('generator source changed') }
if ((Get-FileHash -Path $UpdateScript -Algorithm SHA256).Hash -ne $ProdHashBefore.update) { $failGuard.Add('scheduler/update script changed') }
if ((Get-FileHash -Path $AppPath -Algorithm SHA256).Hash -ne $ProdHashBefore.app) { $failGuard.Add('app.js changed') }
if ((Get-FileHash -Path $IndexPath -Algorithm SHA256).Hash -ne $ProdHashBefore.index) { $failGuard.Add('index.html changed') }
Add-TestResult 'PRODUCTION_FILE_GUARD' ($failGuard.Count -eq 0) ($failGuard -join "`n")

$failed = @($script:Results | Where-Object { $_.Status -ne 'PASS' })
Write-Output ''
Write-Output '=== 031-M-2A SUMMARY ==='
foreach ($row in $script:Results) {
  Write-Output ("{0}: {1}" -f $row.Id, $row.Status)
}
if ($failed.Count -gt 0) { exit 1 }
exit 0
