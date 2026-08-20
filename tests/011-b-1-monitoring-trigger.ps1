$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$env:PYTHONIOENCODING = 'utf-8'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$OwnershipFixture = Join-Path $PSScriptRoot 'fixtures\3363-glass-bridge.ownership.json'
$ContractFixture = Join-Path $PSScriptRoot 'fixtures\011-b-1-monitoring-trigger.json'
$ProdCasesPath = Join-Path $RepoRoot 'data\investment-cases.json'
$ProdQueuePath = Join-Path $RepoRoot 'data\research-queue.json'
$ProdIndexPath = Join-Path $RepoRoot 'data\knowledge-index.json'
$CaseId = '3363-glass-bridge'

if (-not (Test-Path $OwnershipFixture)) { throw "Missing fixture: $OwnershipFixture" }
if (-not (Test-Path $ContractFixture)) { throw "Missing fixture: $ContractFixture" }

$Utf8 = New-Object System.Text.UTF8Encoding $false
$ProdHashBefore = @{
  cases = (Get-FileHash -Path $ProdCasesPath -Algorithm SHA256).Hash
  queue = (Get-FileHash -Path $ProdQueuePath -Algorithm SHA256).Hash
  index = (Get-FileHash -Path $ProdIndexPath -Algorithm SHA256).Hash
}
$Contract = [System.IO.File]::ReadAllText($ContractFixture, $Utf8) | ConvertFrom-Json
$Item = $Contract.monitoringItem
$TriggerBody = ($Contract.expectedInterface.body | ConvertTo-Json -Depth 8 -Compress)
$MissingTriggerHelp = 'production has no monitoringTrigger branch on POST /api/cases; expected interface is documented in tests/fixtures/011-b-1-monitoring-trigger.json'

$script:Results = New-Object System.Collections.Generic.List[object]
$script:TempRoot = Join-Path $env:TEMP ('InvestorTwin-011-B-1-' + [guid]::NewGuid().ToString('N'))
$script:TempCasesPath = $null
$script:TempQueuePath = $null
$script:TempNotesPath = $null
$script:TempCardPath = $null
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
    [System.IO.File]::WriteAllText($py, @'
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
'@, $Utf8)
  }
  return ($payload | & python $py)
}

function Test-SameJson($left, $right) {
  return ((Get-StableJson $left) -eq (Get-StableJson $right))
}

function Read-JsonFile($path) {
  return ([System.IO.File]::ReadAllText($path, $Utf8) | ConvertFrom-Json)
}

function Get-CaseMap {
  $py = Join-Path $script:TempRoot 'load_case.py'
  [System.IO.File]::WriteAllText($py, @'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    store = json.load(f)
print(json.dumps(next(c for c in store["cases"] if c["id"] == "3363-glass-bridge"), ensure_ascii=False, separators=(",", ":")))
'@, $Utf8)
  $raw = & python $py $script:TempCasesPath
  if ($LASTEXITCODE -ne 0) { throw 'load_case.py failed' }
  return ($raw | ConvertFrom-Json)
}

function Test-MonitoringItemMatch {
  $py = Join-Path $script:TempRoot 'match_monitoring.py'
  $outPath = Join-Path $script:TempRoot 'monitoring-match.json'
  [System.IO.File]::WriteAllText($py, @'
import json, sys
src, contract_path, dest = sys.argv[1], sys.argv[2], sys.argv[3]
with open(src, encoding="utf-8") as f:
    store = json.load(f)
with open(contract_path, encoding="utf-8") as f:
    contract = json.load(f)
case = next(c for c in store["cases"] if c["id"] == "3363-glass-bridge")
items = (case.get("positionPlaybook") or {}).get("monitoringItems") or []
expected = contract["monitoringItem"]
matched = False
for item in items:
    if isinstance(item, dict) and item.get("text") == expected.get("text") and item.get("researchId") == expected.get("researchId"):
        matched = True
        break
with open(dest, "w", encoding="utf-8", newline="\n") as f:
    json.dump({"matched": matched, "count": len(items), "researchId": expected.get("researchId")}, f, separators=(",", ":"))
'@, $Utf8)
  & python $py $script:TempCasesPath $ContractFixture $outPath
  if ($LASTEXITCODE -ne 0) { throw 'match_monitoring.py failed' }
  return (Read-JsonFile $outPath)
}

function Get-QueueDump {
  return [System.IO.File]::ReadAllText($script:TempQueuePath, $Utf8)
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
  & python $py $OwnershipFixture $script:TempCasesPath
}

function Set-TempMonitoringItem {
  $py = Join-Path $script:TempRoot 'set_monitoring.py'
  [System.IO.File]::WriteAllText($py, @'
import json, sys
path, contract_path = sys.argv[1], sys.argv[2]
with open(contract_path, encoding="utf-8") as f:
    contract = json.load(f)
with open(path, encoding="utf-8") as f:
    store = json.load(f)
case = next(c for c in store["cases"] if c["id"] == "3363-glass-bridge")
case["positionPlaybook"]["monitoringItems"] = [contract["monitoringItem"]]
with open(path, "w", encoding="utf-8", newline="\n") as f:
    json.dump(store, f, ensure_ascii=False, separators=(",", ":"))
    f.write("\n")
'@, $Utf8)
  & python $py $script:TempCasesPath $ContractFixture
  if ($LASTEXITCODE -ne 0) { throw 'set_monitoring.py failed' }
}

function Write-TempQueue($json) {
  [System.IO.File]::WriteAllText($script:TempQueuePath, $json, $Utf8)
}

function Invoke-Post($path, $json) {
  $bytes = $Utf8.GetBytes($json)
  $uri = "http://localhost:$($script:TestPort)$path"
  try {
    $resp = Invoke-WebRequest -Uri $uri -Method POST -Body $bytes -ContentType 'application/json; charset=utf-8' -UseBasicParsing
    return @{ StatusCode = [int]$resp.StatusCode; Body = $resp.Content }
  } catch [System.Net.WebException] {
    $http = $_.Exception.Response
    if (-not $http) { throw }
    $reader = New-Object System.IO.StreamReader($http.GetResponseStream(), $Utf8)
    $content = $reader.ReadToEnd()
    $reader.Close()
    return @{ StatusCode = [int]$http.StatusCode; Body = $content }
  }
}

function Invoke-MonitoringTrigger {
  return Invoke-Post '/api/cases' $TriggerBody
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
  New-Item -ItemType Directory -Path (Join-Path $script:TempRoot 'research\glass-bridge') | Out-Null
  $script:TempCasesPath = Join-Path $script:TempRoot 'data\investment-cases.json'
  $script:TempQueuePath = Join-Path $script:TempRoot 'data\research-queue.json'
  $script:TempNotesPath = Join-Path $script:TempRoot 'research\glass-bridge\notes.json'
  $script:TempCardPath = Join-Path $script:TempRoot 'research\glass-bridge\card.json'
  Copy-Item (Join-Path $RepoRoot 'data\version.json') (Join-Path $script:TempRoot 'data\version.json') -ErrorAction SilentlyContinue
  Copy-Item (Join-Path $RepoRoot 'scripts\generate-knowledge-index.ps1') (Join-Path $script:TempRoot 'scripts\generate-knowledge-index.ps1')
  Copy-Item (Join-Path $RepoRoot 'research\glass-bridge\card.json') $script:TempCardPath
  Copy-Item (Join-Path $RepoRoot 'research\glass-bridge\notes.json') $script:TempNotesPath
  Copy-Item (Join-Path $RepoRoot 'research\glass-bridge\timeline.json') (Join-Path $script:TempRoot 'research\glass-bridge\timeline.json') -ErrorAction SilentlyContinue
  Copy-Item (Join-Path $RepoRoot 'research\glass-bridge\sources.json') (Join-Path $script:TempRoot 'research\glass-bridge\sources.json') -ErrorAction SilentlyContinue
  New-PatchedServeScript (Join-Path $RepoRoot 'serve.ps1') (Join-Path $script:TempRoot 'serve.ps1')
  Write-TempStoreFromFixture
  Write-TempQueue '{"items":[{"id":"glass-bridge","addedFrom":"Morning Brief"}]}'
  foreach ($port in 18785, 18786, 18787) {
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
        if ($probe.StatusCode -eq 200) { return }
      } catch { }
    }
    if ($script:ServerProc -and -not $script:ServerProc.HasExited) {
      Stop-Process -Id $script:ServerProc.Id -Force -ErrorAction SilentlyContinue
    }
  }
  throw 'Temp serve.ps1 failed to start'
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

function Get-QueueGlassBridgeCount {
  $queue = Read-JsonFile $script:TempQueuePath
  return @($queue.items | Where-Object { $_.id -eq $Item.researchId }).Count
}

function Test-ReResearchSignal {
  $notesRaw = [System.IO.File]::ReadAllText($script:TempNotesPath, $Utf8)
  $cardRaw = [System.IO.File]::ReadAllText($script:TempCardPath, $Utf8)
  $blob = $notesRaw + "`n" + $cardRaw
  $markers = @($Contract.reResearchMarker, $Item.text, 'Monitoring')
  foreach ($marker in $markers) {
    if ($blob -like ('*' + $marker + '*')) { return $true }
  }
  return $false
}

try {
  Start-TempServer
  Write-TempStoreFromFixture
  Set-TempMonitoringItem
  $match = Test-MonitoringItemMatch
  $fail1 = New-Object System.Collections.Generic.List[string]
  if (-not $match.matched) {
    $fail1.Add(("monitoring item was not identified; count={0} researchId={1}" -f $match.count, $match.researchId))
  }
  Add-TestResult 'TEST 1' ($fail1.Count -eq 0) ($fail1 -join "`n")

  $fail2 = New-Object System.Collections.Generic.List[string]
  if ($Item.researchId -ne 'glass-bridge') { $fail2.Add('fixture researchId is not glass-bridge') }
  if ($Contract.expectedInterface.body.monitoringTrigger.researchId -ne $Item.researchId) {
    $fail2.Add('trigger payload researchId does not match monitoring item')
  }
  if ($TriggerBody -notlike ('*"researchId":"' + $Item.researchId + '"*')) {
    $fail2.Add("trigger request cannot obtain researchId: $TriggerBody")
  }
  Add-TestResult 'TEST 2' ($fail2.Count -eq 0) ($fail2 -join "`n")

  Write-TempStoreFromFixture
  Set-TempMonitoringItem
  Write-TempQueue '{"items":[{"id":"glass-bridge","addedFrom":"Morning Brief"}]}'
  Copy-Item (Join-Path $RepoRoot 'research\glass-bridge\notes.json') $script:TempNotesPath -Force
  Copy-Item (Join-Path $RepoRoot 'research\glass-bridge\card.json') $script:TempCardPath -Force
  $beforeExisting = Get-OwnershipSlice (Get-CaseMap)
  $respExisting = Invoke-MonitoringTrigger
  $fail3 = New-Object System.Collections.Generic.List[string]
  if ([int]$respExisting.StatusCode -ne 200) {
    $fail3.Add(("HTTP {0}. {1}. {2}" -f $respExisting.StatusCode, $MissingTriggerHelp, $respExisting.Body))
  }
  $countAfter = Get-QueueGlassBridgeCount
  if ($countAfter -ne 1) { $fail3.Add("queue glass-bridge count=$countAfter expected 1") }
  Add-TestResult 'TEST 3' ($fail3.Count -eq 0) ($fail3 -join "`n")

  $fail4 = New-Object System.Collections.Generic.List[string]
  if ([int]$respExisting.StatusCode -ne 200) {
    $fail4.Add(("HTTP {0}. {1}" -f $respExisting.StatusCode, $MissingTriggerHelp))
  } elseif (-not (Test-ReResearchSignal)) {
    $fail4.Add('queue already had glass-bridge but no re-research note/question was left')
  }
  Add-TestResult 'TEST 4' ($fail4.Count -eq 0) ($fail4 -join "`n")

  $afterExisting = Get-OwnershipSlice (Get-CaseMap)
  $fail5 = New-Object System.Collections.Generic.List[string]
  if ([int]$respExisting.StatusCode -ne 200) {
    $fail5.Add(("HTTP {0}. {1}" -f $respExisting.StatusCode, $MissingTriggerHelp))
  }
  foreach ($msg in @(
      (Assert-Unchanged 'decision' $beforeExisting.decision $afterExisting.decision)
      (Assert-Unchanged 'decisionHistory' $beforeExisting.decisionHistory $afterExisting.decisionHistory)
      (Assert-Unchanged 'thesis.status' $beforeExisting.thesisStatus $afterExisting.thesisStatus)
      (Assert-Unchanged 'supportingEvidence' $beforeExisting.supportingEvidence $afterExisting.supportingEvidence)
      (Assert-Unchanged 'counterEvidence' $beforeExisting.counterEvidence $afterExisting.counterEvidence)
      (Assert-Unchanged 'valuation' $beforeExisting.valuation $afterExisting.valuation)
    )) {
    if ($msg) { $fail5.Add([string]$msg) }
  }
  Add-TestResult 'TEST 5' ($fail5.Count -eq 0) ($fail5 -join "`n")

  Write-TempStoreFromFixture
  Set-TempMonitoringItem
  Write-TempQueue '{"items":[{"id":"fau","addedFrom":"Opportunity Radar"}]}'
  $respMissing = Invoke-MonitoringTrigger
  $fail6 = New-Object System.Collections.Generic.List[string]
  if ([int]$respMissing.StatusCode -ne 200) {
    $fail6.Add(("HTTP {0}. {1}. {2}" -f $respMissing.StatusCode, $MissingTriggerHelp, $respMissing.Body))
  } else {
    $queue = Read-JsonFile $script:TempQueuePath
    $hit = @($queue.items | Where-Object { $_.id -eq $Item.researchId })
    if ($hit.Count -ne 1) {
      $fail6.Add("expected one queue item for $($Item.researchId), got $($hit.Count)")
    } elseif ($hit[0].addedFrom -ne $Contract.expectedQueueSource) {
      $fail6.Add("addedFrom=$($hit[0].addedFrom) expected $($Contract.expectedQueueSource)")
    }
  }
  Add-TestResult 'TEST 6' ($fail6.Count -eq 0) ($fail6 -join "`n")
}
catch {
  Add-TestResult 'SETUP' $false $_.Exception.Message
}
finally {
  Stop-TempServer
  $afterCases = (Get-FileHash -Path $ProdCasesPath -Algorithm SHA256).Hash
  $afterQueue = (Get-FileHash -Path $ProdQueuePath -Algorithm SHA256).Hash
  $afterIndex = (Get-FileHash -Path $ProdIndexPath -Algorithm SHA256).Hash
  $guardOk = ($afterCases -eq $ProdHashBefore.cases) -and ($afterQueue -eq $ProdHashBefore.queue) -and ($afterIndex -eq $ProdHashBefore.index)
  Add-TestResult 'PRODUCTION_FILE_GUARD' $guardOk $(if ($guardOk) { '' } else { 'production data/*.json was modified' })
  if (Test-Path $script:TempRoot) {
    Remove-Item -Recurse -Force $script:TempRoot -ErrorAction SilentlyContinue
  }
}

Write-Output ''
Write-Output '=== 011-B-1 SUMMARY ==='
foreach ($row in $script:Results) {
  Write-Output ("{0}: {1}" -f $row.Id, $row.Status)
  if ($row.Status -ne 'PASS' -and $row.Details) { Write-Output $row.Details }
}
$failed = @($script:Results | Where-Object { $_.Status -ne 'PASS' })
if ($failed.Count -gt 0) { exit 1 } else { exit 0 }
