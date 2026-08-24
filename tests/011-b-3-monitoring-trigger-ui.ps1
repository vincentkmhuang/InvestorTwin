$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$env:PYTHONIOENCODING = 'utf-8'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$OwnershipFixture = Join-Path $PSScriptRoot 'fixtures\3363-glass-bridge.ownership.json'
$ContractFixture = Join-Path $PSScriptRoot 'fixtures\011-b-1-monitoring-trigger.json'
$EnginePath = Join-Path $RepoRoot 'js\workflow-engine.js'
$IndexPath = Join-Path $RepoRoot 'index.html'
$ProdCasesPath = Join-Path $RepoRoot 'data\investment-cases.json'
$ProdQueuePath = Join-Path $RepoRoot 'data\research-queue.json'
$ProdIndexPath = Join-Path $RepoRoot 'data\knowledge-index.json'

if (-not (Test-Path $OwnershipFixture)) { throw "Missing fixture: $OwnershipFixture" }
if (-not (Test-Path $ContractFixture)) { throw "Missing fixture: $ContractFixture" }
if (-not (Test-Path $EnginePath)) { throw "Missing file: $EnginePath" }

$Utf8 = New-Object System.Text.UTF8Encoding $false
$ProdHashBefore = @{
  cases = (Get-FileHash -Path $ProdCasesPath -Algorithm SHA256).Hash
  queue = (Get-FileHash -Path $ProdQueuePath -Algorithm SHA256).Hash
  index = (Get-FileHash -Path $ProdIndexPath -Algorithm SHA256).Hash
}
$Contract = [System.IO.File]::ReadAllText($ContractFixture, $Utf8) | ConvertFrom-Json
$Item = $Contract.monitoringItem
$EngineSrc = [System.IO.File]::ReadAllText($EnginePath, $Utf8)
$IndexSrc = [System.IO.File]::ReadAllText($IndexPath, $Utf8)

$script:Results = New-Object System.Collections.Generic.List[object]
$script:TempRoot = Join-Path $env:TEMP ('InvestorTwin-011-B-3-' + [guid]::NewGuid().ToString('N'))
$script:TempCasesPath = $null
$script:TempQueuePath = $null
$script:TestPort = $null
$script:ServerProc = $null

function Add-TestResult($id, $passed, $details) {
  $status = if ($passed) { 'PASS' } else { 'FAIL' }
  $script:Results.Add([PSCustomObject]@{ Id = $id; Status = $status; Details = $details })
  Write-Output ("{0}: {1}" -f $id, $status)
  if ($details) { Write-Output $details }
}

function Extract-JsMethod($name) {
  $py = Join-Path $script:TempRoot 'extract_js_method.py'
  [System.IO.File]::WriteAllText($py, @'
import json, sys
src_path, name, dest = sys.argv[1], sys.argv[2], sys.argv[3]
src = open(src_path, encoding="utf-8").read()
needles = [f"async {name}(", f"{name}("]
start = -1
for needle in needles:
    idx = src.find(needle)
    if idx >= 0:
        start = idx
        break
if start < 0:
    open(dest, "w", encoding="utf-8").write(json.dumps({"found": False, "body": ""}))
    raise SystemExit(0)
brace = src.find("{", start)
depth = 0
end = None
for i, ch in enumerate(src[brace:], brace):
    if ch == "{":
        depth += 1
    elif ch == "}":
        depth -= 1
        if depth == 0:
            end = i + 1
            break
body = src[start:end] if end else ""
open(dest, "w", encoding="utf-8", newline="\n").write(json.dumps({"found": bool(body), "body": body}, ensure_ascii=False))
'@, $Utf8)
  $outPath = Join-Path $script:TempRoot ("extract-" + $name + ".json")
  & python $py $EnginePath $name $outPath
  if ($LASTEXITCODE -ne 0) { throw "extract_js_method.py failed for $name" }
  return ([System.IO.File]::ReadAllText($outPath, $Utf8) | ConvertFrom-Json)
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
    positionPlaybook = $caseObj.positionPlaybook
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
  New-Item -ItemType Directory -Path (Join-Path $script:TempRoot 'data') | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $script:TempRoot 'scripts') | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $script:TempRoot 'research\glass-bridge') | Out-Null
  $script:TempCasesPath = Join-Path $script:TempRoot 'data\investment-cases.json'
  $script:TempQueuePath = Join-Path $script:TempRoot 'data\research-queue.json'
  Copy-Item (Join-Path $RepoRoot 'data\version.json') (Join-Path $script:TempRoot 'data\version.json') -ErrorAction SilentlyContinue
  Copy-Item (Join-Path $RepoRoot 'scripts\generate-knowledge-index.ps1') (Join-Path $script:TempRoot 'scripts\generate-knowledge-index.ps1')
  Copy-Item (Join-Path $RepoRoot 'research\glass-bridge\card.json') (Join-Path $script:TempRoot 'research\glass-bridge\card.json')
  Copy-Item (Join-Path $RepoRoot 'research\glass-bridge\notes.json') (Join-Path $script:TempRoot 'research\glass-bridge\notes.json')
  Copy-Item (Join-Path $RepoRoot 'research\glass-bridge\timeline.json') (Join-Path $script:TempRoot 'research\glass-bridge\timeline.json') -ErrorAction SilentlyContinue
  Copy-Item (Join-Path $RepoRoot 'research\glass-bridge\sources.json') (Join-Path $script:TempRoot 'research\glass-bridge\sources.json') -ErrorAction SilentlyContinue
  New-PatchedServeScript (Join-Path $RepoRoot 'serve.ps1') (Join-Path $script:TempRoot 'serve.ps1')
  Write-TempStoreFromFixture
  [System.IO.File]::WriteAllText($script:TempQueuePath, '{"items":[{"id":"glass-bridge","addedFrom":"Morning Brief"}]}', $Utf8)
  foreach ($port in 18791, 18792, 18793) {
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

try {
  New-Item -ItemType Directory -Path $script:TempRoot | Out-Null

  $viewFn = Extract-JsMethod 'monitoringItemView'
  $payloadFn = Extract-JsMethod 'buildMonitoringTriggerPayload'
  $canFn = Extract-JsMethod 'canTriggerMonitoringItem'
  $triggerFn = Extract-JsMethod 'triggerMonitoringItem'
  $renderFn = Extract-JsMethod 'renderMonitoringItems'
  $successFn = Extract-JsMethod 'monitoringTriggerSuccessMessage'

  $fail1 = New-Object System.Collections.Generic.List[string]
  if (-not $viewFn.found) { $fail1.Add('monitoringItemView is missing') }
  if ($viewFn.body -notlike '*item.text*') { $fail1.Add('monitoringItemView does not read text') }
  if ($viewFn.body -notlike '*item.researchId*') { $fail1.Add('monitoringItemView does not read researchId') }
  if ($payloadFn.body -notlike '*view.text*') { $fail1.Add('payload builder does not use monitoring text') }
  if ($payloadFn.body -notlike '*view.researchId*') { $fail1.Add('payload builder does not use monitoring researchId') }
  Add-TestResult 'TEST 1' ($fail1.Count -eq 0) ($fail1 -join "`n")

  $fail2 = New-Object System.Collections.Generic.List[string]
  if (-not $payloadFn.found) { $fail2.Add('buildMonitoringTriggerPayload is missing') }
  if ($payloadFn.body -notlike '*id: caseId*') { $fail2.Add('payload is missing case id') }
  if ($payloadFn.body -notlike '*monitoringTrigger:*') { $fail2.Add('payload is missing monitoringTrigger') }
  if ($payloadFn.body -notlike '*text: view.text*') { $fail2.Add('payload text is not monitoring item text') }
  if ($payloadFn.body -notlike '*researchId: view.researchId*') { $fail2.Add('payload researchId is not monitoring item researchId') }
  if ($Contract.expectedInterface.body.id -ne $Contract.caseId) { $fail2.Add('fixture case id mismatch') }
  if ($Contract.expectedInterface.body.monitoringTrigger.researchId -ne $Item.researchId) { $fail2.Add('fixture researchId mismatch') }
  Add-TestResult 'TEST 2' ($fail2.Count -eq 0) ($fail2 -join "`n")

  $fail3 = New-Object System.Collections.Generic.List[string]
  if (-not $triggerFn.found) { $fail3.Add('triggerMonitoringItem is missing') }
  if ($triggerFn.body -notlike "*fetch('/api/cases'*") { $fail3.Add('trigger does not POST /api/cases') }
  if ($triggerFn.body -notlike '*method: ''POST''*') { $fail3.Add('trigger does not use POST') }
  $fetchCount = ([regex]::Matches($triggerFn.body, 'fetch\(')).Count
  if ($fetchCount -ne 1) { $fail3.Add("trigger fetch count=$fetchCount expected 1") }
  Add-TestResult 'TEST 3' ($fail3.Count -eq 0) ($fail3 -join "`n")

  $fail4 = New-Object System.Collections.Generic.List[string]
  if ($triggerFn.body -like '*/api/queue*') { $fail4.Add('trigger calls /api/queue') }
  if ($triggerFn.body -like '*ensureInQueue*') { $fail4.Add('trigger calls ensureInQueue') }
  Add-TestResult 'TEST 4' ($fail4.Count -eq 0) ($fail4 -join "`n")

  $fail5 = New-Object System.Collections.Generic.List[string]
  if ($triggerFn.body -like '*/api/research*') { $fail5.Add('trigger calls /api/research/{id}') }
  if ($triggerFn.body -like '*appendResearchNote*') { $fail5.Add('trigger calls appendResearchNote') }
  Add-TestResult 'TEST 5' ($fail5.Count -eq 0) ($fail5 -join "`n")

  $fail6 = New-Object System.Collections.Generic.List[string]
  if (-not $canFn.found) { $fail6.Add('canTriggerMonitoringItem is missing') }
  if ($canFn.body -notlike '*view.researchId*') { $fail6.Add('canTriggerMonitoringItem does not require researchId') }
  if ($payloadFn.body -notlike '*canTriggerMonitoringItem*' -or $payloadFn.body -notlike '*return null*') {
    $fail6.Add('incomplete payload is still built without researchId')
  }
  if ($renderFn.body -notlike '*if (!view.researchId)*') { $fail6.Add('renderMonitoringItems does not branch on missing researchId') }
  $noIdBranch = ''
  if ($renderFn.body -match '(?s)if \(!view\.researchId\) \{(?<body>.*?)continue;') {
    $noIdBranch = $Matches.body
  }
  if ($noIdBranch -like '*Trigger Research*') { $fail6.Add('Trigger button is rendered without researchId') }
  if ($renderFn.body -notlike '*Trigger Research*') { $fail6.Add('Trigger Research button missing when researchId exists') }
  Add-TestResult 'TEST 6' ($fail6.Count -eq 0) ($fail6 -join "`n")

  $fail7 = New-Object System.Collections.Generic.List[string]
  if (-not $successFn.found) { $fail7.Add('monitoringTriggerSuccessMessage is missing') }
  $msgPy = Join-Path $script:TempRoot 'check_success_message.py'
  $msgOut = Join-Path $script:TempRoot 'check_success_message.json'
  [System.IO.File]::WriteAllText($msgPy, @'
import json, sys
src = open(sys.argv[1], encoding="utf-8").read()
marker = "\u5df2\u89f8\u767c\u91cd\u65b0\u7814\u7a76\uff1a"
open(sys.argv[2], "w", encoding="utf-8").write(json.dumps({"ok": marker in src}))
'@, $Utf8)
  & python $msgPy $EnginePath $msgOut
  $msgCheck = [System.IO.File]::ReadAllText($msgOut, $Utf8) | ConvertFrom-Json
  if (-not $msgCheck.ok) { $fail7.Add('success message is missing') }
  if ($triggerFn.body -notlike '*monitoringTriggerSuccessMessage*') { $fail7.Add('success path does not show success message') }
  if ($EngineSrc -notlike '*data-monitoring-trigger-status*') { $fail7.Add('status element is missing') }
  Add-TestResult 'TEST 7' ($fail7.Count -eq 0) ($fail7 -join "`n")

  $fail8 = New-Object System.Collections.Generic.List[string]
  if ($triggerFn.body -notlike '*data.message*') { $fail8.Add('HTTP 400 path does not display server message') }
  if ($triggerFn.body -notlike '*res.ok*') { $fail8.Add('trigger does not check HTTP success') }
  Add-TestResult 'TEST 8' ($fail8.Count -eq 0) ($fail8 -join "`n")

  $fail9 = New-Object System.Collections.Generic.List[string]
  foreach ($forbidden in @('saveCaseDecision', 'saveCasePositionPlaybook', 'saveCaseMarginOfSafety', 'applyDecisionLocally', 'applyPositionPlaybookLocally', 'loadInvestmentCases', 'upsertCase')) {
    if ($triggerFn.body -like ("*" + $forbidden + "*")) {
      $fail9.Add("trigger calls $forbidden")
    }
  }
  if ($IndexSrc -notlike '*workflow-engine.js?v=025a*') { $fail9.Add('index.html cache version was not updated') }

  Start-TempServer
  $casesHashBefore = (Get-FileHash -Path $script:TempCasesPath -Algorithm SHA256).Hash
  $before = Get-OwnershipSlice (Get-CaseMap)
  $uiPayload = ($Contract.expectedInterface.body | ConvertTo-Json -Depth 8 -Compress)
  $resp = Invoke-Post '/api/cases' $uiPayload
  if ([int]$resp.StatusCode -ne 200) {
    $fail9.Add(("UI payload HTTP {0} {1}" -f $resp.StatusCode, $resp.Body))
  }
  $after = Get-OwnershipSlice (Get-CaseMap)
  $casesHashAfter = (Get-FileHash -Path $script:TempCasesPath -Algorithm SHA256).Hash
  if ($casesHashAfter -ne $casesHashBefore) { $fail9.Add('investment-cases.json was written by monitoringTrigger') }
  foreach ($msg in @(
      (Assert-Unchanged 'decision' $before.decision $after.decision)
      (Assert-Unchanged 'decisionHistory' $before.decisionHistory $after.decisionHistory)
      (Assert-Unchanged 'thesis.status' $before.thesisStatus $after.thesisStatus)
      (Assert-Unchanged 'supportingEvidence' $before.supportingEvidence $after.supportingEvidence)
      (Assert-Unchanged 'counterEvidence' $before.counterEvidence $after.counterEvidence)
      (Assert-Unchanged 'valuation' $before.valuation $after.valuation)
      (Assert-Unchanged 'case.status' $before.caseStatus $after.caseStatus)
      (Assert-Unchanged 'positionPlaybook' $before.positionPlaybook $after.positionPlaybook)
    )) {
    if ($msg) { $fail9.Add([string]$msg) }
  }
  Add-TestResult 'TEST 9' ($fail9.Count -eq 0) ($fail9 -join "`n")
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
  Add-TestResult 'TEST 10' $guardOk $(if ($guardOk) { '' } else { 'production data/*.json was modified' })
  if (Test-Path $script:TempRoot) {
    Remove-Item -Recurse -Force $script:TempRoot -ErrorAction SilentlyContinue
  }
}

Write-Output ''
Write-Output '=== 011-B-3 SUMMARY ==='
foreach ($row in $script:Results) {
  Write-Output ("{0}: {1}" -f $row.Id, $row.Status)
  if ($row.Status -ne 'PASS' -and $row.Details) { Write-Output $row.Details }
}
$failed = @($script:Results | Where-Object { $_.Status -ne 'PASS' })
if ($failed.Count -gt 0) { exit 1 } else { exit 0 }
