param(
  [string]$RootPath = (Split-Path -Parent $PSScriptRoot)
)

function Update-KnowledgeIndex {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RootPath
  )

  $tagMap = @{}
  $cardIds = [System.Collections.Generic.HashSet[string]]::new([string[]]@(), [System.StringComparer]::Ordinal)
  $researchPath = Join-Path $RootPath 'research'

  if (-not (Test-Path $researchPath)) {
    Write-Warning "Research path not found: $researchPath"
    return $null
  }

  Get-ChildItem -Path $researchPath -Directory | ForEach-Object {
    $cardPath = Join-Path $_.FullName 'card.json'
    if (-not (Test-Path $cardPath)) { return }

    $card = Get-Content $cardPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $id = if ($card.id) { [string]$card.id } else { $_.Name }
    if (-not [string]::IsNullOrWhiteSpace($id)) {
      [void]$cardIds.Add($id)
    }

    if (-not $card.tags -or @($card.tags).Count -eq 0) { return }

    $seenTags = @{}
    foreach ($tag in @($card.tags)) {
      $tagKey = [string]$tag
      if ([string]::IsNullOrWhiteSpace($tagKey) -or $seenTags.ContainsKey($tagKey)) { continue }
      $seenTags[$tagKey] = $true

      if (-not $tagMap.ContainsKey($tagKey)) {
        $tagMap[$tagKey] = [System.Collections.Generic.HashSet[string]]::new([string[]]@(), [System.StringComparer]::Ordinal)
      }
      [void]$tagMap[$tagKey].Add($id)
    }
  }

  $sortedTags = [ordered]@{}
  foreach ($tag in ($tagMap.Keys | Sort-Object)) {
    $sortedTags[$tag] = @($tagMap[$tag] | Sort-Object)
  }

  $index = [ordered]@{
    generatedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    tags = $sortedTags
    cardIds = @($cardIds | Sort-Object)
  }

  $indexPath = Join-Path $RootPath 'data\knowledge-index.json'
  $json = $index | ConvertTo-Json -Depth 10
  [System.IO.File]::WriteAllText($indexPath, $json, [System.Text.UTF8Encoding]::new($false))
  return $index
}

if ($MyInvocation.InvocationName -ne '.') {
  $result = Update-KnowledgeIndex -RootPath $RootPath
  if ($result) {
    Write-Output "Knowledge index written to data/knowledge-index.json"
  }
}
