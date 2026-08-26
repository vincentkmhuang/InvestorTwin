$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$env:PYTHONIOENCODING = 'utf-8'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$ContractFixture = Join-Path $PSScriptRoot 'fixtures\012-c-daily-brief.json'
$EnginePath = Join-Path $RepoRoot 'js\data-engine.js'
$AppPath = Join-Path $RepoRoot 'app.js'
$WorkflowPath = Join-Path $RepoRoot 'js\workflow-engine.js'
$IndexPath = Join-Path $RepoRoot 'index.html'
$ServePath = Join-Path $RepoRoot 'serve.ps1'
$ProdBriefPath = Join-Path $RepoRoot 'data\morning-brief.json'
$ProdCasesPath = Join-Path $RepoRoot 'data\investment-cases.json'
$ProdQueuePath = Join-Path $RepoRoot 'data\research-queue.json'
$ProdIndexPath = Join-Path $RepoRoot 'data\knowledge-index.json'

if (-not (Test-Path $ContractFixture)) { throw "Missing fixture: $ContractFixture" }

$Utf8 = New-Object System.Text.UTF8Encoding $false
$ProdHashBefore = @{
  cases = (Get-FileHash -Path $ProdCasesPath -Algorithm SHA256).Hash
  queue = (Get-FileHash -Path $ProdQueuePath -Algorithm SHA256).Hash
  index = (Get-FileHash -Path $ProdIndexPath -Algorithm SHA256).Hash
  serve = (Get-FileHash -Path $ServePath -Algorithm SHA256).Hash
  workflow = (Get-FileHash -Path $WorkflowPath -Algorithm SHA256).Hash
}

$script:Results = New-Object System.Collections.Generic.List[object]
$script:TempRoot = Join-Path $env:TEMP ('InvestorTwin-012-C-' + [guid]::NewGuid().ToString('N'))
$script:TestPort = $null
$script:ServerProc = $null

function Add-TestResult($id, $passed, $details) {
  $status = if ($passed) { 'PASS' } else { 'FAIL' }
  $script:Results.Add([PSCustomObject]@{ Id = $id; Status = $status; Details = $details })
  Write-Output ("{0}: {1}" -f $id, $status)
  if ($details) { Write-Output $details }
}

function Get-FailList($result) {
  if ($null -eq $result -or $null -eq $result.fail) { return @() }
  return @($result.fail | Where-Object { $_ -ne $null -and "$_" -ne '' })
}

function Invoke-PythonValidator($mode) {
  $py = Join-Path $script:TempRoot 'validate_012c.py'
  if (-not (Test-Path $py)) {
    [System.IO.File]::WriteAllText($py, @'
import json, os, re, sys, datetime

def load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)

def js_weekday(date_str):
    try:
        year, month, day = map(int, date_str.strip().split("-"))
    except Exception:
        return None
    return int(datetime.datetime(year, month, day).strftime("%w"))

def show_radar(data):
    wd = js_weekday((data or {}).get("date"))
    if wd == 1:
        return True
    if (data or {}).get("opportunityRadarException") is True and wd is not None and 2 <= wd <= 5:
        return True
    return False

def link_id(item):
    if not isinstance(item, dict):
        return None
    raw = item.get("researchId")
    if raw is None:
        raw = item.get("cardRef")
    text = str(raw or "").strip()
    return text or None

def collect_ids(brief):
    ids = []
    seen = set()
    def push(value):
        rid = link_id(value) if not isinstance(value, str) else (value.strip() or None)
        if rid and rid not in seen:
            seen.add(rid)
            ids.append(rid)
    for block in (brief.get("globalMarketAndNews"), brief.get("taiwanMarketAndNews")):
        for item in (block or {}).get("items") or []:
            push(item)
    for key in ("aiIndustryHighlights", "upcomingEvents", "today3Things", "opportunityRadar"):
        for item in brief.get(key) or []:
            push(item)
    return ids

mode, repo, contract_path, dest = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
contract = load(contract_path)
engine_src = open(os.path.join(repo, "js", "data-engine.js"), encoding="utf-8").read()
app_src = open(os.path.join(repo, "app.js"), encoding="utf-8").read()
workflow_src = open(os.path.join(repo, "js", "workflow-engine.js"), encoding="utf-8").read()
index_src = open(os.path.join(repo, "index.html"), encoding="utf-8").read()
brief = load(os.path.join(repo, "data", "morning-brief.json"))
fail = []

if mode == "source":
    if "data/morning-brief/latest.json" in engine_src or "data/morning-brief/latest.json" in app_src:
        fail.append("production JS still fetches latest.json")
    if engine_src.count("data/morning-brief.json") < 2:
        fail.append("init/loadMorningBrief do not both load morning-brief.json")
    if "normalizeMorningBrief(" not in engine_src:
        fail.append("normalizeMorningBrief missing")
    if "?t=" not in engine_src or "Date.now()" not in engine_src:
        fail.append("morning-brief fetch is missing cache-busting")
    if re.search(r"date\s*=\s*new Date", engine_src) and "morningBrief" in engine_src[engine_src.find("normalizeMorningBrief"):engine_src.find("normalizeMorningBrief")+800]:
        fail.append("normalizer overwrites date from clock")
    if "raw.date" not in engine_src:
        fail.append("date is not taken from JSON")

elif mode == "date":
    date = brief.get("date")
    if not isinstance(date, str) or js_weekday(date) is None:
        fail.append("JSON date must be YYYY-MM-DD")
    if ('id="' + contract["dateElementId"] + '"') not in index_src:
        fail.append("today workbench missing date element")
    if "setText('morningBriefDate', data.date || '--')" not in engine_src:
        fail.append("renderer does not display JSON date")
    if "new Date().toISOString().slice(0, 10)" in engine_src[engine_src.find("renderMorningBrief"):engine_src.find("renderMorningBrief")+2500]:
        fail.append("renderer overwrites brief date")

elif mode == "render":
    for hid in contract["homepageIds"]:
        if ('id="' + hid + '"') not in index_src:
            fail.append("homepage missing id " + hid)
    if "renderMorningBrief(openMorningBriefResearch)" not in app_src:
        fail.append("Morning Brief render path missing")
    if "id=\"todayQueue\"" not in index_src:
        fail.append("today queue preview missing")

elif mode == "research":
    ids = collect_ids(brief)
    glass = os.path.join(repo, "research", "glass-bridge", "card.json")
    if not os.path.isfile(glass):
        fail.append("research/glass-bridge/card.json missing")
    for rid in ids:
        card = os.path.join(repo, "research", rid, "card.json")
        if not os.path.isfile(card):
            fail.append("researchId has no card: " + rid)
    if "ensureInQueue(researchId, 'Morning Brief')" not in app_src:
        fail.append("Morning Brief queue source missing")
    bind = engine_src[engine_src.find("bindResearchClick"):engine_src.find("bindResearchClick") + 450]
    if "morning-brief-static" not in bind:
        fail.append("missing researchId is not static")
    render_fn = engine_src[engine_src.find("async renderMorningBrief("):engine_src.find("async renderMorningBrief(") + 9000]
    if "/api/research/" in render_fn:
        fail.append("Brief render posts /api/research")
    if "/api/queue" in render_fn:
        fail.append("Brief render posts /api/queue")

elif mode == "nullable":
    null_count = 0
    for block in (brief.get("globalMarketAndNews"), brief.get("taiwanMarketAndNews")):
        for item in (block or {}).get("items") or []:
            if isinstance(item, dict) and "researchId" in item and not link_id(item):
                null_count += 1
    for item in brief.get("today3Things") or []:
        if isinstance(item, dict) and "researchId" in item and not link_id(item):
            null_count += 1
    if null_count < 1:
        fail.append("expected items with null researchId")
    click = app_src[app_src.find("async function openMorningBriefResearch"):app_src.find("async function openMorningBriefResearch") + 700]
    if "/api/research/" in click:
        fail.append("click path creates research via API")

elif mode == "radar":
    if not show_radar({"date": "2026-08-10", "opportunityRadarException": False}):
        fail.append("Monday radar should show")
    if show_radar({"date": "2026-08-11", "opportunityRadarException": False}):
        fail.append("Tue-Fri radar should hide by default")
    if not show_radar({"date": "2026-08-11", "opportunityRadarException": True}):
        fail.append("exceptional Tue-Fri radar should show")
    if "weekday === 1" not in engine_src or "opportunityRadarException === true" not in engine_src:
        fail.append("Opportunity Radar rules were changed")

elif mode == "latest":
    if "latest.json" in engine_src or "latest.json" in app_src:
        fail.append("production JS still references latest.json")

elif mode == "guard":
    if "this.queue.items.push({ id, addedFrom: source })" not in workflow_src:
        fail.append("queue schema push missing")
    if "monitoringTrigger" not in workflow_src or "positionPlaybook" not in workflow_src:
        fail.append("monitoring/playbook path missing from workflow-engine")
    if "JSON.stringify({ id, addedFrom: source })" not in workflow_src:
        fail.append("queue POST schema missing")
    if "normalizeMorningBrief(" not in engine_src:
        fail.append("normalizer missing")

else:
    fail.append("unknown mode")

with open(dest, "w", encoding="utf-8", newline="\n") as f:
    json.dump({"fail": fail}, f, ensure_ascii=False, separators=(",", ":"))
'@, $Utf8)
  }
  $outPath = Join-Path $script:TempRoot ("012c-" + $mode + ".json")
  & python $py $mode $RepoRoot $ContractFixture $outPath
  if ($LASTEXITCODE -ne 0) { throw ("validate_012c.py failed for " + $mode) }
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
  New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $script:TempRoot 'data') | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $script:TempRoot 'scripts') | Out-Null
  Copy-Item $ProdBriefPath (Join-Path $script:TempRoot 'data\morning-brief.json')
  Copy-Item $IndexPath (Join-Path $script:TempRoot 'index.html')
  Copy-Item (Join-Path $RepoRoot 'data\version.json') (Join-Path $script:TempRoot 'data\version.json') -ErrorAction SilentlyContinue
  Copy-Item (Join-Path $RepoRoot 'scripts\generate-knowledge-index.ps1') (Join-Path $script:TempRoot 'scripts\generate-knowledge-index.ps1')
  New-PatchedServeScript $ServePath (Join-Path $script:TempRoot 'serve.ps1')
  foreach ($port in 18797, 18798, 18799) {
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
        $probe = Invoke-WebRequest -Uri ("http://localhost:{0}/data/morning-brief.json" -f $port) -UseBasicParsing
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
  New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null

  Add-TestResult 'TEST 1' ((Get-FailList (Invoke-PythonValidator 'source')).Count -eq 0) ((Get-FailList (Invoke-PythonValidator 'source')) -join "`n")
  Add-TestResult 'TEST 2' ((Get-FailList (Invoke-PythonValidator 'date')).Count -eq 0) ((Get-FailList (Invoke-PythonValidator 'date')) -join "`n")
  Add-TestResult 'TEST 3' ((Get-FailList (Invoke-PythonValidator 'render')).Count -eq 0) ((Get-FailList (Invoke-PythonValidator 'render')) -join "`n")
  Add-TestResult 'TEST 4' ((Get-FailList (Invoke-PythonValidator 'research')).Count -eq 0) ((Get-FailList (Invoke-PythonValidator 'research')) -join "`n")
  Add-TestResult 'TEST 5' ((Get-FailList (Invoke-PythonValidator 'nullable')).Count -eq 0) ((Get-FailList (Invoke-PythonValidator 'nullable')) -join "`n")
  Add-TestResult 'TEST 6' ((Get-FailList (Invoke-PythonValidator 'radar')).Count -eq 0) ((Get-FailList (Invoke-PythonValidator 'radar')) -join "`n")
  Add-TestResult 'TEST 7' ((Get-FailList (Invoke-PythonValidator 'latest')).Count -eq 0) ((Get-FailList (Invoke-PythonValidator 'latest')) -join "`n")

  Start-TempServer
  $failHttp = New-Object System.Collections.Generic.List[string]
  try {
    $briefHttp = Invoke-WebRequest -Uri ("http://localhost:{0}/data/morning-brief.json" -f $script:TestPort) -UseBasicParsing
    $indexHttp = Invoke-WebRequest -Uri ("http://localhost:{0}/index.html" -f $script:TestPort) -UseBasicParsing
    if ([int]$briefHttp.StatusCode -ne 200) { $failHttp.Add('GET morning-brief.json failed') }
    else {
      $parsed = $briefHttp.Content | ConvertFrom-Json
      if (-not $parsed.date) { $failHttp.Add('HTTP brief missing date') }
      if (-not ($parsed.PSObject.Properties.Name -contains 'today3Things')) { $failHttp.Add('HTTP brief schema changed') }
    }
    if ([int]$indexHttp.StatusCode -ne 200) { $failHttp.Add('GET index.html failed') }
    elseif ([string]$indexHttp.Content -notlike '*id="morningBriefDate"*') { $failHttp.Add('HTTP index missing brief date') }
  } catch {
    $failHttp.Add($_.Exception.Message)
  }
  $guardFail = Get-FailList (Invoke-PythonValidator 'guard')
  foreach ($item in $guardFail) { $failHttp.Add([string]$item) }
  $hashOk = (
    (Get-FileHash -Path $ProdCasesPath -Algorithm SHA256).Hash -eq $ProdHashBefore.cases -and
    (Get-FileHash -Path $ProdQueuePath -Algorithm SHA256).Hash -eq $ProdHashBefore.queue -and
    (Get-FileHash -Path $ProdIndexPath -Algorithm SHA256).Hash -eq $ProdHashBefore.index -and
    (Get-FileHash -Path $ServePath -Algorithm SHA256).Hash -eq $ProdHashBefore.serve -and
    (Get-FileHash -Path $WorkflowPath -Algorithm SHA256).Hash -eq $ProdHashBefore.workflow
  )
  if (-not $hashOk) { $failHttp.Add('protected production files were modified') }
  Add-TestResult 'TEST 8' ($failHttp.Count -eq 0) ($failHttp -join "`n")
}
finally {
  Stop-TempServer
}

$failed = @($script:Results | Where-Object { $_.Status -ne 'PASS' })
Write-Output ''
Write-Output '=== 012-C SUMMARY ==='
foreach ($row in $script:Results) {
  Write-Output ("{0}: {1}" -f $row.Id, $row.Status)
}
if ($failed.Count -gt 0) { exit 1 }
exit 0
