# 031-D manual Morning Brief daily update.
# Collector then Generator. One-shot local command only. Do not schedule.
param(
  [string]$RootPath,
  [string]$InputPath,
  [switch]$Live
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$env:PYTHONIOENCODING = 'utf-8'

if (-not $RootPath) {
  $RootPath = Split-Path -Parent $PSScriptRoot
}
$RootPath = [System.IO.Path]::GetFullPath($RootPath)

$CollectScript = Join-Path $PSScriptRoot 'collect-evidence.ps1'
$GenerateScript = Join-Path $PSScriptRoot 'generate-morning-brief.ps1'
if (-not (Test-Path -LiteralPath $CollectScript)) { throw "Missing collector wrapper: $CollectScript" }
if (-not (Test-Path -LiteralPath $GenerateScript)) { throw "Missing generator wrapper: $GenerateScript" }

if ($Live -and $InputPath) {
  throw "Use either -InputPath or -Live, not both."
}
if (-not $Live -and -not $InputPath) {
  throw "InputPath fixture is required unless -Live is set."
}

$collectArgs = @{
  RootPath = $RootPath
}
if ($Live) { $collectArgs.Live = $true }
if ($InputPath) { $collectArgs.InputPath = $InputPath }

Write-Output 'DAILY_UPDATE_COLLECT'
& $CollectScript @collectArgs
$collectCode = $LASTEXITCODE
if ($collectCode -ne 0) {
  Write-Output 'DAILY_UPDATE_FAIL'
  exit $collectCode
}

Write-Output 'DAILY_UPDATE_GENERATE'
& $GenerateScript -RootPath $RootPath
$generateCode = $LASTEXITCODE
if ($generateCode -ne 0) {
  Write-Output 'DAILY_UPDATE_FAIL'
  exit $generateCode
}

Write-Output 'DAILY_UPDATE_OK'
exit 0
