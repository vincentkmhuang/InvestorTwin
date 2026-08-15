$root = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $root 'scripts\generate-knowledge-index.ps1')
Update-KnowledgeIndex -RootPath $root | Out-Null
Write-Output 'Knowledge index generated.'
$port = 8765
$myPid = $PID
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.ProcessId -ne $myPid -and $_.CommandLine -like "*serve.ps1*" } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 1

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$port/")
$listener.Prefixes.Add("http://vincent.tailb392b5.ts.net:$port/")
try {
  $listener.Start()
} catch {
  Write-Error "Port $port is in use. Close the existing server and run serve.ps1 again."
  exit 1
}
Write-Output "Serving HTTP on http://localhost:$port/"

function Send-Json($response, $obj, $statusCode = 200) {
  $response.StatusCode = $statusCode
  $response.ContentType = 'application/json; charset=utf-8'
  $json = $obj | ConvertTo-Json -Depth 10 -Compress
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
  $response.OutputStream.Write($bytes, 0, $bytes.Length)
}

function Read-Body($request) {
  if (-not $request.HasEntityBody) { return $null }
  $reader = New-Object System.IO.StreamReader($request.InputStream, $request.ContentEncoding)
  $text = $reader.ReadToEnd()
  if ([string]::IsNullOrWhiteSpace($text)) { return $null }
  return $text | ConvertFrom-Json
}

function Get-GitCommit($rootPath) {
  try {
    $hash = git -C $rootPath rev-parse --short HEAD 2>$null
    if ($hash) { return $hash.Trim() }
  } catch {}
  return 'unknown'
}

function Get-Utf8NoBom {
  return New-Object System.Text.UTF8Encoding $false
}

function Read-Utf8Json($path) {
  $text = [System.IO.File]::ReadAllText($path, (Get-Utf8NoBom))
  return $text | ConvertFrom-Json
}

function Write-Utf8Text($path, $text) {
  [System.IO.File]::WriteAllText($path, $text, (Get-Utf8NoBom))
}

function ConvertTo-JsonArrayText($items) {
  $list = @($items)
  if ($list.Count -eq 0) { return '[]' }
  $parts = foreach ($item in $list) {
    ($item | ConvertTo-Json -Depth 10 -Compress)
  }
  return '[' + ($parts -join ',') + ']'
}

function Write-ResearchCardJson($cardPath, $cardObj, $questions) {
  $arrayKeys = @('tags', 'related')
  $parts = New-Object System.Collections.Generic.List[string]
  $wroteQuestions = $false
  foreach ($prop in $cardObj.PSObject.Properties) {
    $key = $prop.Name
    if ($key -eq 'questions') {
      $wroteQuestions = $true
      [void]$parts.Add('"questions":' + (ConvertTo-JsonArrayText $questions))
    } elseif ($key -in $arrayKeys) {
      [void]$parts.Add('"' + $key + '":' + (ConvertTo-JsonArrayText @($prop.Value)))
    } else {
      [void]$parts.Add('"' + $key + '":' + ($prop.Value | ConvertTo-Json -Depth 10 -Compress))
    }
  }
  if (-not $wroteQuestions) {
    [void]$parts.Add('"questions":' + (ConvertTo-JsonArrayText $questions))
  }
  Write-Utf8Text $cardPath ('{' + ($parts -join ',') + '}')
}

function Get-AsArray($value) {
  if ($null -eq $value) { return @() }
  return @($value)
}

function Get-JsonString($value) {
  return ([string]$value | ConvertTo-Json -Compress)
}

function Get-JsonNullOrString($value) {
  if ($null -eq $value -or $value -eq '') { return 'null' }
  return Get-JsonString $value
}

function Get-JsonNullOrNumber($value) {
  if ($null -eq $value -or $value -eq '') { return 'null' }
  try {
    return ([double]$value).ToString([System.Globalization.CultureInfo]::InvariantCulture)
  } catch {
    return 'null'
  }
}

function ConvertTo-EvidenceJson($items) {
  $list = Get-AsArray $items
  if ($list.Count -eq 0) { return '[]' }
  $parts = foreach ($item in $list) {
    $text = Get-JsonString $item.text
    $rid = if ($null -eq $item.researchId -or $item.researchId -eq '') { 'null' } else { Get-JsonString $item.researchId }
    ('{"text":' + $text + ',"researchId":' + $rid + '}')
  }
  return '[' + ($parts -join ',') + ']'
}

function New-EmptyValuationProfile {
  return [PSCustomObject]@{
    companyType = $null
    primaryMethod = $null
    secondaryMethod = $null
    crossCheckMethod = $null
    userConfirmed = $false
  }
}

function Get-ValuationRecommendation($companyType) {
  switch ($companyType) {
    'Growth' {
      return [PSCustomObject]@{
        primaryMethod = 'Forward PE'
        secondaryMethod = 'Historical PE'
        crossCheckMethod = 'DCF'
      }
    }
    'Financial / Bank' {
      return [PSCustomObject]@{
        primaryMethod = 'PB / ROE'
        secondaryMethod = 'Historical PE'
        crossCheckMethod = 'Dividend Discount'
      }
    }
    'Mature / Value' {
      return [PSCustomObject]@{
        primaryMethod = 'Historical PE'
        secondaryMethod = 'Forward PE'
        crossCheckMethod = 'DCF'
      }
    }
    'Asset-heavy' {
      return [PSCustomObject]@{
        primaryMethod = 'NAV'
        secondaryMethod = 'PB / ROE'
        crossCheckMethod = 'DCF'
      }
    }
    default { return $null }
  }
}

function Ensure-ValuationProfile($caseObj) {
  if (-not $caseObj.valuationProfile) {
    $caseObj | Add-Member -NotePropertyName valuationProfile -NotePropertyValue (New-EmptyValuationProfile) -Force
  }
  return $caseObj.valuationProfile
}

function Get-MethodInputFields {
  return [ordered]@{
    'Forward PE' = @('forwardEPS', 'reasonablePE')
    'Historical PE' = @('referenceEPS', 'historicalPEBear', 'historicalPEBase', 'historicalPEBull')
    'PB / ROE' = @('BVPS', 'ROE', 'reasonablePB')
    'DCF' = @('freeCashFlow', 'growthRate', 'discountRate', 'terminalGrowthRate')
    'EV/EBITDA' = @('EBITDA', 'reasonableEVEBITDA', 'netDebt', 'sharesOutstanding')
    'EV/Sales' = @('revenue', 'reasonableEVSales', 'netDebt', 'sharesOutstanding')
    'Dividend Discount' = @('DPS', 'dividendGrowthRate', 'requiredReturn')
    'NAV' = @('assetValue', 'liabilities', 'sharesOutstanding')
  }
}

function Get-MethodInputObject($methodInputs, $method) {
  if (-not $methodInputs) { return $null }
  $prop = $methodInputs.PSObject.Properties[$method]
  if ($prop) { return $prop.Value }
  return $null
}

function ConvertTo-MethodInputLeafJson($raw) {
  $value = $null
  $sourceType = $null
  $researchId = $null
  $period = $null
  $asOf = $null

  if ($null -ne $raw -and $raw -ne '') {
    $isObject = $raw -is [System.Management.Automation.PSObject] -or $raw -is [System.Collections.IDictionary]
    if ($isObject) {
      if ($raw.PSObject.Properties['value']) { $value = $raw.value }
      if ($raw.PSObject.Properties['sourceType'] -and $raw.sourceType) { $sourceType = [string]$raw.sourceType }
      if ($raw.PSObject.Properties['researchId'] -and $raw.researchId) { $researchId = [string]$raw.researchId }
      if ($raw.PSObject.Properties['period'] -and $raw.period) { $period = [string]$raw.period }
      if ($raw.PSObject.Properties['asOf'] -and $raw.asOf) { $asOf = [string]$raw.asOf }
    } else {
      try { $value = [double]$raw } catch { $value = $null }
    }
  }

  return ('{"value":' + (Get-JsonNullOrNumber $value) + ',"sourceType":' + (Get-JsonNullOrString $sourceType) + ',"researchId":' + (Get-JsonNullOrString $researchId) + ',"period":' + (Get-JsonNullOrString $period) + ',"asOf":' + (Get-JsonNullOrString $asOf) + '}')
}

function ConvertTo-MethodInputsJson($methodInputs) {
  $catalog = Get-MethodInputFields
  $methodParts = New-Object System.Collections.Generic.List[string]
  foreach ($method in $catalog.Keys) {
    $src = Get-MethodInputObject $methodInputs $method
    $fieldParts = foreach ($field in $catalog[$method]) {
      $raw = $null
      if ($src) {
        $fieldProp = $src.PSObject.Properties[$field]
        if ($fieldProp) { $raw = $fieldProp.Value }
      }
      '"' + $field + '":' + (ConvertTo-MethodInputLeafJson $raw)
    }
    [void]$methodParts.Add(('"' + $method + '":{' + ($fieldParts -join ',') + '}'))
  }
  return '{' + ($methodParts -join ',') + '}'
}

function Ensure-MethodInputs($valuation) {
  if (-not $valuation) {
    $valuation = [PSCustomObject]@{
      bear = $null; base = $null; bull = $null; marginOfSafety = $null; buyUnder = $null
      currentPrice = $null; currentDiscount = $null; methodInputs = $null
    }
  }
  if (-not $valuation.PSObject.Properties['methodInputs']) {
    $valuation | Add-Member -NotePropertyName methodInputs -NotePropertyValue $null
  }
  return $valuation
}

function Get-BuyUnder($base, $mos) {
  if ($null -eq $base -or $base -eq '' -or $null -eq $mos -or $mos -eq '') { return $null }
  try {
    return [double]$base * (1 - [double]$mos)
  } catch {
    return $null
  }
}

function New-EmptyMethodFairValue {
  return [PSCustomObject]@{
    bear = $null
    base = $null
    bull = $null
    asOf = $null
  }
}

function Get-MethodInputNumericValue($methodInputs, $method, $field) {
  $methodObj = Get-MethodInputObject $methodInputs $method
  if (-not $methodObj) { return $null }
  $prop = $methodObj.PSObject.Properties[$field]
  if (-not $prop) { return $null }
  $raw = $prop.Value
  if ($null -eq $raw -or $raw -eq '') { return $null }
  $value = $null
  if ($raw -is [System.Management.Automation.PSObject] -or $raw -is [System.Collections.IDictionary]) {
    if ($raw.PSObject.Properties['value']) { $value = $raw.value }
  } else {
    $value = $raw
  }
  if ($null -eq $value -or $value -eq '') { return $null }
  try {
    $n = [double]$value
    if ([double]::IsNaN($n) -or [double]::IsInfinity($n)) { return $null }
    return $n
  } catch {
    return $null
  }
}

function Get-ProductOrNull($left, $right) {
  if ($null -eq $left -or $null -eq $right) { return $null }
  try {
    $n = [double]$left * [double]$right
    if ([double]::IsNaN($n) -or [double]::IsInfinity($n)) { return $null }
    return $n
  } catch {
    return $null
  }
}

function New-MethodFairValue($bear, $base, $bull, $today) {
  $hasValue = $null -ne $bear -or $null -ne $base -or $null -ne $bull
  return [PSCustomObject]@{
    bear = $bear
    base = $base
    bull = $bull
    asOf = if ($hasValue) { $today } else { $null }
  }
}

function Get-ComputedMethodFairValues($methodInputs, $userConfirmed, $today) {
  if (-not $userConfirmed) {
    return [PSCustomObject]@{
      'Forward PE' = (New-EmptyMethodFairValue)
      'Historical PE' = (New-EmptyMethodFairValue)
      'PB / ROE' = (New-EmptyMethodFairValue)
    }
  }

  $fwdBase = Get-ProductOrNull `
    (Get-MethodInputNumericValue $methodInputs 'Forward PE' 'forwardEPS') `
    (Get-MethodInputNumericValue $methodInputs 'Forward PE' 'reasonablePE')
  $refEps = Get-MethodInputNumericValue $methodInputs 'Historical PE' 'referenceEPS'
  $pbBase = Get-ProductOrNull `
    (Get-MethodInputNumericValue $methodInputs 'PB / ROE' 'BVPS') `
    (Get-MethodInputNumericValue $methodInputs 'PB / ROE' 'reasonablePB')

  return [PSCustomObject]@{
    'Forward PE' = (New-MethodFairValue $null $fwdBase $null $today)
    'Historical PE' = (New-MethodFairValue `
      (Get-ProductOrNull $refEps (Get-MethodInputNumericValue $methodInputs 'Historical PE' 'historicalPEBear')) `
      (Get-ProductOrNull $refEps (Get-MethodInputNumericValue $methodInputs 'Historical PE' 'historicalPEBase')) `
      (Get-ProductOrNull $refEps (Get-MethodInputNumericValue $methodInputs 'Historical PE' 'historicalPEBull')) `
      $today)
    'PB / ROE' = (New-MethodFairValue $null $pbBase $null $today)
  }
}

function ConvertTo-MethodFairValuesJson($methodFairValues) {
  $methods = @('Forward PE', 'Historical PE', 'PB / ROE')
  $parts = foreach ($method in $methods) {
    $src = $null
    if ($methodFairValues) {
      $prop = $methodFairValues.PSObject.Properties[$method]
      if ($prop) { $src = $prop.Value }
    }
    $bear = $null
    $base = $null
    $bull = $null
    $asOf = $null
    if ($src) {
      if ($src.PSObject.Properties['bear']) { $bear = $src.bear }
      if ($src.PSObject.Properties['base']) { $base = $src.base }
      if ($src.PSObject.Properties['bull']) { $bull = $src.bull }
      if ($src.PSObject.Properties['asOf'] -and $src.asOf) { $asOf = [string]$src.asOf }
    }
    ('"' + $method + '":{"bear":' + (Get-JsonNullOrNumber $bear) + ',"base":' + (Get-JsonNullOrNumber $base) + ',"bull":' + (Get-JsonNullOrNumber $bull) + ',"asOf":' + (Get-JsonNullOrString $asOf) + '}')
  }
  return '{' + ($parts -join ',') + '}'
}

function Set-CaseMethodFairValues($caseObj, $today) {
  if (-not $caseObj.valuation) { return }
  $confirmed = $false
  if ($caseObj.valuationProfile -and $caseObj.valuationProfile.userConfirmed) {
    $confirmed = [bool]$caseObj.valuationProfile.userConfirmed
  }
  $computed = Get-ComputedMethodFairValues $caseObj.valuation.methodInputs $confirmed $today
  if ($caseObj.valuation.PSObject.Properties['methodFairValues']) {
    $caseObj.valuation.methodFairValues = $computed
  } else {
    $caseObj.valuation | Add-Member -NotePropertyName methodFairValues -NotePropertyValue $computed -Force
  }
  Set-CaseLevelValuation $caseObj
}

function Get-FiniteNumber($raw) {
  if ($null -eq $raw -or $raw -eq '') { return $null }
  try {
    $n = [double]$raw
    if ([double]::IsNaN($n) -or [double]::IsInfinity($n)) { return $null }
    return $n
  } catch {
    return $null
  }
}

function Set-CaseLevelValuation($caseObj) {
  if (-not $caseObj.valuation) { return }
  $confirmed = $false
  $primary = $null
  if ($caseObj.valuationProfile) {
    if ($caseObj.valuationProfile.userConfirmed) { $confirmed = [bool]$caseObj.valuationProfile.userConfirmed }
    if ($caseObj.valuationProfile.primaryMethod) { $primary = [string]$caseObj.valuationProfile.primaryMethod }
  }
  $bear = $null
  $base = $null
  $bull = $null
  if ($confirmed -and $primary) {
    $fv = Get-MethodInputObject $caseObj.valuation.methodFairValues $primary
    if ($fv) {
      if ($fv.PSObject.Properties['bear']) { $bear = Get-FiniteNumber $fv.bear }
      if ($fv.PSObject.Properties['base']) { $base = Get-FiniteNumber $fv.base }
      if ($fv.PSObject.Properties['bull']) { $bull = Get-FiniteNumber $fv.bull }
    }
  }
  $caseObj.valuation.bear = $bear
  $caseObj.valuation.base = $base
  $caseObj.valuation.bull = $bull
  $caseObj.valuation.buyUnder = Get-BuyUnder $base $caseObj.valuation.marginOfSafety
}

function ConvertTo-InvestmentCaseJson($caseObj) {
  $company = $caseObj.company
  if (-not $company) { $company = [PSCustomObject]@{ name = ''; ticker = ''; exchange = $null; currency = $null } }
  $origin = $caseObj.origin
  if (-not $origin) { $origin = [PSCustomObject]@{ source = 'Manual'; createdAt = ''; updatedAt = '' } }
  $thesis = $caseObj.thesis
  if (-not $thesis) {
    $thesis = [PSCustomObject]@{
      thesis = ''; growthDrivers = @(); competitiveAdvantage = ''; earningsTranslation = ''; duration = ''
      supportingEvidence = @(); counterEvidence = @(); toBeVerified = @(); killCriteria = @(); status = 'forming'
    }
  }
  $profile = $caseObj.valuationProfile
  if (-not $profile) {
    $profile = [PSCustomObject]@{
      companyType = $null; primaryMethod = $null; secondaryMethod = $null; crossCheckMethod = $null; userConfirmed = $false
    }
  }
  $val = $caseObj.valuation
  if (-not $val) {
    $val = [PSCustomObject]@{
      bear = $null; base = $null; bull = $null; marginOfSafety = $null; buyUnder = $null
      currentPrice = $null; currentDiscount = $null; methodInputs = $null
    }
  }
  $val = Ensure-MethodInputs $val
  $confirmed = $false
  if ($profile.userConfirmed) { $confirmed = [bool]$profile.userConfirmed }

  $parts = @(
    '"id":' + (Get-JsonString $caseObj.id)
    '"title":' + (Get-JsonString $caseObj.title)
    '"status":' + (Get-JsonString $caseObj.status)
    '"company":{"name":' + (Get-JsonString $company.name) + ',"ticker":' + (Get-JsonString $company.ticker) + ',"exchange":' + (Get-JsonNullOrString $company.exchange) + ',"currency":' + (Get-JsonNullOrString $company.currency) + '}'
    '"origin":{"source":' + (Get-JsonString $origin.source) + ',"createdAt":' + (Get-JsonString $origin.createdAt) + ',"updatedAt":' + (Get-JsonString $origin.updatedAt) + '}'
    '"researchIds":' + (ConvertTo-JsonArrayText (Get-AsArray $caseObj.researchIds))
    '"thesis":{"thesis":' + (Get-JsonString $thesis.thesis) + ',"growthDrivers":' + (ConvertTo-JsonArrayText (Get-AsArray $thesis.growthDrivers)) + ',"competitiveAdvantage":' + (Get-JsonString $thesis.competitiveAdvantage) + ',"earningsTranslation":' + (Get-JsonString $thesis.earningsTranslation) + ',"duration":' + (Get-JsonString $thesis.duration) + ',"supportingEvidence":' + (ConvertTo-EvidenceJson $thesis.supportingEvidence) + ',"counterEvidence":' + (ConvertTo-EvidenceJson $thesis.counterEvidence) + ',"toBeVerified":' + (ConvertTo-EvidenceJson $thesis.toBeVerified) + ',"killCriteria":' + (ConvertTo-JsonArrayText (Get-AsArray $thesis.killCriteria)) + ',"status":' + (Get-JsonString $thesis.status) + '}'
    '"valuationProfile":{"companyType":' + (Get-JsonNullOrString $profile.companyType) + ',"primaryMethod":' + (Get-JsonNullOrString $profile.primaryMethod) + ',"secondaryMethod":' + (Get-JsonNullOrString $profile.secondaryMethod) + ',"crossCheckMethod":' + (Get-JsonNullOrString $profile.crossCheckMethod) + ',"userConfirmed":' + $(if ($confirmed) { 'true' } else { 'false' }) + '}'
    '"valuation":{"bear":' + (Get-JsonNullOrNumber $val.bear) + ',"base":' + (Get-JsonNullOrNumber $val.base) + ',"bull":' + (Get-JsonNullOrNumber $val.bull) + ',"marginOfSafety":' + (Get-JsonNullOrNumber $val.marginOfSafety) + ',"buyUnder":' + (Get-JsonNullOrNumber $val.buyUnder) + ',"currentPrice":null,"currentDiscount":null,"methodInputs":' + (ConvertTo-MethodInputsJson $val.methodInputs) + ',"methodFairValues":' + (ConvertTo-MethodFairValuesJson $val.methodFairValues) + '}'
    '"decision":null'
    '"positionPlaybook":null'
    '"monitoring":null'
  )
  return '{' + ($parts -join ',') + '}'
}

function Read-InvestmentCases($path) {
  if (-not (Test-Path $path)) {
    return [PSCustomObject]@{
      schemaVersion = '1.0'
      updated = (Get-Date -Format 'yyyy-MM-dd')
      cases = @()
    }
  }
  $store = Read-Utf8Json $path
  if (-not $store) {
    return [PSCustomObject]@{
      schemaVersion = '1.0'
      updated = (Get-Date -Format 'yyyy-MM-dd')
      cases = @()
    }
  }
  $store.cases = @(Get-AsArray $store.cases)
  return $store
}

function Write-InvestmentCasesFile($path, $store) {
  $caseJsons = foreach ($caseObj in (Get-AsArray $store.cases)) {
    ConvertTo-InvestmentCaseJson $caseObj
  }
  $list = @($caseJsons)
  $casesJson = if ($list.Count -eq 0) { '[]' } else { '[' + ($list -join ',') + ']' }
  $json = '{"schemaVersion":' + (Get-JsonString $store.schemaVersion) + ',"updated":' + (Get-JsonString $store.updated) + ',"cases":' + $casesJson + '}'
  Write-Utf8Text $path $json
}

while ($listener.IsListening) {
  $context = $listener.GetContext()
  $request = $context.Request
  $response = $context.Response
  $localPath = $request.Url.LocalPath
  $method = $request.HttpMethod

  try {
    if ($localPath -eq '/api/version' -and $method -eq 'GET') {
      $versionPath = Join-Path $root 'data\version.json'
      $info = if (Test-Path $versionPath) {
        Get-Content $versionPath -Raw | ConvertFrom-Json
      } else {
        [PSCustomObject]@{ version = '0.0.4'; sprint = '002'; build = 'unknown' }
      }
      Send-Json $response @{
        version = $info.version
        sprint = $info.sprint
        build = $info.build
        commit = (Get-GitCommit $root)
      }
    }
    elseif ($localPath -eq '/api/queue' -and $method -eq 'POST') {
      $body = Read-Body $request
      $queuePath = Join-Path $root 'data\research-queue.json'
      $queue = Get-Content $queuePath -Raw | ConvertFrom-Json
      $added = $false
      if ($body -and $body.id -and -not ($queue.items | Where-Object { $_.id -eq $body.id })) {
        $queue.items += [PSCustomObject]@{ id = $body.id; addedFrom = $body.addedFrom }
        $queue | ConvertTo-Json -Depth 10 | Set-Content $queuePath -Encoding UTF8
        $added = $true
      }
      Send-Json $response @{ added = $added; items = $queue.items }
    }
    elseif ($localPath -eq '/api/cases' -and $method -eq 'POST') {
      $body = Read-Body $request
      $casesPath = Join-Path $root 'data\investment-cases.json'
      $store = Read-InvestmentCases $casesPath
      $today = Get-Date -Format 'yyyy-MM-dd'

      if ($body -and $body.case) {
        $caseObj = $body.case
        $id = [string]$caseObj.id
        if ([string]::IsNullOrWhiteSpace($id) -or $id -match '[\\/]' -or $id -eq '.' -or $id -eq '..') {
          Send-Json $response @{ error = 'invalid_id'; message = 'Invalid case id' } 400
        } elseif (-not $caseObj.company -or [string]::IsNullOrWhiteSpace([string]$caseObj.company.name) -or [string]::IsNullOrWhiteSpace([string]$caseObj.company.ticker)) {
          Send-Json $response @{ error = 'invalid_payload'; message = 'Company name and ticker are required' } 400
        } else {
          $existing = @($store.cases | Where-Object { $_.id -eq $id })
          if ($existing.Count -gt 0) {
            Send-Json $response @{ created = $false; existing = $true; id = $id }
          } else {
            $caseObj.decision = $null
            $caseObj.positionPlaybook = $null
            $caseObj.monitoring = $null
            if (-not $caseObj.valuation) {
              $caseObj | Add-Member -NotePropertyName valuation -NotePropertyValue ([PSCustomObject]@{
                bear = $null; base = $null; bull = $null
                marginOfSafety = $null; buyUnder = $null
                currentPrice = $null; currentDiscount = $null
              }) -Force
            }
            $caseObj.valuation.currentPrice = $null
            $caseObj.valuation.currentDiscount = $null
            $caseObj.valuation.buyUnder = Get-BuyUnder $caseObj.valuation.base $caseObj.valuation.marginOfSafety
            $store.cases = @(Get-AsArray $store.cases) + @($caseObj)
            $store.updated = $today
            if (-not $store.schemaVersion) { $store | Add-Member -NotePropertyName schemaVersion -NotePropertyValue '1.0' -Force }
            Write-InvestmentCasesFile $casesPath $store
            Send-Json $response @{ created = $true; existing = $false; id = $id }
          }
        }
      } elseif ($body -and $body.id -and ($body.PSObject.Properties.Name -contains 'companyType')) {
        $id = [string]$body.id
        $target = @($store.cases | Where-Object { $_.id -eq $id } | Select-Object -First 1)
        if ($target.Count -eq 0) {
          Send-Json $response @{ error = 'not_found'; message = 'Investment Case not found' } 404
        } else {
          $caseObj = $target[0]
          $type = if ($null -eq $body.companyType) { '' } else { ([string]$body.companyType).Trim() }
          if ([string]::IsNullOrWhiteSpace($type)) {
            $caseObj.valuationProfile = New-EmptyValuationProfile
            Set-CaseMethodFairValues $caseObj $today
            if ($caseObj.origin) { $caseObj.origin.updatedAt = $today }
            $store.updated = $today
            Write-InvestmentCasesFile $casesPath $store
            Send-Json $response @{
              updated = $true
              id = $id
              valuationProfile = $caseObj.valuationProfile
            }
          } else {
            $rec = Get-ValuationRecommendation $type
            if (-not $rec) {
              Send-Json $response @{ error = 'invalid_payload'; message = 'Unsupported companyType' } 400
            } else {
              $profile = Ensure-ValuationProfile $caseObj
              $profile.companyType = $type
              $profile.primaryMethod = $rec.primaryMethod
              $profile.secondaryMethod = $rec.secondaryMethod
              $profile.crossCheckMethod = $rec.crossCheckMethod
              $profile.userConfirmed = $false
              Set-CaseMethodFairValues $caseObj $today
              if ($caseObj.origin) { $caseObj.origin.updatedAt = $today }
              $store.updated = $today
              Write-InvestmentCasesFile $casesPath $store
              Send-Json $response @{
                updated = $true
                id = $id
                valuationProfile = $caseObj.valuationProfile
              }
            }
          }
        }
      } elseif ($body -and $body.id -and $body.confirmValuationProfile) {
        $id = [string]$body.id
        $target = @($store.cases | Where-Object { $_.id -eq $id } | Select-Object -First 1)
        if ($target.Count -eq 0) {
          Send-Json $response @{ error = 'not_found'; message = 'Investment Case not found' } 404
        } else {
          $caseObj = $target[0]
          $profile = Ensure-ValuationProfile $caseObj
          if (-not $profile.companyType -or -not $profile.primaryMethod) {
            Send-Json $response @{ error = 'invalid_payload'; message = 'companyType is not set' } 400
          } else {
            $profile.userConfirmed = $true
            Set-CaseMethodFairValues $caseObj $today
            if ($caseObj.origin) { $caseObj.origin.updatedAt = $today }
            $store.updated = $today
            Write-InvestmentCasesFile $casesPath $store
            Send-Json $response @{
              updated = $true
              id = $id
              userConfirmed = $true
            }
          }
        }
      } elseif ($body -and $body.id -and $body.methodInput) {
        $id = [string]$body.id
        $target = @($store.cases | Where-Object { $_.id -eq $id } | Select-Object -First 1)
        $methodName = if ($body.methodInput.method) { [string]$body.methodInput.method } else { '' }
        $fieldName = if ($body.methodInput.field) { [string]$body.methodInput.field } else { '' }
        $rawValue = $body.methodInput.value
        $isBlank = $null -eq $rawValue -or $rawValue -eq ''
        $parsedValue = $null
        $parseFailed = $false
        if (-not $isBlank) {
          try { $parsedValue = [double]$rawValue } catch { $parseFailed = $true }
          if ($null -eq $parsedValue) { $parseFailed = $true }
        }
        if ($target.Count -eq 0) {
          Send-Json $response @{ error = 'not_found'; message = 'Investment Case not found' } 404
        } elseif (-not (Get-MethodInputFields).Contains($methodName) -or @((Get-MethodInputFields)[$methodName]) -notcontains $fieldName) {
          Send-Json $response @{ error = 'invalid_payload'; message = 'Unsupported method or field' } 400
        } elseif ($parseFailed) {
          Send-Json $response @{ error = 'invalid_payload'; message = 'methodInput value must be a number or empty' } 400
        } else {
          $caseObj = $target[0]
          if (-not $caseObj.valuation) {
            $caseObj | Add-Member -NotePropertyName valuation -NotePropertyValue ([PSCustomObject]@{
              bear = $null; base = $null; bull = $null
              marginOfSafety = $null; buyUnder = $null
              currentPrice = $null; currentDiscount = $null
              methodInputs = $null
            }) -Force
          }
          $caseObj.valuation = Ensure-MethodInputs $caseObj.valuation
          if (-not $caseObj.valuation.methodInputs) {
            $caseObj.valuation | Add-Member -NotePropertyName methodInputs -NotePropertyValue ([PSCustomObject]@{}) -Force
          }
          $methodObj = Get-MethodInputObject $caseObj.valuation.methodInputs $methodName
          if (-not $methodObj) {
            $methodObj = [PSCustomObject]@{}
            $caseObj.valuation.methodInputs | Add-Member -NotePropertyName $methodName -NotePropertyValue $methodObj -Force
          }
          $leaf = if ($isBlank) {
            [PSCustomObject]@{
              value = $null
              sourceType = $null
              researchId = $null
              period = $null
              asOf = $null
            }
          } else {
            [PSCustomObject]@{
              value = $parsedValue
              sourceType = 'user'
              researchId = $null
              period = $null
              asOf = $today
            }
          }
          if ($methodObj.PSObject.Properties[$fieldName]) {
            $methodObj.$fieldName = $leaf
          } else {
            $methodObj | Add-Member -NotePropertyName $fieldName -NotePropertyValue $leaf -Force
          }
          Set-CaseMethodFairValues $caseObj $today
          if ($caseObj.origin) { $caseObj.origin.updatedAt = $today }
          $store.updated = $today
          Write-InvestmentCasesFile $casesPath $store
          Send-Json $response @{
            updated = $true
            id = $id
            method = $methodName
            field = $fieldName
            value = $parsedValue
          }
        }
      } elseif ($body -and $body.id -and ($body.PSObject.Properties.Name -contains 'marginOfSafety')) {
        $id = [string]$body.id
        $target = @($store.cases | Where-Object { $_.id -eq $id } | Select-Object -First 1)
        if ($target.Count -eq 0) {
          Send-Json $response @{ error = 'not_found'; message = 'Investment Case not found' } 404
        } else {
          $rawMos = $body.marginOfSafety
          $mos = $null
          try { $mos = [double]$rawMos } catch { $mos = $null }
          if ($null -eq $mos -or $mos -lt 0) {
            Send-Json $response @{ error = 'invalid_payload'; message = 'Invalid marginOfSafety' } 400
          } else {
            if ($mos -gt 1 -and $mos -le 100) { $mos = $mos / 100 }
            if ($mos -gt 1) {
              Send-Json $response @{ error = 'invalid_payload'; message = 'marginOfSafety must be between 0 and 1' } 400
            } else {
              $caseObj = $target[0]
              if (-not $caseObj.valuation) {
                $caseObj | Add-Member -NotePropertyName valuation -NotePropertyValue ([PSCustomObject]@{
                  bear = $null; base = $null; bull = $null
                  marginOfSafety = $null; buyUnder = $null
                  currentPrice = $null; currentDiscount = $null
                }) -Force
              }
              $caseObj.valuation.marginOfSafety = $mos
              Set-CaseLevelValuation $caseObj
              $caseObj.valuation.currentPrice = $null
              $caseObj.valuation.currentDiscount = $null
              if ($caseObj.origin) { $caseObj.origin.updatedAt = $today }
              $store.updated = $today
              Write-InvestmentCasesFile $casesPath $store
              Send-Json $response @{
                updated = $true
                id = $id
                marginOfSafety = $mos
                buyUnder = $caseObj.valuation.buyUnder
              }
            }
          }
        }
      } else {
        Send-Json $response @{ error = 'invalid_payload'; message = 'case, companyType, confirmValuationProfile, methodInput, or marginOfSafety is required' } 400
      }
    }
    elseif ($localPath -match '^/api/research/(.+)$' -and $method -eq 'POST') {
      $id = [Uri]::UnescapeDataString($Matches[1])
      if ([string]::IsNullOrWhiteSpace($id) -or $id -match '[\\/]' -or $id -eq '.' -or $id -eq '..') {
        Send-Json $response @{ error = 'missing_research'; message = 'Invalid research id' } 400
      } else {
        $dir = Join-Path $root ("research\" + $id)
        $body = Read-Body $request

        if (-not (Test-Path $dir)) {
          New-Item -ItemType Directory -Path $dir -Force | Out-Null
          $card = if ($body.card) { $body.card } else {
            [PSCustomObject]@{
              id = $id; title = $id; summary = ''; investmentThesis = ''
              questions = @(); reason = 'Unknown'; tags = @(); related = @()
              status = 'researching'; updated = (Get-Date -Format 'yyyy-MM-dd')
            }
          }
          $card | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $dir 'card.json') -Encoding UTF8
          '[]' | Set-Content (Join-Path $dir 'notes.json') -Encoding UTF8
          '[]' | Set-Content (Join-Path $dir 'timeline.json') -Encoding UTF8
          '[]' | Set-Content (Join-Path $dir 'sources.json') -Encoding UTF8
          Update-KnowledgeIndex -RootPath $root | Out-Null
          Send-Json $response @{ created = $true; updated = $false; id = $id }
        } else {
          $noteText = $null
          if ($body -and $body.PSObject.Properties.Name -contains 'appendNote' -and $body.appendNote) {
            $noteText = [string]$body.appendNote
          } elseif ($body -and $body.note) {
            if ($body.note -is [string]) { $noteText = [string]$body.note }
            elseif ($body.note.PSObject.Properties.Name -contains 'text') { $noteText = [string]$body.note.text }
          }
          $noteText = if ($null -eq $noteText) { '' } else { $noteText.Trim() }
          $questionText = ''
          if ($body -and $body.PSObject.Properties.Name -contains 'question' -and $body.question) {
            $questionText = ([string]$body.question).Trim()
          }

          if (-not $noteText) {
            Send-Json $response @{ error = 'invalid_payload'; message = 'appendNote/note text is required for update' } 400
          } else {
            try {
              $notesPath = Join-Path $dir 'notes.json'
              $existingNotes = @()
              if (Test-Path $notesPath) {
                $parsedNotes = Read-Utf8Json $notesPath
                if ($parsedNotes -is [System.Array]) {
                  $existingNotes = @($parsedNotes)
                } elseif ($parsedNotes -and ($parsedNotes.PSObject.Properties.Name -contains 'notes')) {
                  $existingNotes = @($parsedNotes.notes)
                }
              }
              $noteEntry = [PSCustomObject]@{
                date = (Get-Date -Format 'yyyy-MM-dd')
                text = $noteText
              }
              $allNotes = @($existingNotes + $noteEntry)
              Write-Utf8Text $notesPath ('{"notes":' + (ConvertTo-JsonArrayText $allNotes) + '}')

              if ($questionText) {
                $cardPath = Join-Path $dir 'card.json'
                if (-not (Test-Path $cardPath)) {
                  throw 'card.json missing for existing research'
                }
                $cardObj = Read-Utf8Json $cardPath
                $questions = @()
                if ($cardObj.PSObject.Properties.Name -contains 'questions' -and $cardObj.questions) {
                  $questions = @($cardObj.questions)
                }
                $questions += $questionText
                $cardObj.updated = (Get-Date -Format 'yyyy-MM-dd')
                Write-ResearchCardJson $cardPath $cardObj $questions
              }

              Send-Json $response @{ created = $false; updated = $true; id = $id }
            } catch {
              Send-Json $response @{ error = 'persistence_failure'; message = $_.Exception.Message } 500
            }
          }
        }
      }
    }
    else {
      if ($localPath -eq '/') { $localPath = '/index.html' }
      $filePath = Join-Path $root ($localPath.TrimStart('/').Replace('/', '\'))
      if (Test-Path $filePath -PathType Leaf) {
        $bytes = [System.IO.File]::ReadAllBytes($filePath)
        $ext = [System.IO.Path]::GetExtension($filePath).ToLower()
        $contentType = switch ($ext) {
          '.html' { 'text/html; charset=utf-8' }
          '.css'  { 'text/css' }
          '.js'   { 'application/javascript' }
          '.json' { 'application/json' }
          default { 'application/octet-stream' }
        }
        $response.ContentType = $contentType
        if ($ext -eq '.html' -or $ext -eq '.js') {
          $response.Headers.Add('Cache-Control', 'no-cache')
        }
        $response.OutputStream.Write($bytes, 0, $bytes.Length)
      } else {
        $response.StatusCode = 404
        $msg = [System.Text.Encoding]::UTF8.GetBytes('Not Found')
        $response.OutputStream.Write($msg, 0, $msg.Length)
      }
    }
  } catch {
    $response.StatusCode = 500
    $msg = [System.Text.Encoding]::UTF8.GetBytes($_.Exception.Message)
    $response.OutputStream.Write($msg, 0, $msg.Length)
  }

  $response.Close()
}
