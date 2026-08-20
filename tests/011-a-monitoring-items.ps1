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

$script:Results = New-Object System.Collections.Generic.List[object]
$script:TempRoot = Join-Path $env:TEMP ('InvestorTwin-011-A-' + [guid]::NewGuid().ToString('N'))
$script:TempCasesPath = $null
$script:TestPort = $null
$script:ServerProc = $null

function Add-TestResult($id, $passed, $details) {
  $status = if ($passed) { 'PASS' } else { 'FAIL' }
  $script:Results.Add([PSCustomObject]@{ Id = $id; Status = $status; Details = $details })
  Write-Output ("{0}: {1}" -f $id, $status)
  if ($details) { Write-Output $details }
}

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
    if isinstance(o, float) and o == int(o) and abs(o) < 1e15:
        return int(o)
    return o
raw = sys.stdin.read()
print("null" if not raw.strip() else json.dumps(norm(json.loads(raw)), ensure_ascii=False, sort_keys=True, separators=(",", ":")))
'@
    [System.IO.File]::WriteAllText($py, $code, $Utf8)
  }
  return ($payload | & python $py)
}

function Test-SameJson($left, $right) {
  return ((Get-StableJson $left) -eq (Get-StableJson $right))
}

function Get-CasePy($path) {
  $py = Join-Path $script:TempRoot 'load_case.py'
  if (-not (Test-Path $py)) {
    [System.IO.File]::WriteAllText($py, @'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    store = json.load(f)
case = next(c for c in store["cases"] if c["id"] == "3363-glass-bridge")
print(json.dumps(case, ensure_ascii=False, separators=(",", ":")))
'@, $Utf8)
  }
  $raw = & python $py $path
  if ($LASTEXITCODE -ne 0) { throw "load_case.py failed" }
  return $raw
}

function Get-CaseMap($path) {
  return ((Get-CasePy $path) | ConvertFrom-Json)
}

function Get-MonitoringDump($path) {
  $py = Join-Path $script:TempRoot 'dump_monitoring.py'
  [System.IO.File]::WriteAllText($py, @'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    store = json.load(f)
case = next(c for c in store["cases"] if c["id"] == "3363-glass-bridge")
items = (case.get("positionPlaybook") or {}).get("monitoringItems")
print(json.dumps(items, ensure_ascii=False, separators=(",", ":")))
'@, $Utf8)
  $raw = & python $py $path
  if ($LASTEXITCODE -ne 0) { throw "dump_monitoring.py failed" }
  return $raw
}

function Get-OwnershipSlice($caseObj) {
  $thesis = $caseObj.thesis
  return [PSCustomObject]@{
    supportingEvidence = $thesis.supportingEvidence
    counterEvidence = $thesis.counterEvidence
    thesisStatus = $thesis.status
    valuation = $caseObj.valuation
    decision = $caseObj.decision
    decisionHistory = $caseObj.decisionHistory
    caseStatus = $caseObj.status
  }
}

function Write-TempStoreFromFixture {
  $py = Join-Path $script:TempRoot 'seed_store.py'
  [System.IO.File]::WriteAllText($py, @'
import json, sys
fixture_path, out_path = sys.argv[1], sys.argv[2]
with open(fixture_path, encoding="utf-8") as f:
    fx = json.load(f)
store = {"schemaVersion": "1.0", "updated": "2026-08-20", "cases": [fx["case"]]}
with open(out_path, "w", encoding="utf-8", newline="\n") as f:
    json.dump(store, f, ensure_ascii=False, separators=(",", ":"))
    f.write("\n")
'@, $Utf8)
  & python $py $FixturePath $script:TempCasesPath
}

function Set-TempMonitoringItemsJson($jsonArray) {
  $py = Join-Path $script:TempRoot 'set_monitoring.py'
  $itemsPath = Join-Path $script:TempRoot 'monitoring-items.json'
  [System.IO.File]::WriteAllText($itemsPath, $jsonArray, $Utf8)
  [System.IO.File]::WriteAllText($py, @'
import json, sys
path, items_path = sys.argv[1], sys.argv[2]
with open(items_path, encoding="utf-8") as f:
    items = json.load(f)
with open(path, encoding="utf-8") as f:
    store = json.load(f)
case = next(c for c in store["cases"] if c["id"] == "3363-glass-bridge")
case["positionPlaybook"]["monitoringItems"] = items
with open(path, "w", encoding="utf-8", newline="\n") as f:
    json.dump(store, f, ensure_ascii=False, separators=(",", ":"))
    f.write("\n")
'@, $Utf8)
  & python $py $script:TempCasesPath $itemsPath
  if ($LASTEXITCODE -ne 0) { throw "set_monitoring.py failed" }
}

function Invoke-CasesPostJson($json) {
  $bytes = $Utf8.GetBytes($json)
  $uri = "http://localhost:$($script:TestPort)/api/cases"
  try {
    $resp = Invoke-WebRequest -Uri $uri -Method POST -Body $bytes -ContentType 'application/json; charset=utf-8' -UseBasicParsing
    return @{ StatusCode = [int]$resp.StatusCode; Body = $resp.Content }
  } catch [System.Net.WebException] {
    $http = $_.Exception.Response
    if (-not $http) { throw }
    $code = [int]$http.StatusCode
    $reader = New-Object System.IO.StreamReader($http.GetResponseStream(), $Utf8)
    $content = $reader.ReadToEnd()
    $reader.Close()
    return @{ StatusCode = $code; Body = $content }
  }
}

function New-PatchedServeScript($sourcePath, $destPath) {
  $src = [System.IO.File]::ReadAllText($sourcePath, $Utf8)
  $needle = 'Write-Output "Serving HTTP on http://localhost:$port/"'
  $idx = $src.IndexOf($needle)
  if ($idx -lt 0) { throw 'Unable to patch temp serve.ps1 header' }
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
  Write-Error "Port $port is in use."
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
  foreach ($port in 18775, 18776, 18777) {
    $script:TestPort = $port
    $env:INVESTORTWIN_TEST_PORT = [string]$port
    $outLog = Join-Path $script:TempRoot 'serve.out.log'
    $errLog = Join-Path $script:TempRoot 'serve.err.log'
    $script:ServerProc = Start-Process -FilePath 'powershell.exe' -WorkingDirectory $script:TempRoot -PassThru -WindowStyle Hidden `
      -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', '.\serve.ps1') `
      -RedirectStandardOutput $outLog -RedirectStandardError $errLog
    $started = $false
    for ($i = 0; $i -lt 25; $i++) {
      Start-Sleep -Milliseconds 200
      if ($script:ServerProc.HasExited) { break }
      try {
        $probe = Invoke-WebRequest -Uri ("http://localhost:{0}/data/investment-cases.json" -f $port) -UseBasicParsing
        if ($probe.StatusCode -eq 200) { $started = $true; break }
      } catch { }
    }
    if ($started) { return }
    if ($script:ServerProc -and -not $script:ServerProc.HasExited) {
      Stop-Process -Id $script:ServerProc.Id -Force -ErrorAction SilentlyContinue
    }
  }
  throw "Temp serve.ps1 failed to start"
}

function Stop-TempServer {
  if ($script:ServerProc -and -not $script:ServerProc.HasExited) {
    Stop-Process -Id $script:ServerProc.Id -Force -ErrorAction SilentlyContinue
  }
}

function Assert-Unchanged($label, $before, $after) {
  if (Test-SameJson $before $after) { return $null }
  return ("{0} changed" -f $label)
}

try {
  Start-TempServer
  $legacyText = '011-A legacy string monitoring item'
  $objectText = 'Glass Bridge production validation'
  $objectId = 'glass-bridge'

  Write-TempStoreFromFixture
  Set-TempMonitoringItemsJson ('["' + $legacyText + '"]')
  $dump1 = Get-MonitoringDump $script:TempCasesPath
  $fail1 = New-Object System.Collections.Generic.List[string]
  if ($dump1 -ne ('["' + $legacyText + '"]')) {
    $fail1.Add("read mismatch: $dump1")
  }
  $respKeep = Invoke-CasesPostJson ('{"id":"' + $CaseId + '","positionPlaybook":{"targetPosition":"011-A keep strings"}}')
  if ([int]$respKeep.StatusCode -ne 200) { $fail1.Add("HTTP $($respKeep.StatusCode) $($respKeep.Body)") }
  $dump1b = Get-MonitoringDump $script:TempCasesPath
  if ($dump1b -ne ('["' + $legacyText + '"]')) {
    $fail1.Add("string item not preserved after unrelated playbook save: $dump1b")
  }
  Add-TestResult 'TEST 1' ($fail1.Count -eq 0) ($fail1 -join "`n")

  Write-TempStoreFromFixture
  $objectJson = '[{"text":"' + $objectText + '","researchId":"' + $objectId + '"}]'
  Set-TempMonitoringItemsJson $objectJson
  $dump2 = Get-MonitoringDump $script:TempCasesPath
  $fail2 = New-Object System.Collections.Generic.List[string]
  if ($dump2 -notlike "*`"text`":`"$objectText`"*") { $fail2.Add("object text missing: $dump2") }
  if ($dump2 -notlike "*`"researchId`":`"$objectId`"*") { $fail2.Add("object researchId missing: $dump2") }
  $respKeep2 = Invoke-CasesPostJson ('{"id":"' + $CaseId + '","positionPlaybook":{"targetPosition":"011-A keep objects"}}')
  if ([int]$respKeep2.StatusCode -ne 200) { $fail2.Add("HTTP $($respKeep2.StatusCode) $($respKeep2.Body)") }
  $dump2b = Get-MonitoringDump $script:TempCasesPath
  if ($dump2b -notlike "*`"text`":`"$objectText`"*") { $fail2.Add("object text not preserved: $dump2b") }
  if ($dump2b -notlike "*`"researchId`":`"$objectId`"*") { $fail2.Add("object researchId not preserved: $dump2b") }
  Add-TestResult 'TEST 2' ($fail2.Count -eq 0) ($fail2 -join "`n")

  Write-TempStoreFromFixture
  $before3 = Get-OwnershipSlice (Get-CaseMap $script:TempCasesPath)
  $saveJson = '{"id":"' + $CaseId + '","positionPlaybook":{"monitoringItems":[{"text":"' + $objectText + '","researchId":"' + $objectId + '"}]}}'
  $resp3 = Invoke-CasesPostJson $saveJson
  $fail3 = New-Object System.Collections.Generic.List[string]
  if ([int]$resp3.StatusCode -ne 200) { $fail3.Add("HTTP $($resp3.StatusCode) $($resp3.Body)") }
  $dump3 = Get-MonitoringDump $script:TempCasesPath
  if ($dump3 -notlike "*`"text`":`"$objectText`"*") { $fail3.Add("saved text missing: $dump3") }
  if ($dump3 -notlike "*`"researchId`":`"$objectId`"*") { $fail3.Add("saved researchId missing: $dump3") }
  Add-TestResult 'TEST 3' ($fail3.Count -eq 0) ($fail3 -join "`n")

  $after4 = Get-OwnershipSlice (Get-CaseMap $script:TempCasesPath)
  $fail4 = New-Object System.Collections.Generic.List[string]
  foreach ($msg in @(
      (Assert-Unchanged 'decision' $before3.decision $after4.decision)
      (Assert-Unchanged 'decisionHistory' $before3.decisionHistory $after4.decisionHistory)
      (Assert-Unchanged 'thesis.status' $before3.thesisStatus $after4.thesisStatus)
      (Assert-Unchanged 'supportingEvidence' $before3.supportingEvidence $after4.supportingEvidence)
      (Assert-Unchanged 'counterEvidence' $before3.counterEvidence $after4.counterEvidence)
      (Assert-Unchanged 'valuation' $before3.valuation $after4.valuation)
      (Assert-Unchanged 'case.status' $before3.caseStatus $after4.caseStatus)
    )) {
    if ($msg) { $fail4.Add([string]$msg) }
  }
  if ($after4.valuation.marginOfSafety -ne $before3.valuation.marginOfSafety) {
    $fail4.Add('MOS changed')
  }
  Add-TestResult 'TEST 4' ($fail4.Count -eq 0) ($fail4 -join "`n")
}
catch {
  Add-TestResult 'SETUP' $false $_.Exception.Message
}
finally {
  Stop-TempServer
  $ProdHashAfter = (Get-FileHash -Path $ProdCasesPath -Algorithm SHA256).Hash
  Add-TestResult 'TEST 5' ($ProdHashBefore -eq $ProdHashAfter) $(if ($ProdHashBefore -ne $ProdHashAfter) { 'data/investment-cases.json was modified' } else { '' })
  if (Test-Path $script:TempRoot) {
    Remove-Item -Recurse -Force $script:TempRoot -ErrorAction SilentlyContinue
  }
}

Write-Output ''
Write-Output '=== 011-A SUMMARY ==='
foreach ($row in $script:Results) {
  Write-Output ("{0}: {1}" -f $row.Id, $row.Status)
  if ($row.Status -ne 'PASS' -and $row.Details) { Write-Output $row.Details }
}
$failed = @($script:Results | Where-Object { $_.Status -ne 'PASS' })
if ($failed.Count -gt 0) { exit 1 } else { exit 0 }
