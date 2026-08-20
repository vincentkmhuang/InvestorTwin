$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$RepoRoot = Split-Path -Parent $PSScriptRoot
$FixturePath = Join-Path $PSScriptRoot 'fixtures\3363-glass-bridge.ownership.json'
$ProdCasesPath = Join-Path $RepoRoot 'data\investment-cases.json'
$CaseId = '3363-glass-bridge'

if (-not (Test-Path $FixturePath)) { throw "Missing fixture: $FixturePath" }
if (-not (Test-Path $ProdCasesPath)) { throw "Missing production store: $ProdCasesPath" }

$Utf8 = New-Object System.Text.UTF8Encoding $false
$ProdHashBefore = (Get-FileHash -Path $ProdCasesPath -Algorithm SHA256).Hash
$Fixture = [System.IO.File]::ReadAllText($FixturePath, $Utf8) | ConvertFrom-Json

$script:Results = New-Object System.Collections.Generic.List[object]
$script:TempRoot = Join-Path $env:TEMP ('InvestorTwin-010-C-1-' + [guid]::NewGuid().ToString('N'))
$script:TempCasesPath = $null
$script:TestPort = $null
$script:ServerProc = $null

function Get-StableJson($value) {
  $payload = $value | ConvertTo-Json -Depth 60 -Compress
  $py = Join-Path $script:TempRoot 'stable_json.py'
  if (-not (Test-Path $py)) {
    $code = @'
import json, sys

def norm(o):
    if isinstance(o, dict):
        return {str(k): norm(v) for k, v in o.items()}
    if isinstance(o, list):
        return [norm(v) for v in o]
    if isinstance(o, bool) or o is None:
        return o
    if isinstance(o, int):
        return o
    if isinstance(o, float):
        if o != o or o in (float("inf"), float("-inf")):
            return None
        if abs(o) < 1e15 and o == int(o):
            return int(o)
        return o
    return o

raw = sys.stdin.read()
if not raw.strip():
    print("null")
else:
    print(json.dumps(norm(json.loads(raw)), ensure_ascii=False, sort_keys=True, separators=(",", ":")))
'@
    [System.IO.File]::WriteAllText($py, $code, $Utf8)
  }
  return ($payload | & python $py)
}

function Test-SameJson($left, $right) {
  return ((Get-StableJson $left) -eq (Get-StableJson $right))
}

function Get-CaseMap($path) {
  $py = Join-Path $script:TempRoot 'load_case.py'
  if (-not (Test-Path $py)) {
    $code = @'
import json, sys
path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    store = json.load(f)
case = next(c for c in store["cases"] if c["id"] == "3363-glass-bridge")
print(json.dumps(case, ensure_ascii=False, separators=(",", ":")))
'@
    [System.IO.File]::WriteAllText($py, $code, $Utf8)
  }
  $raw = & python $py $path
  if ($LASTEXITCODE -ne 0) { throw "load_case.py failed for $path" }
  return ($raw | ConvertFrom-Json)
}

function Get-OwnershipSlice($caseObj) {
  $thesis = $caseObj.thesis
  return [PSCustomObject]@{
    supportingEvidence = $thesis.supportingEvidence
    counterEvidence = $thesis.counterEvidence
    toBeVerified = $thesis.toBeVerified
    thesisText = $thesis.thesis
    thesisStatus = $thesis.status
    valuation = $caseObj.valuation
    decision = $caseObj.decision
    decisionHistory = $caseObj.decisionHistory
    positionPlaybook = $caseObj.positionPlaybook
    caseStatus = $caseObj.status
  }
}

function Write-TempStoreFromFixture {
  $py = Join-Path $script:TempRoot 'seed_store.py'
  $code = @'
import json, sys
fixture_path, out_path = sys.argv[1], sys.argv[2]
with open(fixture_path, encoding="utf-8") as f:
    fx = json.load(f)
store = {
    "schemaVersion": "1.0",
    "updated": "2026-08-20",
    "cases": [fx["case"]]
}
with open(out_path, "w", encoding="utf-8", newline="\n") as f:
    json.dump(store, f, ensure_ascii=False, separators=(",", ":"))
    f.write("\n")
'@
  [System.IO.File]::WriteAllText($py, $code, $Utf8)
  & python $py $FixturePath $script:TempCasesPath
}

function Set-TempPlaybookAddPosition($value) {
  $py = Join-Path $script:TempRoot 'set_add_position.py'
  $code = @'
import json, sys
path = sys.argv[1]
value = sys.argv[2] if len(sys.argv) > 2 else ""
if value == "__NULL__":
    value = None
with open(path, encoding="utf-8") as f:
    store = json.load(f)
case = next(c for c in store["cases"] if c["id"] == "3363-glass-bridge")
case["positionPlaybook"]["addPosition"] = value
with open(path, "w", encoding="utf-8", newline="\n") as f:
    json.dump(store, f, ensure_ascii=False, separators=(",", ":"))
    f.write("\n")
'@
  [System.IO.File]::WriteAllText($py, $code, $Utf8)
  & python $py $script:TempCasesPath $value
  if ($LASTEXITCODE -ne 0) { throw "set_add_position.py failed" }
}

function Invoke-CasesPostJson($json) {
  $bytes = $Utf8.GetBytes($json)
  $uri = "http://localhost:$($script:TestPort)/api/cases"
  try {
    $resp = Invoke-WebRequest -Uri $uri -Method POST -Body $bytes -ContentType 'application/json; charset=utf-8' -UseBasicParsing
    return @{ StatusCode = [int]$resp.StatusCode; Body = $resp.Content; Json = $json }
  } catch [System.Net.WebException] {
    $http = $_.Exception.Response
    if (-not $http) { throw }
    $code = [int]$http.StatusCode
    $stream = $http.GetResponseStream()
    $reader = New-Object System.IO.StreamReader($stream, $Utf8)
    $content = $reader.ReadToEnd()
    $reader.Close()
    return @{ StatusCode = $code; Body = $content; Json = $json }
  }
}

function Invoke-CasesPost($object) {
  $json = $object | ConvertTo-Json -Depth 20 -Compress
  return Invoke-CasesPostJson $json
}

function Add-TestResult($id, $passed, $details) {
  $status = if ($passed) { 'PASS' } else { 'FAIL' }
  $item = [PSCustomObject]@{ Id = $id; Status = $status; Details = $details }
  $script:Results.Add($item)
  Write-Output ("{0}: {1}" -f $id, $status)
  if ($details) { Write-Output $details }
}

function Assert-Unchanged($label, $before, $after) {
  if (Test-SameJson $before $after) { return $null }
  return ("{0} changed.`nBEFORE={1}`nAFTER={2}" -f $label, (Get-StableJson $before), (Get-StableJson $after))
}

function New-PatchedServeScript($sourcePath, $destPath) {
  $src = [System.IO.File]::ReadAllText($sourcePath, $Utf8)
  $needle = 'Write-Output "Serving HTTP on http://localhost:$port/"'
  $idx = $src.IndexOf($needle)
  if ($idx -lt 0) {
    throw 'Unable to patch temp serve.ps1 header; production file was not modified.'
  }
  $end = $idx + $needle.Length
  if ($end -lt $src.Length -and $src[$end] -eq "`r") { $end++ }
  if ($end -lt $src.Length -and $src[$end] -eq "`n") { $end++ }
  $header = @'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$port = [int]$env:INVESTORTWIN_TEST_PORT
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$port/")
try {
  $listener.Start()
} catch {
  Write-Error "Port $port is in use. Close the existing server and run serve.ps1 again."
  exit 1
}
Write-Output "Serving HTTP on http://localhost:$port/"

'@
  [System.IO.File]::WriteAllText($destPath, ($header + $src.Substring($end)), $Utf8)
}

function Start-TempServer {
  New-Item -ItemType Directory -Path $script:TempRoot | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $script:TempRoot 'data') | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $script:TempRoot 'scripts') | Out-Null

  $script:TempCasesPath = Join-Path $script:TempRoot 'data\investment-cases.json'
  Copy-Item (Join-Path $RepoRoot 'data\version.json') (Join-Path $script:TempRoot 'data\version.json') -ErrorAction SilentlyContinue
  Copy-Item (Join-Path $RepoRoot 'scripts\generate-knowledge-index.ps1') (Join-Path $script:TempRoot 'scripts\generate-knowledge-index.ps1')
  New-PatchedServeScript (Join-Path $RepoRoot 'serve.ps1') (Join-Path $script:TempRoot 'serve.ps1')
  Write-TempStoreFromFixture

  $ports = 18765, 18766, 18767, 18768
  $started = $false
  foreach ($port in $ports) {
    $script:TestPort = $port
    $env:INVESTORTWIN_TEST_PORT = [string]$port
    $outLog = Join-Path $script:TempRoot 'serve.out.log'
    $errLog = Join-Path $script:TempRoot 'serve.err.log'
    $script:ServerProc = Start-Process -FilePath 'powershell.exe' -WorkingDirectory $script:TempRoot -PassThru -WindowStyle Hidden `
      -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', '.\serve.ps1') `
      -RedirectStandardOutput $outLog -RedirectStandardError $errLog
    for ($i = 0; $i -lt 25; $i++) {
      Start-Sleep -Milliseconds 200
      if ($script:ServerProc.HasExited) { break }
      try {
        $probe = Invoke-WebRequest -Uri ("http://localhost:{0}/data/investment-cases.json" -f $port) -UseBasicParsing
        if ($probe.StatusCode -eq 200) { $started = $true; break }
      } catch { }
    }
    if ($started) { break }
    if ($script:ServerProc -and -not $script:ServerProc.HasExited) {
      Stop-Process -Id $script:ServerProc.Id -Force -ErrorAction SilentlyContinue
    }
  }
  if (-not $started) {
    $err = ''
    $errLog = Join-Path $script:TempRoot 'serve.err.log'
    if (Test-Path $errLog) { $err = [System.IO.File]::ReadAllText($errLog) }
    throw "Temp serve.ps1 failed to start. $err"
  }
}

function Stop-TempServer {
  if ($script:ServerProc -and -not $script:ServerProc.HasExited) {
    Stop-Process -Id $script:ServerProc.Id -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 300
  }
}

function Invoke-Test($id, $body, $expectStatus, $assert) {
  Write-TempStoreFromFixture
  $before = Get-OwnershipSlice (Get-CaseMap $script:TempCasesPath)
  $resp = Invoke-CasesPost $body
  $afterCase = Get-CaseMap $script:TempCasesPath
  $after = Get-OwnershipSlice $afterCase
  $failures = New-Object System.Collections.Generic.List[string]
  if ([int]$resp.StatusCode -ne [int]$expectStatus) {
    $failures.Add(("HTTP {0} (expected {1}). body={2}" -f $resp.StatusCode, $expectStatus, $resp.Body))
  }
  foreach ($msg in @(& $assert $before $after $resp $afterCase)) {
    if ($msg) { $failures.Add([string]$msg) }
  }
  $passed = ($failures.Count -eq 0)
  $details = if ($passed) { '' } else { ($failures -join "`n") }
  Add-TestResult $id $passed $details
}

try {
  Start-TempServer

  $evidenceText = '010-C-1 supporting evidence'
  $reviewReason = '010-C-1 decision regression'
  $newTarget = '010-C-1 new target'
  $reviewDecision = [PSCustomObject]@{
    stance = 'review'
    asOf = '2026-08-20'
    reason = $reviewReason
    basedOn = [PSCustomObject]@{
      researchIds = @('glass-bridge', 'fau')
      supportingCount = 3
      counterCount = 1
      thesisStatus = 'forming'
    }
  }

  Invoke-Test 'TEST 1' ([PSCustomObject]@{
    id = $CaseId
    thesisEvidence = [PSCustomObject]@{
      side = 'supporting'
      text = $evidenceText
      researchId = 'glass-bridge'
    }
  }) 200 {
    param($before, $after, $resp, $caseObj)
    $msgs = @()
    $msgs += Assert-Unchanged 'decision' $before.decision $after.decision
    $msgs += Assert-Unchanged 'decisionHistory' $before.decisionHistory $after.decisionHistory
    $msgs += Assert-Unchanged 'valuation' $before.valuation $after.valuation
    $msgs += Assert-Unchanged 'positionPlaybook' $before.positionPlaybook $after.positionPlaybook
    $msgs += Assert-Unchanged 'thesis.status' $before.thesisStatus $after.thesisStatus
    $msgs += Assert-Unchanged 'counterEvidence' $before.counterEvidence $after.counterEvidence
    $support = @($after.supportingEvidence)
    if ($support.Count -ne 4) { $msgs += "supportingEvidence count=$($support.Count) expected 4" }
    elseif ($support[-1].text -ne $evidenceText) { $msgs += 'new supporting evidence was not appended' }
    return $msgs
  }

  Invoke-Test 'TEST 2' ([PSCustomObject]@{
    id = $CaseId
    marginOfSafety = 0.25
  }) 200 {
    param($before, $after, $resp, $caseObj)
    $msgs = @()
    $msgs += Assert-Unchanged 'supportingEvidence' $before.supportingEvidence $after.supportingEvidence
    $msgs += Assert-Unchanged 'counterEvidence' $before.counterEvidence $after.counterEvidence
    $msgs += Assert-Unchanged 'decision' $before.decision $after.decision
    $msgs += Assert-Unchanged 'decisionHistory' $before.decisionHistory $after.decisionHistory
    $msgs += Assert-Unchanged 'positionPlaybook' $before.positionPlaybook $after.positionPlaybook
    $msgs += Assert-Unchanged 'thesis.status' $before.thesisStatus $after.thesisStatus
    if ([double]$after.valuation.marginOfSafety -ne 0.25) {
      $msgs += "marginOfSafety=$($after.valuation.marginOfSafety) expected 0.25"
    }
    return $msgs
  }

  Invoke-Test 'TEST 3' ([PSCustomObject]@{
    id = $CaseId
    decision = $reviewDecision
  }) 200 {
    param($before, $after, $resp, $caseObj)
    $msgs = @()
    $msgs += Assert-Unchanged 'supportingEvidence' $before.supportingEvidence $after.supportingEvidence
    $msgs += Assert-Unchanged 'counterEvidence' $before.counterEvidence $after.counterEvidence
    $msgs += Assert-Unchanged 'valuation' $before.valuation $after.valuation
    $msgs += Assert-Unchanged 'positionPlaybook' $before.positionPlaybook $after.positionPlaybook
    $msgs += Assert-Unchanged 'thesis.status' $before.thesisStatus $after.thesisStatus
    if ($after.decision.stance -ne 'review') { $msgs += "decision.stance=$($after.decision.stance) expected review" }
    if ($after.decision.reason -ne $reviewReason) { $msgs += 'decision.reason was not saved' }
    $hist = @($after.decisionHistory)
    if ($hist.Count -ne 2) {
      $msgs += "decisionHistory count=$($hist.Count) expected 2"
    } else {
      $msgs += Assert-Unchanged 'history[0] original watch' @($before.decisionHistory)[0] $hist[0]
      $msgs += Assert-Unchanged 'history[1] previous pass' $before.decision $hist[1]
    }
    return $msgs
  }

  Invoke-Test 'TEST 4' ([PSCustomObject]@{
    id = $CaseId
    positionPlaybook = [PSCustomObject]@{
      targetPosition = $newTarget
      initialPosition = $Fixture.positionPlaybook.initialPosition
      entryTriggers = $Fixture.positionPlaybook.entryTriggers
    }
  }) 200 {
    param($before, $after, $resp, $caseObj)
    $msgs = @()
    $msgs += Assert-Unchanged 'supportingEvidence' $before.supportingEvidence $after.supportingEvidence
    $msgs += Assert-Unchanged 'counterEvidence' $before.counterEvidence $after.counterEvidence
    $msgs += Assert-Unchanged 'valuation' $before.valuation $after.valuation
    $msgs += Assert-Unchanged 'decision' $before.decision $after.decision
    $msgs += Assert-Unchanged 'decisionHistory' $before.decisionHistory $after.decisionHistory
    $msgs += Assert-Unchanged 'thesis.status' $before.thesisStatus $after.thesisStatus
    if ($after.positionPlaybook.targetPosition -ne $newTarget) {
      $msgs += "targetPosition=$($after.positionPlaybook.targetPosition) expected $newTarget"
    }
    $msgs += Assert-Unchanged 'initialPosition' $before.positionPlaybook.initialPosition $after.positionPlaybook.initialPosition
    $msgs += Assert-Unchanged 'entryTriggers' $before.positionPlaybook.entryTriggers $after.positionPlaybook.entryTriggers
    $msgs += Assert-Unchanged 'addPosition' $before.positionPlaybook.addPosition $after.positionPlaybook.addPosition
    $msgs += Assert-Unchanged 'addConditions' $before.positionPlaybook.addConditions $after.positionPlaybook.addConditions
    $msgs += Assert-Unchanged 'exitConditions' $before.positionPlaybook.exitConditions $after.positionPlaybook.exitConditions
    $msgs += Assert-Unchanged 'monitoringItems' $before.positionPlaybook.monitoringItems $after.positionPlaybook.monitoringItems
    return $msgs
  }

  Invoke-Test 'TEST 5' ([PSCustomObject]@{
    id = $CaseId
    positionPlaybook = [PSCustomObject]@{
      targetPosition = $newTarget
    }
  }) 200 {
    param($before, $after, $resp, $caseObj)
    $msgs = @()
    $msgs += Assert-Unchanged 'supportingEvidence' $before.supportingEvidence $after.supportingEvidence
    $msgs += Assert-Unchanged 'counterEvidence' $before.counterEvidence $after.counterEvidence
    $msgs += Assert-Unchanged 'valuation' $before.valuation $after.valuation
    $msgs += Assert-Unchanged 'decision' $before.decision $after.decision
    $msgs += Assert-Unchanged 'decisionHistory' $before.decisionHistory $after.decisionHistory
    if ($after.positionPlaybook.targetPosition -ne $newTarget) {
      $msgs += "targetPosition=$($after.positionPlaybook.targetPosition) expected $newTarget"
    }
    $msgs += Assert-Unchanged 'initialPosition (missing property must keep value)' $before.positionPlaybook.initialPosition $after.positionPlaybook.initialPosition
    $msgs += Assert-Unchanged 'entryTriggers (missing property must keep value)' $before.positionPlaybook.entryTriggers $after.positionPlaybook.entryTriggers
    $msgs += Assert-Unchanged 'addPosition' $before.positionPlaybook.addPosition $after.positionPlaybook.addPosition
    $msgs += Assert-Unchanged 'addConditions' $before.positionPlaybook.addConditions $after.positionPlaybook.addConditions
    $msgs += Assert-Unchanged 'exitConditions' $before.positionPlaybook.exitConditions $after.positionPlaybook.exitConditions
    $msgs += Assert-Unchanged 'monitoringItems' $before.positionPlaybook.monitoringItems $after.positionPlaybook.monitoringItems
    return $msgs
  }

  Write-TempStoreFromFixture
  $before5b = Get-OwnershipSlice (Get-CaseMap $script:TempCasesPath)
  $resp5b = Invoke-CasesPostJson ('{"id":"' + $CaseId + '","positionPlaybook":null}')
  $after5b = Get-OwnershipSlice (Get-CaseMap $script:TempCasesPath)
  $fail5b = New-Object System.Collections.Generic.List[string]
  if ([int]$resp5b.StatusCode -ne 400) {
    $fail5b.Add(("HTTP {0} (expected 400). body={1}" -f $resp5b.StatusCode, $resp5b.Body))
  }
  foreach ($msg in @(
      (Assert-Unchanged 'positionPlaybook' $before5b.positionPlaybook $after5b.positionPlaybook)
      (Assert-Unchanged 'decision' $before5b.decision $after5b.decision)
      (Assert-Unchanged 'decisionHistory' $before5b.decisionHistory $after5b.decisionHistory)
      (Assert-Unchanged 'valuation' $before5b.valuation $after5b.valuation)
      (Assert-Unchanged 'supportingEvidence' $before5b.supportingEvidence $after5b.supportingEvidence)
    )) {
    if ($msg) { $fail5b.Add([string]$msg) }
  }
  Add-TestResult 'TEST 5b' ($fail5b.Count -eq 0) ($fail5b -join "`n")

  Write-TempStoreFromFixture
  Set-TempPlaybookAddPosition '010-C-1-add-position'
  $before5c = Get-OwnershipSlice (Get-CaseMap $script:TempCasesPath)
  $resp5c = Invoke-CasesPostJson ('{"id":"' + $CaseId + '","positionPlaybook":{"addPosition":null}}')
  $after5cCase = Get-CaseMap $script:TempCasesPath
  $after5c = Get-OwnershipSlice $after5cCase
  $fail5c = New-Object System.Collections.Generic.List[string]
  if ([int]$resp5c.StatusCode -ne 200) {
    $fail5c.Add(("HTTP {0} (expected 200). body={1}" -f $resp5c.StatusCode, $resp5c.Body))
  }
  if ($null -ne $after5c.positionPlaybook.addPosition) {
    $fail5c.Add("addPosition=$($after5c.positionPlaybook.addPosition) expected null")
  }
  foreach ($msg in @(
      (Assert-Unchanged 'targetPosition' $before5c.positionPlaybook.targetPosition $after5c.positionPlaybook.targetPosition)
      (Assert-Unchanged 'initialPosition' $before5c.positionPlaybook.initialPosition $after5c.positionPlaybook.initialPosition)
      (Assert-Unchanged 'entryTriggers' $before5c.positionPlaybook.entryTriggers $after5c.positionPlaybook.entryTriggers)
      (Assert-Unchanged 'addConditions' $before5c.positionPlaybook.addConditions $after5c.positionPlaybook.addConditions)
      (Assert-Unchanged 'exitConditions' $before5c.positionPlaybook.exitConditions $after5c.positionPlaybook.exitConditions)
      (Assert-Unchanged 'monitoringItems' $before5c.positionPlaybook.monitoringItems $after5c.positionPlaybook.monitoringItems)
      (Assert-Unchanged 'decision' $before5c.decision $after5c.decision)
      (Assert-Unchanged 'valuation' $before5c.valuation $after5c.valuation)
      (Assert-Unchanged 'supportingEvidence' $before5c.supportingEvidence $after5c.supportingEvidence)
    )) {
    if ($msg) { $fail5c.Add([string]$msg) }
  }
  Add-TestResult 'TEST 5c' ($fail5c.Count -eq 0) ($fail5c -join "`n")

  Invoke-Test 'TEST 6' ([PSCustomObject]@{
    id = $CaseId
    decision = $reviewDecision
  }) 200 {
    param($before, $after, $resp, $caseObj)
    $msgs = @()
    $msgs += Assert-Unchanged 'thesis.text' $before.thesisText $after.thesisText
    $msgs += Assert-Unchanged 'thesis.status' $before.thesisStatus $after.thesisStatus
    $msgs += Assert-Unchanged 'supportingEvidence' $before.supportingEvidence $after.supportingEvidence
    $msgs += Assert-Unchanged 'counterEvidence' $before.counterEvidence $after.counterEvidence
    $msgs += Assert-Unchanged 'toBeVerified' $before.toBeVerified $after.toBeVerified
    $msgs += Assert-Unchanged 'valuation' $before.valuation $after.valuation
    $msgs += Assert-Unchanged 'positionPlaybook' $before.positionPlaybook $after.positionPlaybook
    $msgs += Assert-Unchanged 'case.status' $before.caseStatus $after.caseStatus
    if ($after.decision.stance -ne 'review') { $msgs += "decision.stance=$($after.decision.stance) expected review" }
    $hist = @($after.decisionHistory)
    if ($hist.Count -ne 2) {
      $msgs += "decisionHistory count=$($hist.Count) expected 2 (append only)"
    } else {
      $msgs += Assert-Unchanged 'history[0]' @($before.decisionHistory)[0] $hist[0]
      $msgs += Assert-Unchanged 'history[1] previous decision' $before.decision $hist[1]
    }
    return $msgs
  }

  Write-TempStoreFromFixture
}
catch {
  Add-TestResult 'SETUP' $false $_.Exception.Message
}
finally {
  Stop-TempServer
  $ProdHashAfter = (Get-FileHash -Path $ProdCasesPath -Algorithm SHA256).Hash
  if ($ProdHashBefore -ne $ProdHashAfter) {
    Add-TestResult 'PRODUCTION_FILE_GUARD' $false 'data/investment-cases.json was modified; this is a test-harness failure'
  } else {
    Add-TestResult 'PRODUCTION_FILE_GUARD' $true ''
  }
  if (Test-Path $script:TempRoot) {
    Remove-Item -Recurse -Force $script:TempRoot -ErrorAction SilentlyContinue
  }
}

Write-Output ''
Write-Output '=== 010-C-1 SUMMARY ==='
foreach ($row in $script:Results) {
  if ($row.Status -eq 'PASS') {
    Write-Output ("{0}: PASS" -f $row.Id)
  } else {
    Write-Output ("{0}: FAIL" -f $row.Id)
    if ($row.Details) { Write-Output $row.Details }
  }
}
$failed = @($script:Results | Where-Object { $_.Status -ne 'PASS' })
if ($failed.Count -gt 0) { exit 1 } else { exit 0 }
