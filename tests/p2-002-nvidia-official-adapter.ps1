$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$env:PYTHONIOENCODING = 'utf-8'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$OfficialUrl = 'https://blogs.nvidia.com/blog/nvidia-to-acquire-hugging-face/'
$Sprint001Path = Join-Path $PSScriptRoot 'p2-001-news-intelligence-foundation.ps1'
$AdapterPath = Join-Path $RepoRoot 'scripts\nvidia-official-adapter.py'
$EvalPath = Join-Path $RepoRoot 'scripts\evaluate-news-intelligence.py'
$HtmlPath = Join-Path $PSScriptRoot 'fixtures\p2-002-nvidia-hugging-face.html'
$NewsPath = Join-Path $PSScriptRoot 'fixtures\p2-002-news-nvidia-huggingface.json'
$MissingTitleHtml = Join-Path $PSScriptRoot 'fixtures\p2-002-nvidia-missing-title.html'
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

foreach ($path in @($Sprint001Path, $AdapterPath, $EvalPath, $HtmlPath, $NewsPath, $MissingTitleHtml, $SpecPath, $HandbookPath)) {
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
  sprint001 = (Get-FileHash -Path $Sprint001Path -Algorithm SHA256).Hash
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
  $stderrPath = Join-Path $env:TEMP ('p2-002-adapter-fail-' + [guid]::NewGuid().ToString('N') + '.txt')
  $stdoutPath = Join-Path $env:TEMP ('p2-002-adapter-out-' + [guid]::NewGuid().ToString('N') + '.txt')
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
    (Get-FileHash -Path $Sprint001Path -Algorithm SHA256).Hash -eq $ProdHashBefore.sprint001 -and
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

Write-Output '=== P2-001 REGRESSION ==='
$sprint001 = & powershell -NoProfile -File $Sprint001Path
$sprint001Text = ($sprint001 | ForEach-Object { "$_" }) -join "`n"
Write-Output $sprint001Text
$sprint001Ok = ($LASTEXITCODE -eq 0)
Add-TestResult 'TEST 1-20' $sprint001Ok $(if ($sprint001Ok) { 'Sprint 001 TEST 1-20 still PASS' } else { $sprint001Text })

$offlineRun = Invoke-Adapter @('--url', $OfficialUrl, '--html', $HtmlPath)
$offline = $offlineRun.News
$offlineEval = Invoke-EvalJson $offlineRun.Raw
$fixtureEval = Invoke-EvalInput $NewsPath

$fail21 = New-Object System.Collections.Generic.List[string]
if ($offline.source -ne 'NVIDIA Official Blog') { $fail21.Add("source=$($offline.source)") }
if ([string]$offline.title -notlike '*NVIDIA to Acquire Hugging Face*') { $fail21.Add("title=$($offline.title)") }
if ([string]$offline.publishedTime -ne '2026-09-03') { $fail21.Add("publishedTime=$($offline.publishedTime)") }
if ([string]$offline.url -ne $OfficialUrl) { $fail21.Add("url=$($offline.url)") }
if (-not $offline.summary -and -not $offline.content) { $fail21.Add('missing summary/content') }
Add-TestResult 'TEST 21' ($fail21.Count -eq 0) ($fail21 -join "`n")

$fail22 = New-Object System.Collections.Generic.List[string]
foreach ($field in @('source', 'title', 'publishedTime', 'url')) {
  if (-not $offline.$field) { $fail22.Add("News Object missing $field") }
}
if (-not $offline.summary -and -not $offline.content) { $fail22.Add('News Object missing summary/content') }
if ([string]$NewsRaw.source -ne 'NVIDIA Official Blog') { $fail22.Add('offline fixture source is not NVIDIA Official Blog') }
if ([string]$NewsRaw.publishedTime -ne '2026-09-03') { $fail22.Add('offline fixture publishedTime is not 2026-09-03') }
Add-TestResult 'TEST 22' ($fail22.Count -eq 0) ($fail22 -join "`n")

$fail23 = New-Object System.Collections.Generic.List[string]
foreach ($field in @('importance', 'relevance', 'impact', 'researchCandidate', 'candidate')) {
  if ($null -ne $offline.PSObject.Properties[$field]) { $fail23.Add("adapter News Object contains $field") }
  if ($null -ne $NewsRaw.PSObject.Properties[$field]) { $fail23.Add("offline fixture contains $field") }
}
Add-TestResult 'TEST 23' ($fail23.Count -eq 0) ($fail23 -join "`n")

$fail24 = New-Object System.Collections.Generic.List[string]
foreach ($field in @('news', 'event', 'importance', 'relevance', 'relevanceBasis', 'impact', 'researchCandidate')) {
  if ($null -eq $offlineEval.PSObject.Properties[$field]) { $fail24.Add("evaluation missing $field") }
}
Add-TestResult 'TEST 24' ($fail24.Count -eq 0) ($fail24 -join "`n")

$fail25 = New-Object System.Collections.Generic.List[string]
if ([int]$offlineEval.importance -ne 5) { $fail25.Add("adapter evaluation importance=$($offlineEval.importance)") }
if ($offlineEval.relevance -ne 'High') { $fail25.Add("adapter evaluation relevance=$($offlineEval.relevance)") }
if ($offlineEval.researchCandidate.eligible -ne $true) { $fail25.Add('adapter evaluation Candidate is not YES') }
if ([int]$fixtureEval.importance -ne 5) { $fail25.Add("fixture evaluation importance=$($fixtureEval.importance)") }
if ($fixtureEval.relevance -ne 'High') { $fail25.Add("fixture evaluation relevance=$($fixtureEval.relevance)") }
if ($fixtureEval.researchCandidate.eligible -ne $true) { $fail25.Add('fixture evaluation Candidate is not YES') }
Add-TestResult 'TEST 25' ($fail25.Count -eq 0) ($fail25 -join "`n")

$fail26 = New-Object System.Collections.Generic.List[string]
$httpReject = Invoke-AdapterFail @('--url', 'http://blogs.nvidia.com/blog/nvidia-to-acquire-hugging-face/')
if ([int]$httpReject.ExitCode -eq 0) { $fail26.Add('HTTP URL was accepted') }
if ([string]$httpReject.Text -notlike '*HTTPS*') { $fail26.Add('HTTP URL did not report HTTPS FAIL') }
$badUrl = Invoke-AdapterFail @('--url', 'not-a-url')
if ([int]$badUrl.ExitCode -eq 0) { $fail26.Add('invalid URL was accepted') }
if ([string]$badUrl.Text -notlike '*NI_ADAPTER_FAIL*') { $fail26.Add('invalid URL did not FAIL') }
Add-TestResult 'TEST 26' ($fail26.Count -eq 0) ($fail26 -join "`n")

$fail27 = New-Object System.Collections.Generic.List[string]
$reuters = Invoke-AdapterFail @('--url', 'https://www.reuters.com/technology/nvidia-hugging-face/')
if ([int]$reuters.ExitCode -eq 0) { $fail27.Add('Reuters URL was accepted') }
if ([string]$reuters.Text -notlike '*REJECT*') { $fail27.Add('non-NVIDIA source was not REJECTED') }
$yahoo = Invoke-AdapterFail @('--url', 'https://finance.yahoo.com/news/nvidia-hugging-face/')
if ([int]$yahoo.ExitCode -eq 0) { $fail27.Add('Yahoo Finance URL was accepted') }
Add-TestResult 'TEST 27' ($fail27.Count -eq 0) ($fail27 -join "`n")

$fail28 = New-Object System.Collections.Generic.List[string]
$missing = Invoke-AdapterFail @('--url', $OfficialUrl, '--html', $MissingTitleHtml)
if ([int]$missing.ExitCode -eq 0) { $fail28.Add('missing title HTML produced a News Object') }
if ([string]$missing.Text -notlike '*missing required field*') { $fail28.Add('missing title did not report VALIDATION FAIL') }
if ([string]$missing.Text -like '*"source": "NVIDIA Official Blog"*') { $fail28.Add('missing title still emitted a News Object') }
Add-TestResult 'TEST 28' ($fail28.Count -eq 0) ($fail28 -join "`n")

$fail29 = New-Object System.Collections.Generic.List[string]
foreach ($src in @($AdapterSrc, $EvalSrc)) {
  if ($src -like '*/api/queue*') { $fail29.Add('source references POST /api/queue') }
  if ($src -like '*/api/research*') { $fail29.Add('source references POST /api/research') }
  if ($src -like '*research-queue.json*') { $fail29.Add('source writes or loads research-queue.json') }
  if ($src -like '*card.json*') { $fail29.Add('source writes Research Card files') }
}
if ($AdapterSrc -like '*morning-brief.json*') { $fail29.Add('adapter references morning-brief.json') }
Add-TestResult 'TEST 29' ($fail29.Count -eq 0) ($fail29 -join "`n")

$guardOk = Test-ProtectedHashes
Add-TestResult 'TEST 30' $guardOk $(if ($guardOk) { '' } else { 'protected production, Sprint 001, Handbook, or SPEC files were modified' })
Add-TestResult 'PRODUCTION_FILE_GUARD' $guardOk $(if ($guardOk) { '' } else { 'protected production, Sprint 001, Handbook, or SPEC files were modified' })

Write-Output ''
Write-Output '=== LIVE SOURCE TEST ==='
$liveOk = $false
$liveDetails = ''
try {
  $liveRun = Invoke-Adapter @('--url', $OfficialUrl)
  $live = $liveRun.News
  $liveEval = Invoke-EvalJson $liveRun.Raw
  $liveFail = New-Object System.Collections.Generic.List[string]
  if ($live.source -ne 'NVIDIA Official Blog') { $liveFail.Add("source=$($live.source)") }
  if ([string]$live.title -notlike '*NVIDIA to Acquire Hugging Face*') { $liveFail.Add("title=$($live.title)") }
  if ([string]$live.publishedTime -ne '2026-09-03') { $liveFail.Add("publishedTime=$($live.publishedTime)") }
  if ([string]$live.url -ne $OfficialUrl) { $liveFail.Add("url=$($live.url)") }
  if ([string]$live.summary -notlike '*Hugging Face*') { $liveFail.Add('live summary missing Hugging Face') }
  if ([int]$liveEval.importance -ne 5) { $liveFail.Add("live importance=$($liveEval.importance)") }
  if ($liveEval.relevance -ne 'High') { $liveFail.Add("live relevance=$($liveEval.relevance)") }
  if ($liveEval.researchCandidate.eligible -ne $true) { $liveFail.Add('live Candidate is not YES') }
  $liveOk = ($liveFail.Count -eq 0)
  $liveDetails = if ($liveOk) {
    "source=$($live.source); title=$($live.title); publishedTime=$($live.publishedTime); Candidate=YES"
  } else {
    ($liveFail -join "`n")
  }
} catch {
  $liveDetails = [string]$_
}
Add-TestResult 'LIVE_SOURCE_TEST' $liveOk $liveDetails

$missingUrl = Invoke-AdapterFail @('--url', 'https://blogs.nvidia.com/blog/p2-002-does-not-exist-invalid-url/')
$missingUrlOk = ([int]$missingUrl.ExitCode -ne 0)
Add-TestResult 'LIVE_INVALID_URL' $missingUrlOk $(if ($missingUrlOk) { 'non-existent NVIDIA URL FAIL' } else { 'non-existent NVIDIA URL was accepted' })

$failed = @($script:Results | Where-Object { $_.Id -notlike 'LIVE_*' -and $_.Status -ne 'PASS' })
Write-Output ''
Write-Output '=== P2-002 SUMMARY ==='
foreach ($row in $script:Results) {
  Write-Output ("{0}: {1}" -f $row.Id, $row.Status)
  if ($row.Status -ne 'PASS' -and $row.Details) { Write-Output $row.Details }
}
if ($failed.Count -gt 0) { exit 1 }
exit 0
