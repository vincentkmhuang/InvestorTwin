# 031-A Morning Brief generator wrapper. Reads Evidence, writes data/morning-brief.json.
param(
  [string]$RootPath
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

$prev = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
  $output = & python $Generator --root $RootPath 2>&1
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
