$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$RepoRoot = Split-Path -Parent $PSScriptRoot
$StylePath = Join-Path $RepoRoot 'style.css'
$IndexPath = Join-Path $RepoRoot 'index.html'
$AppPath = Join-Path $RepoRoot 'app.js'
$EnginePath = Join-Path $RepoRoot 'js\data-engine.js'
$WorkflowPath = Join-Path $RepoRoot 'js\workflow-engine.js'
$ServePath = Join-Path $RepoRoot 'serve.ps1'
$BriefPath = Join-Path $RepoRoot 'data\morning-brief.json'

$Utf8 = New-Object System.Text.UTF8Encoding $false
$script:Results = New-Object System.Collections.Generic.List[object]

function Add-TestResult($id, $passed, $details) {
  $status = if ($passed) { 'PASS' } else { 'FAIL' }
  $script:Results.Add([PSCustomObject]@{ Id = $id; Status = $status; Details = $details })
  Write-Output ("{0}: {1}" -f $id, $status)
  if ($details) { Write-Output $details }
}

$css = [System.IO.File]::ReadAllText($StylePath, $Utf8)
$index = [System.IO.File]::ReadAllText($IndexPath, $Utf8)
$mediaNeedle = '@media (max-width: 900px) and (orientation: landscape)'
$mediaIdx = $css.IndexOf($mediaNeedle)
$baseCss = if ($mediaIdx -ge 0) { $css.Substring(0, $mediaIdx) } else { $css }
$mediaCss = if ($mediaIdx -ge 0) { $css.Substring($mediaIdx) } else { '' }

$fail1 = New-Object System.Collections.Generic.List[string]
if ($baseCss -notlike '*aside{width:220px*') { $fail1.Add('desktop aside width 220px missing') }
if ($baseCss -notlike '*explorer-grid{display:grid;grid-template-columns:220px 1fr*') { $fail1.Add('desktop explorer-grid changed') }
if ($baseCss -like '*#cards{*') { $fail1.Add('desktop #cards layout should stay default') }
Add-TestResult 'TEST 1' ($fail1.Count -eq 0) ($fail1 -join "`n")

$fail2 = New-Object System.Collections.Generic.List[string]
if ($mediaIdx -lt 0) { $fail2.Add('phone landscape media query missing') }
if ($mediaCss -notlike '*width: 132px*') { $fail2.Add('landscape aside is not narrowed') }
if ($mediaCss -notlike '*.version-info { display: none; }*' -and $mediaCss -notlike '*.version-info{display:none}*') { $fail2.Add('version-info is not hidden in landscape') }
if ($mediaCss -like '*orientation: portrait*') { $fail2.Add('portrait lock/query should not be required') }
Add-TestResult 'TEST 2' ($fail2.Count -eq 0) ($fail2 -join "`n")

$fail3 = New-Object System.Collections.Generic.List[string]
if ($mediaCss -notlike '*#today.morning-brief*' -or $mediaCss -notlike '*grid-template-columns: 1fr 1fr*') {
  $fail3.Add('today workbench is not a 2-column landscape grid')
}
if ($mediaCss -notlike '*#today.morning-brief > .box:first-child*' -and $mediaCss -notlike '*grid-column: 1 / -1*') {
  $fail3.Add('first today box does not span full width')
}
Add-TestResult 'TEST 3' ($fail3.Count -eq 0) ($fail3 -join "`n")

$fail4 = New-Object System.Collections.Generic.List[string]
if ($mediaCss -notlike '*#cards*' -or $mediaCss -notlike '*#cases*') { $fail4.Add('#cards/#cases landscape rules missing') }
if ($mediaCss -notlike '*minmax(0, 35%)*' -or $mediaCss -notlike '*minmax(0, 65%)*') {
  $fail4.Add('#cards/#cases must be about 35% / 65%, not 50/50')
}
if ($mediaCss -like '*grid-template-columns: 1fr 1fr;*#cards*' -or $mediaCss -like '*#cards*1fr 1fr*') { }
Add-TestResult 'TEST 4' ($fail4.Count -eq 0) ($fail4 -join "`n")

$fail5 = New-Object System.Collections.Generic.List[string]
foreach ($id in @('today', 'morningExecutiveSummary', 'queue', 'cards', 'card', 'cases', 'caseView')) {
  if ($index -notlike ('*id="' + $id + '"*')) { $fail5.Add("index.html missing $id") }
}
if ($index -notlike '*style.css?v=0051*') { $fail5.Add('style cache token is not 0051') }
Add-TestResult 'TEST 5' ($fail5.Count -eq 0) ($fail5 -join "`n")

$fail6 = New-Object System.Collections.Generic.List[string]
$app = [System.IO.File]::ReadAllText($AppPath, $Utf8)
$engine = [System.IO.File]::ReadAllText($EnginePath, $Utf8)
$workflow = [System.IO.File]::ReadAllText($WorkflowPath, $Utf8)
$serve = [System.IO.File]::ReadAllText($ServePath, $Utf8)
$brief = [System.IO.File]::ReadAllText($BriefPath, $Utf8)
if ($app -notlike '*renderMorningBrief(openMorningBriefResearch)*') { $fail6.Add('app.js Morning Brief render missing') }
if ($engine -notlike '*normalizeMorningBrief(*') { $fail6.Add('morning brief normalizer missing') }
if ($workflow -notlike '*this.queue.items.push({ id, addedFrom: source })*') { $fail6.Add('queue schema missing') }
if ($serve -notlike '*http://localhost:$port/*') { $fail6.Add('serve.ps1 localhost bind missing') }
if ($brief -notlike '*"today3Things"*') { $fail6.Add('morning-brief canonical field missing') }
Add-TestResult 'TEST 6' ($fail6.Count -eq 0) ($fail6 -join "`n")

$failed = @($script:Results | Where-Object { $_.Status -ne 'PASS' })
Write-Output ''
Write-Output '=== 012-M LANDSCAPE UI SUMMARY ==='
foreach ($row in $script:Results) {
  Write-Output ("{0}: {1}" -f $row.Id, $row.Status)
}
if ($failed.Count -gt 0) { exit 1 }
exit 0
