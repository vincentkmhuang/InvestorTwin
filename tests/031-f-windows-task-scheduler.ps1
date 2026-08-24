$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$env:PYTHONIOENCODING = 'utf-8'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$FixturePath = Join-Path $PSScriptRoot 'fixtures\031-f-windows-task-scheduler.json'
$DefinitionPath = Join-Path $RepoRoot 'scripts\morning-brief-task.definition.json'
$RegisterScript = Join-Path $RepoRoot 'scripts\register-morning-brief-task.ps1'
$UpdateScript = Join-Path $RepoRoot 'scripts\update-morning-brief.ps1'
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

if (-not (Test-Path $FixturePath)) { throw "Missing fixture: $FixturePath" }
if (-not (Test-Path $DefinitionPath)) { throw "Missing task definition: $DefinitionPath" }
if (-not (Test-Path $RegisterScript)) { throw "Missing register script: $RegisterScript" }

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

function Add-TestResult($id, $passed, $details) {
  $status = if ($passed) { 'PASS' } else { 'FAIL' }
  $script:Results.Add([PSCustomObject]@{ Id = $id; Status = $status; Details = $details })
  Write-Output ("{0}: {1}" -f $id, $status)
  if ($details) { Write-Output $details }
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

function Get-InvestorTwinTasks {
  return @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
    $_.TaskName -eq $Contract.taskName -or $_.TaskPath -like '*InvestorTwin*'
  })
}

$tasksBefore = Get-InvestorTwinTasks

try {
  $definition = [System.IO.File]::ReadAllText($DefinitionPath, $Utf8) | ConvertFrom-Json
  $registerSrc = [System.IO.File]::ReadAllText($RegisterScript, $Utf8)
  $updateSrc = [System.IO.File]::ReadAllText($UpdateScript, $Utf8)
  $generateSrc = [System.IO.File]::ReadAllText($GeneratePy, $Utf8)

  $failA = New-Object System.Collections.Generic.List[string]
  if ([string]$definition.powershellExe -ne [string]$Contract.powershellExe) {
    $failA.Add("powershellExe=$($definition.powershellExe)")
  }
  if (-not (Test-Path -LiteralPath $definition.powershellExe)) {
    $failA.Add('PowerShell executable does not exist')
  }
  if ($definition.powershellExe -notlike '*\System32\WindowsPowerShell\v1.0\powershell.exe') {
    $failA.Add('PowerShell path is not Windows PowerShell 5.1')
  }
  Add-TestResult 'TEST A' ($failA.Count -eq 0) ($failA -join "`n")

  $failB = New-Object System.Collections.Generic.List[string]
  if ([string]$definition.scriptPath -ne [string]$Contract.scriptPath) {
    $failB.Add("scriptPath=$($definition.scriptPath)")
  }
  if (-not (Test-Path -LiteralPath $definition.scriptPath)) { $failB.Add('update script missing') }
  Add-TestResult 'TEST B' ($failB.Count -eq 0) ($failB -join "`n")

  $failC = New-Object System.Collections.Generic.List[string]
  if ([string]$definition.workingDirectory -ne [string]$Contract.workingDirectory) {
    $failC.Add("workingDirectory=$($definition.workingDirectory)")
  }
  if ([string]$definition.rootPath -ne 'C:\InvestorTwin') { $failC.Add('rootPath is not C:\InvestorTwin') }
  Add-TestResult 'TEST C' ($failC.Count -eq 0) ($failC -join "`n")

  $dry = Invoke-Script $RegisterScript @{}
  $failD = New-Object System.Collections.Generic.List[string]
  if ($dry.ExitCode -ne 0) { $failD.Add("DryRun failed: $($dry.Text)") }
  if ($dry.Text -notlike '*TASK_DRY_RUN*') { $failD.Add('DryRun did not print TASK_DRY_RUN') }
  $jsonLine = ($dry.Text -split "`n" | Where-Object { $_ -like '{*' } | Select-Object -Last 1)
  $resolved = $null
  try { $resolved = $jsonLine | ConvertFrom-Json } catch { $failD.Add('DryRun did not print JSON') }
  if ($resolved) {
    if ($resolved.arguments -notlike '*-Live*') { $failD.Add('Action arguments missing -Live') }
    if ($resolved.arguments -notlike ('*-File ' + [string]$Contract.scriptPath + '*') -and $resolved.arguments -notlike ('*-File "' + [string]$Contract.scriptPath + '"*')) {
      if ($resolved.arguments -notlike ('*' + [string]$Contract.scriptPath + '*')) {
        $failD.Add('Action arguments missing script path')
      }
    }
    if ($resolved.arguments -notlike '*-PythonPath*') { $failD.Add('Action arguments missing -PythonPath') }
    if ($resolved.pythonPath -like '*\WindowsApps\python.exe') { $failD.Add('PythonPath is the WindowsApps stub') }
    if (-not (Test-Path -LiteralPath $resolved.pythonPath)) { $failD.Add('resolved PythonPath does not exist') }
    if ($resolved.register -eq $true) { $failD.Add('DryRun marked register=true') }
  }
  if ($registerSrc -notlike '*if ($Register)*') { $failD.Add('Register-ScheduledTask is not gated') }
  Add-TestResult 'TEST D' ($failD.Count -eq 0) ($failD -join "`n")

  $failE = New-Object System.Collections.Generic.List[string]
  if ([string]$definition.trigger.at -ne [string]$Contract.at) { $failE.Add("trigger.at=$($definition.trigger.at)") }
  if ([string]$definition.trigger.type -ne 'Daily') { $failE.Add('trigger is not Daily') }
  if ($registerSrc -notlike '*New-ScheduledTaskTrigger -Daily*') { $failE.Add('register script does not create a Daily trigger') }
  Add-TestResult 'TEST E' ($failE.Count -eq 0) ($failE -join "`n")

  $failF = New-Object System.Collections.Generic.List[string]
  if ([string]$definition.principal.logonType -ne 'Interactive') {
    $failF.Add("v1 logonType=$($definition.principal.logonType); Password/S4U is not safe for first Enable")
  }
  if ($registerSrc -like '*LogonType Password*') { $failF.Add('register script enables Password logon') }
  if ($registerSrc -like '*LogonType S4U*') { $failF.Add('register script enables S4U logon') }
  if ($registerSrc -like '*-Password *') { $failF.Add('register script accepts a task password') }
  if ($definition.principal.forbidSystemAccount -ne $true) { $failF.Add('SYSTEM account is not forbidden') }
  Add-TestResult 'TEST F' ($failF.Count -eq 0) ($failF -join "`n")

  $failG = New-Object System.Collections.Generic.List[string]
  $gh = @(Get-ChildItem -Path (Join-Path $RepoRoot '.github\workflows') -ErrorAction SilentlyContinue)
  if ($gh.Count -gt 0) { $failG.Add('GitHub Actions workflow exists') }
  if (Test-Path -LiteralPath (Join-Path $RepoRoot 'vercel.json')) { $failG.Add('vercel.json exists') }
  if ($updateSrc -like '*Register-ScheduledTask*') { $failG.Add('update script registers a scheduled task') }
  if ($updateSrc -like '*schtasks*') { $failG.Add('update script calls schtasks') }
  if ($registerSrc -like '*.github/workflows*') { $failG.Add('register script adds GitHub Actions') }
  if ($registerSrc -like '*vercel.json*') { $failG.Add('register script adds Vercel Cron') }
  Add-TestResult 'TEST G' ($failG.Count -eq 0) ($failG -join "`n")

  $failH = New-Object System.Collections.Generic.List[string]
  if ([string]$definition.statusFile -ne 'C:\InvestorTwin\data\morning-brief-update-status.json') {
    $failH.Add('statusFile is not the canonical status path')
  }
  foreach ($key in @($Contract.statusKeys)) {
    if ($updateSrc -notlike ('*' + $key + '*')) { $failH.Add("update script missing status key $key") }
  }
  if ($updateSrc -notlike '*exit $Code*') { $failH.Add('update script does not exit with a status code') }
  Add-TestResult 'TEST H' ($failH.Count -eq 0) ($failH -join "`n")

  $failI = New-Object System.Collections.Generic.List[string]
  if ([string]$definition.canonicalBrief -ne 'C:\InvestorTwin\data\morning-brief.json') {
    $failI.Add('canonical Brief path is wrong')
  }
  if ($generateSrc -like '*morning-brief/latest.json*') { $failI.Add('generator writes latest.json') }
  if ($updateSrc -like '*morning-brief/latest.json*') { $failI.Add('update script writes latest.json') }
  Add-TestResult 'TEST I' ($failI.Count -eq 0) ($failI -join "`n")

  $failJ = New-Object System.Collections.Generic.List[string]
  if ($updateSrc -notlike '*Enter-UpdateLock*') { $failJ.Add('update script missing lock') }
  if ($generateSrc -notlike '*os.replace*') { $failJ.Add('generator missing atomic replace') }
  if ($updateSrc -notlike '*morning-brief-update-status.json*') { $failJ.Add('update script missing status file') }
  if ($updateSrc -notlike '*System32\WindowsPowerShell\v1.0\powershell.exe*') {
    $failJ.Add('child PowerShell path is not absolute')
  }
  Add-TestResult 'TEST J' ($failJ.Count -eq 0) ($failJ -join "`n")
}
catch {
  Add-TestResult 'SETUP' $false $_.Exception.Message
}

$tasksAfter = Get-InvestorTwinTasks
$failCreate = New-Object System.Collections.Generic.List[string]
if ($tasksAfter.Count -gt $tasksBefore.Count) {
  $failCreate.Add('tests registered a production scheduled task')
}
Add-TestResult 'NO_PRODUCTION_TASK' ($failCreate.Count -eq 0) ($failCreate -join "`n")

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
$failGuard = New-Object System.Collections.Generic.List[string]
if ($afterGlass -ne $ProdHashBefore.glass) { $failGuard.Add('production glass-bridge card.json changed') }
if ($afterHbm -ne $ProdHashBefore.hbm) { $failGuard.Add('production hbm card.json changed') }
if ($afterCpo -ne $ProdHashBefore.cpo) { $failGuard.Add('production cpo card.json changed') }
if ($afterFau -ne $ProdHashBefore.fau) { $failGuard.Add('production fau card.json changed') }
if ($afterCases -ne $ProdHashBefore.cases) { $failGuard.Add('production investment-cases.json / Decision / Playbook changed') }
if ($afterQueue -ne $ProdHashBefore.queue) { $failGuard.Add('production research-queue.json changed') }
if ($afterDram -ne $ProdHashBefore.dram) { $failGuard.Add('production ai-dram thesis changed') }
if ($afterCpoThesis -ne $ProdHashBefore.cpoThesis) { $failGuard.Add('production cpo-glass-bridge thesis changed') }
if ($afterBrief -ne $ProdHashBefore.brief) { $failGuard.Add('tests rewrote production morning-brief.json') }
if ($afterLatest -ne $ProdHashBefore.latest) { $failGuard.Add('production morning-brief/latest.json changed') }
if ($ProdStatusExisted) {
  $afterStatus = (Get-FileHash -Path $ProdStatusPath -Algorithm SHA256).Hash
  if ($afterStatus -ne $ProdHashBefore.status) { $failGuard.Add('tests rewrote production morning-brief-update-status.json') }
} elseif (Test-Path -LiteralPath $ProdStatusPath) {
  $failGuard.Add('tests created production morning-brief-update-status.json')
}
if ($ProdLockExisted) {
  $afterLock = (Get-FileHash -Path $ProdLockPath -Algorithm SHA256).Hash
  if ($afterLock -ne $ProdHashBefore.lock) { $failGuard.Add('tests rewrote production morning-brief-update.lock') }
} elseif (Test-Path -LiteralPath $ProdLockPath) {
  $failGuard.Add('tests created production morning-brief-update.lock')
}
Add-TestResult 'PRODUCTION_FILE_GUARD' ($failGuard.Count -eq 0) ($failGuard -join "`n")

$reg = Invoke-SiblingTest '031-e1-scheduler-hardening.ps1'
Add-TestResult 'REGRESSION 031-E1' ($reg.ExitCode -eq 0) $(if ($reg.ExitCode -eq 0) { '' } else { $reg.Text })

$failed = @($script:Results | Where-Object { $_.Status -ne 'PASS' })
Write-Output ''
Write-Output '=== 031-F SUMMARY ==='
foreach ($row in $script:Results) {
  Write-Output ("{0}: {1}" -f $row.Id, $row.Status)
  if ($row.Status -ne 'PASS' -and $row.Details) { Write-Output $row.Details }
}
if ($failed.Count -gt 0) { exit 1 }
exit 0
