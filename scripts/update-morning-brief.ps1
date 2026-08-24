# 031-E1 Morning Brief daily update (manual or future Task Scheduler).
# Collector then Generator. One-shot. Do not register a scheduled task here.
param(
  [string]$RootPath,
  [string]$InputPath,
  [string]$PythonPath,
  [switch]$Live
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$env:PYTHONIOENCODING = 'utf-8'
$Utf8 = New-Object System.Text.UTF8Encoding $false

if (-not $RootPath) {
  $RootPath = Split-Path -Parent $PSScriptRoot
}
$RootPath = [System.IO.Path]::GetFullPath($RootPath)

$CollectScript = Join-Path $PSScriptRoot 'collect-evidence.ps1'
$GenerateScript = Join-Path $PSScriptRoot 'generate-morning-brief.ps1'
$LockPath = Join-Path $RootPath 'data\morning-brief-update.lock'
$StatusPath = Join-Path $RootPath 'data\morning-brief-update-status.json'
$script:LockOwned = $false
$script:StartedAt = $null

if (-not (Test-Path -LiteralPath $CollectScript)) { throw "Missing collector wrapper: $CollectScript" }
if (-not (Test-Path -LiteralPath $GenerateScript)) { throw "Missing generator wrapper: $GenerateScript" }

if ($Live -and $InputPath) {
  throw "Use either -InputPath or -Live, not both."
}
if (-not $Live -and -not $InputPath) {
  throw "InputPath fixture is required unless -Live is set."
}

function Get-UtcStamp {
  return [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
}

function Write-UpdateStatus {
  param(
    [bool]$Ok,
    [int]$ExitCode,
    [string]$Stage,
    [string]$ErrorText,
    [string]$BriefDate,
    [string]$RunId
  )
  $dir = Split-Path -Parent $StatusPath
  if (-not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
  }
  $payload = [ordered]@{
    ok = [bool]$Ok
    startedAt = $script:StartedAt
    finishedAt = (Get-UtcStamp)
    briefDate = $(if ($BriefDate) { $BriefDate } else { $null })
    runId = $(if ($RunId) { $RunId } else { $null })
    exitCode = [int]$ExitCode
    stage = $Stage
    error = $(if ($ErrorText) { $ErrorText } else { $null })
  }
  [System.IO.File]::WriteAllText($StatusPath, (($payload | ConvertTo-Json -Compress) + "`n"), $Utf8)
}

function Complete-Update {
  param(
    [int]$Code,
    [string]$Stage,
    [string]$ErrorText,
    [string]$BriefDate,
    [string]$RunId
  )
  $ok = ($Code -eq 0)
  if (-not $script:StartedAt) { $script:StartedAt = (Get-UtcStamp) }
  Write-UpdateStatus -Ok $ok -ExitCode $Code -Stage $Stage -ErrorText $ErrorText -BriefDate $BriefDate -RunId $RunId
  if ($ok) { Write-Output 'DAILY_UPDATE_OK' } else { Write-Output 'DAILY_UPDATE_FAIL' }
  exit $Code
}

function Test-ProcessAlive([int]$ProcessId) {
  if ($ProcessId -le 0) { return $false }
  try {
    Get-Process -Id $ProcessId -ErrorAction Stop | Out-Null
    return $true
  } catch {
    return $false
  }
}

function Read-LockPid($path) {
  try {
    if (-not (Test-Path -LiteralPath $path)) { return 0 }
    $obj = ([System.IO.File]::ReadAllText($path, $Utf8) | ConvertFrom-Json)
    return [int]$obj.pid
  } catch {
    return 0
  }
}

function Enter-UpdateLock {
  $dir = Split-Path -Parent $LockPath
  if (-not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
  }
  if (Test-Path -LiteralPath $LockPath) {
    $existing = Read-LockPid $LockPath
    if (Test-ProcessAlive $existing) {
      return $false
    }
    Remove-Item -LiteralPath $LockPath -Force -ErrorAction SilentlyContinue
  }
  $payload = (@{ pid = $PID; startedAt = (Get-UtcStamp) } | ConvertTo-Json -Compress) + "`n"
  [System.IO.File]::WriteAllText($LockPath, $payload, $Utf8)
  Start-Sleep -Milliseconds 50
  if ((Read-LockPid $LockPath) -ne $PID) {
    return $false
  }
  $script:LockOwned = $true
  return $true
}

function Exit-UpdateLock {
  if (-not $script:LockOwned) { return }
  if (Test-Path -LiteralPath $LockPath) {
    $existing = Read-LockPid $LockPath
    if (($existing -eq $PID) -or ($existing -eq 0)) {
      Remove-Item -LiteralPath $LockPath -Force -ErrorAction SilentlyContinue
    }
  }
  $script:LockOwned = $false
}

function Test-PythonExe([string]$Path) {
  if (-not $Path) { return $false }
  if ($Path -ne 'python' -and -not (Test-Path -LiteralPath $Path)) { return $false }
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    & $Path -c "import sys; raise SystemExit(0)" 2>&1 | Out-Null
    return ($LASTEXITCODE -eq 0)
  } catch {
    return $false
  } finally {
    $ErrorActionPreference = $prev
  }
}

function Resolve-InvestorTwinPython([string]$Requested) {
  if ($Requested) {
    if (Test-PythonExe $Requested) { return $Requested }
    return $null
  }
  if ($env:INVESTORTWIN_PYTHON) {
    if (Test-PythonExe $env:INVESTORTWIN_PYTHON) { return $env:INVESTORTWIN_PYTHON }
    return $null
  }
  $py = Get-Command py -ErrorAction SilentlyContinue
  if ($py) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
      $exe = (& py -3 -c "import sys; print(sys.executable)" 2>$null | Select-Object -First 1)
      if ($LASTEXITCODE -eq 0 -and $exe) {
        $exe = [string]$exe.Trim()
        if (Test-PythonExe $exe) { return $exe }
      }
    } catch { }
    finally { $ErrorActionPreference = $prev }
  }
  $cmd = Get-Command python -ErrorAction SilentlyContinue
  if ($cmd -and $cmd.Source -and (Test-PythonExe $cmd.Source)) { return $cmd.Source }
  return $null
}

function Invoke-ChildScript($file, $argSplat) {
  $pwsh = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  if (-not (Test-Path -LiteralPath $pwsh)) {
    throw "Windows PowerShell not found: $pwsh"
  }
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $out = & $pwsh -NoProfile -ExecutionPolicy Bypass -File $file @argSplat 2>&1
    return @{ ExitCode = [int]$LASTEXITCODE; Text = (($out | ForEach-Object { "$_" }) -join "`n") }
  } finally {
    $ErrorActionPreference = $prev
  }
}

$script:StartedAt = Get-UtcStamp

try {
  $resolvedPython = Resolve-InvestorTwinPython $PythonPath
  if (-not $resolvedPython) {
    Write-Output 'DAILY_UPDATE_PYTHON_MISSING'
    Complete-Update -Code 3 -Stage 'python' -ErrorText 'Python executable was not found. Set -PythonPath or INVESTORTWIN_PYTHON to an absolute interpreter path.'
  }
  $env:INVESTORTWIN_PYTHON = $resolvedPython

  if (-not (Enter-UpdateLock)) {
    Write-Output 'DAILY_UPDATE_LOCK'
    Write-Output 'DAILY_UPDATE_FAIL'
    exit 4
  }

  $collectArgs = @{
    RootPath = $RootPath
    PythonPath = $resolvedPython
  }
  if ($Live) { $collectArgs.Live = $true }
  if ($InputPath) { $collectArgs.InputPath = $InputPath }

  Write-Output 'DAILY_UPDATE_COLLECT'
  $collect = Invoke-ChildScript $CollectScript $collectArgs
  Write-Output $collect.Text
  $runId = $null
  if ($collect.Text -match 'runId=(run-\S+)') { $runId = $Matches[1].Trim() }
  if ($collect.ExitCode -ne 0) {
    Complete-Update -Code $collect.ExitCode -Stage 'collect' -ErrorText $collect.Text -RunId $runId
  }

  Write-Output 'DAILY_UPDATE_GENERATE'
  $gen = Invoke-ChildScript $GenerateScript @{
    RootPath = $RootPath
    PythonPath = $resolvedPython
  }
  Write-Output $gen.Text
  $briefDate = $null
  if ($gen.Text -match 'date=(\d{4}-\d{2}-\d{2})') { $briefDate = $Matches[1] }
  if ($gen.ExitCode -ne 0) {
    Complete-Update -Code $gen.ExitCode -Stage 'generate' -ErrorText $gen.Text -BriefDate $briefDate -RunId $runId
  }

  Complete-Update -Code 0 -Stage 'complete' -BriefDate $briefDate -RunId $runId
}
finally {
  Exit-UpdateLock
}
