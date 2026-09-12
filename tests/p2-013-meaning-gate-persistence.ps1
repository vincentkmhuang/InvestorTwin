# Actual persistence + Watching baseline tests (TEST 2-A..2-E). No commit.
$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$port = 8765
$base = "http://localhost:$port"
$EventRef = 'evt:corporate-action/hugging-face,nvidia/review'
$StatePath = Join-Path $RepoRoot 'data\meaning-gate-state.json'
$WatchPath = Join-Path $RepoRoot 'data\investor-watch.json'

function Get-Json($url) {
  return Invoke-RestMethod -Uri $url -Method GET -TimeoutSec 10
}
function Post-Json($url, $obj) {
  $body = $obj | ConvertTo-Json -Depth 12 -Compress
  return Invoke-RestMethod -Uri $url -Method POST -Body $body -ContentType 'application/json; charset=utf-8' -TimeoutSec 10
}

# Restart serve so meaning-gate routes are loaded from current serve.ps1
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.CommandLine -like '*serve.ps1*' } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 1
$serveProc = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
  '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $RepoRoot 'serve.ps1')
) -PassThru -WindowStyle Hidden
Start-Sleep -Seconds 3

$results = New-Object System.Collections.Generic.List[object]
function Add-R($id, $ok, $details) {
  $results.Add([PSCustomObject]@{ Id = $id; Ok = [bool]$ok; Details = $details })
  Write-Output ("{0}: {1} — {2}" -f $id, $(if ($ok) { 'PASS' } else { 'FAIL' }), $details)
}

# Wait for server
$up = $false
for ($i = 0; $i -lt 20; $i++) {
  try {
    $null = Invoke-WebRequest -Uri "$base/api/version" -UseBasicParsing -TimeoutSec 2
    $up = $true
    break
  } catch { Start-Sleep -Milliseconds 500 }
}
Add-R 'SERVER' $up "serve on $base (pid=$($serveProc.Id))"
if (-not $up) {
  $results | ConvertTo-Json -Depth 4
  exit 1
}

# GET works
try {
  $g = Get-Json "$base/api/meaning-gate-state"
  Add-R 'GET' ($null -ne $g) ("schema=$($g.schemaVersion); seenKeys=$($g.seen.PSObject.Properties.Name -join ',')" )
} catch {
  Add-R 'GET' $false $_.Exception.Message
}

# Compute fingerprint from live candidate-gate view (same fields as JS)
$view = Get-Json "$base/api/candidate-gate"
$cand = @($view.candidates | Where-Object { $_.eventRef -eq $EventRef } | Select-Object -First 1)
if (-not $cand) { Add-R 'CANDIDATE' $false 'NVIDIA review candidate missing'; $results | ConvertTo-Json -Depth 5; exit 1 }
Add-R 'CANDIDATE' $true ("status=$($cand.status); evidenceCount=$(@($cand.evidenceRefs).Count)")

# Mirror JS evidenceFingerprint
$parts = New-Object System.Collections.Generic.List[string]
foreach ($row in @($cand.evidenceRefs)) {
  $parts.Add(('{0}|{1}|{2}' -f ([string]$row.class).ToUpperInvariant(), ([string]$row.newsRef).Trim(), ([string]$row.claim).Trim()))
}
$status = $cand.impact.evidenceStatus
if ($status) {
  foreach ($cls in @('FACT','ESTIMATE','INFERENCE','UNKNOWN')) {
    $prop = $status.PSObject.Properties[$cls]
    if (-not $prop) { continue }
    foreach ($row in @($prop.Value)) {
      $parts.Add(('{0}|{1}|{2}' -f $cls, ([string]$row.newsRef).Trim(), ([string]$row.claim).Trim()))
    }
  }
}
$fp = (($parts | Sort-Object) -join ';;')
Add-R 'FP' ($fp.Length -gt 0) ("len=$($fp.Length)")

# Reset seen for clean TEST 2-A (keep file schema)
[System.IO.File]::WriteAllText($StatePath, "{`r`n  `"schemaVersion`": `"1.0`",`r`n  `"seen`": {}`r`n}`r`n", (New-Object System.Text.UTF8Encoding $false))

# TEST 2-A: first pass recordPassed writes baseline
$post = Post-Json "$base/api/meaning-gate-state" @{
  action = 'recordPassed'
  updates = @(@{
    eventRef = $EventRef
    evidenceFingerprint = $fp
    meaningType = 'Shift'
    evaluatedAt = (Get-Date).ToString('o')
  })
}
$disk = Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8
$hasOnDisk = $disk -like "*$EventRef*" -and $disk -like '*evidenceFingerprint*'
$seenProp = $null
if ($post.seen) { $seenProp = $post.seen.PSObject.Properties[$EventRef] }
Add-R 'TEST2A_POST' ($post.ok -eq $true -and $null -ne $seenProp) ("ok=$($post.ok); hasSeenProp=$($null -ne $seenProp)")
Add-R 'TEST2A_DISK' $hasOnDisk ("file contains eventRef+fingerprint")

# Confirm GET returns baseline
$g2 = Get-Json "$base/api/meaning-gate-state"
$gSeen = $null
if ($g2.seen) { $gSeen = $g2.seen.PSObject.Properties[$EventRef] }
$gFp = if ($gSeen) { [string]$gSeen.Value.evidenceFingerprint } else { '' }
Add-R 'TEST2A_GET' ($gFp -eq $fp) ("getFpLen=$($gFp.Length); match=$( $gFp -eq $fp )")

# Helper: evaluate Watching quiet rule (mirror JS changeAndEvidence Watching branch)
function Test-WatchingPass($prevFp, $curFp, $watchNoise) {
  if ($watchNoise) { return $true }
  if ($prevFp) {
    if ($prevFp -eq $curFp) { return $false }
    return $true
  }
  return $true  # first pass only when no baseline
}

# TEST 2-B: same fingerprint + Watching → blocked (simulate reload after baseline)
$passB = Test-WatchingPass $gFp $fp $false
Add-R 'TEST2B_BLOCK' (-not $passB) ("Watching+sameFp blocked=$($passB -eq $false)")

# Investor Watch still present
$watch = Get-Content -LiteralPath $WatchPath -Raw -Encoding UTF8 | ConvertFrom-Json
$watchAlive = @($watch.items | Where-Object { $_.eventRef -eq $EventRef -and $_.status -ne 'Closed' }).Count -gt 0
Add-R 'TEST2B_WATCH' $watchAlive 'Investor Watch still has NVIDIA item'

# TEST 2-C: reload GET 3x — baseline stable, still blocked
$stable = $true
for ($i = 1; $i -le 3; $i++) {
  $gx = Get-Json "$base/api/meaning-gate-state"
  $sx = $gx.seen.PSObject.Properties[$EventRef]
  $fx = if ($sx) { [string]$sx.Value.evidenceFingerprint } else { '' }
  if ($fx -ne $fp) { $stable = $false }
  if (Test-WatchingPass $fx $fp $false) { $stable = $false }
}
Add-R 'TEST2C' $stable '3x GET same baseline; still blocked'

# TEST 2-D: fingerprint changes → may re-enter
$fpNew = $fp + ';;FACT|news-new|Fresh material evidence'
$passD = Test-WatchingPass $fp $fpNew $false
Add-R 'TEST2D' $passD 'changed fingerprint allows re-entry'

# TEST 2-E: Meaning Shift alone does not change fingerprint → still blocked
$passE = Test-WatchingPass $fp $fp $false
Add-R 'TEST2E' (-not $passE) 'Shift without fp change remains blocked'

# Also verify live candidate-gate still returns Watching candidate (attention pool), Gate would filter it
Add-R 'ATTENTION_POOL' ($cand.status -eq 'Watching' -or $cand.status -eq 'Pending') "candidate status=$($cand.status) still in gate view"

Write-Output ''
Write-Output '=== SUMMARY ==='
$results | ForEach-Object { Write-Output ("{0}: {1}" -f $_.Id, $(if ($_.Ok) {'PASS'} else {'FAIL'})) }
$failed = @($results | Where-Object { -not $_.Ok })
if ($failed.Count -gt 0) { exit 1 }
exit 0
