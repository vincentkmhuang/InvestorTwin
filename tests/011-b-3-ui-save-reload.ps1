$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$env:PYTHONIOENCODING = 'utf-8'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$FixturePath = Join-Path $PSScriptRoot 'fixtures\3363-glass-bridge.ownership.json'
$EnginePath = Join-Path $RepoRoot 'js\workflow-engine.js'
$IndexPath = Join-Path $RepoRoot 'index.html'
$DataEnginePath = Join-Path $RepoRoot 'js\data-engine.js'
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
$IndexSrc = [System.IO.File]::ReadAllText($IndexPath, $Utf8)
$DataEngineSrc = [System.IO.File]::ReadAllText($DataEnginePath, $Utf8)

$script:Results = New-Object System.Collections.Generic.List[object]
$script:TempRoot = Join-Path $env:TEMP ('InvestorTwin-011-B-3-ui-reload-' + [guid]::NewGuid().ToString('N'))
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

function Get-CaseMap($path) {
  $py = Join-Path $script:TempRoot 'load_case.py'
  [System.IO.File]::WriteAllText($py, @'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    store = json.load(f)
print(json.dumps(next(c for c in store["cases"] if c["id"] == "3363-glass-bridge"), ensure_ascii=False, separators=(",", ":")))
'@, $Utf8)
  $raw = & python $py $path
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

function New-BrowserSaveArtifacts {
  $py = Join-Path $script:TempRoot 'browser_save_payload.py'
  $outPath = Join-Path $script:TempRoot 'browser-save-payload.json'
  [System.IO.File]::WriteAllText($py, @'
import json, sys
fixture_path, out_path = sys.argv[1], sys.argv[2]
editor_line = "Glass Bridge \u91cf\u7522\u9a57\u8b49\u662f\u5426\u78ba\u8a8d|glass-bridge"
expected_text = "Glass Bridge \u91cf\u7522\u9a57\u8b49\u662f\u5426\u78ba\u8a8d"

def parse_monitoring_editor_lines(text):
    items = []
    for raw in str(text or "").splitlines():
        line = raw.strip()
        if not line:
            continue
        sep = line.rfind("|")
        if sep > 0:
            item_text = line[:sep].strip()
            research_id = line[sep + 1:].strip()
            if item_text and research_id:
                items.append({"text": item_text, "researchId": research_id})
                continue
        items.append(line)
    return items

def normalize_monitoring_items(raw):
    if raw is None:
        lst = []
    elif isinstance(raw, list):
        lst = raw
    else:
        lst = [raw]
    out = []
    for item in lst:
        if item is None or item == "":
            continue
        if isinstance(item, str):
            text = item.strip()
            if text:
                out.append(text)
            continue
        if isinstance(item, dict):
            text = str(item.get("text") or "").strip()
            if not text:
                continue
            research_id = item.get("researchId")
            research_id = None if research_id is None else str(research_id).strip() or None
            if research_id:
                out.append({"text": text, "researchId": research_id})
            else:
                out.append({"text": text, "researchId": None})
    return out

with open(fixture_path, encoding="utf-8") as f:
    fx = json.load(f)
playbook = (fx.get("case") or {}).get("positionPlaybook") or {}
parsed = parse_monitoring_editor_lines(editor_line)
items = normalize_monitoring_items(parsed)
payload = {
    "id": "3363-glass-bridge",
    "positionPlaybook": {
        "targetPosition": playbook.get("targetPosition"),
        "initialPosition": playbook.get("initialPosition"),
        "entryTriggers": playbook.get("entryTriggers") or [],
        "monitoringItems": items,
    },
}
ok = (
    len(items) == 1
    and isinstance(items[0], dict)
    and items[0].get("text") == expected_text
    and items[0].get("researchId") == "glass-bridge"
)
with open(out_path, "w", encoding="utf-8", newline="\n") as f:
    json.dump({"ok": ok, "payload": payload, "expectedText": expected_text}, f, ensure_ascii=False, separators=(",", ":"))
body_path = out_path.replace("browser-save-payload.json", "browser-post-body.json")
with open(body_path, "w", encoding="utf-8", newline="\n") as f:
    json.dump(payload, f, ensure_ascii=False, separators=(",", ":"))
'@, $Utf8)
  & python $py $FixturePath $outPath
  if ($LASTEXITCODE -ne 0) { throw 'browser_save_payload.py failed' }
  return ([System.IO.File]::ReadAllText($outPath, $Utf8) | ConvertFrom-Json)
}

function Invoke-FetchLikeCasesPost($json) {
  $py = Join-Path $script:TempRoot 'fetch_like_post.py'
  $bodyPath = Join-Path $script:TempRoot 'post-body.json'
  $outPath = Join-Path $script:TempRoot 'post-result.json'
  [System.IO.File]::WriteAllText($bodyPath, $json, $Utf8)
  [System.IO.File]::WriteAllText($py, @'
import json, sys, urllib.error, urllib.request
body_path, port, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
body = open(body_path, encoding="utf-8").read().encode("utf-8")
req = urllib.request.Request(
    "http://localhost:%s/api/cases" % port,
    data=body,
    method="POST",
    headers={"Content-Type": "application/json"},
)
try:
    with urllib.request.urlopen(req) as resp:
        result = {"status": int(resp.status), "body": resp.read().decode("utf-8")}
except urllib.error.HTTPError as e:
    result = {"status": int(e.code), "body": e.read().decode("utf-8", "replace")}
with open(out_path, "w", encoding="utf-8", newline="\n") as f:
    json.dump(result, f, ensure_ascii=False, separators=(",", ":"))
'@, $Utf8)
  & python $py $bodyPath ([string]$script:TestPort) $outPath
  if ($LASTEXITCODE -ne 0) { throw 'fetch_like_post.py failed' }
  return ([System.IO.File]::ReadAllText($outPath, $Utf8) | ConvertFrom-Json)
}

function Get-ReloadedPlaybook {
  $py = Join-Path $script:TempRoot 'dataengine_reload.py'
  $outPath = Join-Path $script:TempRoot 'reloaded-playbook.json'
  [System.IO.File]::WriteAllText($py, @'
import json, sys, time, urllib.request
port, out_path = sys.argv[1], sys.argv[2]
url = "http://localhost:%s/data/investment-cases.json?t=%s" % (port, int(time.time() * 1000))
raw = urllib.request.urlopen(url).read().decode("utf-8")
store = json.loads(raw)
case = next(c for c in store["cases"] if c["id"] == "3363-glass-bridge")
playbook = case.get("positionPlaybook") or {}
items = playbook.get("monitoringItems")
info = {
    "url": url,
    "isList": isinstance(items, list),
    "count": len(items) if isinstance(items, list) else (0 if items is None else 1),
    "items": items if isinstance(items, list) else ([items] if items is not None else []),
    "rawItems": items,
    "targetPosition": playbook.get("targetPosition"),
    "initialPosition": playbook.get("initialPosition"),
    "entryTriggers": playbook.get("entryTriggers"),
}
with open(out_path, "w", encoding="utf-8", newline="\n") as f:
    json.dump(info, f, ensure_ascii=False, separators=(",", ":"))
'@, $Utf8)
  & python $py ([string]$script:TestPort) $outPath
  if ($LASTEXITCODE -ne 0) { throw 'dataengine_reload.py failed' }
  return ([System.IO.File]::ReadAllText($outPath, $Utf8) | ConvertFrom-Json)
}

function Get-RenderProbe($info) {
  $py = Join-Path $script:TempRoot 'render_probe.py'
  $inPath = Join-Path $script:TempRoot 'render-in.json'
  $outPath = Join-Path $script:TempRoot 'render-out.json'
  [System.IO.File]::WriteAllText($inPath, ($info | ConvertTo-Json -Depth 20 -Compress), $Utf8)
  [System.IO.File]::WriteAllText($py, @'
import json, sys
src, dest = sys.argv[1], sys.argv[2]
info = json.load(open(src, encoding="utf-8"))
raw = info.get("rawItems")
if raw is None:
    lst = []
elif isinstance(raw, list):
    lst = raw
else:
    lst = [raw]
rows = []
editor = []
for item in lst:
    if isinstance(item, str):
        text = item.strip()
        if not text:
            continue
        rows.append(text)
        editor.append(text)
        continue
    if isinstance(item, dict):
        text = str(item.get("text") or "").strip()
        if not text:
            continue
        research_id = item.get("researchId")
        research_id = None if research_id is None else str(research_id).strip() or None
        if research_id:
            rows.append("%s [%s]" % (text, research_id))
            editor.append("%s | %s" % (text, research_id))
        else:
            rows.append(text)
            editor.append(text)
display = "--" if not rows else "; ".join(rows)
out = {
    "display": display,
    "editor": "\n".join(editor),
    "showsDash": display == "--",
    "editorBlank": not editor,
}
json.dump(out, open(dest, "w", encoding="utf-8", newline="\n"), ensure_ascii=False, separators=(",", ":"))
'@, $Utf8)
  & python $py $inPath $outPath
  if ($LASTEXITCODE -ne 0) { throw 'render_probe.py failed' }
  return ([System.IO.File]::ReadAllText($outPath, $Utf8) | ConvertFrom-Json)
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
  foreach ($port in 18798, 18799, 18800) {
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

try {
  Start-TempServer
  $wrapper = New-BrowserSaveArtifacts
  $payload = $wrapper.payload
  $payloadJson = [System.IO.File]::ReadAllText((Join-Path $script:TempRoot 'browser-post-body.json'), $Utf8)

  $fail1 = New-Object System.Collections.Generic.List[string]
  if ($IndexSrc -notmatch 'js/workflow-engine\.js\?v=') { $fail1.Add('index.html does not load workflow-engine.js with a cache token') }
  if ($IndexSrc -notlike '*workflow-engine.js?v=011b3b*') { $fail1.Add('index.html is not on workflow-engine.js?v=011b3b; a stale tab can keep an older editor/save path') }
  if ($EngineSrc -notlike "*lastIndexOf('|')*") { $fail1.Add('parseMonitoringEditorLines does not split on |') }
  if ($EngineSrc -notlike '*monitoringItems: this.normalizeMonitoringItems(monitoringItems)*') { $fail1.Add('saveCasePositionPlaybook payload omits monitoringItems') }
  if ($EngineSrc -notlike '*JSON.stringify({ id: caseId, positionPlaybook: payload })*') { $fail1.Add('Save does not POST { id, positionPlaybook }') }
  if ($EngineSrc -notlike '*this.parseMonitoringEditorLines(monitoringInput.value)*') { $fail1.Add('Save click does not read the Monitoring Items textarea') }
  if ($EngineSrc -notlike '*monitoringItems: this.normalizeMonitoringItems(playbook.monitoringItems)*') { $fail1.Add('positionPlaybookView does not normalize monitoringItems on reload') }
  if ($DataEngineSrc -notlike "*investment-cases.json?t=*") { $fail1.Add('loadInvestmentCases does not cache-bust like the UI reload path') }
  Add-TestResult 'TEST 1' ($fail1.Count -eq 0) ($fail1 -join "`n")

  $fail2 = New-Object System.Collections.Generic.List[string]
  if (-not $wrapper.ok) { $fail2.Add('JS-equivalent parser did not produce { text, researchId } from text|researchId') }
  $mi = @($payload.positionPlaybook.monitoringItems)
  if ($mi.Count -ne 1) { $fail2.Add("payload monitoringItems count=$($mi.Count)") }
  elseif ([string]$mi[0].researchId -ne 'glass-bridge') { $fail2.Add('payload researchId mismatch') }
  if ($payloadJson.IndexOf('"monitoringItems":[{') -lt 0) { $fail2.Add('JSON.stringify-equivalent payload is missing monitoringItems array of objects') }
  Add-TestResult 'TEST 2' ($fail2.Count -eq 0) ($fail2 -join "`n")

  Write-TempStoreFromFixture
  $before = Get-OwnershipSlice (Get-CaseMap $script:TempCasesPath)
  $resp = Invoke-FetchLikeCasesPost $payloadJson
  $fail3 = New-Object System.Collections.Generic.List[string]
  if ([int]$resp.status -ne 200) { $fail3.Add("HTTP $($resp.status) $($resp.body)") }
  Add-TestResult 'TEST 3' ($fail3.Count -eq 0) ($fail3 -join "`n")

  $reloaded = Get-ReloadedPlaybook
  $fail4 = New-Object System.Collections.Generic.List[string]
  if (-not $reloaded.isList) { $fail4.Add('GET monitoringItems is not a JSON array; render would treat a scalar object as empty before normalizeMonitoringItems') }
  if ([int]$reloaded.count -ne 1) { $fail4.Add("GET count=$($reloaded.count) expected 1") }
  else {
    $hit = @($reloaded.items)[0]
    if ([string]$hit.researchId -ne 'glass-bridge') { $fail4.Add('GET researchId mismatch') }
    if ([string]$hit.text -ne [string]$wrapper.expectedText) { $fail4.Add('GET text mismatch') }
  }
  Add-TestResult 'TEST 4' ($fail4.Count -eq 0) ($fail4 -join "`n")

  $render = Get-RenderProbe $reloaded
  $fail5 = New-Object System.Collections.Generic.List[string]
  if ([string]$render.showsDash -eq 'True' -or [string]$render.display -eq '--') { $fail5.Add('renderInvestmentCase would show -- after reload') }
  if ([string]$render.editorBlank -eq 'True') { $fail5.Add('editor textarea would be blank after reload') }
  if ([string]$render.display -notlike '*glass-bridge*') { $fail5.Add("display=$($render.display)") }
  if ([string]$render.editor -notlike '*glass-bridge*') { $fail5.Add("editor=$($render.editor)") }
  Add-TestResult 'TEST 5' ($fail5.Count -eq 0) ($fail5 -join "`n")

  $after = Get-OwnershipSlice (Get-CaseMap $script:TempCasesPath)
  $fail6 = New-Object System.Collections.Generic.List[string]
  foreach ($msg in @(
      $(if (Test-SameJson $before.decision $after.decision) { $null } else { 'decision changed' })
      $(if (Test-SameJson $before.decisionHistory $after.decisionHistory) { $null } else { 'decisionHistory changed' })
      $(if (Test-SameJson $before.thesisStatus $after.thesisStatus) { $null } else { 'thesis.status changed' })
      $(if (Test-SameJson $before.supportingEvidence $after.supportingEvidence) { $null } else { 'supportingEvidence changed' })
      $(if (Test-SameJson $before.counterEvidence $after.counterEvidence) { $null } else { 'counterEvidence changed' })
      $(if (Test-SameJson $before.valuation $after.valuation) { $null } else { 'valuation changed' })
      $(if (Test-SameJson $before.caseStatus $after.caseStatus) { $null } else { 'case.status changed' })
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
Write-Output '=== 011-B-3 UI SAVE/RELOAD SUMMARY ==='
foreach ($row in $script:Results) {
  Write-Output ("{0}: {1}" -f $row.Id, $row.Status)
  if ($row.Status -ne 'PASS' -and $row.Details) { Write-Output $row.Details }
}
$failed = @($script:Results | Where-Object { $_.Status -ne 'PASS' })
if ($failed.Count -gt 0) { exit 1 } else { exit 0 }
