param(
  [string]$InputPath,
  [string]$RootPath,
  [string]$ExpectedAsOf,
  [string]$CapturedAt,
  [switch]$Live
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$env:PYTHONIOENCODING = 'utf-8'

if (-not $RootPath) {
  $RootPath = Split-Path -Parent $PSScriptRoot
}
$RootPath = [System.IO.Path]::GetFullPath($RootPath)
$Collector = Join-Path $PSScriptRoot 'collect-evidence.py'
if (-not (Test-Path -LiteralPath $Collector)) {
  throw "Missing collector: $Collector"
}

if ($Live -and $InputPath) {
  throw "Use either -InputPath or -Live, not both."
}
if (-not $Live -and -not $InputPath) {
  throw "InputPath fixture is required unless -Live is set."
}
if ($InputPath) {
  $InputPath = [System.IO.Path]::GetFullPath($InputPath)
  if (-not (Test-Path -LiteralPath $InputPath)) {
    throw "Input file not found: $InputPath"
  }
}

$pyArgs = @($Collector, '--root', $RootPath)
if ($InputPath) { $pyArgs += @('--input', $InputPath) }
if ($ExpectedAsOf) { $pyArgs += @('--expected-asof', $ExpectedAsOf) }
if ($CapturedAt) { $pyArgs += @('--captured-at', $CapturedAt) }
if ($Live) { $pyArgs += '--live' }

$prev = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
  $output = & python @pyArgs 2>&1
  $exitCode = $LASTEXITCODE
} finally {
  $ErrorActionPreference = $prev
}

$text = ($output | ForEach-Object { "$_" }) -join "`n"
Write-Output $text
if ($exitCode -ne 0) {
  exit $exitCode
}
exit 0
