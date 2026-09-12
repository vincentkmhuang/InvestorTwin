$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$GateJs = Join-Path $RepoRoot 'js\investment-meaning-gate.js'
$GateClient = Join-Path $RepoRoot 'js\candidate-gate.js'
$AppJs = Join-Path $RepoRoot 'app.js'
$IndexHtml = Join-Path $RepoRoot 'index.html'
$PyTest = Join-Path $PSScriptRoot 'p2-013-investment-meaning-gate.py'
$GenPy = Join-Path $RepoRoot 'scripts\generate-morning-brief.py'
# UTF-8 empty-state product sentence bytes (Today has no attention-worthy investment changes.)
$EmptyNeedle = [System.Text.Encoding]::UTF8.GetString([byte[]](
  0xE4,0xBB,0x8A,0xE5,0xA4,0xA9,0xE6,0xB2,0x92,0xE6,0x9C,0x89,0xE9,0x9C,0x80,0xE8,0xA6,0x81,
  0xE7,0x89,0xB9,0xE5,0x88,0xA5,0xE6,0x8F,0x90,0xE9,0xAB,0x98,0xE6,0xB3,0xA8,0xE6,0x84,0x8F,
  0xE5,0x8A,0x9B,0xE7,0x9A,0x84,0xE6,0x8A,0x95,0xE8,0xB3,0x87,0xE8,0xAE,0x8A,0xE5,0x8C,0x96,
  0xE3,0x80,0x82
))

$script:Results = New-Object System.Collections.Generic.List[object]
function Add-TestResult($id, $passed, $details) {
  $status = if ($passed) { 'PASS' } else { 'FAIL' }
  $script:Results.Add([PSCustomObject]@{ Id = $id; Status = $status; Details = $details })
  Write-Output ("{0}: {1}" -f $id, $status)
  if ($details) { Write-Output $details }
}

foreach ($path in @($GateJs, $GateClient, $AppJs, $IndexHtml, $PyTest, $GenPy)) {
  if (-not (Test-Path -LiteralPath $path)) { throw "Missing: $path" }
}

$Utf8 = New-Object System.Text.UTF8Encoding $false
$gateSrc = [System.IO.File]::ReadAllText($GateJs, $Utf8)
$clientSrc = [System.IO.File]::ReadAllText($GateClient, $Utf8)
$appSrc = [System.IO.File]::ReadAllText($AppJs, $Utf8)
$html = [System.IO.File]::ReadAllText($IndexHtml, $Utf8)

# Structure / wiring
$failS = New-Object System.Collections.Generic.List[string]
if ($gateSrc -notlike '*InvestmentMeaningGate*') { $failS.Add('InvestmentMeaningGate missing') }
if ($gateSrc -notlike '*filterForToday*') { $failS.Add('filterForToday missing') }
if ($gateSrc -notlike '*watching_without_new_evidence*') { $failS.Add('Watching quiet rule missing') }
if ($gateSrc -notlike '*personal_relevance*') { $failS.Add('personal relevance rule missing') }
if ($clientSrc -notlike '*attentionCandidatesForToday*') { $failS.Add('attentionCandidatesForToday missing') }
if ($clientSrc -notlike '*InvestmentMeaningGate.filterForToday*') { $failS.Add('client does not call Meaning Gate filter') }
if ($appSrc -notlike '*attentionCandidatesForToday*') { $failS.Add('Today render does not use Meaning Gate path') }
if ($html -notlike '*investment-meaning-gate.js*') { $failS.Add('meaning gate script not in index.html') }
if ($html -notlike '*todayMeaningEmpty*') { $failS.Add('empty state container missing') }
if ($html.IndexOf($EmptyNeedle) -lt 0) { $failS.Add('empty state product copy missing') }
if ($html -like '*id="todayMarketTemperature"*') { $failS.Add('Market Temperature leaked back into Today') }
if ($html -like '*id="todayGlobalMarket"*') { $failS.Add('Global market leaked back into Today') }
Add-TestResult 'TEST 013-WIRE' ($failS.Count -eq 0) ($failS -join "`n")

# Python mirror of TEST 1-6
$pyOut = & python $PyTest 2>&1 | Out-String
$pyOk = ($LASTEXITCODE -eq 0)
Add-TestResult 'TEST 013-RULES' $pyOk $(if ($pyOk) { 'TEST1-6 rule mirror PASS' } else { $pyOut.Substring(0, [Math]::Min(2500, $pyOut.Length)) })

# Explicit case names from python JSON if present
try {
  $jsonLine = ($pyOut | Select-String -Pattern '"name":' -SimpleMatch -NotMatch | Out-String)
  $parsed = $pyOut | ConvertFrom-Json -ErrorAction SilentlyContinue
  if (-not $parsed) {
    # full stdout is JSON
    $parsed = ($pyOut.Trim() | ConvertFrom-Json)
  }
  if ($parsed -and $parsed.results) {
    foreach ($row in $parsed.results) {
      Add-TestResult $row.name ([bool]$row.ok) ("passed=$($row.passed); expect=$($row.expect_pass); reason=$($row.reason -join ',')")
    }
  }
} catch {
  Add-TestResult 'TEST 013-PARSE' $false ([string]$_)
}

# TEST 7 empty-state product language (no No Data / No Candidate)
$fail7 = New-Object System.Collections.Generic.List[string]
if ($html.IndexOf($EmptyNeedle) -lt 0) { $fail7.Add('empty product sentence missing') }
if ($html -match '(?i)no data') { $fail7.Add('No Data wording present') }
if ($html -match '(?i)no candidate') { $fail7.Add('No Candidate wording present') }
if ($appSrc -notlike '*todayMeaningEmpty*') { $fail7.Add('empty state not driven from Today render') }
Add-TestResult 'TEST7_empty_state' ($fail7.Count -eq 0) ($fail7 -join "`n")

# Generator untouched
$genDiff = & git -C $RepoRoot diff --name-only -- scripts/generate-morning-brief.py
Add-TestResult 'TEST 013-GEN' ([string]::IsNullOrWhiteSpace($genDiff)) $(if ($genDiff) { "generator dirty: $genDiff" } else { 'generate-morning-brief.py untouched' })

# serve parse
$errs = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'serve.ps1'), [ref]$null, [ref]$errs)
Add-TestResult 'TEST 013-SERVE' (-not ($errs -and $errs.Count)) $(if ($errs) { ($errs | Select-Object -First 3 | ForEach-Object { $_.ToString() }) -join "`n" } else { 'serve.ps1 parse OK' })

Write-Output ''
Write-Output '=== P2-013 SUMMARY ==='
$script:Results | ForEach-Object {
  Write-Output ("{0}: {1}" -f $_.Id, $_.Status)
  if ($_.Details) { Write-Output $_.Details }
}
$failed = @($script:Results | Where-Object { $_.Status -ne 'PASS' })
if ($failed.Count -gt 0) { exit 1 }
exit 0
