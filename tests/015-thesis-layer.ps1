$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$env:PYTHONIOENCODING = 'utf-8'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$SchemaPath = Join-Path $RepoRoot 'data\theses\schema.json'
$FixturePath = Join-Path $PSScriptRoot 'fixtures\015-thesis-layer.json'
$ThesesDir = Join-Path $RepoRoot 'data\theses'
$ProdBriefPath = Join-Path $RepoRoot 'data\morning-brief.json'
$LatestPath = Join-Path $RepoRoot 'data\morning-brief\latest.json'
$ServePath = Join-Path $RepoRoot 'serve.ps1'
$QueuePath = Join-Path $RepoRoot 'data\research-queue.json'
$CasesPath = Join-Path $RepoRoot 'data\investment-cases.json'
$EvidenceSchema = Join-Path $RepoRoot 'data\evidence\schema.json'
$CollectPy = Join-Path $RepoRoot 'scripts\collect-evidence.py'
$CollectPs1 = Join-Path $RepoRoot 'scripts\collect-evidence.ps1'

if (-not (Test-Path $SchemaPath)) { throw "Missing schema: $SchemaPath" }
if (-not (Test-Path $FixturePath)) { throw "Missing fixture: $FixturePath" }

$Utf8 = New-Object System.Text.UTF8Encoding $false
$ProdHashBefore = @{
  brief = (Get-FileHash -Path $ProdBriefPath -Algorithm SHA256).Hash
  latest = (Get-FileHash -Path $LatestPath -Algorithm SHA256).Hash
  serve = (Get-FileHash -Path $ServePath -Algorithm SHA256).Hash
  queue = (Get-FileHash -Path $QueuePath -Algorithm SHA256).Hash
  cases = (Get-FileHash -Path $CasesPath -Algorithm SHA256).Hash
  evidenceSchema = (Get-FileHash -Path $EvidenceSchema -Algorithm SHA256).Hash
  collectPy = (Get-FileHash -Path $CollectPy -Algorithm SHA256).Hash
  collectPs1 = (Get-FileHash -Path $CollectPs1 -Algorithm SHA256).Hash
}

$script:Results = New-Object System.Collections.Generic.List[object]

function Add-TestResult($id, $passed, $details) {
  $status = if ($passed) { 'PASS' } else { 'FAIL' }
  $script:Results.Add([PSCustomObject]@{ Id = $id; Status = $status; Details = $details })
  Write-Output ("{0}: {1}" -f $id, $status)
  if ($details) { Write-Output $details }
}

function Read-Json($path) {
  return ([System.IO.File]::ReadAllText($path, $Utf8) | ConvertFrom-Json)
}

function Get-PropNames($obj) {
  if ($null -eq $obj) { return @() }
  return @($obj.PSObject.Properties.Name)
}

function Test-ThesisAgainstSchema($thesis, $schema) {
  $errors = New-Object System.Collections.Generic.List[string]
  foreach ($key in $schema.required) {
    if (-not (Get-Member -InputObject $thesis -Name $key -MemberType NoteProperty)) {
      $errors.Add("missing field $key")
    }
  }
  if ($schema.types -notcontains [string]$thesis.type) { $errors.Add("type=$($thesis.type)") }
  if ($schema.statuses -notcontains [string]$thesis.status) { $errors.Add("status=$($thesis.status)") }
  if ($schema.confidence -notcontains [string]$thesis.confidence) { $errors.Add("confidence=$($thesis.confidence)") }
  if (-not [string]$thesis.thesis) { $errors.Add('thesis text empty') }
  if (-not [string]$thesis.updatedAt) { $errors.Add('updatedAt empty') }
  if ($null -eq $thesis.supportingEvidence) { $errors.Add('supportingEvidence missing') }
  if ($null -eq $thesis.contradictingEvidence) { $errors.Add('contradictingEvidence missing') }
  if ($null -eq $thesis.linkedResearch) { $errors.Add('linkedResearch missing') }
  if ($null -eq $thesis.invalidationConditions) { $errors.Add('invalidationConditions missing') }
  if ($null -eq $thesis.keyIndicators) { $errors.Add('keyIndicators missing') }
  $hasDecision = $false
  foreach ($name in (Get-PropNames $thesis)) {
    if ($name -eq 'linkedDecision') { $hasDecision = $true }
  }
  if (-not $hasDecision) { $errors.Add('linkedDecision missing') }
  return $errors
}

function Test-EvidenceRefs($items, $schema, $label) {
  $errors = New-Object System.Collections.Generic.List[string]
  if ($null -eq $items) { return $errors }
  foreach ($item in @($items)) {
    foreach ($need in $schema.evidenceRefRequired) {
      if (-not [string]$item.$need) { $errors.Add("$label missing $need") }
    }
    foreach ($name in (Get-PropNames $item)) {
      if ($schema.evidenceRefForbidden -contains $name) {
        $errors.Add("$label copied forbidden field $name")
      }
    }
  }
  return $errors
}

function Test-ResearchRefs($items, $schema) {
  $errors = New-Object System.Collections.Generic.List[string]
  if ($null -eq $items) { return $errors }
  foreach ($item in @($items)) {
    foreach ($need in $schema.researchRefRequired) {
      if (-not [string]$item.$need) { $errors.Add("linkedResearch missing $need") }
    }
    foreach ($name in (Get-PropNames $item)) {
      if ($schema.researchRefForbidden -contains $name) {
        $errors.Add("linkedResearch copied forbidden field $name")
      }
    }
  }
  return $errors
}

function Copy-ThesisWithChange($thesis, $field, $valueJson) {
  $py = Join-Path $env:TEMP ('InvestorTwin-015-copy-' + [guid]::NewGuid().ToString('N') + '.py')
  $src = Join-Path $env:TEMP ('InvestorTwin-015-src-' + [guid]::NewGuid().ToString('N') + '.json')
  $val = Join-Path $env:TEMP ('InvestorTwin-015-val-' + [guid]::NewGuid().ToString('N') + '.json')
  $dst = Join-Path $env:TEMP ('InvestorTwin-015-dst-' + [guid]::NewGuid().ToString('N') + '.json')
  [System.IO.File]::WriteAllText($src, ($thesis | ConvertTo-Json -Depth 20), $Utf8)
  [System.IO.File]::WriteAllText($val, $valueJson, $Utf8)
  [System.IO.File]::WriteAllText($py, "import json,sys`ndata=json.load(open(sys.argv[1],encoding='utf-8'))`ndata[sys.argv[3]]=json.load(open(sys.argv[4],encoding='utf-8'))`njson.dump(data, open(sys.argv[2],'w',encoding='utf-8'))`n", $Utf8)
  & python $py $src $dst $field $val
  if ($LASTEXITCODE -ne 0) { throw 'copy thesis failed' }
  $out = Read-Json $dst
  Remove-Item -LiteralPath $py, $src, $val, $dst -Force -ErrorAction SilentlyContinue
  return $out
}

$schema = Read-Json $SchemaPath
$fixture = Read-Json $FixturePath
$theses = @($fixture.theses)

$fail1 = New-Object System.Collections.Generic.List[string]
if ($schema.schemaVersion -ne '015-a') { $fail1.Add("schemaVersion=$($schema.schemaVersion)") }
if ($schema.layer -ne 'thesis') { $fail1.Add('layer must be thesis') }
if ($schema.writesBrief -ne $false) { $fail1.Add('writesBrief must be false') }
if ($schema.writesEvidence -ne $false) { $fail1.Add('writesEvidence must be false') }
if ($schema.writesQueue -ne $false) { $fail1.Add('writesQueue must be false') }
if ($schema.writesCases -ne $false) { $fail1.Add('writesCases must be false') }
if ($schema.writesDecision -ne $false) { $fail1.Add('writesDecision must be false') }
if ($schema.writesPlaybook -ne $false) { $fail1.Add('writesPlaybook must be false') }
foreach ($key in @('thesisId','type','title','subject','thesis','rationale','supportingEvidence','contradictingEvidence','keyIndicators','invalidationConditions','status','confidence','linkedResearch','linkedDecision','updatedAt')) {
  if ($schema.required -notcontains $key) { $fail1.Add("schema missing required $key") }
}
if ($theses.Count -ne 4) { $fail1.Add("fixture theses=$($theses.Count) expected 4") }
foreach ($thesis in $theses) {
  $errs = Test-ThesisAgainstSchema $thesis $schema
  foreach ($err in $errs) { $fail1.Add("$($thesis.thesisId): $err") }
}
Add-TestResult 'TEST 1' ($fail1.Count -eq 0) ($fail1 -join "`n")

$fail2 = New-Object System.Collections.Generic.List[string]
$expectedTypes = @('industry','company','position')
foreach ($t in $expectedTypes) {
  if ($schema.types -notcontains $t) { $fail2.Add("schema missing type $t") }
}
if (@($schema.types).Count -ne 3) { $fail2.Add('schema types must be exactly 3') }
$seenTypes = @($theses | ForEach-Object { [string]$_.type } | Sort-Object -Unique)
foreach ($t in $expectedTypes) {
  if ($seenTypes -notcontains $t) { $fail2.Add("fixture missing type $t") }
}
$badType = Copy-ThesisWithChange $theses[0] 'type' '"macro"'
$badTypeErrs = Test-ThesisAgainstSchema $badType $schema
if ($badTypeErrs.Count -eq 0) { $fail2.Add('invalid type macro was accepted') }
Add-TestResult 'TEST 2' ($fail2.Count -eq 0) ($fail2 -join "`n")

$fail3 = New-Object System.Collections.Generic.List[string]
$expectedStatus = @('active','under_review','challenged','confirmed','invalidated')
foreach ($s in $expectedStatus) {
  if ($schema.statuses -notcontains $s) { $fail3.Add("schema missing status $s") }
}
$badStatus = Copy-ThesisWithChange $theses[0] 'status' '"open"'
$badStatusErrs = Test-ThesisAgainstSchema $badStatus $schema
if ($badStatusErrs.Count -eq 0) { $fail3.Add('invalid status open was accepted') }
$okStatus = Copy-ThesisWithChange $theses[0] 'status' '"confirmed"'
if ((Test-ThesisAgainstSchema $okStatus $schema).Count -ne 0) { $fail3.Add('status confirmed should be valid') }
$okInv = Copy-ThesisWithChange $theses[0] 'status' '"invalidated"'
if ((Test-ThesisAgainstSchema $okInv $schema).Count -ne 0) { $fail3.Add('status invalidated should be valid') }
Add-TestResult 'TEST 3' ($fail3.Count -eq 0) ($fail3 -join "`n")

$fail4 = New-Object System.Collections.Generic.List[string]
$expectedConf = @('low','medium','high','very_high')
foreach ($c in $expectedConf) {
  if ($schema.confidence -notcontains $c) { $fail4.Add("schema missing confidence $c") }
}
if ($schema.confidencePolicy -notmatch 'not subjective') { $fail4.Add('confidencePolicy must reject subjective belief') }
$veryHigh = Copy-ThesisWithChange $theses[0] 'confidence' '"very_high"'
if ((Test-ThesisAgainstSchema $veryHigh $schema).Count -ne 0) { $fail4.Add('confidence very_high should be valid') }
$badConf = Copy-ThesisWithChange $theses[0] 'confidence' '"extreme"'
if ((Test-ThesisAgainstSchema $badConf $schema).Count -eq 0) { $fail4.Add('invalid confidence extreme was accepted') }
$seenConf = @($theses | ForEach-Object { [string]$_.confidence })
if ($seenConf -notcontains 'low') { $fail4.Add('fixture missing low') }
if ($seenConf -notcontains 'medium') { $fail4.Add('fixture missing medium') }
if ($seenConf -notcontains 'high') { $fail4.Add('fixture missing high') }
Add-TestResult 'TEST 4' ($fail4.Count -eq 0) ($fail4 -join "`n")

$fail5 = New-Object System.Collections.Generic.List[string]
$supportCount = 0
foreach ($thesis in $theses) {
  $errs = Test-EvidenceRefs $thesis.supportingEvidence $schema 'supportingEvidence'
  foreach ($err in $errs) { $fail5.Add("$($thesis.thesisId): $err") }
  $supportCount += @($thesis.supportingEvidence).Count
}
if ($supportCount -lt 1) { $fail5.Add('no supportingEvidence references') }
$copied = Copy-ThesisWithChange $theses[0] 'supportingEvidence' '[{"instrument":"US10Y","value":4.69,"asOf":"2026-08-20"}]'
$copiedErrs = Test-EvidenceRefs $copied.supportingEvidence $schema 'supportingEvidence'
if ($copiedErrs.Count -eq 0) { $fail5.Add('supportingEvidence accepted copied value/asOf') }
Add-TestResult 'TEST 5' ($fail5.Count -eq 0) ($fail5 -join "`n")

$fail6 = New-Object System.Collections.Generic.List[string]
$contraCount = 0
foreach ($thesis in $theses) {
  $errs = Test-EvidenceRefs $thesis.contradictingEvidence $schema 'contradictingEvidence'
  foreach ($err in $errs) { $fail6.Add("$($thesis.thesisId): $err") }
  $contraCount += @($thesis.contradictingEvidence).Count
}
if ($contraCount -lt 1) { $fail6.Add('no contradictingEvidence references') }
$copiedContra = Copy-ThesisWithChange $theses[0] 'contradictingEvidence' '[{"instrument":"SOX","changeDoD":-0.5,"source":"stooq"}]'
$copiedContraErrs = Test-EvidenceRefs $copiedContra.contradictingEvidence $schema 'contradictingEvidence'
if ($copiedContraErrs.Count -eq 0) { $fail6.Add('contradictingEvidence accepted copied DoD/source') }
Add-TestResult 'TEST 6' ($fail6.Count -eq 0) ($fail6 -join "`n")

$fail7 = New-Object System.Collections.Generic.List[string]
$researchCount = 0
foreach ($thesis in $theses) {
  $errs = Test-ResearchRefs $thesis.linkedResearch $schema
  foreach ($err in $errs) { $fail7.Add("$($thesis.thesisId): $err") }
  $researchCount += @($thesis.linkedResearch).Count
}
if ($researchCount -lt 1) { $fail7.Add('no linkedResearch references') }
$cpo = @($theses | Where-Object { $_.thesisId -eq 'cpo-glass-bridge' })[0]
$ids = @($cpo.linkedResearch | ForEach-Object { [string]$_.researchId })
foreach ($need in @('glass-bridge','cpo','fau')) {
  if ($ids -notcontains $need) { $fail7.Add("cpo-glass-bridge missing researchId $need") }
}
$copiedCard = Copy-ThesisWithChange $cpo 'linkedResearch' '[{"researchId":"glass-bridge","title":"Glass Bridge","summary":"copied"}]'
$copiedCardErrs = Test-ResearchRefs $copiedCard.linkedResearch $schema
if ($copiedCardErrs.Count -eq 0) { $fail7.Add('linkedResearch accepted copied card fields') }
Add-TestResult 'TEST 7' ($fail7.Count -eq 0) ($fail7 -join "`n")

$fail8 = New-Object System.Collections.Generic.List[string]
$position = @($theses | Where-Object { $_.type -eq 'position' })[0]
if (-not $position) { $fail8.Add('fixture missing position thesis') }
else {
  if ($position.thesisId -ne '00687b') { $fail8.Add("position thesisId=$($position.thesisId)") }
  if (@($position.linkedResearch).Count -ne 0) { $fail8.Add('position thesis must stand without Research Cards') }
  if ($null -ne $position.linkedDecision) { $fail8.Add('position thesis must stand without Decision') }
  $posErrs = Test-ThesisAgainstSchema $position $schema
  foreach ($err in $posErrs) { $fail8.Add("position: $err") }
  $hasUs10 = $false
  $hasUs30 = $false
  foreach ($ref in @($position.supportingEvidence)) {
    if ($ref.instrument -eq 'US10Y') { $hasUs10 = $true }
    if ($ref.instrument -eq 'US30Y') { $hasUs30 = $true }
  }
  if (-not $hasUs10 -or -not $hasUs30) { $fail8.Add('00687b must reference US10Y and US30Y') }
}
Add-TestResult 'TEST 8' ($fail8.Count -eq 0) ($fail8 -join "`n")

$fail9 = New-Object System.Collections.Generic.List[string]
foreach ($thesis in $theses) {
  if (-not ($thesis.invalidationConditions -is [System.Array])) {
    $fail9.Add("$($thesis.thesisId) invalidationConditions must be array")
    continue
  }
  if (@($thesis.invalidationConditions).Count -lt 1) {
    $fail9.Add("$($thesis.thesisId) missing invalidationConditions")
  }
  foreach ($line in @($thesis.invalidationConditions)) {
    if (-not [string]$line) { $fail9.Add("$($thesis.thesisId) empty invalidationConditions") }
  }
}
Add-TestResult 'TEST 9' ($fail9.Count -eq 0) ($fail9 -join "`n")

$fail10 = New-Object System.Collections.Generic.List[string]
$prodIds = @('ai-dram','ai-thermal','00687b','cpo-glass-bridge')
foreach ($id in $prodIds) {
  $path = Join-Path $ThesesDir ($id + '.json')
  if (-not (Test-Path $path)) { $fail10.Add("missing production thesis $id") ; continue }
  $prod = Read-Json $path
  $errs = Test-ThesisAgainstSchema $prod $schema
  foreach ($err in $errs) { $fail10.Add("${id}: $err") }
}
if ((Get-FileHash -Path $ProdBriefPath -Algorithm SHA256).Hash -ne $ProdHashBefore.brief) { $fail10.Add('morning-brief.json was modified') }
if ((Get-FileHash -Path $LatestPath -Algorithm SHA256).Hash -ne $ProdHashBefore.latest) { $fail10.Add('latest.json was modified') }
if ((Get-FileHash -Path $QueuePath -Algorithm SHA256).Hash -ne $ProdHashBefore.queue) { $fail10.Add('research-queue.json was modified') }
if ((Get-FileHash -Path $CasesPath -Algorithm SHA256).Hash -ne $ProdHashBefore.cases) { $fail10.Add('investment-cases.json was modified') }
if ((Get-FileHash -Path $ServePath -Algorithm SHA256).Hash -ne $ProdHashBefore.serve) { $fail10.Add('serve.ps1 was modified') }
if ((Get-FileHash -Path $EvidenceSchema -Algorithm SHA256).Hash -ne $ProdHashBefore.evidenceSchema) { $fail10.Add('evidence schema was modified') }
if ((Get-FileHash -Path $CollectPy -Algorithm SHA256).Hash -ne $ProdHashBefore.collectPy) { $fail10.Add('collect-evidence.py was modified') }
if ((Get-FileHash -Path $CollectPs1 -Algorithm SHA256).Hash -ne $ProdHashBefore.collectPs1) { $fail10.Add('collect-evidence.ps1 was modified') }
Add-TestResult 'TEST 10' ($fail10.Count -eq 0) ($fail10 -join "`n")

$failed = @($script:Results | Where-Object { $_.Status -ne 'PASS' })
Write-Output ''
Write-Output '=== 015 SUMMARY ==='
foreach ($row in $script:Results) {
  Write-Output ("{0}: {1}" -f $row.Id, $row.Status)
}
if ($failed.Count -gt 0) { exit 1 }
exit 0
