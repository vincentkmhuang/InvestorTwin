$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$env:PYTHONIOENCODING = 'utf-8'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$FixturePath = Join-Path $PSScriptRoot 'fixtures\3363-glass-bridge.ownership.json'
$EnginePath = Join-Path $RepoRoot 'js\workflow-engine.js'
$ProdCasesPath = Join-Path $RepoRoot 'data\investment-cases.json'
$ProdQueuePath = Join-Path $RepoRoot 'data\research-queue.json'
$ProdIndexPath = Join-Path $RepoRoot 'data\knowledge-index.json'
$CaseId = '3363-glass-bridge'

if (-not (Test-Path $FixturePath)) { throw "Missing fixture: $FixturePath" }
if (-not (Test-Path $EnginePath)) { throw "Missing file: $EnginePath" }

$Utf8 = New-Object System.Text.UTF8Encoding $false
$ProdHashBefore = @{
  cases = (Get-FileHash -Path $ProdCasesPath -Algorithm SHA256).Hash
  queue = (Get-FileHash -Path $ProdQueuePath -Algorithm SHA256).Hash
  index = (Get-FileHash -Path $ProdIndexPath -Algorithm SHA256).Hash
}
$EngineSrc = [System.IO.File]::ReadAllText($EnginePath, $Utf8)

$script:Results = New-Object System.Collections.Generic.List[object]
$script:TempRoot = Join-Path $env:TEMP ('InvestorTwin-011-B-3-save-' + [guid]::NewGuid().ToString('N'))
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

function Get-MonitoringInfo {
  $py = Join-Path $script:TempRoot 'dump_monitoring.py'
  $outPath = Join-Path $script:TempRoot 'monitoring-info.json'
  [System.IO.File]::WriteAllText($py, @'
import json, sys
src, dest = sys.argv[1], sys.argv[2]
with open(src, encoding="utf-8") as f:
    store = json.load(f)
case = next(c for c in store["cases"] if c["id"] == "3363-glass-bridge")
items = (case.get("positionPlaybook") or {}).get("monitoringItems")
info = {
    "isList": isinstance(items, list),
    "count": len(items) if isinstance(items, list) else (0 if items is None else 1),
    "items": items if isinstance(items, list) else ([items] if items is not None else []),
}
with open(dest, "w", encoding="utf-8", newline="\n") as f:
    json.dump(info, f, ensure_ascii=False, separators=(",", ":"))
'@, $Utf8)
  & python $py $script:TempCasesPath $outPath
  if ($LASTEXITCODE -ne 0) { throw 'dump_monitoring.py failed' }
  return ([System.IO.File]::ReadAllText($outPath, $Utf8) | ConvertFrom-Json)
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

function Write-UiSaveBody($text, $researchId, $includeMonitoring) {
  $py = Join-Path $script:TempRoot 'ui_save_body.py'
  $argsPath = Join-Path $script:TempRoot 'ui-save-args.json'
  $outPath = Join-Path $script:TempRoot 'ui-save.json'
  $argsObj = @{
    flag = $(if ($includeMonitoring) { '1' } else { '0' })
    text = [string]$text
    researchId = $(if ($null -eq $researchId) { '' } else { [string]$researchId })
  }
  $argsJson = ($argsObj | ConvertTo-Json -Compress)
  [System.IO.File]::WriteAllText($argsPath, $argsJson, $Utf8)
  [System.IO.File]::WriteAllText($py, @'
import json, sys
args_path, out_path = sys.argv[1], sys.argv[2]
with open(args_path, encoding="utf-8") as f:
    args = json.load(f)
body = {
    "id": "3363-glass-bridge",
    "positionPlaybook": {
        "targetPosition": "keep-target",
        "initialPosition": "keep-initial",
        "entryTriggers": ["keep-entry"]
    }
}
if args.get("flag") == "1":
    text = args.get("text") or ""
    research_id = args.get("researchId") or ""
    if research_id:
        body["positionPlaybook"]["monitoringItems"] = [{"text": text, "researchId": research_id}]
    elif text == "__EMPTY_ARRAY__":
        body["positionPlaybook"]["monitoringItems"] = []
    else:
        body["positionPlaybook"]["monitoringItems"] = [text]
with open(out_path, "w", encoding="utf-8", newline="\n") as f:
    json.dump(body, f, ensure_ascii=False, separators=(",", ":"))
'@, $Utf8)
  & python $py $argsPath $outPath
  if ($LASTEXITCODE -ne 0) { throw 'ui_save_body.py failed' }
  return [System.IO.File]::ReadAllText($outPath, $Utf8)
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
    $reader = New-Object System.IO.StreamReader($http.GetResponseStream(), $Utf8)
    $content = $reader.ReadToEnd()
    $reader.Close()
    return @{ StatusCode = [int]$http.StatusCode; Body = $content }
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
  foreach ($port in 18794, 18795, 18796) {
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

function Get-MonitoringHits($info) {
  return @($info.items)
}

try {
  Start-TempServer
  $pyText = Join-Path $script:TempRoot 'object_text.py'
  [System.IO.File]::WriteAllText($pyText, @'
import json, sys
open(sys.argv[1], "w", encoding="utf-8").write("Glass Bridge \u91cf\u7522\u9a57\u8b49\u662f\u5426\u78ba\u8a8d")
'@, $Utf8)
  $objectTextPath = Join-Path $script:TempRoot 'object-text.txt'
  & python $pyText $objectTextPath
  $objectText = [System.IO.File]::ReadAllText($objectTextPath, $Utf8).Trim()
  $objectId = 'glass-bridge'
  $legacyText = '011-B-3 legacy string monitoring item'

  if ($EngineSrc -notlike "*lastIndexOf('|')*") {
    throw 'parseMonitoringEditorLines does not split on |'
  }

  Write-TempStoreFromFixture
  $before1 = Get-OwnershipSlice (Get-CaseMap)
  $resp1 = Invoke-CasesPostJson (Write-UiSaveBody $objectText $objectId $true)
  $fail1 = New-Object System.Collections.Generic.List[string]
  if ([int]$resp1.StatusCode -ne 200) { $fail1.Add("HTTP $($resp1.StatusCode) $($resp1.Body)") }
  $info1 = Get-MonitoringInfo
  if (-not $info1.isList) { $fail1.Add('monitoringItems is not a JSON array after save') }
  $hit1 = @(Get-MonitoringHits $info1)
  if ($hit1.Count -ne 1) {
    $fail1.Add("count=$($hit1.Count) expected 1")
  } else {
    if ([string]$hit1[0].text -ne $objectText) { $fail1.Add('saved text mismatch') }
    if ([string]$hit1[0].researchId -ne $objectId) { $fail1.Add('saved researchId mismatch') }
  }
  Add-TestResult 'TEST 1' ($fail1.Count -eq 0) ($fail1 -join "`n")

  Write-TempStoreFromFixture
  $resp2 = Invoke-CasesPostJson (Write-UiSaveBody $legacyText '' $true)
  $fail2 = New-Object System.Collections.Generic.List[string]
  if ([int]$resp2.StatusCode -ne 200) { $fail2.Add("HTTP $($resp2.StatusCode) $($resp2.Body)") }
  $info2 = Get-MonitoringInfo
  $hit2 = @(Get-MonitoringHits $info2)
  $legacyHit = $false
  foreach ($item in $hit2) {
    $asText = [string]$item
    if ($item -is [string] -or $item.PSObject.Properties['text']) {
      if ($asText -eq $legacyText -or [string]$item.text -eq $legacyText) { $legacyHit = $true }
    }
  }
  if (-not $legacyHit) { $fail2.Add('legacy string monitoring item was not saved') }
  Add-TestResult 'TEST 2' ($fail2.Count -eq 0) ($fail2 -join "`n")

  $fail3 = New-Object System.Collections.Generic.List[string]
  if ($EngineSrc -notlike "*lastIndexOf('|')*") { $fail3.Add('editor parser does not accept text|researchId') }
  if ($EngineSrc -like "*lastIndexOf(' | ')*") { $fail3.Add('editor parser still requires spaced pipe only') }
  Write-TempStoreFromFixture
  $resp3 = Invoke-CasesPostJson (Write-UiSaveBody $objectText $objectId $true)
  if ([int]$resp3.StatusCode -ne 200) { $fail3.Add("HTTP $($resp3.StatusCode) $($resp3.Body)") }
  $info3 = Get-MonitoringInfo
  $hit3 = @(Get-MonitoringHits $info3)
  if ($hit3.Count -ne 1 -or [string]$hit3[0].researchId -ne $objectId) {
    $fail3.Add('text|researchId did not keep researchId')
  }
  Add-TestResult 'TEST 3' ($fail3.Count -eq 0) ($fail3 -join "`n")

  Write-TempStoreFromFixture
  $respSeed = Invoke-CasesPostJson (Write-UiSaveBody $objectText $objectId $true)
  $fail4 = New-Object System.Collections.Generic.List[string]
  if ([int]$respSeed.StatusCode -ne 200) { $fail4.Add("seed HTTP $($respSeed.StatusCode)") }
  $respKeep = Invoke-CasesPostJson (Write-UiSaveBody 'ignored' '' $false)
  if ([int]$respKeep.StatusCode -ne 200) { $fail4.Add("keep HTTP $($respKeep.StatusCode) $($respKeep.Body)") }
  $info4 = Get-MonitoringInfo
  $hit4 = @(Get-MonitoringHits $info4)
  if ($hit4.Count -ne 1 -or [string]$hit4[0].researchId -ne $objectId) {
    $fail4.Add('missing monitoringItems cleared existing value')
  }
  Add-TestResult 'TEST 4' ($fail4.Count -eq 0) ($fail4 -join "`n")

  $respClear = Invoke-CasesPostJson (Write-UiSaveBody '__EMPTY_ARRAY__' '' $true)
  $fail5 = New-Object System.Collections.Generic.List[string]
  if ([int]$respClear.StatusCode -ne 200) { $fail5.Add("HTTP $($respClear.StatusCode) $($respClear.Body)") }
  $info5 = Get-MonitoringInfo
  if (-not $info5.isList) { $fail5.Add('cleared monitoringItems is not a list') }
  if ([int]$info5.count -ne 0) { $fail5.Add("count=$($info5.count) expected 0 after explicit []") }
  Add-TestResult 'TEST 5' ($fail5.Count -eq 0) ($fail5 -join "`n")

  Write-TempStoreFromFixture
  $before6 = Get-OwnershipSlice (Get-CaseMap)
  $resp6 = Invoke-CasesPostJson (Write-UiSaveBody $objectText $objectId $true)
  $fail6 = New-Object System.Collections.Generic.List[string]
  if ([int]$resp6.StatusCode -ne 200) { $fail6.Add("HTTP $($resp6.StatusCode) $($resp6.Body)") }
  $after6 = Get-OwnershipSlice (Get-CaseMap)
  foreach ($msg in @(
      (Assert-Unchanged 'decision' $before6.decision $after6.decision)
      (Assert-Unchanged 'decisionHistory' $before6.decisionHistory $after6.decisionHistory)
      (Assert-Unchanged 'thesis.status' $before6.thesisStatus $after6.thesisStatus)
      (Assert-Unchanged 'supportingEvidence' $before6.supportingEvidence $after6.supportingEvidence)
      (Assert-Unchanged 'counterEvidence' $before6.counterEvidence $after6.counterEvidence)
      (Assert-Unchanged 'valuation' $before6.valuation $after6.valuation)
      (Assert-Unchanged 'case.status' $before6.caseStatus $after6.caseStatus)
    )) {
    if ($msg) { $fail6.Add([string]$msg) }
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
  Add-TestResult 'TEST 7' $guardOk $(if ($guardOk) { '' } else { 'production data/*.json was modified' })
  if (Test-Path $script:TempRoot) {
    Remove-Item -Recurse -Force $script:TempRoot -ErrorAction SilentlyContinue
  }
}

Write-Output ''
Write-Output '=== 011-B-3 SAVE SUMMARY ==='
foreach ($row in $script:Results) {
  Write-Output ("{0}: {1}" -f $row.Id, $row.Status)
  if ($row.Status -ne 'PASS' -and $row.Details) { Write-Output $row.Details }
}
$failed = @($script:Results | Where-Object { $_.Status -ne 'PASS' })
if ($failed.Count -gt 0) { exit 1 } else { exit 0 }
