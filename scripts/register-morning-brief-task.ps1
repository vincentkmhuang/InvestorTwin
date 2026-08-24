# 031-F Windows Task Scheduler helper for Morning Brief daily update.
# Default is DryRun: print the resolved task definition, do not register.
# Production register requires an explicit -Register after the Safety Gate.
param(
  [switch]$DryRun,
  [switch]$Register,
  [switch]$Disable,
  [switch]$Unregister,
  [string]$PythonPath
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$RootPath = Split-Path -Parent $PSScriptRoot
$RootPath = [System.IO.Path]::GetFullPath($RootPath)
$DefinitionPath = Join-Path $PSScriptRoot 'morning-brief-task.definition.json'
$Utf8 = New-Object System.Text.UTF8Encoding $false

if (-not (Test-Path -LiteralPath $DefinitionPath)) {
  throw "Missing task definition: $DefinitionPath"
}

$modeCount = @($DryRun, $Register, $Disable, $Unregister | Where-Object { $_ }).Count
if ($modeCount -gt 1) {
  throw "Use only one of -DryRun, -Register, -Disable, -Unregister."
}
if ($modeCount -eq 0) { $DryRun = $true }

$Contract = ([System.IO.File]::ReadAllText($DefinitionPath, $Utf8) | ConvertFrom-Json)

function Test-PythonExe([string]$Path) {
  if (-not $Path) { return $false }
  if ($Path -like '*\WindowsApps\python.exe') { return $false }
  if (-not (Test-Path -LiteralPath $Path)) { return $false }
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

function Resolve-TaskPython([string]$Requested) {
  $candidates = New-Object System.Collections.Generic.List[string]
  if ($Requested) {
    [void]$candidates.Add($Requested)
  } elseif ($env:INVESTORTWIN_PYTHON) {
    [void]$candidates.Add($env:INVESTORTWIN_PYTHON)
  } else {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
      foreach ($line in @(& py -3 -c "import sys; print(sys.executable)" 2>&1)) {
        $text = [string]$line
        if ($text -like '*python.exe') { [void]$candidates.Add($text.Trim()) }
      }
    } catch { }
    $cmd = Get-Command python -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) { [void]$candidates.Add([string]$cmd.Source) }
    $ErrorActionPreference = $prev
  }
  foreach ($path in $candidates) {
    if (Test-PythonExe $path) { return $path }
  }
  if ($Requested) {
    throw "PythonPath is not a usable interpreter: $Requested"
  }
  if ($env:INVESTORTWIN_PYTHON) {
    throw "INVESTORTWIN_PYTHON is not a usable interpreter: $($env:INVESTORTWIN_PYTHON)"
  }
  throw "Python executable was not found. Set -PythonPath or INVESTORTWIN_PYTHON to an absolute interpreter path."
}

function Get-ResolvedTaskDefinition([string]$ResolvedPython) {
  $psExe = [string]$Contract.powershellExe
  if (-not (Test-Path -LiteralPath $psExe)) {
    throw "PowerShell executable not found: $psExe"
  }
  $scriptPath = [string]$Contract.scriptPath
  if (-not (Test-Path -LiteralPath $scriptPath)) {
    throw "Update script not found: $scriptPath"
  }
  $wd = [string]$Contract.workingDirectory
  $root = [string]$Contract.rootPath
  $arguments = @(
    '-NoProfile',
    '-ExecutionPolicy', 'Bypass',
    '-File', $scriptPath,
    '-Live',
    '-RootPath', $root,
    '-PythonPath', $ResolvedPython
  ) -join ' '
  return [ordered]@{
    taskPath = [string]$Contract.taskPath
    taskName = [string]$Contract.taskName
    description = [string]$Contract.description
    powershellExe = $psExe
    arguments = $arguments
    workingDirectory = $wd
    scriptPath = $scriptPath
    rootPath = $root
    pythonPath = $ResolvedPython
    trigger = $Contract.trigger
    principal = $Contract.principal
    settings = $Contract.settings
    statusFile = [string]$Contract.statusFile
    canonicalBrief = [string]$Contract.canonicalBrief
    logonType = [string]$Contract.principal.logonType
    register = $false
  }
}

function Assert-SafeToMutate {
  if ([string]$Contract.principal.logonType -ne 'Interactive') {
    throw "v1 scheduler must use Interactive logon; Password / S4U is not enabled by this script."
  }
  if ([string]$Contract.workingDirectory -ne $RootPath) {
    throw "Working directory contract does not match this repo: $($Contract.workingDirectory) vs $RootPath"
  }
}

$resolvedPython = Resolve-TaskPython $PythonPath
$resolved = Get-ResolvedTaskDefinition $resolvedPython

if ($DryRun) {
  Write-Output 'TASK_DRY_RUN'
  Write-Output (($resolved | ConvertTo-Json -Compress))
  exit 0
}

Assert-SafeToMutate

if ($Register) {
  $action = New-ScheduledTaskAction -Execute $resolved.powershellExe -Argument $resolved.arguments -WorkingDirectory $resolved.workingDirectory
  $triggerTime = [datetime]::ParseExact([string]$Contract.trigger.at, 'HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)
  $trigger = New-ScheduledTaskTrigger -Daily -At $triggerTime
  $settings = New-ScheduledTaskSettingsSet `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes ([int]$Contract.settings.executionTimeLimitMinutes)) `
    -StartWhenAvailable `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries
  $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
  Register-ScheduledTask `
    -TaskName $resolved.taskName `
    -TaskPath $resolved.taskPath `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -Principal $principal `
    -Description $resolved.description `
    -Force | Out-Null
  Write-Output 'TASK_REGISTERED'
  Write-Output (($resolved | ConvertTo-Json -Compress))
  exit 0
}

if ($Disable) {
  Disable-ScheduledTask -TaskName $resolved.taskName -TaskPath $resolved.taskPath | Out-Null
  Write-Output 'TASK_DISABLED'
  exit 0
}

if ($Unregister) {
  Unregister-ScheduledTask -TaskName $resolved.taskName -TaskPath $resolved.taskPath -Confirm:$false
  Write-Output 'TASK_UNREGISTERED'
  exit 0
}

throw "No scheduler action selected."
