$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$env:PYTHONIOENCODING = 'utf-8'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$ContractFixture = Join-Path $PSScriptRoot 'fixtures\012-a-morning-brief.json'
$ProdBriefPath = Join-Path $RepoRoot 'data\morning-brief.json'
$EnginePath = Join-Path $RepoRoot 'js\data-engine.js'
$AppPath = Join-Path $RepoRoot 'app.js'
$WorkflowPath = Join-Path $RepoRoot 'js\workflow-engine.js'
$IndexPath = Join-Path $RepoRoot 'index.html'
$ProdCasesPath = Join-Path $RepoRoot 'data\investment-cases.json'
$ProdQueuePath = Join-Path $RepoRoot 'data\research-queue.json'
$ProdIndexPath = Join-Path $RepoRoot 'data\knowledge-index.json'

if (-not (Test-Path $ContractFixture)) { throw "Missing fixture: $ContractFixture" }
if (-not (Test-Path $ProdBriefPath)) { throw "Missing file: $ProdBriefPath" }

$Utf8 = New-Object System.Text.UTF8Encoding $false
$ProdHashBefore = @{
  cases = (Get-FileHash -Path $ProdCasesPath -Algorithm SHA256).Hash
  queue = (Get-FileHash -Path $ProdQueuePath -Algorithm SHA256).Hash
  index = (Get-FileHash -Path $ProdIndexPath -Algorithm SHA256).Hash
}

$script:Results = New-Object System.Collections.Generic.List[object]
$script:TempRoot = Join-Path $env:TEMP ('InvestorTwin-012-A-' + [guid]::NewGuid().ToString('N'))
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
  $py = Join-Path $script:TempRoot 'validate_012a.py'
  if (-not (Test-Path $py)) {
    [System.IO.File]::WriteAllText($py, @'
import json, os, sys, datetime

def load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)

def link_id(item):
    if item is None:
        return None
    if isinstance(item, str):
        return item.strip() or None
    if not isinstance(item, dict):
        return None
    raw = item.get("researchId")
    if raw is None:
        raw = item.get("cardRef")
    text = str(raw or "").strip()
    return text or None

def news_group(raw, legacy_summary=None, legacy_items=None):
    if isinstance(raw, dict):
        items = raw.get("items")
        if not isinstance(items, list):
            items = raw.get("news") if isinstance(raw.get("news"), list) else []
        summary = raw.get("summary")
        if summary is None:
            summary = legacy_summary
        return {"summary": None if summary is None else str(summary), "items": items}
    return {
        "summary": None if legacy_summary is None else str(legacy_summary),
        "items": legacy_items if isinstance(legacy_items, list) else []
    }

def normalize(raw):
    if not isinstance(raw, dict):
        return {}
    executive = raw.get("executiveSummary")
    if executive is None:
        executive = raw.get("summary")
    summary = raw.get("summary")
    if summary is None:
        summary = executive
    lens = raw.get("macroDecisionLens")
    if not isinstance(lens, list):
        lens = raw.get("topThings") if isinstance(raw.get("topThings"), list) else []
    ai = raw.get("aiIndustryHighlights")
    if not isinstance(ai, list):
        ai = raw.get("aiHighlights") if isinstance(raw.get("aiHighlights"), list) else []
    today = raw.get("today3Things")
    if not isinstance(today, list):
        today = raw.get("todaysThreeThings") if isinstance(raw.get("todaysThreeThings"), list) else []
    radar = raw.get("opportunityRadar") if isinstance(raw.get("opportunityRadar"), list) else []
    return {
        "date": None if raw.get("date") is None else str(raw.get("date")).strip() or None,
        "executiveSummary": None if executive is None else str(executive),
        "summary": None if summary is None else str(summary),
        "macroDecisionLens": lens,
        "marketTemperature": raw.get("marketTemperature") if isinstance(raw.get("marketTemperature"), dict) else {},
        "globalMarketAndNews": news_group(raw.get("globalMarketAndNews"), raw.get("globalMarket"), raw.get("globalNews")),
        "taiwanMarketAndNews": news_group(raw.get("taiwanMarketAndNews"), raw.get("taiwanMarket"), raw.get("taiwanNews")),
        "aiIndustryHighlights": ai,
        "upcomingEvents": raw.get("upcomingEvents") if isinstance(raw.get("upcomingEvents"), list) else [],
        "today3Things": today,
        "opportunityRadar": radar,
        "opportunityRadarException": raw.get("opportunityRadarException") is True,
    }

def collect_ids(brief):
    ids = []
    seen = set()
    def push(value):
        rid = link_id(value)
        if rid and rid not in seen:
            seen.add(rid)
            ids.append(rid)
    for block in (brief.get("globalMarketAndNews"), brief.get("taiwanMarketAndNews")):
        items = (block or {}).get("items") or []
        for item in items:
            push(item)
    for key in ("aiIndustryHighlights", "upcomingEvents", "today3Things", "opportunityRadar"):
        for item in brief.get(key) or []:
            push(item)
    return ids

def weekday(date_str):
    if not isinstance(date_str, str):
        return None
    try:
        dt = datetime.datetime.strptime(date_str.strip(), "%Y-%m-%d")
    except ValueError:
        return None
    return dt.weekday()  # Monday=0 in datetime; JS UTC getUTCDay Sunday=0

def js_weekday(date_str):
    if not isinstance(date_str, str):
        return None
    try:
        year, month, day = map(int, date_str.strip().split("-"))
    except Exception:
        return None
    dt = datetime.datetime(year, month, day)
    # Match JS Date.UTC(...).getUTCDay(): Sunday=0
    return int(dt.strftime("%w"))

def show_radar(data):
    wd = js_weekday((data or {}).get("date"))
    if wd == 1:
        return True
    if (data or {}).get("opportunityRadarException") is True and wd is not None and 2 <= wd <= 5:
        return True
    return False

def walk_null_ok(brief):
    rows = []
    for block_name, block in (("global", brief.get("globalMarketAndNews")), ("taiwan", brief.get("taiwanMarketAndNews"))):
        for item in (block or {}).get("items") or []:
            rows.append(item)
    for key in ("aiIndustryHighlights", "upcomingEvents", "today3Things"):
        rows.extend(brief.get(key) or [])
    return rows

mode, repo, contract_path, dest = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
contract = load(contract_path)
brief_path = os.path.join(repo, "data", "morning-brief.json")
engine_path = os.path.join(repo, "js", "data-engine.js")
app_path = os.path.join(repo, "app.js")
workflow_path = os.path.join(repo, "js", "workflow-engine.js")
index_path = os.path.join(repo, "index.html")
raw = load(brief_path)
brief = normalize(raw)
engine_src = open(engine_path, encoding="utf-8").read()
app_src = open(app_path, encoding="utf-8").read()
workflow_src = open(workflow_path, encoding="utf-8").read()
index_src = open(index_path, encoding="utf-8").read()
fail = []

if mode == "schema":
    for key in contract["requiredFields"]:
        if key not in raw:
            fail.append("missing canonical field: " + key)
    if not (raw.get("executiveSummary") or raw.get("summary")):
        fail.append("executiveSummary/summary missing")
    for group_name in ("globalMarketAndNews", "taiwanMarketAndNews"):
        group = raw.get(group_name)
        if not isinstance(group, dict) or "summary" not in group or "items" not in group:
            fail.append(group_name + " must be {summary, items}")
        elif not isinstance(group.get("items"), list):
            fail.append(group_name + ".items must be an array")
    if not isinstance(raw.get("marketTemperature"), dict):
        fail.append("marketTemperature must be an object")
    if not isinstance(raw.get("opportunityRadar"), list):
        fail.append("opportunityRadar must be an array")
    if "opportunityRadarException" not in raw:
        fail.append("opportunityRadarException missing")
    date = raw.get("date")
    if not isinstance(date, str) or js_weekday(date) is None:
        fail.append("date must be YYYY-MM-DD")

elif mode == "source":
    if "data/morning-brief/latest.json" in engine_src or "data/morning-brief/latest.json" in app_src:
        fail.append("production JS still fetches latest.json")
    if engine_src.count("data/morning-brief.json") < 2:
        fail.append("init/loadMorningBrief do not both load morning-brief.json")
    if "normalizeMorningBrief(" not in engine_src:
        fail.append("normalizeMorningBrief missing")
    if "data/morning-brief.json" not in engine_src:
        fail.append("canonical source path missing")
    if "data-engine.js?v=012c1" not in index_src:
        fail.append("index.html cache token is not 012c1")

elif mode == "render":
    for hid in contract["homepageIds"]:
        if ('id="' + hid + '"') not in index_src:
            fail.append("homepage missing id " + hid)
    for needle in (
        "data.macroDecisionLens",
        "data.globalMarketAndNews",
        "data.taiwanMarketAndNews",
        "data.aiIndustryHighlights",
        "data.today3Things",
        "data.opportunityRadar",
        "shouldShowOpportunityRadar",
        "morning-brief-static",
        "researchLinkId",
    ):
        if needle not in engine_src:
            fail.append("renderer missing " + needle)
    if "class=\"page morning-brief\"" not in index_src and "class='page morning-brief'" not in index_src:
        if 'id="today"' not in index_src or "morning-brief" not in index_src:
            fail.append("today page is not Morning Brief")

elif mode == "research":
    ids = collect_ids(brief)
    if "glass-bridge" not in ids:
        fail.append("expected researchId glass-bridge")
    for rid in ids:
        card = os.path.join(repo, "research", rid, "card.json")
        if not os.path.isfile(card):
            fail.append("researchId has no card: " + rid)
        else:
            card_obj = load(card)
            if str(card_obj.get("id") or "") != rid:
                fail.append("card id mismatch for " + rid)
    if "openMorningBriefResearch" not in app_src:
        fail.append("openMorningBriefResearch missing")
    if "ensureInQueue(researchId, 'Morning Brief')" not in app_src:
        fail.append("Morning Brief queue source missing")
    render_fn_start = engine_src.find("async renderMorningBrief(")
    render_fn = engine_src[render_fn_start:render_fn_start + 8000] if render_fn_start >= 0 else ""
    if "/api/research/" in render_fn:
        fail.append("Morning Brief render posts /api/research")
    if "openMorningBriefResearch" in app_src:
        start = app_src.find("async function openMorningBriefResearch")
        fn = app_src[start:start + 1200]
        if "/api/research/" in fn:
            fail.append("openMorningBriefResearch posts /api/research")

elif mode == "nullable":
    rows = walk_null_ok(brief)
    null_count = 0
    for item in rows:
        if not isinstance(item, dict):
            continue
        if "researchId" in item and not link_id(item):
            null_count += 1
    if null_count < 1:
        fail.append("expected at least one item with null researchId")
    bind = engine_src[engine_src.find("bindResearchClick"):engine_src.find("bindResearchClick") + 400]
    if "morning-brief-static" not in bind:
        fail.append("missing researchId is not rendered as static")
    if "normalizeMorningBrief(" not in engine_src or "todaysThreeThings" not in engine_src:
        fail.append("legacy todaysThreeThings mapping missing")
    if "topThings" not in engine_src or "aiHighlights" not in engine_src:
        fail.append("legacy field mapping missing")
    legacy = normalize({
        "date": "2026-08-11",
        "summary": "legacy summary",
        "topThings": ["one"],
        "globalMarket": "g",
        "globalNews": [{"title": "n", "researchId": None}],
        "taiwanMarket": "t",
        "taiwanNews": [],
        "aiHighlights": [{"title": "a", "cardRef": "cpo"}],
        "todaysThreeThings": [{"text": "x", "researchId": None}],
        "upcomingEvents": [],
        "opportunityRadar": ["fau"],
        "opportunityRadarException": False,
    })
    if legacy.get("executiveSummary") != "legacy summary":
        fail.append("legacy summary alias failed")
    if legacy.get("macroDecisionLens") != ["one"]:
        fail.append("legacy topThings mapping failed")
    if (legacy.get("globalMarketAndNews") or {}).get("summary") != "g":
        fail.append("legacy globalMarket mapping failed")
    if collect_ids(legacy) != ["cpo", "fau"]:
        fail.append("legacy cardRef/researchId collect failed: " + json.dumps(collect_ids(legacy)))

elif mode == "radar":
    monday = {"date": "2026-08-10", "opportunityRadarException": False}
    tuesday = {"date": "2026-08-11", "opportunityRadarException": False}
    tuesday_ex = {"date": "2026-08-11", "opportunityRadarException": True}
    saturday_ex = {"date": "2026-08-15", "opportunityRadarException": True}
    if js_weekday("2026-08-10") != 1:
        fail.append("2026-08-10 should be Monday in JS weekday")
    if not show_radar(monday):
        fail.append("Monday radar should show")
    if show_radar(tuesday):
        fail.append("Tue-Fri radar should hide by default")
    if not show_radar(tuesday_ex):
        fail.append("exceptional Tue-Fri radar should show")
    if show_radar(saturday_ex):
        fail.append("weekend exception should not show radar")
    if "weekday === 1" not in engine_src:
        fail.append("JS Monday radar rule missing")
    if "opportunityRadarException === true" not in engine_src:
        fail.append("JS exception radar rule missing")
    if contract["opportunityRadar"]["mondayTitle"] not in engine_src:
        fail.append("Monday radar title missing")

elif mode == "queue":
    keys = set(contract["queueItemKeys"])
    if "ensureInQueue" not in workflow_src:
        fail.append("ensureInQueue missing")
    if "addedFrom: source" not in workflow_src and "addedFrom:source" not in workflow_src:
        fail.append("queue item addedFrom missing")
    if "{ id, addedFrom }" not in workflow_src and "id = $id; addedFrom = $addedFrom" not in workflow_src:
        if "addedFrom" not in workflow_src or "this.queue.items.push({ id, addedFrom: source })" not in workflow_src:
            fail.append("queue schema push missing")
    if "monitoringTrigger" in app_src[app_src.find("openMorningBriefResearch"):app_src.find("openMorningBriefResearch") + 800]:
        fail.append("Morning Brief click uses monitoringTrigger")

else:
    fail.append("unknown mode")

with open(dest, "w", encoding="utf-8", newline="\n") as f:
    json.dump({"fail": fail}, f, ensure_ascii=False, separators=(",", ":"))
'@, $Utf8)
  }
  $outPath = Join-Path $script:TempRoot ("012a-" + $mode + ".json")
  & python $py $mode $RepoRoot $ContractFixture $outPath
  if ($LASTEXITCODE -ne 0) { throw ("validate_012a.py failed for " + $mode) }
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
  New-Item -ItemType Directory -Path (Join-Path $script:TempRoot 'js') | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $script:TempRoot 'research\glass-bridge') | Out-Null
  Copy-Item (Join-Path $RepoRoot 'data\morning-brief.json') (Join-Path $script:TempRoot 'data\morning-brief.json')
  Copy-Item (Join-Path $RepoRoot 'data\version.json') (Join-Path $script:TempRoot 'data\version.json') -ErrorAction SilentlyContinue
  Copy-Item (Join-Path $RepoRoot 'data\research-queue.json') (Join-Path $script:TempRoot 'data\research-queue.json')
  Copy-Item (Join-Path $RepoRoot 'scripts\generate-knowledge-index.ps1') (Join-Path $script:TempRoot 'scripts\generate-knowledge-index.ps1')
  Copy-Item $IndexPath (Join-Path $script:TempRoot 'index.html')
  Copy-Item $EnginePath (Join-Path $script:TempRoot 'js\data-engine.js')
  Copy-Item (Join-Path $RepoRoot 'research\glass-bridge\card.json') (Join-Path $script:TempRoot 'research\glass-bridge\card.json')
  New-PatchedServeScript (Join-Path $RepoRoot 'serve.ps1') (Join-Path $script:TempRoot 'serve.ps1')
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

function Get-Http($path) {
  $uri = "http://localhost:$($script:TestPort)$path"
  try {
    $resp = Invoke-WebRequest -Uri $uri -UseBasicParsing
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

try {
  New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null

  $schemaFail = Get-FailList (Invoke-PythonValidator 'schema')
  Add-TestResult 'TEST 1' ($schemaFail.Count -eq 0) ($schemaFail -join "`n")

  $sourceFail = Get-FailList (Invoke-PythonValidator 'source')
  Add-TestResult 'TEST 2' ($sourceFail.Count -eq 0) ($sourceFail -join "`n")

  Start-TempServer
  $fail3 = New-Object System.Collections.Generic.List[string]
  $briefHttp = Get-Http '/data/morning-brief.json'
  if ([int]$briefHttp.StatusCode -ne 200) { $fail3.Add('GET morning-brief.json failed') }
  else {
    $parsed = $briefHttp.Body | ConvertFrom-Json
    if (-not $parsed.date) { $fail3.Add('HTTP brief missing date') }
    if (-not $parsed.executiveSummary) { $fail3.Add('HTTP brief missing executiveSummary') }
    if (-not $parsed.today3Things) { $fail3.Add('HTTP brief missing today3Things') }
  }
  $indexHttp = Get-Http '/index.html'
  if ([int]$indexHttp.StatusCode -ne 200) { $fail3.Add('GET index.html failed') }
  elseif ($indexHttp.Body -notlike '*id="today"*') { $fail3.Add('index.html missing today page') }
  $cardHttp = Get-Http '/research/glass-bridge/card.json'
  if ([int]$cardHttp.StatusCode -ne 200) { $fail3.Add('GET glass-bridge card failed') }
  foreach ($item in (Get-FailList (Invoke-PythonValidator 'render'))) { $fail3.Add([string]$item) }
  Add-TestResult 'TEST 3' ($fail3.Count -eq 0) ($fail3 -join "`n")

  $researchFail = Get-FailList (Invoke-PythonValidator 'research')
  Add-TestResult 'TEST 4' ($researchFail.Count -eq 0) ($researchFail -join "`n")

  $nullableFail = Get-FailList (Invoke-PythonValidator 'nullable')
  Add-TestResult 'TEST 5' ($nullableFail.Count -eq 0) ($nullableFail -join "`n")

  $radarFail = Get-FailList (Invoke-PythonValidator 'radar')
  Add-TestResult 'TEST 6' ($radarFail.Count -eq 0) ($radarFail -join "`n")

  $queueFail = Get-FailList (Invoke-PythonValidator 'queue')
  Add-TestResult 'TEST 7' ($queueFail.Count -eq 0) ($queueFail -join "`n")

  $guardOk = (
    (Get-FileHash -Path $ProdCasesPath -Algorithm SHA256).Hash -eq $ProdHashBefore.cases -and
    (Get-FileHash -Path $ProdQueuePath -Algorithm SHA256).Hash -eq $ProdHashBefore.queue -and
    (Get-FileHash -Path $ProdIndexPath -Algorithm SHA256).Hash -eq $ProdHashBefore.index
  )
  Add-TestResult 'TEST 8' $guardOk $(if ($guardOk) { '' } else { 'production data/*.json was modified' })
}
finally {
  Stop-TempServer
}

$failed = @($script:Results | Where-Object { $_.Status -ne 'PASS' })
Write-Output ''
Write-Output '=== 012-A SUMMARY ==='
foreach ($row in $script:Results) {
  Write-Output ("{0}: {1}" -f $row.Id, $row.Status)
}
if ($failed.Count -gt 0) { exit 1 }
exit 0
