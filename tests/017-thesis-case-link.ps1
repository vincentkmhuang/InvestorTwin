$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$env:PYTHONIOENCODING = 'utf-8'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$FixturePath = Join-Path $PSScriptRoot 'fixtures\017-thesis-case-link.json'
$ProdCasesPath = Join-Path $RepoRoot 'data\investment-cases.json'
$ProdQueuePath = Join-Path $RepoRoot 'data\research-queue.json'
$ProdBriefPath = Join-Path $RepoRoot 'data\morning-brief.json'
$LatestPath = Join-Path $RepoRoot 'data\morning-brief\latest.json'
$ProdIndexPath = Join-Path $RepoRoot 'data\knowledge-index.json'
$ServePath = Join-Path $RepoRoot 'serve.ps1'
$WorkflowPath = Join-Path $RepoRoot 'js\workflow-engine.js'
$ThesesDir = Join-Path $RepoRoot 'data\theses'

if (-not (Test-Path $FixturePath)) { throw "Missing fixture: $FixturePath" }

$Utf8 = New-Object System.Text.UTF8Encoding $false
$ProdHashBefore = @{
  cases = (Get-FileHash -Path $ProdCasesPath -Algorithm SHA256).Hash
  queue = (Get-FileHash -Path $ProdQueuePath -Algorithm SHA256).Hash
  brief = (Get-FileHash -Path $ProdBriefPath -Algorithm SHA256).Hash
  latest = (Get-FileHash -Path $LatestPath -Algorithm SHA256).Hash
  index = (Get-FileHash -Path $ProdIndexPath -Algorithm SHA256).Hash
}

$Contract = [System.IO.File]::ReadAllText($FixturePath, $Utf8) | ConvertFrom-Json
$script:Results = New-Object System.Collections.Generic.List[object]
$script:TempRoot = Join-Path $env:TEMP ('InvestorTwin-017-' + [guid]::NewGuid().ToString('N'))
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

function New-MinimalCase($id, $thesisId, $includeThesisIdProperty) {
  $case = [ordered]@{
    id = $id
    title = "$id fixture"
    status = 'draft'
    company = @{
      name = '017 Co'
      ticker = '017T'
      exchange = $null
      currency = $null
    }
    origin = @{
      source = 'Manual'
      createdAt = '2026-08-23'
      updatedAt = '2026-08-23'
    }
    researchIds = @('glass-bridge')
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
  $list = @($cases)
  if ($list.Count -eq 0) {
    [System.IO.File]::WriteAllText($script:TempCasesPath, '{"schemaVersion":"1.0","updated":"2026-08-23","cases":[]}', $Utf8)
    return
  }
  $store = @{
    schemaVersion = '1.0'
    updated = '2026-08-23'
    cases = $list
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

function Invoke-GetCasesHttp {
  $uri = "http://localhost:$($script:TestPort)/data/investment-cases.json?t=017"
  $resp = Invoke-WebRequest -Uri $uri -UseBasicParsing
  return ($resp.Content | ConvertFrom-Json)
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
  foreach ($port in 18817, 18818, 18819) {
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

function Invoke-SiblingTest($relPath) {
  $path = Join-Path $PSScriptRoot $relPath
  $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $path 2>&1 | Out-String
  return @{ ExitCode = $LASTEXITCODE; Text = $out }
}

function Test-HasProp($obj, $name) {
  if ($null -eq $obj) { return $false }
  return [bool]$obj.PSObject.Properties[$name]
}

try {
  $prodCases = Read-JsonFile $ProdCasesPath
  $prodCase = @($prodCases.cases | Where-Object { $_.id -eq '3363-glass-bridge' } | Select-Object -First 1)
  $prodThesisPath = Join-Path $ThesesDir ($Contract.validThesisId + '.json')
  $prodThesis = if (Test-Path $prodThesisPath) { Read-JsonFile $prodThesisPath } else { $null }
  $workflowSrc = [System.IO.File]::ReadAllText($WorkflowPath, $Utf8)

  Start-TempServer

  $linked = New-MinimalCase $Contract.linkedCaseId $Contract.validThesisId $true
  $createLinked = Invoke-Post '/api/cases' @{ case = $linked }
  $created = Get-CaseFromStore $Contract.linkedCaseId
  $fail1 = New-Object System.Collections.Generic.List[string]
  if ([int]$createLinked.StatusCode -ne 200) {
    $fail1.Add(("create HTTP {0}: {1}" -f $createLinked.StatusCode, $createLinked.Body))
  } else {
    $body = $createLinked.Body | ConvertFrom-Json
    if ($body.created -ne $true) { $fail1.Add('valid thesisId did not create a Case') }
  }
  if (-not $created) {
    $fail1.Add('created Case missing from store')
  } elseif ($created.thesisId -ne $Contract.validThesisId) {
    $fail1.Add("created thesisId=$($created.thesisId)")
  }
  if (-not $prodCase) {
    $fail1.Add('production 3363-glass-bridge missing')
  } elseif ($prodCase.thesisId -ne $Contract.validThesisId) {
    $fail1.Add("production thesisId=$($prodCase.thesisId)")
  }
  if (-not $prodThesis) {
    $fail1.Add("missing data/theses/$($Contract.validThesisId).json")
  } elseif ($prodThesis.thesisId -ne $Contract.validThesisId) {
    $fail1.Add('Thesis file thesisId mismatch')
  }
  if ($workflowSrc -notmatch 'thesisId:\s*null') {
    $fail1.Add('createCaseFromResearch does not preserve thesisId')
  }
  Add-TestResult 'TEST 1' ($fail1.Count -eq 0) ($fail1 -join "`n")

  $fail2 = New-Object System.Collections.Generic.List[string]
  $httpStore = $null
  try { $httpStore = Invoke-GetCasesHttp } catch { $fail2.Add("HTTP reload failed: $($_.Exception.Message)") }
  $httpCase = if ($httpStore) { @($httpStore.cases | Where-Object { $_.id -eq $Contract.linkedCaseId } | Select-Object -First 1) } else { $null }
  if (-not $httpCase) {
    $fail2.Add('HTTP reload missing created Case')
  } elseif ($httpCase.thesisId -ne $Contract.validThesisId) {
    $fail2.Add("HTTP reload thesisId=$($httpCase.thesisId)")
  }
  $mos = Invoke-Post '/api/cases' @{ id = $Contract.linkedCaseId; marginOfSafety = 0.2 }
  if ([int]$mos.StatusCode -ne 200) {
    $fail2.Add(("reload write HTTP {0}: {1}" -f $mos.StatusCode, $mos.Body))
  }
  $afterWrite = Get-CaseFromStore $Contract.linkedCaseId
  $httpAfter = $null
  try { $httpAfter = Invoke-GetCasesHttp } catch { $fail2.Add("second HTTP reload failed: $($_.Exception.Message)") }
  $httpAfterCase = if ($httpAfter) { @($httpAfter.cases | Where-Object { $_.id -eq $Contract.linkedCaseId } | Select-Object -First 1) } else { $null }
  if (-not $afterWrite -or $afterWrite.thesisId -ne $Contract.validThesisId) {
    $fail2.Add("file reload thesisId=$($afterWrite.thesisId)")
  }
  if (-not $httpAfterCase -or $httpAfterCase.thesisId -ne $Contract.validThesisId) {
    $fail2.Add("API JSON reload thesisId=$($httpAfterCase.thesisId)")
  }
  if ($afterWrite -and $afterWrite.thesis.thesis -ne $Contract.legacyThesisText) {
    $fail2.Add('reload copied Thesis content into Case.thesis')
  }
  Add-TestResult 'TEST 2' ($fail2.Count -eq 0) ($fail2 -join "`n")

  $beforeInvalid = Read-JsonFile $script:TempCasesPath
  $invalidCase = New-MinimalCase $Contract.invalidCaseId $Contract.invalidThesisId $true
  $createInvalid = Invoke-Post '/api/cases' @{ case = $invalidCase }
  $fail3 = New-Object System.Collections.Generic.List[string]
  if ([int]$createInvalid.StatusCode -lt 400) {
    $fail3.Add(("missing thesisId was accepted HTTP {0}: {1}" -f $createInvalid.StatusCode, $createInvalid.Body))
  } else {
    $err = $createInvalid.Body | ConvertFrom-Json
    if ($err.error -ne 'invalid_payload') { $fail3.Add("error=$($err.error)") }
  }
  $ghost = Get-CaseFromStore $Contract.invalidCaseId
  if ($ghost) { $fail3.Add('rejected thesisId was still written') }
  $afterInvalid = Read-JsonFile $script:TempCasesPath
  if (@($afterInvalid.cases).Count -ne @($beforeInvalid.cases).Count) {
    $fail3.Add('rejected create changed case count')
  }
  Add-TestResult 'TEST 3' ($fail3.Count -eq 0) ($fail3 -join "`n")

  $nullCase = New-MinimalCase $Contract.nullCaseId $null $true
  $createNull = Invoke-Post '/api/cases' @{ case = $nullCase }
  $storedNull = Get-CaseFromStore $Contract.nullCaseId
  $fail4 = New-Object System.Collections.Generic.List[string]
  if ([int]$createNull.StatusCode -ne 200) {
    $fail4.Add(("null thesisId HTTP {0}: {1}" -f $createNull.StatusCode, $createNull.Body))
  }
  if (-not $storedNull) {
    $fail4.Add('null thesisId Case was not created')
  } elseif ($null -ne $storedNull.thesisId -and "$($storedNull.thesisId)" -ne '') {
    $fail4.Add("null thesisId stored as $($storedNull.thesisId)")
  }
  Add-TestResult 'TEST 4' ($fail4.Count -eq 0) ($fail4 -join "`n")

  $legacy = New-MinimalCase $Contract.legacyCaseId $null $false
  Write-TempCases @($legacy)
  $fail5 = New-Object System.Collections.Generic.List[string]
  $legacyHttp = $null
  try { $legacyHttp = Invoke-GetCasesHttp } catch { $fail5.Add("legacy HTTP read failed: $($_.Exception.Message)") }
  $legacyRead = if ($legacyHttp) { @($legacyHttp.cases | Where-Object { $_.id -eq $Contract.legacyCaseId } | Select-Object -First 1) } else { $null }
  if (-not $legacyRead) {
    $fail5.Add('legacy Case without thesisId could not be read')
  } else {
    if ($legacyRead.id -ne $Contract.legacyCaseId) { $fail5.Add('legacy id mismatch') }
    if ($legacyRead.thesis.thesis -ne $Contract.legacyThesisText) { $fail5.Add('legacy Case.thesis was rewritten') }
  }
  $fileLegacy = Get-CaseFromStore $Contract.legacyCaseId
  if (-not $fileLegacy) { $fail5.Add('legacy Case missing from file read') }
  elseif (Test-HasProp $fileLegacy 'thesisId') { $fail5.Add('seeded legacy Case unexpectedly already had thesisId') }
  $legacyMos = Invoke-Post '/api/cases' @{ id = $Contract.legacyCaseId; marginOfSafety = 0.15 }
  if ([int]$legacyMos.StatusCode -ne 200) {
    $fail5.Add(("legacy update HTTP {0}: {1}" -f $legacyMos.StatusCode, $legacyMos.Body))
  } else {
    $legacyAfter = Get-CaseFromStore $Contract.legacyCaseId
    if (-not $legacyAfter) {
      $fail5.Add('legacy Case disappeared after update')
    } elseif ($null -ne $legacyAfter.thesisId -and "$($legacyAfter.thesisId)" -ne '') {
      $fail5.Add("legacy update invented thesisId=$($legacyAfter.thesisId)")
    }
  }
  Add-TestResult 'TEST 5' ($fail5.Count -eq 0) ($fail5 -join "`n")

  Write-TempCases @()
  $dpCase = New-MinimalCase $Contract.linkedCaseId $Contract.validThesisId $true
  $createDp = Invoke-Post '/api/cases' @{ case = $dpCase }
  $dec = Invoke-Post '/api/cases' @{ id = $Contract.linkedCaseId; decision = $Contract.decision }
  $pb = Invoke-Post '/api/cases' @{ id = $Contract.linkedCaseId; positionPlaybook = $Contract.positionPlaybook }
  $afterDp = Get-CaseFromStore $Contract.linkedCaseId
  $fail6 = New-Object System.Collections.Generic.List[string]
  if ([int]$createDp.StatusCode -ne 200) { $fail6.Add(("TEST 6 create HTTP {0}" -f $createDp.StatusCode)) }
  if ([int]$dec.StatusCode -ne 200) { $fail6.Add(("decision HTTP {0}: {1}" -f $dec.StatusCode, $dec.Body)) }
  if ([int]$pb.StatusCode -ne 200) { $fail6.Add(("playbook HTTP {0}: {1}" -f $pb.StatusCode, $pb.Body)) }
  if (-not $afterDp) {
    $fail6.Add('Decision/Playbook Case missing')
  } else {
    if ($afterDp.thesisId -ne $Contract.validThesisId) { $fail6.Add("thesisId lost after Decision/Playbook: $($afterDp.thesisId)") }
    if ($afterDp.decision.stance -ne $Contract.decision.stance) { $fail6.Add("decision.stance=$($afterDp.decision.stance)") }
    if ($afterDp.decision.reason -ne $Contract.decision.reason) { $fail6.Add('decision.reason changed') }
    $basedOnNames = @($afterDp.decision.basedOn.PSObject.Properties.Name)
    foreach ($need in @('researchIds', 'supportingCount', 'counterCount', 'thesisStatus')) {
      if ($basedOnNames -notcontains $need) { $fail6.Add("decision.basedOn missing $need") }
    }
    if ($basedOnNames -contains 'thesisId') { $fail6.Add('Decision schema gained thesisId') }
    if ($afterDp.positionPlaybook.targetPosition -ne $Contract.positionPlaybook.targetPosition) {
      $fail6.Add("playbook.targetPosition=$($afterDp.positionPlaybook.targetPosition)")
    }
    if ($afterDp.positionPlaybook.initialPosition -ne $Contract.positionPlaybook.initialPosition) {
      $fail6.Add("playbook.initialPosition=$($afterDp.positionPlaybook.initialPosition)")
    }
    if ($afterDp.thesis.thesis -ne $Contract.legacyThesisText) {
      $fail6.Add('Decision/Playbook overwrite copied Thesis Layer text')
    }
  }
  Add-TestResult 'TEST 6' ($fail6.Count -eq 0) ($fail6 -join "`n")
}
catch {
  Add-TestResult 'SETUP' $false $_.Exception.Message
}
finally {
  Stop-TempServer
}

$reg013 = Invoke-SiblingTest '013-evidence-layer.ps1'
Add-TestResult 'TEST 7' ($reg013.ExitCode -eq 0) $(if ($reg013.ExitCode -ne 0) { $reg013.Text } else { '' })

$reg012a = Invoke-SiblingTest '012-a-morning-brief.ps1'
Add-TestResult 'TEST 8' ($reg012a.ExitCode -eq 0) $(if ($reg012a.ExitCode -ne 0) { $reg012a.Text } else { '' })

$reg012c = Invoke-SiblingTest '012-c-daily-brief.ps1'
Add-TestResult 'TEST 9' ($reg012c.ExitCode -eq 0) $(if ($reg012c.ExitCode -ne 0) { $reg012c.Text } else { '' })

$reg015 = Invoke-SiblingTest '015-thesis-layer.ps1'
Add-TestResult 'TEST 10' ($reg015.ExitCode -eq 0) $(if ($reg015.ExitCode -ne 0) { $reg015.Text } else { '' })

$afterCases = (Get-FileHash -Path $ProdCasesPath -Algorithm SHA256).Hash
$afterQueue = (Get-FileHash -Path $ProdQueuePath -Algorithm SHA256).Hash
$afterBrief = (Get-FileHash -Path $ProdBriefPath -Algorithm SHA256).Hash
$afterLatest = (Get-FileHash -Path $LatestPath -Algorithm SHA256).Hash
$afterIndex = (Get-FileHash -Path $ProdIndexPath -Algorithm SHA256).Hash
$guardOk = ($afterCases -eq $ProdHashBefore.cases) -and ($afterQueue -eq $ProdHashBefore.queue) -and ($afterBrief -eq $ProdHashBefore.brief) -and ($afterLatest -eq $ProdHashBefore.latest) -and ($afterIndex -eq $ProdHashBefore.index)
Add-TestResult 'PRODUCTION_FILE_GUARD' $guardOk $(if ($guardOk) { '' } else { 'production data files were modified by tests' })

if (Test-Path $script:TempRoot) {
  Remove-Item -Recurse -Force $script:TempRoot -ErrorAction SilentlyContinue
}

$failed = @($script:Results | Where-Object { $_.Status -ne 'PASS' })
Write-Output ''
Write-Output '=== 017 SUMMARY ==='
foreach ($row in $script:Results) {
  Write-Output ("{0}: {1}" -f $row.Id, $row.Status)
  if ($row.Status -ne 'PASS' -and $row.Details) { Write-Output $row.Details }
}
if ($failed.Count -gt 0) { exit 1 }
exit 0
