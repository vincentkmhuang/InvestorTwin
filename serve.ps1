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
  $reader = New-Object System.IO.StreamReader($request.InputStream, [System.Text.Encoding]::UTF8)
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

function Get-AllowedDecisionStances {
  return @('watch', 'pass', 'initiate', 'hold', 'reduce', 'exit', 'review')
}

function Test-IsJsonObject($value) {
  if ($null -eq $value) { return $false }
  return ($value -is [System.Management.Automation.PSObject] -or $value -is [System.Collections.IDictionary])
}

function Get-PersistedDecision($raw) {
  if (-not (Test-IsJsonObject $raw)) { return $null }
  $stance = ''
  if ($raw.PSObject.Properties['stance'] -and $raw.stance) { $stance = [string]$raw.stance }
  if ((Get-AllowedDecisionStances) -notcontains $stance) { return $null }

  $asOf = ''
  if ($raw.PSObject.Properties['asOf'] -and $null -ne $raw.asOf) { $asOf = [string]$raw.asOf }
  $reason = ''
  if ($raw.PSObject.Properties['reason'] -and $null -ne $raw.reason) { $reason = [string]$raw.reason }

  $researchIds = @()
  $supportingCount = $null
  $counterCount = $null
  $thesisStatus = $null
  $basedOnRaw = $null
  if ($raw.PSObject.Properties['basedOn']) { $basedOnRaw = $raw.basedOn }
  if (Test-IsJsonObject $basedOnRaw) {
    if ($basedOnRaw.PSObject.Properties['researchIds']) {
      $researchIds = @(Get-AsArray $basedOnRaw.researchIds)
    }
    if ($basedOnRaw.PSObject.Properties['supportingCount'] -and $null -ne $basedOnRaw.supportingCount -and $basedOnRaw.supportingCount -ne '') {
      try { $supportingCount = [int]$basedOnRaw.supportingCount } catch { $supportingCount = $null }
    }
    if ($basedOnRaw.PSObject.Properties['counterCount'] -and $null -ne $basedOnRaw.counterCount -and $basedOnRaw.counterCount -ne '') {
      try { $counterCount = [int]$basedOnRaw.counterCount } catch { $counterCount = $null }
    }
    if ($basedOnRaw.PSObject.Properties['thesisStatus'] -and $basedOnRaw.thesisStatus) {
      $thesisStatus = [string]$basedOnRaw.thesisStatus
    }
  }

  return [PSCustomObject]@{
    stance = $stance
    asOf = $asOf
    reason = $reason
    basedOn = [PSCustomObject]@{
      researchIds = $researchIds
      supportingCount = $supportingCount
      counterCount = $counterCount
      thesisStatus = $thesisStatus
    }
  }
}

function ConvertTo-DecisionJson($raw) {
  $decision = Get-PersistedDecision $raw
  if ($null -eq $decision) { return 'null' }
  $basedOn = $decision.basedOn
  return ('{"stance":' + (Get-JsonString $decision.stance) +
    ',"asOf":' + (Get-JsonString $decision.asOf) +
    ',"reason":' + (Get-JsonString $decision.reason) +
    ',"basedOn":{"researchIds":' + (ConvertTo-JsonArrayText (Get-AsArray $basedOn.researchIds)) +
    ',"supportingCount":' + (Get-JsonNullOrNumber $basedOn.supportingCount) +
    ',"counterCount":' + (Get-JsonNullOrNumber $basedOn.counterCount) +
    ',"thesisStatus":' + (Get-JsonNullOrString $basedOn.thesisStatus) + '}}')
}

function ConvertTo-DecisionHistoryJson($raw) {
  $list = Get-AsArray $raw
  if ($list.Count -eq 0) { return '[]' }
  $parts = foreach ($item in $list) {
    $json = ConvertTo-DecisionJson $item
    if ($json -ne 'null') { $json }
  }
  $kept = @($parts)
  if ($kept.Count -eq 0) { return '[]' }
  return '[' + ($kept -join ',') + ']'
}

function ConvertTo-PositionPlaybookJson($raw) {
  if (-not (Test-IsJsonObject $raw)) { return 'null' }
  $target = $null
  $initial = $null
  $add = $null
  if ($raw.PSObject.Properties['targetPosition'] -and $null -ne $raw.targetPosition -and $raw.targetPosition -ne '') {
    $target = $raw.targetPosition
  }
  if ($raw.PSObject.Properties['initialPosition'] -and $null -ne $raw.initialPosition -and $raw.initialPosition -ne '') {
    $initial = $raw.initialPosition
  }
  if ($raw.PSObject.Properties['addPosition'] -and $null -ne $raw.addPosition -and $raw.addPosition -ne '') {
    $add = $raw.addPosition
  }
  $entryTriggers = @()
  $addConditions = @()
  $exitConditions = @()
  if ($raw.PSObject.Properties['entryTriggers']) { $entryTriggers = @(Get-AsArray $raw.entryTriggers) }
  if ($raw.PSObject.Properties['addConditions']) { $addConditions = @(Get-AsArray $raw.addConditions) }
  if ($raw.PSObject.Properties['exitConditions']) { $exitConditions = @(Get-AsArray $raw.exitConditions) }
  $monitoringRaw = $null
  if (Test-HasJsonProperty $raw 'monitoringItems') { $monitoringRaw = $raw.monitoringItems }
  return ('{"targetPosition":' + (Get-JsonNullOrString $target) +
    ',"initialPosition":' + (Get-JsonNullOrString $initial) +
    ',"addPosition":' + (Get-JsonNullOrString $add) +
    ',"entryTriggers":' + (ConvertTo-JsonArrayText $entryTriggers) +
    ',"addConditions":' + (ConvertTo-JsonArrayText $addConditions) +
    ',"exitConditions":' + (ConvertTo-JsonArrayText $exitConditions) +
    ',"monitoringItems":' + (ConvertTo-MonitoringItemsJson $monitoringRaw) + '}')
}

function New-EmptyPositionPlaybook {
  return [PSCustomObject]@{
    targetPosition = $null
    initialPosition = $null
    addPosition = $null
    entryTriggers = @()
    addConditions = @()
    exitConditions = @()
    monitoringItems = @()
  }
}

function Get-PlaybookTextOrNull($value) {
  if ($null -eq $value -or $value -eq '') { return $null }
  $text = ([string]$value).Trim()
  if ([string]::IsNullOrWhiteSpace($text)) { return $null }
  return $text
}

function Get-PlaybookStringList($raw) {
  $result = @()
  foreach ($item in (Get-AsArray $raw)) {
    if ($null -eq $item -or $item -eq '') { continue }
    $text = ([string]$item).Trim()
    if (-not [string]::IsNullOrWhiteSpace($text)) {
      $result += $text
    }
  }
  return $result
}

function Test-HasJsonProperty($obj, $name) {
  if ($null -eq $obj) { return $false }
  if ($obj -is [System.Collections.IDictionary]) {
    return $obj.Contains($name)
  }
  return [bool]$obj.PSObject.Properties[$name]
}

function Get-ExistingPlaybookText($base, $name) {
  if (-not (Test-HasJsonProperty $base $name)) { return $null }
  return $base.$name
}

function Get-ExistingPlaybookList($base, $name) {
  if (-not (Test-HasJsonProperty $base $name)) { return @() }
  return @(Get-AsArray $base.$name)
}

function Merge-PlaybookTextField($base, $incoming, $name) {
  if (-not (Test-HasJsonProperty $incoming $name)) {
    return Get-ExistingPlaybookText $base $name
  }
  return Get-PlaybookTextOrNull $incoming.$name
}

function Merge-PlaybookListField($base, $incoming, $name) {
  if (-not (Test-HasJsonProperty $incoming $name)) {
    return @(Get-ExistingPlaybookList $base $name)
  }
  $raw = $incoming.$name
  if ($null -eq $raw) { return @() }
  return @(Get-PlaybookStringList $raw)
}

function Normalize-MonitoringItem($item) {
  if ($null -eq $item -or $item -eq '') { return $null }
  if (Test-IsJsonObject $item) {
    $text = Get-PlaybookTextOrNull $item.text
    if ($null -eq $text) { return $null }
    $researchId = $null
    if (Test-HasJsonProperty $item 'researchId') {
      $researchId = Get-PlaybookTextOrNull $item.researchId
    }
    return [PSCustomObject]@{
      text = $text
      researchId = $researchId
    }
  }
  return Get-PlaybookTextOrNull $item
}

function Get-MonitoringItemList($raw) {
  $items = New-Object System.Collections.Generic.List[object]
  if ($null -eq $raw) { return ,$items }
  if ($raw -is [string]) {
    [void]$items.Add($raw)
    return ,$items
  }
  # A 1-element JSON array is often unwrapped to a single object. If it has
  # `text`, it is one monitoring item — do not enumerate PSObject properties.
  if (Test-HasJsonProperty $raw 'text') {
    [void]$items.Add($raw)
    return ,$items
  }
  if ($raw -is [System.Collections.IDictionary]) {
    [void]$items.Add($raw)
    return ,$items
  }
  if ($raw -is [System.Collections.IEnumerable]) {
    $tmp = New-Object System.Collections.Generic.List[object]
    $allChars = $true
    foreach ($item in $raw) {
      if ($null -eq $item) { continue }
      if ($item -isnot [char]) { $allChars = $false }
      [void]$tmp.Add($item)
    }
    if ($allChars -and $tmp.Count -gt 0) {
      [void]$items.Add([string]$raw)
      return ,$items
    }
    foreach ($item in $tmp) { [void]$items.Add($item) }
    return ,$items
  }
  [void]$items.Add($raw)
  return ,$items
}

function Get-NormalizedMonitoringItems($raw) {
  $result = New-Object System.Collections.Generic.List[object]
  foreach ($item in (Get-MonitoringItemList $raw)) {
    $norm = Normalize-MonitoringItem $item
    if ($null -ne $norm) { [void]$result.Add($norm) }
  }
  return ,$result
}

function ConvertTo-MonitoringItemsJson($items) {
  $kept = New-Object System.Collections.Generic.List[string]
  foreach ($item in (Get-MonitoringItemList (Get-NormalizedMonitoringItems $items))) {
    if (Test-IsJsonObject $item) {
      [void]$kept.Add(('{"text":' + (Get-JsonString $item.text) + ',"researchId":' + (Get-JsonNullOrString $item.researchId) + '}'))
    } else {
      [void]$kept.Add((Get-JsonString $item))
    }
  }
  if ($kept.Count -eq 0) { return '[]' }
  return '[' + ($kept -join ',') + ']'
}

function Merge-PlaybookMonitoringItemsField($base, $incoming) {
  if (-not (Test-HasJsonProperty $incoming 'monitoringItems')) {
    $existing = $null
    if (Test-HasJsonProperty $base 'monitoringItems') { $existing = $base.monitoringItems }
    return Get-NormalizedMonitoringItems $existing
  }
  $raw = $incoming.monitoringItems
  if ($null -eq $raw) { return Get-NormalizedMonitoringItems @() }
  return Get-NormalizedMonitoringItems $raw
}

function Merge-PositionPlaybookFromEditor($existing, $incoming) {
  if (-not (Test-IsJsonObject $incoming)) { return $null }
  $base = if (Test-IsJsonObject $existing) { $existing } else { New-EmptyPositionPlaybook }

  return [PSCustomObject]@{
    targetPosition = Merge-PlaybookTextField $base $incoming 'targetPosition'
    initialPosition = Merge-PlaybookTextField $base $incoming 'initialPosition'
    addPosition = Merge-PlaybookTextField $base $incoming 'addPosition'
    entryTriggers = Merge-PlaybookListField $base $incoming 'entryTriggers'
    addConditions = Merge-PlaybookListField $base $incoming 'addConditions'
    exitConditions = Merge-PlaybookListField $base $incoming 'exitConditions'
    monitoringItems = Merge-PlaybookMonitoringItemsField $base $incoming
  }
}

function Test-EvidenceDuplicate($items, $text, $researchId) {
  foreach ($item in (Get-AsArray $items)) {
    if (([string]$item.text) -eq $text -and ([string]$item.researchId) -eq $researchId) {
      return $true
    }
  }
  return $false
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

function Get-CaseThesisId($caseObj) {
  if (-not (Test-HasJsonProperty $caseObj 'thesisId')) { return $null }
  $raw = $caseObj.thesisId
  if ($null -eq $raw -or $raw -eq '') { return $null }
  if (Test-IsJsonObject $raw) { return $null }
  if ($raw -is [System.Collections.IEnumerable] -and $raw -isnot [string]) { return $null }
  $text = ([string]$raw).Trim()
  if ([string]::IsNullOrWhiteSpace($text)) { return $null }
  return $text
}

function Resolve-CaseThesisId($rootPath, $caseObj) {
  if (Test-HasJsonProperty $caseObj 'thesisId') {
    $raw = $caseObj.thesisId
    if ($null -ne $raw) {
      if (Test-IsJsonObject $raw) {
        return @{ ok = $false; value = $null; message = 'thesisId must be a string or null' }
      }
      if ($raw -is [System.Collections.IEnumerable] -and $raw -isnot [string]) {
        return @{ ok = $false; value = $null; message = 'thesisId must be a string or null' }
      }
    }
  }
  $thesisId = Get-CaseThesisId $caseObj
  if ($null -eq $thesisId) {
    return @{ ok = $true; value = $null; message = $null }
  }
  if ($thesisId -match '[\\/]' -or $thesisId -eq '.' -or $thesisId -eq '..') {
    return @{ ok = $false; value = $null; message = 'thesisId is invalid' }
  }
  $path = Join-Path $rootPath ('data\theses\' + $thesisId + '.json')
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    return @{ ok = $false; value = $null; message = 'thesisId does not match an existing Thesis' }
  }
  return @{ ok = $true; value = $thesisId; message = $null }
}

function Get-ThesesDir($rootPath) {
  return (Join-Path $rootPath 'data\theses')
}

function Get-ThesisFilePath($rootPath, $thesisId) {
  return (Join-Path (Get-ThesesDir $rootPath) ($thesisId + '.json'))
}

function Test-ValidThesisId($thesisId) {
  if ([string]::IsNullOrWhiteSpace($thesisId)) { return $false }
  if ($thesisId -match '[\\/]' -or $thesisId -eq '.' -or $thesisId -eq '..') { return $false }
  if ($thesisId -eq 'schema') { return $false }
  return [bool]($thesisId -match '^[A-Za-z0-9][A-Za-z0-9_-]*$')
}

function Read-ThesisFile($rootPath, $thesisId) {
  if (-not (Test-ValidThesisId $thesisId)) { return $null }
  $path = Get-ThesisFilePath $rootPath $thesisId
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
  return Read-Utf8Json $path
}

function ConvertTo-ThesisJson($thesisObj) {
  $parts = @(
    '"thesisId":' + (Get-JsonString $thesisObj.thesisId)
    '"type":' + (Get-JsonString $thesisObj.type)
    '"title":' + (Get-JsonString $thesisObj.title)
    '"subject":' + (Get-JsonString $thesisObj.subject)
    '"thesis":' + (Get-JsonString $thesisObj.thesis)
    '"rationale":' + (Get-JsonString $thesisObj.rationale)
    '"supportingEvidence":' + (ConvertTo-JsonArrayText @(Get-AsArray $thesisObj.supportingEvidence))
    '"contradictingEvidence":' + (ConvertTo-JsonArrayText @(Get-AsArray $thesisObj.contradictingEvidence))
    '"keyIndicators":' + (ConvertTo-JsonArrayText @(Get-AsArray $thesisObj.keyIndicators))
    '"invalidationConditions":' + (ConvertTo-JsonArrayText @(Get-AsArray $thesisObj.invalidationConditions))
    '"status":' + (Get-JsonString $thesisObj.status)
    '"confidence":' + (Get-JsonString $thesisObj.confidence)
    '"linkedResearch":' + (ConvertTo-JsonArrayText @(Get-AsArray $thesisObj.linkedResearch))
    '"linkedDecision":' + (Get-JsonNullOrString $thesisObj.linkedDecision)
    '"updatedAt":' + (Get-JsonString $thesisObj.updatedAt)
  )
  return '{' + ($parts -join ',') + '}'
}

function Write-ThesisFile($rootPath, $thesisObj) {
  $thesisId = [string]$thesisObj.thesisId
  $path = Get-ThesisFilePath $rootPath $thesisId
  Write-Utf8Text $path (ConvertTo-ThesisJson $thesisObj)
}

function Get-ThesisList($rootPath) {
  $dir = Get-ThesesDir $rootPath
  $items = New-Object System.Collections.Generic.List[object]
  if (-not (Test-Path -LiteralPath $dir)) { return @() }
  $files = @(Get-ChildItem -LiteralPath $dir -Filter '*.json' | Where-Object { $_.BaseName -ne 'schema' })
  foreach ($file in $files) {
    try {
      $obj = Read-Utf8Json $file.FullName
      if ($null -eq $obj) { continue }
      if (-not (Test-HasJsonProperty $obj 'thesisId') -and -not $file.BaseName) { continue }
      $id = if ($obj.PSObject.Properties['thesisId'] -and $obj.thesisId) { [string]$obj.thesisId } else { $file.BaseName }
      $linked = @()
      foreach ($ref in @(Get-AsArray $obj.linkedResearch)) {
        if ($ref -and $ref.researchId) {
          $linked += [PSCustomObject]@{ researchId = [string]$ref.researchId }
        }
      }
      [void]$items.Add([PSCustomObject]@{
        thesisId = $id
        title = [string]$obj.title
        thesis = [string]$obj.thesis
        status = [string]$obj.status
        linkedResearch = $linked
        linkedDecision = $(if ($null -eq $obj.linkedDecision -or $obj.linkedDecision -eq '') { $null } else { [string]$obj.linkedDecision })
      })
    } catch {
      continue
    }
  }
  return @($items.ToArray())
}

function Get-CardThesisId($cardObj) {
  if (-not (Test-HasJsonProperty $cardObj 'thesisId')) { return $null }
  $raw = $cardObj.thesisId
  if ($null -eq $raw -or $raw -eq '') { return $null }
  $text = ([string]$raw).Trim()
  if ([string]::IsNullOrWhiteSpace($text)) { return $null }
  return $text
}

function Add-ThesisLinkedResearch($rootPath, $thesisId, $researchId) {
  $thesis = Read-ThesisFile $rootPath $thesisId
  if (-not $thesis) { return $false }
  $statusBefore = [string]$thesis.status
  $refs = @(Get-AsArray $thesis.linkedResearch)
  $exists = $false
  foreach ($ref in $refs) {
    if ($ref -and [string]$ref.researchId -eq $researchId) { $exists = $true; break }
  }
  if ($exists) { return $true }
  $refs = @($refs + @([PSCustomObject]@{ researchId = $researchId }))
  $thesis | Add-Member -NotePropertyName linkedResearch -NotePropertyValue $refs -Force
  $thesis | Add-Member -NotePropertyName status -NotePropertyValue $statusBefore -Force
  Write-ThesisFile $rootPath $thesis
  $after = Read-ThesisFile $rootPath $thesisId
  return ([string]$after.status -eq $statusBefore)
}

function Set-CardThesisId($rootPath, $researchId, $thesisId) {
  $cardPath = Join-Path $rootPath ("research\" + $researchId + "\card.json")
  if (-not (Test-Path -LiteralPath $cardPath -PathType Leaf)) { return $false }
  $card = Read-Utf8Json $cardPath
  $questions = @(Get-AsArray $card.questions)
  $card | Add-Member -NotePropertyName thesisId -NotePropertyValue $thesisId -Force
  Write-ResearchCardJson $cardPath $card $questions
  return $true
}

function New-ThesisRecord($thesisId, $title, $thesisText, $researchId) {
  $today = Get-Date -Format 'yyyy-MM-dd'
  $linked = @()
  if ($researchId) {
    $linked = @([PSCustomObject]@{ researchId = $researchId })
  }
  return [PSCustomObject]@{
    thesisId = $thesisId
    type = 'industry'
    title = $title
    subject = $title
    thesis = $thesisText
    rationale = ''
    supportingEvidence = @()
    contradictingEvidence = @()
    keyIndicators = @('To be filled during Thesis Review')
    invalidationConditions = @('To be filled during Thesis Review')
    status = 'under_review'
    confidence = 'medium'
    linkedResearch = $linked
    linkedDecision = $null
    updatedAt = $today
  }
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
    '"thesisId":' + (Get-JsonNullOrString (Get-CaseThesisId $caseObj))
    '"thesis":{"thesis":' + (Get-JsonString $thesis.thesis) + ',"growthDrivers":' + (ConvertTo-JsonArrayText (Get-AsArray $thesis.growthDrivers)) + ',"competitiveAdvantage":' + (Get-JsonString $thesis.competitiveAdvantage) + ',"earningsTranslation":' + (Get-JsonString $thesis.earningsTranslation) + ',"duration":' + (Get-JsonString $thesis.duration) + ',"supportingEvidence":' + (ConvertTo-EvidenceJson $thesis.supportingEvidence) + ',"counterEvidence":' + (ConvertTo-EvidenceJson $thesis.counterEvidence) + ',"toBeVerified":' + (ConvertTo-EvidenceJson $thesis.toBeVerified) + ',"killCriteria":' + (ConvertTo-JsonArrayText (Get-AsArray $thesis.killCriteria)) + ',"status":' + (Get-JsonString $thesis.status) + '}'
    '"valuationProfile":{"companyType":' + (Get-JsonNullOrString $profile.companyType) + ',"primaryMethod":' + (Get-JsonNullOrString $profile.primaryMethod) + ',"secondaryMethod":' + (Get-JsonNullOrString $profile.secondaryMethod) + ',"crossCheckMethod":' + (Get-JsonNullOrString $profile.crossCheckMethod) + ',"userConfirmed":' + $(if ($confirmed) { 'true' } else { 'false' }) + '}'
    '"valuation":{"bear":' + (Get-JsonNullOrNumber $val.bear) + ',"base":' + (Get-JsonNullOrNumber $val.base) + ',"bull":' + (Get-JsonNullOrNumber $val.bull) + ',"marginOfSafety":' + (Get-JsonNullOrNumber $val.marginOfSafety) + ',"buyUnder":' + (Get-JsonNullOrNumber $val.buyUnder) + ',"currentPrice":null,"currentDiscount":null,"methodInputs":' + (ConvertTo-MethodInputsJson $val.methodInputs) + ',"methodFairValues":' + (ConvertTo-MethodFairValuesJson $val.methodFairValues) + '}'
    '"decision":' + (ConvertTo-DecisionJson $caseObj.decision)
    '"decisionHistory":' + (ConvertTo-DecisionHistoryJson $caseObj.decisionHistory)
    '"positionPlaybook":' + (ConvertTo-PositionPlaybookJson $caseObj.positionPlaybook)
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

function Get-RequiredTriggerString($obj, $name) {
  if (-not (Test-HasJsonProperty $obj $name)) { return $null }
  $raw = $obj.$name
  if ($null -eq $raw) { return $null }
  if (Test-IsJsonObject $raw) { return $null }
  if ($raw -is [System.Collections.IEnumerable] -and $raw -isnot [string]) { return $null }
  return Get-PlaybookTextOrNull $raw
}

function Read-ResearchQueue($rootPath) {
  $queuePath = Join-Path $rootPath 'data\research-queue.json'
  $queue = Get-Content $queuePath -Raw | ConvertFrom-Json
  if (-not $queue) {
    return [PSCustomObject]@{ items = @() }
  }
  if (-not (Test-HasJsonProperty $queue 'items')) {
    $queue | Add-Member -NotePropertyName items -NotePropertyValue @() -Force
  }
  return $queue
}

function Write-ResearchQueue($rootPath, $queue) {
  $queuePath = Join-Path $rootPath 'data\research-queue.json'
  $queue | ConvertTo-Json -Depth 10 | Set-Content $queuePath -Encoding UTF8
}

function Get-LatestEvidenceItems($rootPath) {
  $map = @{}
  $candidates = @()

  $historyRoot = Join-Path $rootPath 'data\evidence\history'
  if (Test-Path -LiteralPath $historyRoot) {
    foreach ($instDir in @(Get-ChildItem -LiteralPath $historyRoot -Directory -ErrorAction SilentlyContinue)) {
      $latest = @(Get-ChildItem -LiteralPath $instDir.FullName -Filter '*.json' -ErrorAction SilentlyContinue |
        Sort-Object BaseName -Descending |
        Select-Object -First 1)[0]
      if ($latest) {
        $candidates += [PSCustomObject]@{ File = $latest; Instrument = $instDir.Name; Rank = 2 }
      }
    }
  }

  $runsRoot = Join-Path $rootPath 'data\evidence\runs'
  if (Test-Path -LiteralPath $runsRoot) {
    $run = @(Get-ChildItem -LiteralPath $runsRoot -Directory -ErrorAction SilentlyContinue |
      Sort-Object Name -Descending |
      Select-Object -First 1)[0]
    if ($run) {
      $norm = Join-Path $run.FullName 'normalized'
      if (Test-Path -LiteralPath $norm) {
        foreach ($file in @(Get-ChildItem -LiteralPath $norm -Filter '*.json' -ErrorAction SilentlyContinue)) {
          $candidates += [PSCustomObject]@{ File = $file; Instrument = $file.BaseName; Rank = 1 }
        }
      }
    }
  }

  $pathSeps = [char[]]@(
    [System.IO.Path]::DirectorySeparatorChar,
    [System.IO.Path]::AltDirectorySeparatorChar
  )
  $rootFull = [System.IO.Path]::GetFullPath($rootPath).TrimEnd($pathSeps)
  foreach ($candidate in @($candidates)) {
    $file = @($candidate.File)[0]
    if (-not $file) { continue }
    $instrument = [string]$candidate.Instrument
    $rank = [int]$candidate.Rank
    $obj = $null
    try { $obj = Read-Utf8Json $file.FullName } catch { continue }
    if ($obj -and $obj.instrument) { $instrument = [string]$obj.instrument }
    if (-not $instrument) { continue }
    $asOf = ''
    if ($obj -and $obj.asOf) {
      $asOf = [string]$obj.asOf
    } elseif ($file.BaseName -match '^\d{4}-\d{2}-\d{2}$') {
      $asOf = $file.BaseName
    } elseif ($obj -and $obj.expectedAsOf) {
      $asOf = [string]$obj.expectedAsOf
    }
    $status = 'fresh'
    if ($obj -and $obj.status) { $status = [string]$obj.status }
    $sourceId = $null
    if ($obj -and $obj.sourceId) { $sourceId = [string]$obj.sourceId }
    $itemFull = [System.IO.Path]::GetFullPath([string]$file.FullName)
    $rel = $itemFull
    if ($itemFull.Length -gt $rootFull.Length -and $itemFull.Substring(0, $rootFull.Length).ToLowerInvariant() -eq $rootFull.ToLowerInvariant()) {
      $rel = $itemFull.Substring($rootFull.Length).TrimStart($pathSeps)
    }
    $rel = ([string]$rel).Replace('\', '/')
    $item = [PSCustomObject]@{
      instrument = $instrument
      asOf = $asOf
      status = $status
      sourceId = $sourceId
      evidencePath = $rel
      writesBrief = $false
      rank = $rank
    }
    $existing = $map[$instrument]
    if (-not $existing) {
      $map[$instrument] = $item
    } elseif ($rank -gt [int]$existing.rank) {
      $map[$instrument] = $item
    } elseif ($rank -eq [int]$existing.rank -and [string]$asOf -gt [string]$existing.asOf) {
      $map[$instrument] = $item
    }
  }

  $items = @()
  foreach ($key in @($map.Keys)) {
    $row = $map[$key]
    $items += [PSCustomObject]@{
      instrument = [string]$row.instrument
      asOf = [string]$row.asOf
      status = [string]$row.status
      sourceId = $(if ($null -eq $row.sourceId) { $null } else { [string]$row.sourceId })
      path = [string]$row.evidencePath
      writesBrief = $false
    }
  }
  return $items
}

function Ensure-QueueItem($rootPath, $id, $addedFrom) {
  $queue = Read-ResearchQueue $rootPath
  $added = $false
  if ($id -and -not ($queue.items | Where-Object { $_.id -eq $id })) {
    $queue.items += [PSCustomObject]@{ id = $id; addedFrom = $addedFrom }
    Write-ResearchQueue $rootPath $queue
    $added = $true
  }
  return @{ added = $added; items = $queue.items }
}

function Add-ResearchNoteAndQuestion($rootPath, $id, $noteText, $questionText) {
  $dir = Join-Path $rootPath ("research\" + $id)
  if (-not (Test-Path $dir)) { return $false }

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
  return $true
}

function Invoke-MonitoringTriggerRequest($rootPath, $response, $body) {
  $trigger = $body.monitoringTrigger
  if (-not (Test-IsJsonObject $trigger)) {
    Send-Json $response @{ error = 'invalid_payload'; message = 'monitoringTrigger must be an object' } 400
    return
  }

  $text = Get-RequiredTriggerString $trigger 'text'
  $researchId = Get-RequiredTriggerString $trigger 'researchId'
  if ($null -eq $text -or $null -eq $researchId) {
    Send-Json $response @{ error = 'invalid_payload'; message = 'monitoringTrigger text and researchId are required' } 400
    return
  }
  if ($researchId -match '[\\/]' -or $researchId -eq '.' -or $researchId -eq '..') {
    Send-Json $response @{ error = 'invalid_payload'; message = 'monitoringTrigger researchId is invalid' } 400
    return
  }

  try {
    $queueResult = Ensure-QueueItem $rootPath $researchId 'Monitoring'
    if (-not $queueResult.added) {
      $noteText = 'needs re-research: ' + $text
      Add-ResearchNoteAndQuestion $rootPath $researchId $noteText $text
    }
    Send-Json $response @{
      updated = $true
      id = $researchId
      added = [bool]$queueResult.added
    }
  } catch {
    Send-Json $response @{ error = 'persistence_failure'; message = $_.Exception.Message } 500
  }
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
    elseif ($localPath -eq '/api/theses' -and $method -eq 'GET') {
      Send-Json $response ([PSCustomObject]@{ items = @(Get-ThesisList $root) })
    }
    elseif (($localPath -eq '/api/evidence' -or $localPath -eq '/api/evidence/latest') -and $method -eq 'GET') {
      $evidenceItems = @(Get-LatestEvidenceItems $root)
      $response.StatusCode = 200
      $response.ContentType = 'application/json; charset=utf-8'
      $payload = '{"writesBrief":false,"layer":"evidence","items":' + (ConvertTo-JsonArrayText $evidenceItems) + '}'
      $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
      $response.OutputStream.Write($bytes, 0, $bytes.Length)
    }
    elseif ($localPath -eq '/api/theses' -and $method -eq 'POST') {
      $body = Read-Body $request
      $thesisId = if ($body -and $body.thesisId) { ([string]$body.thesisId).Trim() } else { '' }
      $title = if ($body -and $body.title) { ([string]$body.title).Trim() } else { '' }
      $thesisText = if ($body -and $body.thesis) { ([string]$body.thesis).Trim() } else { '' }
      $researchId = if ($body -and $body.researchId) { ([string]$body.researchId).Trim() } else { '' }
      if (-not (Test-ValidThesisId $thesisId)) {
        Send-Json $response @{ error = 'invalid_payload'; message = 'thesisId is invalid' } 400
      } elseif (-not $title -or -not $thesisText) {
        Send-Json $response @{ error = 'invalid_payload'; message = 'title and thesis are required' } 400
      } elseif ($researchId -and ($researchId -match '[\\/]' -or $researchId -eq '.' -or $researchId -eq '..')) {
        Send-Json $response @{ error = 'invalid_payload'; message = 'researchId is invalid' } 400
      } elseif ($researchId -and -not (Test-Path -LiteralPath (Join-Path $root ("research\" + $researchId + "\card.json")) -PathType Leaf)) {
        Send-Json $response @{ error = 'invalid_payload'; message = 'researchId does not match an existing Research Card' } 400
      } elseif (Test-Path -LiteralPath (Get-ThesisFilePath $root $thesisId) -PathType Leaf) {
        Send-Json $response @{ error = 'invalid_payload'; message = 'thesisId already exists' } 400
      } else {
        if (-not $researchId) { $researchId = $null }
        # Client-supplied status is ignored. Create is always under_review.
        $record = New-ThesisRecord $thesisId $title $thesisText $researchId
        Write-ThesisFile $root $record
        if ($researchId) {
          Set-CardThesisId $root $researchId $thesisId | Out-Null
        }
        $written = Read-ThesisFile $root $thesisId
        Send-Json $response @{
          created = $true
          thesisId = $thesisId
          status = [string]$written.status
          researchId = $researchId
        }
      }
    }
    elseif ($localPath -eq '/api/queue' -and $method -eq 'POST') {
      $body = Read-Body $request
      $id = if ($body -and $body.id) { $body.id } else { $null }
      $addedFrom = if ($body -and $body.addedFrom) { $body.addedFrom } else { $null }
      $result = Ensure-QueueItem $root $id $addedFrom
      Send-Json $response @{ added = $result.added; items = $result.items }
    }
    elseif ($localPath -eq '/api/cases' -and $method -eq 'POST') {
      $body = Read-Body $request
      if ($body -and (Test-HasJsonProperty $body 'monitoringTrigger')) {
        Invoke-MonitoringTriggerRequest $root $response $body
      } else {
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
            $thesisIdResult = Resolve-CaseThesisId $root $caseObj
            if (-not $thesisIdResult.ok) {
              Send-Json $response @{ error = 'invalid_payload'; message = $thesisIdResult.message } 400
            } else {
              $caseObj | Add-Member -NotePropertyName thesisId -NotePropertyValue $thesisIdResult.value -Force
              $caseObj | Add-Member -NotePropertyName decision -NotePropertyValue $null -Force
              $caseObj | Add-Member -NotePropertyName decisionHistory -NotePropertyValue @() -Force
              if (-not (Test-IsJsonObject $caseObj.positionPlaybook)) {
                $caseObj | Add-Member -NotePropertyName positionPlaybook -NotePropertyValue $null -Force
              }
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
      } elseif ($body -and $body.id -and (Test-HasJsonProperty $body 'thesisId') -and -not (Test-HasJsonProperty $body 'case') -and -not (Test-HasJsonProperty $body 'decision') -and -not (Test-HasJsonProperty $body 'positionPlaybook') -and -not (Test-HasJsonProperty $body 'thesisEvidence') -and -not (Test-HasJsonProperty $body 'marginOfSafety') -and -not (Test-HasJsonProperty $body 'methodInput') -and -not (Test-HasJsonProperty $body 'companyType') -and -not (Test-HasJsonProperty $body 'confirmValuationProfile') -and -not (Test-HasJsonProperty $body 'monitoringTrigger')) {
        $id = [string]$body.id
        $target = @($store.cases | Where-Object { $_.id -eq $id } | Select-Object -First 1)
        if ($target.Count -eq 0) {
          Send-Json $response @{ error = 'not_found'; message = 'Investment Case not found' } 404
        } else {
          $caseObj = $target[0]
          $probe = [PSCustomObject]@{ thesisId = $body.thesisId }
          $thesisIdResult = Resolve-CaseThesisId $root $probe
          if (-not $thesisIdResult.ok) {
            Send-Json $response @{ error = 'invalid_payload'; message = $thesisIdResult.message } 400
          } elseif ($null -eq $thesisIdResult.value) {
            Send-Json $response @{ error = 'invalid_payload'; message = 'thesisId is required to link a Thesis' } 400
          } else {
            $caseObj | Add-Member -NotePropertyName thesisId -NotePropertyValue $thesisIdResult.value -Force
            if ($caseObj.origin) { $caseObj.origin.updatedAt = $today }
            $store.updated = $today
            Write-InvestmentCasesFile $casesPath $store
            Send-Json $response @{
              updated = $true
              id = $id
              thesisId = $thesisIdResult.value
            }
          }
        }
      } elseif ($body -and $body.id -and $body.thesisEvidence) {
        $id = [string]$body.id
        $target = @($store.cases | Where-Object { $_.id -eq $id } | Select-Object -First 1)
        $ev = $body.thesisEvidence
        $side = if ($ev.side) { ([string]$ev.side).Trim() } else { '' }
        $text = if ($null -eq $ev.text) { '' } else { ([string]$ev.text).Trim() }
        $researchId = if ($null -eq $ev.researchId) { '' } else { ([string]$ev.researchId).Trim() }
        if ($target.Count -eq 0) {
          Send-Json $response @{ error = 'not_found'; message = 'Investment Case not found' } 404
        } elseif ($side -ne 'supporting' -and $side -ne 'counter') {
          Send-Json $response @{ error = 'invalid_payload'; message = 'thesisEvidence.side must be supporting or counter' } 400
        } elseif ([string]::IsNullOrWhiteSpace($text) -or [string]::IsNullOrWhiteSpace($researchId)) {
          Send-Json $response @{ error = 'invalid_payload'; message = 'thesisEvidence text and researchId are required' } 400
        } else {
          $caseObj = $target[0]
          $linked = @(Get-AsArray $caseObj.researchIds)
          if ($linked -notcontains $researchId) {
            Send-Json $response @{ error = 'invalid_payload'; message = 'Research Card is not linked to this Investment Case' } 400
          } elseif (-not $caseObj.thesis) {
            Send-Json $response @{ error = 'invalid_payload'; message = 'Investment Case thesis is missing' } 400
          } else {
            $thesis = $caseObj.thesis
            $supporting = @(Get-AsArray $thesis.supportingEvidence)
            $counter = @(Get-AsArray $thesis.counterEvidence)
            $isDup = (Test-EvidenceDuplicate $supporting $text $researchId) -or (Test-EvidenceDuplicate $counter $text $researchId)
            if ($isDup) {
              Send-Json $response @{ updated = $false; duplicate = $true; id = $id }
            } else {
              $entry = [PSCustomObject]@{ text = $text; researchId = $researchId }
              if ($side -eq 'supporting') {
                $thesis.supportingEvidence = @($supporting + $entry)
              } else {
                $thesis.counterEvidence = @($counter + $entry)
              }
              if ($caseObj.origin) { $caseObj.origin.updatedAt = $today }
              $store.updated = $today
              Write-InvestmentCasesFile $casesPath $store
              Send-Json $response @{
                updated = $true
                duplicate = $false
                id = $id
                side = $side
              }
            }
          }
        }
      } elseif ($body -and $body.id -and ($body.PSObject.Properties.Name -contains 'decision')) {
        $id = [string]$body.id
        $target = @($store.cases | Where-Object { $_.id -eq $id } | Select-Object -First 1)
        $incoming = $body.decision
        $stance = if ((Test-IsJsonObject $incoming) -and $incoming.stance) { [string]$incoming.stance } else { '' }
        $reason = if ((Test-IsJsonObject $incoming) -and $null -ne $incoming.reason) { ([string]$incoming.reason).Trim() } else { '' }
        if ($target.Count -eq 0) {
          Send-Json $response @{ error = 'not_found'; message = 'Investment Case not found' } 404
        } elseif ((Get-AllowedDecisionStances) -notcontains $stance) {
          Send-Json $response @{ error = 'invalid_payload'; message = 'decision.stance is invalid' } 400
        } elseif ([string]::IsNullOrWhiteSpace($reason)) {
          Send-Json $response @{ error = 'invalid_payload'; message = 'decision.reason is required' } 400
        } else {
          $caseObj = $target[0]
          if ($incoming.reason -ne $reason) { $incoming.reason = $reason }
          if (-not $incoming.asOf) { $incoming | Add-Member -NotePropertyName asOf -NotePropertyValue $today -Force }
          $normalized = Get-PersistedDecision $incoming
          if ($null -eq $normalized) {
            Send-Json $response @{ error = 'invalid_payload'; message = 'decision is invalid' } 400
          } else {
            $old = Get-PersistedDecision $caseObj.decision
            if ($old) {
              $history = @(Get-AsArray $caseObj.decisionHistory)
              $caseObj | Add-Member -NotePropertyName decisionHistory -NotePropertyValue (@($history + $old)) -Force
            } elseif (-not $caseObj.PSObject.Properties['decisionHistory']) {
              $caseObj | Add-Member -NotePropertyName decisionHistory -NotePropertyValue @() -Force
            }
            $caseObj | Add-Member -NotePropertyName decision -NotePropertyValue $normalized -Force
            if ($caseObj.origin) { $caseObj.origin.updatedAt = $today }
            $store.updated = $today
            Write-InvestmentCasesFile $casesPath $store
            Send-Json $response @{
              updated = $true
              id = $id
              stance = $normalized.stance
            }
          }
        }
      } elseif ($body -and $body.id -and ($body.PSObject.Properties.Name -contains 'positionPlaybook')) {
        $id = [string]$body.id
        $target = @($store.cases | Where-Object { $_.id -eq $id } | Select-Object -First 1)
        $incoming = $body.positionPlaybook
        if ($target.Count -eq 0) {
          Send-Json $response @{ error = 'not_found'; message = 'Investment Case not found' } 404
        } elseif (-not (Test-IsJsonObject $incoming)) {
          Send-Json $response @{ error = 'invalid_payload'; message = 'positionPlaybook must be an object' } 400
        } else {
          $caseObj = $target[0]
          $merged = Merge-PositionPlaybookFromEditor $caseObj.positionPlaybook $incoming
          $caseObj | Add-Member -NotePropertyName positionPlaybook -NotePropertyValue $merged -Force
          if ($caseObj.origin) { $caseObj.origin.updatedAt = $today }
          $store.updated = $today
          Write-InvestmentCasesFile $casesPath $store
          Send-Json $response @{
            updated = $true
            id = $id
          }
        }
      } else {
        Send-Json $response @{ error = 'invalid_payload'; message = 'case, companyType, confirmValuationProfile, methodInput, marginOfSafety, thesisEvidence, thesisId, decision, positionPlaybook, or monitoringTrigger is required' } 400
      }
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
          $hasThesisId = $body -and (Test-HasJsonProperty $body 'thesisId')
          $incomingThesisId = $null
          if ($hasThesisId) {
            $incomingThesisId = if ($null -eq $body.thesisId) { '' } else { ([string]$body.thesisId).Trim() }
          }

          if ($hasThesisId -and $noteText) {
            Send-Json $response @{ error = 'invalid_payload'; message = 'send thesisId or appendNote, not both' } 400
          } elseif ($hasThesisId) {
            if (-not (Test-ValidThesisId $incomingThesisId)) {
              Send-Json $response @{ error = 'invalid_payload'; message = 'thesisId is invalid' } 400
            } elseif (-not (Read-ThesisFile $root $incomingThesisId)) {
              Send-Json $response @{ error = 'invalid_payload'; message = 'thesisId does not match an existing Thesis' } 400
            } else {
              Set-CardThesisId $root $id $incomingThesisId | Out-Null
              Add-ThesisLinkedResearch $root $incomingThesisId $id | Out-Null
              $writtenCard = Read-Utf8Json (Join-Path $dir 'card.json')
              $writtenThesis = Read-ThesisFile $root $incomingThesisId
              Send-Json $response @{
                created = $false
                updated = $true
                id = $id
                thesisId = (Get-CardThesisId $writtenCard)
                thesisStatus = [string]$writtenThesis.status
              }
            }
          } elseif (-not $noteText) {
            Send-Json $response @{ error = 'invalid_payload'; message = 'appendNote/note text is required for update' } 400
          } else {
            try {
              Add-ResearchNoteAndQuestion $root $id $noteText $questionText
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
