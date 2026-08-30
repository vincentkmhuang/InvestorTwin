$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$env:PYTHONIOENCODING = 'utf-8'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$ContractFixture = Join-Path $PSScriptRoot 'fixtures\012-b-today-workbench.json'
$AppPath = Join-Path $RepoRoot 'app.js'
$IndexPath = Join-Path $RepoRoot 'index.html'
$StylePath = Join-Path $RepoRoot 'style.css'
$WorkflowPath = Join-Path $RepoRoot 'js\workflow-engine.js'
$EnginePath = Join-Path $RepoRoot 'js\data-engine.js'
$ServePath = Join-Path $RepoRoot 'serve.ps1'
$ProdCasesPath = Join-Path $RepoRoot 'data\investment-cases.json'
$ProdQueuePath = Join-Path $RepoRoot 'data\research-queue.json'
$ProdIndexPath = Join-Path $RepoRoot 'data\knowledge-index.json'
$ProdBriefPath = Join-Path $RepoRoot 'data\morning-brief.json'

if (-not (Test-Path $ContractFixture)) { throw "Missing fixture: $ContractFixture" }

$Utf8 = New-Object System.Text.UTF8Encoding $false
$ProdHashBefore = @{
  cases = (Get-FileHash -Path $ProdCasesPath -Algorithm SHA256).Hash
  queue = (Get-FileHash -Path $ProdQueuePath -Algorithm SHA256).Hash
  index = (Get-FileHash -Path $ProdIndexPath -Algorithm SHA256).Hash
  brief = (Get-FileHash -Path $ProdBriefPath -Algorithm SHA256).Hash
  serve = (Get-FileHash -Path $ServePath -Algorithm SHA256).Hash
  workflow = (Get-FileHash -Path $WorkflowPath -Algorithm SHA256).Hash
  engine = (Get-FileHash -Path $EnginePath -Algorithm SHA256).Hash
}

$script:Results = New-Object System.Collections.Generic.List[object]
$script:TempRoot = Join-Path $env:TEMP ('InvestorTwin-012-B-' + [guid]::NewGuid().ToString('N'))
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
  $py = Join-Path $script:TempRoot 'validate_012b.py'
  if (-not (Test-Path $py)) {
    [System.IO.File]::WriteAllText($py, @'
import json, os, sys

def load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)

def extract_fn(src, name):
    needles = ["function " + name + "(", "async function " + name + "("]
    start = -1
    for needle in needles:
        idx = src.find(needle)
        if idx >= 0:
            start = idx
            break
    if start < 0:
        return ""
    brace = src.find("{", start)
    depth = 0
    for i, ch in enumerate(src[brace:], brace):
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return src[start:i + 1]
    return src[start:]

mode, repo, contract_path, dest = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
contract = load(contract_path)
index_src = open(os.path.join(repo, "index.html"), encoding="utf-8").read()
app_src = open(os.path.join(repo, "app.js"), encoding="utf-8").read()
style_src = open(os.path.join(repo, "style.css"), encoding="utf-8").read()
workflow_src = open(os.path.join(repo, "js", "workflow-engine.js"), encoding="utf-8").read()
fail = []
preview = extract_fn(app_src, "renderTodayQueue")
render_fn = extract_fn(app_src, "render")
show_page = extract_fn(app_src, "showPage")

if mode == "markup":
    today_block = index_src[index_src.find('id="today"'):index_src.find('id="queue"')]
    queue_page = index_src[index_src.find('id="queue"'):index_src.find('id="cards"')]
    if 'id="todayQueue"' in today_block or contract["forbiddenTodayQueueHeading"] in today_block:
        fail.append("Today Workspace must not display Research Queue as 今日佇列")
    if 'id="queueList"' not in queue_page:
        fail.append("queue page list missing")
    if contract["todayPageTitle"] not in index_src:
        fail.append("today page title missing in index.html")
    if "today-workspace" not in today_block:
        fail.append("today-workspace skeleton class missing")
    if "app.js?v=0052" not in index_src:
        fail.append("app.js cache token is not 0052")
    if "style.css?v=0053" not in index_src:
        fail.append("style.css cache token is not 0053")
    if "data-engine.js?v=012c1" not in index_src:
        fail.append("012-C data-engine cache token missing")

elif mode == "preview":
    if "renderTodayQueue" in app_src:
        fail.append("Today Workspace still renders a queue preview")
    if "getQueueIds()" not in render_fn:
        fail.append("queue page render no longer reads getQueueIds()")
    for banned in contract["forbiddenInPreview"]:
        if banned in render_fn:
            fail.append("render() calls " + banned)

elif mode == "click":
    if "fromPage: 'queue'" not in render_fn:
        fail.append("queue page click path was changed")
    if contract["todayPageTitle"] not in show_page:
        fail.append("showPage today title is not workbench title")

elif mode == "brief":
    for hid in contract["homepageBriefIds"]:
        if ('id="' + hid + '"') not in index_src:
            fail.append("Morning Brief homepage missing id " + hid)
    if "renderMorningBrief(openMorningBriefResearch)" not in app_src:
        fail.append("Morning Brief render path missing")
    if "ensureInQueue(researchId, 'Morning Brief')" not in app_src:
        fail.append("Morning Brief queue source missing")

elif mode == "schema":
    if "this.queue.items.push({ id, addedFrom: source })" not in workflow_src:
        fail.append("queue schema push missing")
    if "JSON.stringify({ id, addedFrom: source })" not in workflow_src:
        fail.append("queue POST schema missing")
    queue_page = index_src[index_src.find('id="queue"'):index_src.find('id="cards"')]
    if 'id="topic"' not in queue_page:
        fail.append("queue page editor was removed")

else:
    fail.append("unknown mode")

with open(dest, "w", encoding="utf-8", newline="\n") as f:
    json.dump({"fail": fail}, f, ensure_ascii=False, separators=(",", ":"))
'@, $Utf8)
  }
  $outPath = Join-Path $script:TempRoot ("012b-" + $mode + ".json")
  & python $py $mode $RepoRoot $ContractFixture $outPath
  if ($LASTEXITCODE -ne 0) { throw ("validate_012b.py failed for " + $mode) }
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
  Copy-Item $IndexPath (Join-Path $script:TempRoot 'index.html')
  Copy-Item (Join-Path $RepoRoot 'data\morning-brief.json') (Join-Path $script:TempRoot 'data\morning-brief.json')
  Copy-Item (Join-Path $RepoRoot 'data\version.json') (Join-Path $script:TempRoot 'data\version.json') -ErrorAction SilentlyContinue
  Copy-Item (Join-Path $RepoRoot 'scripts\generate-knowledge-index.ps1') (Join-Path $script:TempRoot 'scripts\generate-knowledge-index.ps1')
  New-PatchedServeScript $ServePath (Join-Path $script:TempRoot 'serve.ps1')
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
        $probe = Invoke-WebRequest -Uri ("http://localhost:{0}/index.html" -f $port) -UseBasicParsing
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

  Add-TestResult 'TEST 1' ((Get-FailList (Invoke-PythonValidator 'markup')).Count -eq 0) ((Get-FailList (Invoke-PythonValidator 'markup')) -join "`n")
  Add-TestResult 'TEST 2' ((Get-FailList (Invoke-PythonValidator 'preview')).Count -eq 0) ((Get-FailList (Invoke-PythonValidator 'preview')) -join "`n")
  Add-TestResult 'TEST 3' ((Get-FailList (Invoke-PythonValidator 'click')).Count -eq 0) ((Get-FailList (Invoke-PythonValidator 'click')) -join "`n")
  Add-TestResult 'TEST 4' ((Get-FailList (Invoke-PythonValidator 'brief')).Count -eq 0) ((Get-FailList (Invoke-PythonValidator 'brief')) -join "`n")
  Add-TestResult 'TEST 5' ((Get-FailList (Invoke-PythonValidator 'schema')).Count -eq 0) ((Get-FailList (Invoke-PythonValidator 'schema')) -join "`n")

  Start-TempServer
  $fail6 = New-Object System.Collections.Generic.List[string]
  try {
    $indexHttp = Invoke-WebRequest -Uri ("http://localhost:{0}/index.html" -f $script:TestPort) -UseBasicParsing
    if ([int]$indexHttp.StatusCode -ne 200) { $fail6.Add('GET index.html failed') }
    else {
      $body = [string]$indexHttp.Content
      if ($body -like '*id="todayQueue"*') { $fail6.Add('HTTP index still has todayQueue on Today Workspace') }
      if ($body -notlike '*id="morningExecutiveSummary"*') { $fail6.Add('HTTP index missing Morning Brief') }
      if ($body -notlike '*id="queue"*') { $fail6.Add('HTTP index missing queue page') }
    }
  } catch {
    $fail6.Add($_.Exception.Message)
  }
  Add-TestResult 'TEST 6' ($fail6.Count -eq 0) ($fail6 -join "`n")

  $guardOk = (
    (Get-FileHash -Path $ProdCasesPath -Algorithm SHA256).Hash -eq $ProdHashBefore.cases -and
    (Get-FileHash -Path $ProdQueuePath -Algorithm SHA256).Hash -eq $ProdHashBefore.queue -and
    (Get-FileHash -Path $ProdIndexPath -Algorithm SHA256).Hash -eq $ProdHashBefore.index -and
    (Get-FileHash -Path $ProdBriefPath -Algorithm SHA256).Hash -eq $ProdHashBefore.brief -and
    (Get-FileHash -Path $ServePath -Algorithm SHA256).Hash -eq $ProdHashBefore.serve -and
    (Get-FileHash -Path $WorkflowPath -Algorithm SHA256).Hash -eq $ProdHashBefore.workflow -and
    (Get-FileHash -Path $EnginePath -Algorithm SHA256).Hash -eq $ProdHashBefore.engine
  )
  Add-TestResult 'TEST 7' $guardOk $(if ($guardOk) { '' } else { 'protected production files were modified' })
}
finally {
  Stop-TempServer
}

$failed = @($script:Results | Where-Object { $_.Status -ne 'PASS' })
Write-Output ''
Write-Output '=== 012-B SUMMARY ==='
foreach ($row in $script:Results) {
  Write-Output ("{0}: {1}" -f $row.Id, $row.Status)
}
if ($failed.Count -gt 0) { exit 1 }
exit 0
