# 031-B Morning Brief generator wrapper. Selection + mapping; writes data/morning-brief.json.
param(
  [string]$RootPath,
  [string]$PythonPath
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$env:PYTHONIOENCODING = 'utf-8'

if (-not $RootPath) {
  $RootPath = Split-Path -Parent $PSScriptRoot
}
$RootPath = [System.IO.Path]::GetFullPath($RootPath)
$Generator = Join-Path $PSScriptRoot 'generate-morning-brief.py'
if (-not (Test-Path -LiteralPath $Generator)) {
  throw "Missing generator: $Generator"
}

if (-not $PythonPath) { $PythonPath = $env:INVESTORTWIN_PYTHON }
if (-not $PythonPath) { $PythonPath = 'python' }

$prev = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
  $output = & $PythonPath $Generator --root $RootPath 2>&1
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
