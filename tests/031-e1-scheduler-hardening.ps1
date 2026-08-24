$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$env:PYTHONIOENCODING = 'utf-8'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$FixturePath = Join-Path $PSScriptRoot 'fixtures\031-e1-scheduler-hardening.json'
$UpdateScript = Join-Path $RepoRoot 'scripts\update-morning-brief.ps1'
$CollectPy = Join-Path $RepoRoot 'scripts\collect-evidence.py'
$GeneratePy = Join-Path $RepoRoot 'scripts\generate-morning-brief.py'
$ProdBriefPath = Join-Path $RepoRoot 'data\morning-brief.json'
$LatestPath = Join-Path $RepoRoot 'data\morning-brief\latest.json'
$ProdCasesPath = Join-Path $RepoRoot 'data\investment-cases.json'
$ProdQueuePath = Join-Path $RepoRoot 'data\research-queue.json'
$ThesesDir = Join-Path $RepoRoot 'data\theses'
$GlassCardPath = Join-Path $RepoRoot 'research\glass-bridge\card.json'
$HbmCardPath = Join-Path $RepoRoot 'research\hbm\card.json'
$CpoCardPath = Join-Path $RepoRoot 'research\cpo\card.json'
$FauCardPath = Join-Path $RepoRoot 'research\fau\card.json'
$ProdStatusPath = Join-Path $RepoRoot 'data\morning-brief-update-status.json'
$ProdLockPath = Join-Path $RepoRoot 'data\morning-brief-update.lock'
$FredFixture = Join-Path $PSScriptRoot 'fixtures\014-fred-observation-date.json'
$MissingFixture = Join-Path $PSScriptRoot 'fixtures\014-missing.json'

if (-not (Test-Path $FixturePath)) { throw "Missing fixture: $FixturePath" }
if (-not (Test-Path $UpdateScript)) { throw "Missing daily update script: $UpdateScript" }

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
}
$ProdStatusExisted = Test-Path -LiteralPath $ProdStatusPath
$ProdLockExisted = Test-Path -LiteralPath $ProdLockPath
if ($ProdStatusExisted) {
  $ProdHashBefore.status = (Get-FileHash -Path $ProdStatusPath -Algorithm SHA256).Hash
}
if ($ProdLockExisted) {
  $ProdHashBefore.lock = (Get-FileHash -Path $ProdLockPath -Algorithm SHA256).Hash
}

$Contract = [System.IO.File]::ReadAllText($FixturePath, $Utf8) | ConvertFrom-Json
$script:Results = New-Object System.Collections.Generic.List[object]
$script:TempRoot = Join-Path $env:TEMP ('InvestorTwin-031E1-' + [guid]::NewGuid().ToString('N'))

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
  [System.IO.File]::WriteAllText($path, (($obj | ConvertTo-Json -Compress) + "`n"), $Utf8)
}

function New-PipelineRoot($name) {
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

function Invoke-Script($file, $argSplat) {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $file @argSplat 2>&1
    return @{ ExitCode = [int]$LASTEXITCODE; Text = (($out | ForEach-Object { "$_" }) -join "`n") }
  } finally {
    $ErrorActionPreference = $prev
  }
}

function Invoke-SiblingTest($relPath) {
  $path = Join-Path $PSScriptRoot $relPath
  $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $path 2>&1 | Out-String
  return @{ ExitCode = $LASTEXITCODE; Text = $out }
}

function Get-StatusMissingKeys($statusObj) {
  $missing = New-Object System.Collections.Generic.List[string]
  foreach ($key in @($Contract.statusKeys)) {
    if (-not ($statusObj.PSObject.Properties.Name -contains $key)) {
      $missing.Add($key)
    }
  }
  return $missing
}

try {
  New-Item -ItemType Directory -Path $script:TempRoot | Out-Null
  $updateSrc = [System.IO.File]::ReadAllText($UpdateScript, $Utf8)
  $collectSrc = [System.IO.File]::ReadAllText($CollectPy, $Utf8)
  $generateSrc = [System.IO.File]::ReadAllText($GeneratePy, $Utf8)

  $failSched = New-Object System.Collections.Generic.List[string]
  if ($updateSrc -like '*Register-ScheduledTask*') { $failSched.Add('update script registers a scheduled task') }
  if ($updateSrc -like '*schtasks*') { $failSched.Add('update script calls schtasks') }
  if ($updateSrc -like '*.github/workflows*') { $failSched.Add('update script adds GitHub Actions') }
  if ($updateSrc -like '*vercel.json*') { $failSched.Add('update script adds a Vercel schedule file') }
  if ($updateSrc -like '*git commit*') { $failSched.Add('update script commits') }
  if ($updateSrc -like '*git push*') { $failSched.Add('update script pushes') }
  if ($updateSrc -like '*/api/queue*') { $failSched.Add('update script posts Queue') }
  if ($updateSrc -notlike '*Resolve-InvestorTwinPython*') { $failSched.Add('update script has no Python discovery') }
  if ($generateSrc -notlike '*os.replace*') { $failSched.Add('generator does not use os.replace') }
  if ($generateSrc -like '*morning-brief/latest.json*' -and $generateSrc -notlike '*may only write data/morning-brief.json*') {
    $failSched.Add('generator may write latest.json')
  }
  Add-TestResult 'TEST 0' ($failSched.Count -eq 0) ($failSched -join "`n")

  $pyRoot = New-PipelineRoot 'python-missing'
  $pyBriefBefore = (Get-FileHash -Path (Join-Path $pyRoot 'data\morning-brief.json') -Algorithm SHA256).Hash
  $pyQueueBefore = (Get-FileHash -Path (Join-Path $pyRoot 'data\research-queue.json') -Algorithm SHA256).Hash
  $missingPython = Join-Path $pyRoot 'no-such-python.exe'
  $pyRun = Invoke-Script $UpdateScript @{
    RootPath = $pyRoot
    InputPath = $FredFixture
    PythonPath = $missingPython
  }
  $fail1 = New-Object System.Collections.Generic.List[string]
  if ($pyRun.ExitCode -eq 0) { $fail1.Add('missing Python exited 0') }
  if ($pyRun.Text -like '*BRIEF_GEN_OK*') { $fail1.Add('missing Python still ran Generator') }
  if ($pyRun.Text -like '*DAILY_UPDATE_COLLECT*') { $fail1.Add('missing Python still ran Collector') }
  if ($pyRun.Text -notlike '*DAILY_UPDATE_PYTHON_MISSING*') { $fail1.Add('missing Python did not print DAILY_UPDATE_PYTHON_MISSING') }
  if ($pyRun.Text -notlike '*DAILY_UPDATE_FAIL*') { $fail1.Add('missing Python did not print DAILY_UPDATE_FAIL') }
  $pyBriefAfter = (Get-FileHash -Path (Join-Path $pyRoot 'data\morning-brief.json') -Algorithm SHA256).Hash
  if ($pyBriefAfter -ne $pyBriefBefore) { $fail1.Add('missing Python modified Brief') }
  $pyQueueAfter = (Get-FileHash -Path (Join-Path $pyRoot 'data\research-queue.json') -Algorithm SHA256).Hash
  if ($pyQueueAfter -ne $pyQueueBefore) { $fail1.Add('missing Python modified Queue') }
  $pyStatusPath = Join-Path $pyRoot 'data\morning-brief-update-status.json'
  if (-not (Test-Path -LiteralPath $pyStatusPath)) {
    $fail1.Add('missing Python did not write status')
  } else {
    $pyStatus = Read-JsonFile $pyStatusPath
    $missingKeys = Get-StatusMissingKeys $pyStatus
    if ($missingKeys.Count -gt 0) { $fail1.Add('status missing keys: ' + ($missingKeys -join ',')) }
    if ($pyStatus.ok -eq $true) { $fail1.Add('missing Python status ok=true') }
    if ([string]$pyStatus.stage -ne 'python') { $fail1.Add("missing Python stage=$($pyStatus.stage)") }
    if ([int]$pyStatus.exitCode -eq 0) { $fail1.Add('missing Python status exitCode=0') }
    if (-not $pyStatus.error) { $fail1.Add('missing Python status has no error') }
  }
  if (Test-Path -LiteralPath (Join-Path $pyRoot 'data\morning-brief-update.lock')) {
    $fail1.Add('missing Python left a lock file')
  }
  Add-TestResult 'TEST 1' ($fail1.Count -eq 0) ($fail1 -join "`n")

  $collectRoot = New-PipelineRoot 'collect-hard-fail'
  $collectBriefBefore = (Get-FileHash -Path (Join-Path $collectRoot 'data\morning-brief.json') -Algorithm SHA256).Hash
  $collectRun = Invoke-Script $UpdateScript @{
    RootPath = $collectRoot
    InputPath = (Join-Path $collectRoot 'data\morning-brief.json')
  }
  $fail2 = New-Object System.Collections.Generic.List[string]
  if ($collectRun.ExitCode -eq 0) { $fail2.Add('collector hard fail exited 0') }
  if ($collectRun.Text -like '*BRIEF_GEN_OK*') { $fail2.Add('collector hard fail still ran Generator') }
  if ($collectRun.Text -like '*DAILY_UPDATE_GENERATE*') { $fail2.Add('collector hard fail printed DAILY_UPDATE_GENERATE') }
  if ($collectRun.Text -notlike '*DAILY_UPDATE_FAIL*') { $fail2.Add('collector hard fail did not print DAILY_UPDATE_FAIL') }
  $collectBriefAfter = (Get-FileHash -Path (Join-Path $collectRoot 'data\morning-brief.json') -Algorithm SHA256).Hash
  if ($collectBriefAfter -ne $collectBriefBefore) { $fail2.Add('collector hard fail modified Brief') }
  $collectStatus = Read-JsonFile (Join-Path $collectRoot 'data\morning-brief-update-status.json')
  if ($collectStatus.ok -eq $true) { $fail2.Add('collector hard fail status ok=true') }
  if ([string]$collectStatus.stage -ne 'collect') { $fail2.Add("collector hard fail stage=$($collectStatus.stage)") }
  if (-not $collectStatus.error) { $fail2.Add('collector hard fail status has no error') }
  if (Test-Path -LiteralPath (Join-Path $collectRoot 'data\morning-brief-update.lock')) {
    $fail2.Add('collector hard fail left a lock file')
  }
  Add-TestResult 'TEST 2' ($fail2.Count -eq 0) ($fail2 -join "`n")

  $genRoot = New-PipelineRoot 'generate-fail'
  $genBriefPath = Join-Path $genRoot 'data\morning-brief.json'
  $genBriefBefore = (Get-FileHash -Path $genBriefPath -Algorithm SHA256).Hash
  $genDateBefore = [string](Read-JsonFile $genBriefPath).date
  $genRun = Invoke-Script $UpdateScript @{
    RootPath = $genRoot
    InputPath = $MissingFixture
  }
  $fail3 = New-Object System.Collections.Generic.List[string]
  if ($genRun.ExitCode -eq 0) { $fail3.Add('generator fail exited 0') }
  if ($genRun.Text -notlike '*DAILY_UPDATE_COLLECT*') { $fail3.Add('generator fail did not run Collector') }
  if ($genRun.Text -notlike '*EVIDENCE_OK*') { $fail3.Add('soft collector did not print EVIDENCE_OK') }
  if ($genRun.Text -like '*BRIEF_GEN_OK*') { $fail3.Add('failed generator printed BRIEF_GEN_OK') }
  if ($genRun.Text -notlike '*DAILY_UPDATE_GENERATE*') { $fail3.Add('generator fail did not reach Generator') }
  if ($genRun.Text -notlike '*DAILY_UPDATE_FAIL*') { $fail3.Add('generator fail did not print DAILY_UPDATE_FAIL') }
  $genBriefAfter = (Get-FileHash -Path $genBriefPath -Algorithm SHA256).Hash
  $genDateAfter = [string](Read-JsonFile $genBriefPath).date
  if ($genBriefAfter -ne $genBriefBefore) { $fail3.Add('generator fail modified Brief') }
  if ($genDateAfter -ne $genDateBefore) { $fail3.Add("generator fail changed Brief date $genDateBefore -> $genDateAfter") }
  $genStatus = Read-JsonFile (Join-Path $genRoot 'data\morning-brief-update-status.json')
  if ($genStatus.ok -eq $true) { $fail3.Add('generator fail status ok=true') }
  if ([string]$genStatus.stage -ne 'generate') { $fail3.Add("generator fail stage=$($genStatus.stage)") }
  if (Test-Path -LiteralPath (Join-Path $genRoot 'data\morning-brief.json.tmp')) {
    $fail3.Add('generator fail left a temp Brief')
  }
  if (Test-Path -LiteralPath (Join-Path $genRoot 'data\morning-brief-update.lock')) {
    $fail3.Add('generator fail left a lock file')
  }
  Add-TestResult 'TEST 3' ($fail3.Count -eq 0) ($fail3 -join "`n")

  $okRoot = New-PipelineRoot 'success'
  $okLatestBefore = (Get-FileHash -Path (Join-Path $okRoot 'data\morning-brief\latest.json') -Algorithm SHA256).Hash
  $okQueueBefore = (Get-FileHash -Path (Join-Path $okRoot 'data\research-queue.json') -Algorithm SHA256).Hash
  $okCasesBefore = (Get-FileHash -Path (Join-Path $okRoot 'data\investment-cases.json') -Algorithm SHA256).Hash
  $okHbmBefore = (Get-FileHash -Path (Join-Path $okRoot 'research\hbm\card.json') -Algorithm SHA256).Hash
  $okOldDate = [string](Read-JsonFile (Join-Path $okRoot 'data\morning-brief.json')).date
  $okRun = Invoke-Script $UpdateScript @{
    RootPath = $okRoot
    InputPath = $FredFixture
  }
  $fail4 = New-Object System.Collections.Generic.List[string]
  if ($okRun.ExitCode -ne 0) { $fail4.Add("success run failed: $($okRun.Text)") }
  if ($okRun.Text -notlike '*DAILY_UPDATE_OK*') { $fail4.Add('success run did not print DAILY_UPDATE_OK') }
  if ($okRun.Text -notlike '*BRIEF_GEN_OK*') { $fail4.Add('success run did not print BRIEF_GEN_OK') }
  if (Test-Path -LiteralPath (Join-Path $okRoot 'data\morning-brief.json.tmp')) {
    $fail4.Add('success run left morning-brief.json.tmp')
  }
  if (-not (Test-Path -LiteralPath (Join-Path $okRoot 'data\morning-brief.backup.json'))) {
    $fail4.Add('success run did not keep backup')
  }
  $okBrief = Read-JsonFile (Join-Path $okRoot 'data\morning-brief.json')
  if ([string]$okBrief.date -eq $okOldDate) { $fail4.Add('success run copied old Brief date') }
  Add-TestResult 'TEST 4' ($fail4.Count -eq 0) ($fail4 -join "`n")

  $lockRoot = New-PipelineRoot 'lock'
  $lockBriefBefore = (Get-FileHash -Path (Join-Path $lockRoot 'data\morning-brief.json') -Algorithm SHA256).Hash
  $lockPath = Join-Path $lockRoot 'data\morning-brief-update.lock'
  $lockStatusPath = Join-Path $lockRoot 'data\morning-brief-update-status.json'
  $seedStatus = [ordered]@{
    ok = $true
    startedAt = '2026-08-20T00:00:00Z'
    finishedAt = '2026-08-20T00:01:00Z'
    briefDate = '2026-08-20'
    runId = 'run-keep'
    exitCode = 0
    stage = 'complete'
    error = $null
  }
  Write-JsonFile $lockStatusPath $seedStatus
  $seedStatusHash = (Get-FileHash -Path $lockStatusPath -Algorithm SHA256).Hash
  Write-JsonFile $lockPath @{ pid = $PID; startedAt = '2026-08-20T00:00:00Z' }
  $lockRun = Invoke-Script $UpdateScript @{
    RootPath = $lockRoot
    InputPath = $FredFixture
  }
  $fail5 = New-Object System.Collections.Generic.List[string]
  if ($lockRun.ExitCode -eq 0) { $fail5.Add('lock contention exited 0') }
  if ($lockRun.Text -notlike '*DAILY_UPDATE_LOCK*') { $fail5.Add('lock contention did not print DAILY_UPDATE_LOCK') }
  if ($lockRun.Text -like '*BRIEF_GEN_OK*') { $fail5.Add('lock contention ran Generator') }
  if ($lockRun.Text -like '*DAILY_UPDATE_COLLECT*') { $fail5.Add('lock contention ran Collector') }
  $lockBriefAfter = (Get-FileHash -Path (Join-Path $lockRoot 'data\morning-brief.json') -Algorithm SHA256).Hash
  if ($lockBriefAfter -ne $lockBriefBefore) { $fail5.Add('lock contention modified Brief') }
  $lockStatusHashAfter = (Get-FileHash -Path $lockStatusPath -Algorithm SHA256).Hash
  if ($lockStatusHashAfter -ne $seedStatusHash) { $fail5.Add('lock contention overwrote in-progress status') }
  if (-not (Test-Path -LiteralPath $lockPath)) { $fail5.Add('lock contention deleted the held lock') }
  Add-TestResult 'TEST 5' ($fail5.Count -eq 0) ($fail5 -join "`n")

  $fail6 = New-Object System.Collections.Generic.List[string]
  $okStatusPath = Join-Path $okRoot 'data\morning-brief-update-status.json'
  if (-not (Test-Path -LiteralPath $okStatusPath)) {
    $fail6.Add('success run did not write status')
  } else {
    $okStatus = Read-JsonFile $okStatusPath
    $missingKeys = Get-StatusMissingKeys $okStatus
    if ($missingKeys.Count -gt 0) { $fail6.Add('success status missing keys: ' + ($missingKeys -join ',')) }
    if ($okStatus.ok -ne $true) { $fail6.Add('success status ok is not true') }
    if ([int]$okStatus.exitCode -ne 0) { $fail6.Add("success status exitCode=$($okStatus.exitCode)") }
    if ([string]$okStatus.stage -ne 'complete') { $fail6.Add("success status stage=$($okStatus.stage)") }
    if (-not $okStatus.startedAt) { $fail6.Add('success status missing startedAt') }
    if (-not $okStatus.finishedAt) { $fail6.Add('success status missing finishedAt') }
    if (-not $okStatus.briefDate) { $fail6.Add('success status missing briefDate') }
    if (-not $okStatus.runId) { $fail6.Add('success status missing runId') }
    if ($okStatus.error) { $fail6.Add('success status has error') }
  }
  Add-TestResult 'TEST 6' ($fail6.Count -eq 0) ($fail6 -join "`n")

  $fail7 = New-Object System.Collections.Generic.List[string]
  $failStatus = Read-JsonFile (Join-Path $pyRoot 'data\morning-brief-update-status.json')
  $failMissing = Get-StatusMissingKeys $failStatus
  if ($failMissing.Count -gt 0) { $fail7.Add('failure status missing keys: ' + ($failMissing -join ',')) }
  if ($failStatus.ok -eq $true) { $fail7.Add('failure status ok=true') }
  if (-not $failStatus.error) { $fail7.Add('failure status missing error') }
  if ([string]$failStatus.stage -ne 'python') { $fail7.Add('failure status stage is not python') }
  if (-not $failStatus.startedAt) { $fail7.Add('failure status missing startedAt') }
  if (-not $failStatus.finishedAt) { $fail7.Add('failure status missing finishedAt') }
  if ([int]$failStatus.exitCode -eq 0) { $fail7.Add('failure status exitCode=0') }
  Add-TestResult 'TEST 7' ($fail7.Count -eq 0) ($fail7 -join "`n")

  $fail8 = New-Object System.Collections.Generic.List[string]
  $okLatestAfter = (Get-FileHash -Path (Join-Path $okRoot 'data\morning-brief\latest.json') -Algorithm SHA256).Hash
  if ($okLatestAfter -ne $okLatestBefore) { $fail8.Add('first run modified latest.json canonical copy') }
  $rerun = Invoke-Script $UpdateScript @{
    RootPath = $okRoot
    InputPath = $FredFixture
  }
  if ($rerun.ExitCode -ne 0) { $fail8.Add("same-day rerun failed: $($rerun.Text)") }
  if ($rerun.Text -notlike '*DAILY_UPDATE_OK*') { $fail8.Add('same-day rerun did not print DAILY_UPDATE_OK') }
  $canonical = @(Get-ChildItem -Path (Join-Path $okRoot 'data') -Filter 'morning-brief.json' -File)
  if ($canonical.Count -ne 1) { $fail8.Add("expected one canonical Brief, found $($canonical.Count)") }
  $rerunLatest = (Get-FileHash -Path (Join-Path $okRoot 'data\morning-brief\latest.json') -Algorithm SHA256).Hash
  if ($rerunLatest -ne $okLatestBefore) { $fail8.Add('same-day rerun restored latest.json as a second canonical Brief') }
  if (Test-Path -LiteralPath (Join-Path $okRoot 'data\morning-brief-update.lock')) {
    $fail8.Add('same-day rerun left a lock file')
  }
  $okQueueAfter = (Get-FileHash -Path (Join-Path $okRoot 'data\research-queue.json') -Algorithm SHA256).Hash
  $okCasesAfter = (Get-FileHash -Path (Join-Path $okRoot 'data\investment-cases.json') -Algorithm SHA256).Hash
  $okHbmAfter = (Get-FileHash -Path (Join-Path $okRoot 'research\hbm\card.json') -Algorithm SHA256).Hash
  if ($okQueueAfter -ne $okQueueBefore) { $fail8.Add('pipeline wrote Queue') }
  if ($okCasesAfter -ne $okCasesBefore) { $fail8.Add('pipeline wrote Case / Decision / Playbook') }
  if ($okHbmAfter -ne $okHbmBefore) { $fail8.Add('pipeline wrote Research Card') }
  Add-TestResult 'TEST 8' ($fail8.Count -eq 0) ($fail8 -join "`n")
}
catch {
  Add-TestResult 'SETUP' $false $_.Exception.Message
}

$afterGlass = (Get-FileHash -Path $GlassCardPath -Algorithm SHA256).Hash
$afterHbm = (Get-FileHash -Path $HbmCardPath -Algorithm SHA256).Hash
$afterCpo = (Get-FileHash -Path $CpoCardPath -Algorithm SHA256).Hash
$afterFau = (Get-FileHash -Path $FauCardPath -Algorithm SHA256).Hash
$afterCases = (Get-FileHash -Path $ProdCasesPath -Algorithm SHA256).Hash
$afterQueue = (Get-FileHash -Path $ProdQueuePath -Algorithm SHA256).Hash
$afterDram = (Get-FileHash -Path (Join-Path $ThesesDir 'ai-dram.json') -Algorithm SHA256).Hash
$afterCpoThesis = (Get-FileHash -Path (Join-Path $ThesesDir 'cpo-glass-bridge.json') -Algorithm SHA256).Hash
$afterBrief = (Get-FileHash -Path $ProdBriefPath -Algorithm SHA256).Hash
$afterLatest = (Get-FileHash -Path $LatestPath -Algorithm SHA256).Hash
$fail9 = New-Object System.Collections.Generic.List[string]
if ($afterGlass -ne $ProdHashBefore.glass) { $fail9.Add('production glass-bridge card.json changed') }
if ($afterHbm -ne $ProdHashBefore.hbm) { $fail9.Add('production hbm card.json changed') }
if ($afterCpo -ne $ProdHashBefore.cpo) { $fail9.Add('production cpo card.json changed') }
if ($afterFau -ne $ProdHashBefore.fau) { $fail9.Add('production fau card.json changed') }
if ($afterCases -ne $ProdHashBefore.cases) { $fail9.Add('production investment-cases.json / Decision / Playbook changed') }
if ($afterQueue -ne $ProdHashBefore.queue) { $fail9.Add('production research-queue.json changed') }
if ($afterDram -ne $ProdHashBefore.dram) { $fail9.Add('production ai-dram thesis changed') }
if ($afterCpoThesis -ne $ProdHashBefore.cpoThesis) { $fail9.Add('production cpo-glass-bridge thesis changed') }
if ($afterBrief -ne $ProdHashBefore.brief) { $fail9.Add('tests rewrote production morning-brief.json') }
if ($afterLatest -ne $ProdHashBefore.latest) { $fail9.Add('production morning-brief/latest.json changed') }
if ($ProdStatusExisted) {
  $afterStatus = (Get-FileHash -Path $ProdStatusPath -Algorithm SHA256).Hash
  if ($afterStatus -ne $ProdHashBefore.status) { $fail9.Add('tests rewrote production morning-brief-update-status.json') }
} elseif (Test-Path -LiteralPath $ProdStatusPath) {
  $fail9.Add('tests created production morning-brief-update-status.json')
}
if ($ProdLockExisted) {
  $afterLock = (Get-FileHash -Path $ProdLockPath -Algorithm SHA256).Hash
  if ($afterLock -ne $ProdHashBefore.lock) { $fail9.Add('tests rewrote production morning-brief-update.lock') }
} elseif (Test-Path -LiteralPath $ProdLockPath) {
  $fail9.Add('tests created production morning-brief-update.lock')
}
Add-TestResult 'TEST 9' ($fail9.Count -eq 0) ($fail9 -join "`n")
Add-TestResult 'PRODUCTION_FILE_GUARD' ($fail9.Count -eq 0) ($fail9 -join "`n")

$fail10 = New-Object System.Collections.Generic.List[string]
foreach ($rel in @(
    '025-research-thesis-case.ps1',
    '027-research-intake.ps1',
    '029-research-conclusion-history.ps1',
    '031-a-morning-brief-pipeline.ps1',
    '031-b-morning-brief-intelligence.ps1',
    '031-c-morning-brief-workspace.ps1',
    '031-d-daily-auto-update-gate.ps1'
  )) {
  $reg = Invoke-SiblingTest $rel
  if ($reg.ExitCode -ne 0) { $fail10.Add($reg.Text) }
}
Add-TestResult 'TEST 10' ($fail10.Count -eq 0) ($fail10 -join "`n")

if (Test-Path $script:TempRoot) {
  Remove-Item -Recurse -Force $script:TempRoot -ErrorAction SilentlyContinue
}

$failed = @($script:Results | Where-Object { $_.Status -ne 'PASS' })
Write-Output ''
Write-Output '=== 031-E1 SUMMARY ==='
foreach ($row in $script:Results) {
  Write-Output ("{0}: {1}" -f $row.Id, $row.Status)
  if ($row.Status -ne 'PASS' -and $row.Details) { Write-Output $row.Details }
}
if ($failed.Count -gt 0) { exit 1 }
exit 0
