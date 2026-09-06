$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$env:PYTHONIOENCODING = 'utf-8'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$OfficialUrl = 'https://www.federalreserve.gov/newsevents/pressreleases/monetary20260819a.htm'
$Sprint001Path = Join-Path $PSScriptRoot 'p2-001-news-intelligence-foundation.ps1'
$Sprint002Path = Join-Path $PSScriptRoot 'p2-002-nvidia-official-adapter.ps1'
$AdapterPath = Join-Path $RepoRoot 'scripts\federal-reserve-official-adapter.py'
$NvidiaAdapterPath = Join-Path $RepoRoot 'scripts\nvidia-official-adapter.py'
$EvalPath = Join-Path $RepoRoot 'scripts\evaluate-news-intelligence.py'
$HtmlPath = Join-Path $PSScriptRoot 'fixtures\p2-003-fed-fomc-minutes-20260819.html'
$NewsPath = Join-Path $PSScriptRoot 'fixtures\p2-003-news-fed-fomc-minutes.json'
$MissingTitleHtml = Join-Path $PSScriptRoot 'fixtures\p2-003-fed-missing-title.html'
$SpecPath = Join-Path $RepoRoot 'docs\Phase 2 Sprint 001 News Intelligence Foundation SPEC.md'
$HandbookPath = Join-Path $RepoRoot 'docs\Investor Twin Handbook V2.0.md'
$GeneratePath = Join-Path $RepoRoot 'scripts\generate-morning-brief.py'
$CollectPath = Join-Path $RepoRoot 'scripts\collect-evidence.py'
$AppPath = Join-Path $RepoRoot 'app.js'
$EnginePath = Join-Path $RepoRoot 'js\data-engine.js'
$WorkflowPath = Join-Path $RepoRoot 'js\workflow-engine.js'
$IndexPath = Join-Path $RepoRoot 'index.html'
$ProdBriefPath = Join-Path $RepoRoot 'data\morning-brief.json'
$ProdQueuePath = Join-Path $RepoRoot 'data\research-queue.json'
$ProdCasesPath = Join-Path $RepoRoot 'data\investment-cases.json'
$ProdIndexPath = Join-Path $RepoRoot 'data\knowledge-index.json'
$ForbiddenNewsDir = Join-Path $RepoRoot 'data\news'
$ForbiddenEventsDir = Join-Path $RepoRoot 'data\events'

foreach ($path in @($Sprint001Path, $Sprint002Path, $AdapterPath, $NvidiaAdapterPath, $EvalPath, $HtmlPath, $NewsPath, $MissingTitleHtml, $SpecPath, $HandbookPath)) {
  if (-not (Test-Path -LiteralPath $path)) { throw "Missing: $path" }
}

$Utf8 = New-Object System.Text.UTF8Encoding $false
$AdapterSrc = [System.IO.File]::ReadAllText($AdapterPath, $Utf8)
$EvalSrc = [System.IO.File]::ReadAllText($EvalPath, $Utf8)
$NewsRaw = [System.IO.File]::ReadAllText($NewsPath, $Utf8) | ConvertFrom-Json

$ProdHashBefore = @{
  brief = (Get-FileHash -Path $ProdBriefPath -Algorithm SHA256).Hash
  queue = (Get-FileHash -Path $ProdQueuePath -Algorithm SHA256).Hash
  cases = (Get-FileHash -Path $ProdCasesPath -Algorithm SHA256).Hash
  index = (Get-FileHash -Path $ProdIndexPath -Algorithm SHA256).Hash
  generate = (Get-FileHash -Path $GeneratePath -Algorithm SHA256).Hash
  collect = (Get-FileHash -Path $CollectPath -Algorithm SHA256).Hash
  eval = (Get-FileHash -Path $EvalPath -Algorithm SHA256).Hash
  nvidia = (Get-FileHash -Path $NvidiaAdapterPath -Algorithm SHA256).Hash
  sprint001 = (Get-FileHash -Path $Sprint001Path -Algorithm SHA256).Hash
  sprint002 = (Get-FileHash -Path $Sprint002Path -Algorithm SHA256).Hash
  spec = (Get-FileHash -Path $SpecPath -Algorithm SHA256).Hash
  handbook = (Get-FileHash -Path $HandbookPath -Algorithm SHA256).Hash
  app = (Get-FileHash -Path $AppPath -Algorithm SHA256).Hash
  engine = (Get-FileHash -Path $EnginePath -Algorithm SHA256).Hash
  workflow = (Get-FileHash -Path $WorkflowPath -Algorithm SHA256).Hash
  html = (Get-FileHash -Path $IndexPath -Algorithm SHA256).Hash
}

$script:Results = New-Object System.Collections.Generic.List[object]
function Add-TestResult($id, $passed, $details) {
  $status = if ($passed) { 'PASS' } else { 'FAIL' }
  $script:Results.Add([PSCustomObject]@{ Id = $id; Status = $status; Details = $details })
  Write-Output ("{0}: {1}" -f $id, $status)
  if ($details) { Write-Output $details }
}

function Get-Python {
  $python = $env:INVESTORTWIN_PYTHON
  if (-not $python) { $python = 'python' }
  return $python
}

function Invoke-Adapter($argumentList) {
  $python = Get-Python
  $out = & $python $AdapterPath @argumentList 2>&1
  $text = ($out | ForEach-Object { "$_" }) -join "`n"
  if ($LASTEXITCODE -ne 0) { throw "adapter failed: $text" }
  return [PSCustomObject]@{ Raw = $text; News = ($text | ConvertFrom-Json) }
}

function Invoke-AdapterFail($argumentList) {
  $python = Get-Python
  $stderrPath = Join-Path $env:TEMP ('p2-003-adapter-fail-' + [guid]::NewGuid().ToString('N') + '.txt')
  $stdoutPath = Join-Path $env:TEMP ('p2-003-adapter-out-' + [guid]::NewGuid().ToString('N') + '.txt')
  $argLine = (@($AdapterPath) + @($argumentList))
  $proc = Start-Process -FilePath $python -ArgumentList $argLine -Wait -PassThru -NoNewWindow -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
  $text = ''
  if (Test-Path -LiteralPath $stdoutPath) { $text += [System.IO.File]::ReadAllText($stdoutPath) }
  if (Test-Path -LiteralPath $stderrPath) { $text += [System.IO.File]::ReadAllText($stderrPath) }
  Remove-Item -LiteralPath $stdoutPath, $stderrPath -ErrorAction SilentlyContinue
  return [PSCustomObject]@{ ExitCode = $proc.ExitCode; Text = $text }
}

function Invoke-EvalInput($fixturePath) {
  $python = Get-Python
  $out = & $python $EvalPath --input $fixturePath 2>&1
  $text = ($out | ForEach-Object { "$_" }) -join "`n"
  if ($LASTEXITCODE -ne 0) { throw "evaluate failed: $text" }
  return ($text | ConvertFrom-Json)
}

function Invoke-EvalJson($jsonText) {
  $python = Get-Python
  $out = $jsonText | & $python $EvalPath 2>&1
  $text = ($out | ForEach-Object { "$_" }) -join "`n"
  if ($LASTEXITCODE -ne 0) { throw "evaluate stdin failed: $text" }
  return ($text | ConvertFrom-Json)
}

function Test-ProtectedHashes {
  return (
    (Get-FileHash -Path $ProdBriefPath -Algorithm SHA256).Hash -eq $ProdHashBefore.brief -and
    (Get-FileHash -Path $ProdQueuePath -Algorithm SHA256).Hash -eq $ProdHashBefore.queue -and
    (Get-FileHash -Path $ProdCasesPath -Algorithm SHA256).Hash -eq $ProdHashBefore.cases -and
    (Get-FileHash -Path $ProdIndexPath -Algorithm SHA256).Hash -eq $ProdHashBefore.index -and
    (Get-FileHash -Path $GeneratePath -Algorithm SHA256).Hash -eq $ProdHashBefore.generate -and
    (Get-FileHash -Path $CollectPath -Algorithm SHA256).Hash -eq $ProdHashBefore.collect -and
    (Get-FileHash -Path $EvalPath -Algorithm SHA256).Hash -eq $ProdHashBefore.eval -and
    (Get-FileHash -Path $NvidiaAdapterPath -Algorithm SHA256).Hash -eq $ProdHashBefore.nvidia -and
    (Get-FileHash -Path $Sprint001Path -Algorithm SHA256).Hash -eq $ProdHashBefore.sprint001 -and
    (Get-FileHash -Path $Sprint002Path -Algorithm SHA256).Hash -eq $ProdHashBefore.sprint002 -and
    (Get-FileHash -Path $SpecPath -Algorithm SHA256).Hash -eq $ProdHashBefore.spec -and
    (Get-FileHash -Path $HandbookPath -Algorithm SHA256).Hash -eq $ProdHashBefore.handbook -and
    (Get-FileHash -Path $AppPath -Algorithm SHA256).Hash -eq $ProdHashBefore.app -and
    (Get-FileHash -Path $EnginePath -Algorithm SHA256).Hash -eq $ProdHashBefore.engine -and
    (Get-FileHash -Path $WorkflowPath -Algorithm SHA256).Hash -eq $ProdHashBefore.workflow -and
    (Get-FileHash -Path $IndexPath -Algorithm SHA256).Hash -eq $ProdHashBefore.html -and
    -not (Test-Path -LiteralPath $ForbiddenNewsDir) -and
    -not (Test-Path -LiteralPath $ForbiddenEventsDir)
  )
}

Write-Output '=== P2-001 / P2-002 REGRESSION ==='
$sprint001 = & powershell -NoProfile -File $Sprint001Path
$sprint001Text = ($sprint001 | ForEach-Object { "$_" }) -join "`n"
Write-Output $sprint001Text
$sprint001Ok = ($LASTEXITCODE -eq 0)
Add-TestResult 'TEST 1-20' $sprint001Ok $(if ($sprint001Ok) { 'Sprint 001 TEST 1-20 still PASS' } else { $sprint001Text })

$sprint002 = & powershell -NoProfile -File $Sprint002Path
$sprint002Text = ($sprint002 | ForEach-Object { "$_" }) -join "`n"
Write-Output $sprint002Text
$sprint002Ok = ($LASTEXITCODE -eq 0)
Add-TestResult 'TEST 21-30' $sprint002Ok $(if ($sprint002Ok) { 'Sprint 002 TEST 21-30 still PASS' } else { $sprint002Text })

$offlineRun = Invoke-Adapter @('--url', $OfficialUrl, '--html', $HtmlPath)
$offline = $offlineRun.News
$offlineEval = Invoke-EvalJson $offlineRun.Raw
$fixtureEval = Invoke-EvalInput $NewsPath

$fail31 = New-Object System.Collections.Generic.List[string]
if ($offline.source -ne 'Federal Reserve Official') { $fail31.Add("source=$($offline.source)") }
if ([string]$offline.title -notlike '*Minutes of the Federal Open Market Committee*') { $fail31.Add("title=$($offline.title)") }
if ([string]$offline.url -ne $OfficialUrl) { $fail31.Add("url=$($offline.url)") }
if (-not $offline.summary -and -not $offline.content) { $fail31.Add('missing summary/content') }
Add-TestResult 'TEST 31' ($fail31.Count -eq 0) ($fail31 -join "`n")

$fail32 = New-Object System.Collections.Generic.List[string]
foreach ($field in @('source', 'title', 'publishedTime', 'url')) {
  if (-not $offline.$field) { $fail32.Add("News Object missing $field") }
}
if (-not $offline.summary -and -not $offline.content) { $fail32.Add('News Object missing summary/content') }
if ([string]$NewsRaw.source -ne 'Federal Reserve Official') { $fail32.Add('offline fixture source is not Federal Reserve Official') }
Add-TestResult 'TEST 32' ($fail32.Count -eq 0) ($fail32 -join "`n")

$fail33 = New-Object System.Collections.Generic.List[string]
foreach ($field in @('importance', 'relevance', 'impact', 'researchCandidate', 'candidate')) {
  if ($null -ne $offline.PSObject.Properties[$field]) { $fail33.Add("adapter News Object contains $field") }
  if ($null -ne $NewsRaw.PSObject.Properties[$field]) { $fail33.Add("offline fixture contains $field") }
}
Add-TestResult 'TEST 33' ($fail33.Count -eq 0) ($fail33 -join "`n")

$fail34 = New-Object System.Collections.Generic.List[string]
foreach ($field in @('news', 'event', 'importance', 'relevance', 'relevanceBasis', 'impact', 'researchCandidate')) {
  if ($null -eq $offlineEval.PSObject.Properties[$field]) { $fail34.Add("evaluation missing $field") }
}
if ($null -eq $fixtureEval.event) { $fail34.Add('fixture evaluation missing event') }
Add-TestResult 'TEST 34' ($fail34.Count -eq 0) ($fail34 -join "`n")

$fail35 = New-Object System.Collections.Generic.List[string]
if ($offlineEval.event.eventType -ne 'Policy') { $fail35.Add("adapter eventType=$($offlineEval.event.eventType)") }
if ($fixtureEval.event.eventType -ne 'Policy') { $fail35.Add("fixture eventType=$($fixtureEval.event.eventType)") }
Add-TestResult 'TEST 35' ($fail35.Count -eq 0) ($fail35 -join "`n")

$fail36 = New-Object System.Collections.Generic.List[string]
if ([string]$offline.publishedTime -ne '2026-08-19') { $fail36.Add("adapter publishedTime=$($offline.publishedTime)") }
if ([string]$NewsRaw.publishedTime -ne '2026-08-19') { $fail36.Add("fixture publishedTime=$($NewsRaw.publishedTime)") }
Add-TestResult 'TEST 36' ($fail36.Count -eq 0) ($fail36 -join "`n")

$fail37 = New-Object System.Collections.Generic.List[string]
$httpReject = Invoke-AdapterFail @('--url', 'http://www.federalreserve.gov/newsevents/pressreleases/monetary20260819a.htm')
if ([int]$httpReject.ExitCode -eq 0) { $fail37.Add('HTTP URL was accepted') }
if ([string]$httpReject.Text -notlike '*HTTPS*') { $fail37.Add('HTTP URL did not report HTTPS FAIL') }
$badUrl = Invoke-AdapterFail @('--url', 'not-a-url')
if ([int]$badUrl.ExitCode -eq 0) { $fail37.Add('invalid URL was accepted') }
if ([string]$badUrl.Text -notlike '*NI_ADAPTER_FAIL*') { $fail37.Add('invalid URL did not FAIL') }
Add-TestResult 'TEST 37' ($fail37.Count -eq 0) ($fail37 -join "`n")

$fail38 = New-Object System.Collections.Generic.List[string]
$nvidia = Invoke-AdapterFail @('--url', 'https://blogs.nvidia.com/blog/nvidia-to-acquire-hugging-face/')
if ([int]$nvidia.ExitCode -eq 0) { $fail38.Add('NVIDIA URL was accepted') }
if ([string]$nvidia.Text -notlike '*REJECT*') { $fail38.Add('NVIDIA URL was not REJECTED') }
$reuters = Invoke-AdapterFail @('--url', 'https://www.reuters.com/markets/fed-minutes/')
if ([int]$reuters.ExitCode -eq 0) { $fail38.Add('Reuters URL was accepted') }
Add-TestResult 'TEST 38' ($fail38.Count -eq 0) ($fail38 -join "`n")

$fail39 = New-Object System.Collections.Generic.List[string]
$missing = Invoke-AdapterFail @('--url', $OfficialUrl, '--html', $MissingTitleHtml)
if ([int]$missing.ExitCode -eq 0) { $fail39.Add('missing title HTML produced a News Object') }
if ([string]$missing.Text -notlike '*missing required field*') { $fail39.Add('missing title did not report VALIDATION FAIL') }
if ([string]$missing.Text -like '*"source": "Federal Reserve Official"*') { $fail39.Add('missing title still emitted a News Object') }
Add-TestResult 'TEST 39' ($fail39.Count -eq 0) ($fail39 -join "`n")

$fail40 = New-Object System.Collections.Generic.List[string]
foreach ($src in @($AdapterSrc, $EvalSrc)) {
  if ($src -like '*/api/queue*') { $fail40.Add('source references POST /api/queue') }
  if ($src -like '*/api/research*') { $fail40.Add('source references POST /api/research') }
  if ($src -like '*research-queue.json*') { $fail40.Add('source writes or loads research-queue.json') }
  if ($src -like '*card.json*') { $fail40.Add('source writes Research Card files') }
}
if ($AdapterSrc -like '*morning-brief.json*') { $fail40.Add('adapter references morning-brief.json') }
if ($AdapterSrc -like '*source-registry.py*' -or $AdapterSrc -like '*adapter-base.py*') {
  $fail40.Add('adapter introduced a source registry / adapter framework')
}
Add-TestResult 'TEST 40' ($fail40.Count -eq 0) ($fail40 -join "`n")

$guardOk = Test-ProtectedHashes
Add-TestResult 'TEST 41' $guardOk $(if ($guardOk) { '' } else { 'protected production, Sprint 001/002, Handbook, SPEC, or NVIDIA adapter files were modified' })
Add-TestResult 'PRODUCTION_FILE_GUARD' $guardOk $(if ($guardOk) { '' } else { 'protected production, Sprint 001/002, Handbook, SPEC, or NVIDIA adapter files were modified' })

Write-Output ''
Write-Output '=== LIVE SOURCE TEST ==='
$liveOk = $false
$liveDetails = ''
try {
  $liveRun = Invoke-Adapter @('--url', $OfficialUrl)
  $live = $liveRun.News
  $liveEval = Invoke-EvalJson $liveRun.Raw
  $liveFail = New-Object System.Collections.Generic.List[string]
  if ($live.source -ne 'Federal Reserve Official') { $liveFail.Add("source=$($live.source)") }
  if ([string]$live.title -notlike '*Minutes of the Federal Open Market Committee*') { $liveFail.Add("title=$($live.title)") }
  if ([string]$live.publishedTime -ne '2026-08-19') { $liveFail.Add("publishedTime=$($live.publishedTime)") }
  if ([string]$live.url -ne $OfficialUrl) { $liveFail.Add("url=$($live.url)") }
  if ([string]$live.summary -notlike '*Federal Open Market Committee*') { $liveFail.Add('live summary missing FOMC') }
  if ($liveEval.event.eventType -ne 'Policy') { $liveFail.Add("live eventType=$($liveEval.event.eventType)") }
  $liveOk = ($liveFail.Count -eq 0)
  $liveDetails = if ($liveOk) {
    "source=$($live.source); title=$($live.title); publishedTime=$($live.publishedTime); eventType=$($liveEval.event.eventType); importance=$($liveEval.importance); relevance=$($liveEval.relevance); candidate=$($liveEval.researchCandidate.eligible)"
  } else {
    ($liveFail -join "`n")
  }
} catch {
  $liveDetails = [string]$_
}
Add-TestResult 'LIVE_SOURCE_TEST' $liveOk $liveDetails

$missingUrl = Invoke-AdapterFail @('--url', 'https://www.federalreserve.gov/newsevents/pressreleases/p2-003-does-not-exist.htm')
$missingUrlOk = ([int]$missingUrl.ExitCode -ne 0)
Add-TestResult 'LIVE_INVALID_URL' $missingUrlOk $(if ($missingUrlOk) { 'non-existent Federal Reserve URL FAIL' } else { 'non-existent Federal Reserve URL was accepted' })

$failed = @($script:Results | Where-Object { $_.Id -notlike 'LIVE_*' -and $_.Status -ne 'PASS' })
Write-Output ''
Write-Output '=== P2-003 SUMMARY ==='
foreach ($row in $script:Results) {
  Write-Output ("{0}: {1}" -f $row.Id, $row.Status)
  if ($row.Status -ne 'PASS' -and $row.Details) { Write-Output $row.Details }
}
if ($failed.Count -gt 0) { exit 1 }
exit 0
