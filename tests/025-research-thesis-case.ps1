$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$env:PYTHONIOENCODING = 'utf-8'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$FixturePath = Join-Path $PSScriptRoot 'fixtures\025-research-thesis-case.json'
$ProdCasesPath = Join-Path $RepoRoot 'data\investment-cases.json'
$ProdQueuePath = Join-Path $RepoRoot 'data\research-queue.json'
$ProdBriefPath = Join-Path $RepoRoot 'data\morning-brief.json'
$LatestPath = Join-Path $RepoRoot 'data\morning-brief\latest.json'
$ProdIndexPath = Join-Path $RepoRoot 'data\knowledge-index.json'
$ServePath = Join-Path $RepoRoot 'serve.ps1'
$WorkflowPath = Join-Path $RepoRoot 'js\workflow-engine.js'
$DataEnginePath = Join-Path $RepoRoot 'js\data-engine.js'
$ThesesDir = Join-Path $RepoRoot 'data\theses'
$GlassCardPath = Join-Path $RepoRoot 'research\glass-bridge\card.json'
$HbmCardPath = Join-Path $RepoRoot 'research\hbm\card.json'

if (-not (Test-Path $FixturePath)) { throw "Missing fixture: $FixturePath" }

$Utf8 = New-Object System.Text.UTF8Encoding $false
$ProdHashBefore = @{
  cases = (Get-FileHash -Path $ProdCasesPath -Algorithm SHA256).Hash
  queue = (Get-FileHash -Path $ProdQueuePath -Algorithm SHA256).Hash
  brief = (Get-FileHash -Path $ProdBriefPath -Algorithm SHA256).Hash
  latest = (Get-FileHash -Path $LatestPath -Algorithm SHA256).Hash
  index = (Get-FileHash -Path $ProdIndexPath -Algorithm SHA256).Hash
  cpo = (Get-FileHash -Path (Join-Path $ThesesDir 'cpo-glass-bridge.json') -Algorithm SHA256).Hash
  dram = (Get-FileHash -Path (Join-Path $ThesesDir 'ai-dram.json') -Algorithm SHA256).Hash
  glass = (Get-FileHash -Path $GlassCardPath -Algorithm SHA256).Hash
  hbm = (Get-FileHash -Path $HbmCardPath -Algorithm SHA256).Hash
}

$Contract = [System.IO.File]::ReadAllText($FixturePath, $Utf8) | ConvertFrom-Json
$script:Results = New-Object System.Collections.Generic.List[object]
$script:TempRoot = Join-Path $env:TEMP ('InvestorTwin-025-' + [guid]::NewGuid().ToString('N'))
$script:TempCasesPath = $null
$script:TestPort = $null
$script:ServerProc = $null

function Add-TestResult($id, $passed, $details) {
  $status = if ($passed) { 'PASS' } else { 'FAIL' }
  $script:Results.Add([PSCustomObject]@{ Id = $id; Status = $status; Details = $details })
  Write-Output ("{0}: {1}" -f $id, $status)
  if ($details) { Write-Output $details }
}

function Read-JsonFile($path) {
  return ([System.IO.File]::ReadAllText($path, $Utf8) | ConvertFrom-Json)
}

function Write-JsonFile($path, $obj) {
  [System.IO.File]::WriteAllText($path, ($obj | ConvertTo-Json -Depth 20), $Utf8)
}

function New-ResearchSeed($researchId, $conclusion) {
  $dir = Join-Path $script:TempRoot ("research\" + $researchId)
  New-Item -ItemType Directory -Path $dir -Force | Out-Null
  Write-JsonFile (Join-Path $dir 'card.json') ([ordered]@{
    id = $researchId
    title = $researchId
    summary = '025 research seed'
    investmentThesis = '025 card working thesis text'
    questions = @('Is the chain wired?')
    reason = 'Manual'
    tags = @()
    related = @()
    status = 'researching'
    updated = '2026-08-23'
    researchConclusion = @{
      conclusion = $conclusion
      status = 'uncertain'
      asOf = '2026-08-23'
    }
  })
  Write-JsonFile (Join-Path $dir 'sources.json') @(@{
    title = '025 official source'
    url = 'https://example.test/025'
  })
  [System.IO.File]::WriteAllText((Join-Path $dir 'notes.json'), '[]', $Utf8)
  [System.IO.File]::WriteAllText((Join-Path $dir 'timeline.json'), '[]', $Utf8)
}

function New-MinimalCase($id, $researchId, $thesisId, $includeThesisIdProperty) {
  $case = [ordered]@{
    id = $id
    title = "$id fixture"
    status = 'draft'
    company = @{
      name = '025 Co'
      ticker = '025T'
      exchange = $null
      currency = $null
    }
    origin = @{
      source = 'Manual'
      createdAt = '2026-08-23'
      updatedAt = '2026-08-23'
    }
    researchIds = @($researchId)
    thesis = @{
      thesis = [string]$Contract.legacyThesisText
      growthDrivers = @()
      competitiveAdvantage = ''
      earningsTranslation = ''
      duration = ''
      supportingEvidence = @()
      counterEvidence = @()
      toBeVerified = @()
      killCriteria = @()
      status = 'forming'
    }
    valuationProfile = @{
      companyType = $null
      primaryMethod = $null
      secondaryMethod = $null
      crossCheckMethod = $null
      userConfirmed = $false
    }
    valuation = @{
      bear = $null
      base = $null
      bull = $null
      marginOfSafety = $null
      buyUnder = $null
      currentPrice = $null
      currentDiscount = $null
    }
    decision = $null
    decisionHistory = @()
    positionPlaybook = $null
    monitoring = $null
  }
  if ($includeThesisIdProperty) {
    $case['thesisId'] = $thesisId
  }
  return $case
}

function Get-CaseFromStore($id) {
  $store = Read-JsonFile $script:TempCasesPath
  return @($store.cases | Where-Object { $_.id -eq $id } | Select-Object -First 1)
}

function Write-TempCases($cases) {
  $store = @{
    schemaVersion = '1.0'
    updated = '2026-08-23'
    cases = @($cases)
  }
  [System.IO.File]::WriteAllText($script:TempCasesPath, ($store | ConvertTo-Json -Depth 20 -Compress), $Utf8)
}

function Invoke-Post($path, $payload) {
  $json = if ($payload -is [string]) { $payload } else { $payload | ConvertTo-Json -Depth 20 -Compress }
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

function Invoke-Get($path) {
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
  New-Item -ItemType Directory -Path (Join-Path $script:TempRoot 'data\theses') | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $script:TempRoot 'scripts') | Out-Null
  $script:TempCasesPath = Join-Path $script:TempRoot 'data\investment-cases.json'
  Copy-Item (Join-Path $RepoRoot 'data\version.json') (Join-Path $script:TempRoot 'data\version.json') -ErrorAction SilentlyContinue
  Copy-Item (Join-Path $RepoRoot 'scripts\generate-knowledge-index.ps1') (Join-Path $script:TempRoot 'scripts\generate-knowledge-index.ps1')
  Copy-Item (Join-Path $ThesesDir '*') (Join-Path $script:TempRoot 'data\theses') -Force
  New-PatchedServeScript $ServePath (Join-Path $script:TempRoot 'serve.ps1')
  Write-TempCases @()
  New-ResearchSeed $Contract.createResearchId '025 create-path research conclusion'
  New-ResearchSeed $Contract.linkResearchId '025 link-path research conclusion'
  foreach ($port in 18827, 18828, 18829) {
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
  $errText = ''
  $errLog = Join-Path $script:TempRoot 'serve.err.log'
  if (Test-Path $errLog) { $errText = [System.IO.File]::ReadAllText($errLog) }
  throw ("Temp serve.ps1 failed to start. $errText")
}

function Stop-TempServer {
  if ($script:ServerProc -and -not $script:ServerProc.HasExited) {
    Stop-Process -Id $script:ServerProc.Id -Force -ErrorAction SilentlyContinue
  }
}

try {
  $workflowSrc = [System.IO.File]::ReadAllText($WorkflowPath, $Utf8)
  $dataEngineSrc = [System.IO.File]::ReadAllText($DataEnginePath, $Utf8)
  $serveSrc = [System.IO.File]::ReadAllText($ServePath, $Utf8)
  $prodCases = Read-JsonFile $ProdCasesPath
  $prodCase = @($prodCases.cases | Where-Object { $_.id -eq '3363-glass-bridge' } | Select-Object -First 1)
  $prodThesis = Read-JsonFile (Join-Path $ThesesDir 'cpo-glass-bridge.json')
  $prodGlass = Read-JsonFile $GlassCardPath
  $prodHbm = Read-JsonFile $HbmCardPath

  Start-TempServer

  $cpoBefore = Read-JsonFile (Join-Path $script:TempRoot 'data\theses\cpo-glass-bridge.json')
  $cpoStatusBefore = [string]$cpoBefore.status

  $fail1 = New-Object System.Collections.Generic.List[string]
  if ($workflowSrc -notlike '*data-create-thesis*') { $fail1.Add('UI missing 建立 Thesis') }
  if ($workflowSrc -notlike '*data-link-thesis*') { $fail1.Add('UI missing 連結既有 Thesis') }
  if ($workflowSrc -notlike '*createThesisFromResearch*') { $fail1.Add('missing createThesisFromResearch') }
  if ($workflowSrc -notlike '*linkResearchThesis*') { $fail1.Add('missing linkResearchThesis') }
  $list = Invoke-Get '/api/theses'
  if ([int]$list.StatusCode -ne 200) {
    $fail1.Add("GET /api/theses HTTP $($list.StatusCode)")
  } else {
    $listed = $list.Body | ConvertFrom-Json
    $ids = @($listed.items | ForEach-Object { [string]$_.thesisId })
    if ($ids -notcontains $Contract.existingThesisId) { $fail1.Add('GET /api/theses missing cpo-glass-bridge') }
  }
  $create = Invoke-Post '/api/theses' @{
    thesisId = $Contract.newThesisId
    title = '025 Test Thesis'
    thesis = '025 created thesis text from research conclusion'
    researchId = $Contract.createResearchId
    status = $Contract.confirmedAttemptStatus
  }
  if ([int]$create.StatusCode -ne 200) {
    $fail1.Add(("create thesis HTTP {0}: {1}" -f $create.StatusCode, $create.Body))
  } else {
    $createdBody = $create.Body | ConvertFrom-Json
    if ($createdBody.status -ne 'under_review') { $fail1.Add("create status=$($createdBody.status)") }
  }
  $link = Invoke-Post ("/api/research/" + $Contract.linkResearchId) @{ thesisId = $Contract.existingThesisId }
  if ([int]$link.StatusCode -ne 200) {
    $fail1.Add(("link thesis HTTP {0}: {1}" -f $link.StatusCode, $link.Body))
  }
  Add-TestResult 'TEST 1' ($fail1.Count -eq 0) ($fail1 -join "`n")

  $fail2 = New-Object System.Collections.Generic.List[string]
  $createdCardPath = Join-Path $script:TempRoot ("research\" + $Contract.createResearchId + "\card.json")
  $linkedCardPath = Join-Path $script:TempRoot ("research\" + $Contract.linkResearchId + "\card.json")
  $createdCard = Read-JsonFile $createdCardPath
  $linkedCard = Read-JsonFile $linkedCardPath
  if ($createdCard.thesisId -ne $Contract.newThesisId) { $fail2.Add("create card thesisId=$($createdCard.thesisId)") }
  if ($linkedCard.thesisId -ne $Contract.existingThesisId) { $fail2.Add("link card thesisId=$($linkedCard.thesisId)") }
  $createdHttp = Invoke-Get ("/research/" + $Contract.createResearchId + "/card.json")
  $createdHttpCard = $createdHttp.Body | ConvertFrom-Json
  if ($createdHttpCard.thesisId -ne $Contract.newThesisId) { $fail2.Add('HTTP card.json did not persist thesisId') }
  if ($prodGlass.thesisId -ne 'cpo-glass-bridge') { $fail2.Add('production glass-bridge missing thesisId') }
  if ($prodHbm.thesisId -ne 'ai-dram') { $fail2.Add('production hbm missing thesisId') }
  Add-TestResult 'TEST 2' ($fail2.Count -eq 0) ($fail2 -join "`n")

  $fail3 = New-Object System.Collections.Generic.List[string]
  $caseCreate = Invoke-Post '/api/cases' @{ case = (New-MinimalCase $Contract.caseId $Contract.createResearchId $null $true) }
  if ([int]$caseCreate.StatusCode -ne 200) {
    $fail3.Add(("create case HTTP {0}: {1}" -f $caseCreate.StatusCode, $caseCreate.Body))
  }
  $beforeLink = Get-CaseFromStore $Contract.caseId
  $caseLink = Invoke-Post '/api/cases' @{ id = $Contract.caseId; thesisId = $Contract.newThesisId }
  if ([int]$caseLink.StatusCode -ne 200) {
    $fail3.Add(("link case HTTP {0}: {1}" -f $caseLink.StatusCode, $caseLink.Body))
  }
  $afterLink = Get-CaseFromStore $Contract.caseId
  $layer = Read-JsonFile (Join-Path $script:TempRoot ("data\theses\" + $Contract.newThesisId + ".json"))
  if (-not $afterLink) {
    $fail3.Add('linked Case missing')
  } else {
    if ($afterLink.thesisId -ne $Contract.newThesisId) { $fail3.Add("case.thesisId=$($afterLink.thesisId)") }
    if ($afterLink.thesis.thesis -ne $Contract.legacyThesisText) { $fail3.Add('Case.thesis was overwritten with Thesis Layer text') }
    if ($beforeLink -and $afterLink.decision -ne $beforeLink.decision) { $fail3.Add('linking Thesis changed Decision') }
  }
  if (-not $layer -or $layer.thesis -eq $Contract.legacyThesisText) { $fail3.Add('Thesis Layer file was not the Case display source') }
  if ($layer.thesis -notlike '*025 created thesis*') { $fail3.Add('Thesis file missing created thesis text') }
  if ($workflowSrc -notlike '*data/theses/*') { $fail3.Add('Case UI does not load data/theses/{id}.json') }
  if ($workflowSrc -notlike '*Case working notes*') { $fail3.Add('Case UI missing Case working notes label') }
  if (-not $prodCase) { $fail3.Add('production 3363-glass-bridge missing') }
  elseif ($prodCase.thesisId -ne 'cpo-glass-bridge') { $fail3.Add("production case thesisId=$($prodCase.thesisId)") }
  elseif ($prodCase.thesis.thesis -eq $prodThesis.thesis) { $fail3.Add('production Case nested thesis already equals Thesis Layer; display must stay separate') }
  Add-TestResult 'TEST 3' ($fail3.Count -eq 0) ($fail3 -join "`n")

  $fail4 = New-Object System.Collections.Generic.List[string]
  $dec1 = Invoke-Post '/api/cases' @{ id = $Contract.caseId; decision = $Contract.decision }
  $dec2 = Invoke-Post '/api/cases' @{ id = $Contract.caseId; decision = $Contract.decisionUpdate }
  $pb = Invoke-Post '/api/cases' @{ id = $Contract.caseId; positionPlaybook = $Contract.positionPlaybook }
  $afterDec = Get-CaseFromStore $Contract.caseId
  if ([int]$dec1.StatusCode -ne 200) { $fail4.Add(("decision create HTTP {0}: {1}" -f $dec1.StatusCode, $dec1.Body)) }
  if ([int]$dec2.StatusCode -ne 200) { $fail4.Add(("decision update HTTP {0}: {1}" -f $dec2.StatusCode, $dec2.Body)) }
  if ([int]$pb.StatusCode -ne 200) { $fail4.Add(("playbook HTTP {0}: {1}" -f $pb.StatusCode, $pb.Body)) }
  if (-not $afterDec) {
    $fail4.Add('Decision Case missing')
  } else {
    if ($afterDec.decision.stance -ne $Contract.decisionUpdate.stance) { $fail4.Add("current stance=$($afterDec.decision.stance)") }
    $history = @($afterDec.decisionHistory)
    if ($history.Count -lt 1) { $fail4.Add('decisionHistory empty after update') }
    elseif ($history[0].stance -ne $Contract.decision.stance) { $fail4.Add("history stance=$($history[0].stance)") }
    $basedOnNames = @($afterDec.decision.basedOn.PSObject.Properties.Name)
    foreach ($need in @('researchIds', 'supportingCount', 'counterCount', 'thesisStatus')) {
      if ($basedOnNames -notcontains $need) { $fail4.Add("basedOn missing $need") }
    }
    if ($basedOnNames -contains 'thesisId') { $fail4.Add('Decision schema gained thesisId') }
    if ($afterDec.positionPlaybook.targetPosition -ne $Contract.positionPlaybook.targetPosition) {
      $fail4.Add('playbook.targetPosition changed')
    }
  }
  if ($workflowSrc -notlike '*saveCaseDecision*') { $fail4.Add('Decision save API missing') }
  if ($workflowSrc -match 'createThesisFromResearch[\s\S]{0,400}saveCaseDecision') {
    $fail4.Add('creating Thesis also saves Decision')
  }
  Add-TestResult 'TEST 4' ($fail4.Count -eq 0) ($fail4 -join "`n")

  $fail5 = New-Object System.Collections.Generic.List[string]
  if ($workflowSrc -notlike '*integrityGateView*') { $fail5.Add('missing integrityGateView') }
  if ($workflowSrc -notlike '*Ready for Thesis Review*') { $fail5.Add('missing Ready for Thesis Review') }
  if ($workflowSrc -notlike '*data-integrity-gate*') { $fail5.Add('Integrity Gate is not rendered') }
  $gateFn = [regex]::Match($workflowSrc, 'integrityGateView\(card, sources, thesis\) \{[\s\S]*?\n  \},')
  if (-not $gateFn.Success) {
    $fail5.Add('could not read integrityGateView')
  } else {
    if ($gateFn.Value -like '*fetch(*') { $fail5.Add('Integrity Gate performs a write/fetch') }
    if ($gateFn.Value -like '*status*confirmed*') { $fail5.Add('Integrity Gate mentions confirmed status write') }
  }
  $createdCard2 = Read-JsonFile $createdCardPath
  $createdThesis = Read-JsonFile (Join-Path $script:TempRoot ("data\theses\" + $Contract.newThesisId + ".json"))
  if (-not $createdCard2.researchConclusion.conclusion) { $fail5.Add('card missing researchConclusion') }
  if ($createdCard2.thesisId -ne $Contract.newThesisId) { $fail5.Add('gate cannot see thesisId on card') }
  if ($createdThesis.status -ne 'under_review') { $fail5.Add('gate path changed Thesis.status') }
  Add-TestResult 'TEST 5' ($fail5.Count -eq 0) ($fail5 -join "`n")

  $fail6 = New-Object System.Collections.Generic.List[string]
  $chainCard = Read-JsonFile $createdCardPath
  $chainThesis = Read-JsonFile (Join-Path $script:TempRoot ("data\theses\" + $Contract.newThesisId + ".json"))
  $chainCase = Get-CaseFromStore $Contract.caseId
  $linkedIds = @($chainThesis.linkedResearch | ForEach-Object { [string]$_.researchId })
  if ($chainCard.thesisId -ne $Contract.newThesisId) { $fail6.Add('chain break: Research Card.thesisId') }
  if (-not $chainCard.researchConclusion.conclusion) { $fail6.Add('chain break: Research Conclusion') }
  if ($linkedIds -notcontains $Contract.createResearchId) { $fail6.Add('chain break: Thesis.linkedResearch') }
  if (-not $chainCase -or $chainCase.thesisId -ne $Contract.newThesisId) { $fail6.Add('chain break: Case.thesisId') }
  if (-not $chainCase.decision -or $chainCase.decision.stance -ne $Contract.decisionUpdate.stance) { $fail6.Add('chain break: Decision') }
  foreach ($trace in @('research-conclusion', 'thesis', 'case', 'decision')) {
    if ($workflowSrc -notlike ("*data-trace=`"$trace`"*") -and $workflowSrc -notlike ("*data-trace='$trace'*")) {
      $fail6.Add("UI missing data-trace $trace")
    }
  }
  if ($dataEngineSrc -notlike '*findCasesByThesisId*') { $fail6.Add('missing findCasesByThesisId') }
  Add-TestResult 'TEST 6' ($fail6.Count -eq 0) ($fail6 -join "`n")

  $fail7 = New-Object System.Collections.Generic.List[string]
  $cpoAfter = Read-JsonFile (Join-Path $script:TempRoot 'data\theses\cpo-glass-bridge.json')
  if ([string]$cpoAfter.status -ne $cpoStatusBefore) {
    $fail7.Add("link changed cpo-glass-bridge status from $cpoStatusBefore to $($cpoAfter.status)")
  }
  if ($createdThesis.status -eq 'confirmed') { $fail7.Add('create honored client status=confirmed') }
  if ($serveSrc -notlike "*status = 'under_review'*") { $fail7.Add('New-ThesisRecord does not force under_review') }
  if ($serveSrc -notlike '*Client-supplied status is ignored*') { $fail7.Add('POST /api/theses does not ignore client status') }
  if ($workflowSrc -notmatch 'thesisId:\s*null') { $fail7.Add('createCaseFromResearch no longer keeps thesisId null') }
  if ($workflowSrc -match 'JSON\.stringify\(\{[^}]*status') {
    $fail7.Add('createThesisFromResearch sends status')
  }
  foreach ($fnName in @('linkResearchThesis', 'createThesisFromResearch', 'persistCaseThesisId', 'integrityGateView')) {
    $fn = [regex]::Match($workflowSrc, ($fnName + '\([^\)]*\) \{[\s\S]*?\n  \},'))
    if ($fn.Success) {
      if ($fn.Value -like '*saveCaseDecision*') { $fail7.Add("$fnName saves Decision") }
      if ($fn.Value -like '*saveCasePositionPlaybook*') { $fail7.Add("$fnName saves Position Playbook") }
    }
  }
  Add-TestResult 'TEST 7' ($fail7.Count -eq 0) ($fail7 -join "`n")
}
catch {
  $details = $_.Exception.Message
  $errLog = Join-Path $script:TempRoot 'serve.err.log'
  $outLog = Join-Path $script:TempRoot 'serve.out.log'
  if (Test-Path $errLog) { $details += "`nERR: " + [System.IO.File]::ReadAllText($errLog) }
  if (Test-Path $outLog) { $details += "`nOUT: " + [System.IO.File]::ReadAllText($outLog) }
  Add-TestResult 'SETUP' $false $details
}
finally {
  Stop-TempServer
}

$afterCases = (Get-FileHash -Path $ProdCasesPath -Algorithm SHA256).Hash
$afterQueue = (Get-FileHash -Path $ProdQueuePath -Algorithm SHA256).Hash
$afterBrief = (Get-FileHash -Path $ProdBriefPath -Algorithm SHA256).Hash
$afterLatest = (Get-FileHash -Path $LatestPath -Algorithm SHA256).Hash
$afterIndex = (Get-FileHash -Path $ProdIndexPath -Algorithm SHA256).Hash
$afterCpo = (Get-FileHash -Path (Join-Path $ThesesDir 'cpo-glass-bridge.json') -Algorithm SHA256).Hash
$afterDram = (Get-FileHash -Path (Join-Path $ThesesDir 'ai-dram.json') -Algorithm SHA256).Hash
$afterGlass = (Get-FileHash -Path $GlassCardPath -Algorithm SHA256).Hash
$afterHbm = (Get-FileHash -Path $HbmCardPath -Algorithm SHA256).Hash
$guardOk = ($afterCases -eq $ProdHashBefore.cases) -and ($afterQueue -eq $ProdHashBefore.queue) -and ($afterBrief -eq $ProdHashBefore.brief) -and ($afterLatest -eq $ProdHashBefore.latest) -and ($afterIndex -eq $ProdHashBefore.index) -and ($afterCpo -eq $ProdHashBefore.cpo) -and ($afterDram -eq $ProdHashBefore.dram) -and ($afterGlass -eq $ProdHashBefore.glass) -and ($afterHbm -eq $ProdHashBefore.hbm)
Add-TestResult 'PRODUCTION_FILE_GUARD' $guardOk $(if ($guardOk) { '' } else { 'production data files were modified by tests' })

if (Test-Path $script:TempRoot) {
  Remove-Item -Recurse -Force $script:TempRoot -ErrorAction SilentlyContinue
}

$failed = @($script:Results | Where-Object { $_.Status -ne 'PASS' })
Write-Output ''
Write-Output '=== 025 SUMMARY ==='
foreach ($row in $script:Results) {
  Write-Output ("{0}: {1}" -f $row.Id, $row.Status)
  if ($row.Status -ne 'PASS' -and $row.Details) { Write-Output $row.Details }
}
if ($failed.Count -gt 0) { exit 1 }
exit 0
