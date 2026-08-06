$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$port = 8765
$myPid = $PID
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.ProcessId -ne $myPid -and $_.CommandLine -like "*serve.ps1*" } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 1

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$port/")
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
    elseif ($localPath -match '^/api/research/(.+)$' -and $method -eq 'POST') {
      $id = $Matches[1]
      $dir = Join-Path $root ("research\" + $id)
      $created = $false
      if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $body = Read-Body $request
        $card = if ($body.card) { $body.card } else {
          [PSCustomObject]@{
            id = $id; title = $id; summary = ''; investmentThesis = ''
            questions = @(); status = 'researching'; updated = (Get-Date -Format 'yyyy-MM-dd')
          }
        }
        $card | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $dir 'card.json') -Encoding UTF8
        '[]' | Set-Content (Join-Path $dir 'notes.json') -Encoding UTF8
        '[]' | Set-Content (Join-Path $dir 'timeline.json') -Encoding UTF8
        '[]' | Set-Content (Join-Path $dir 'sources.json') -Encoding UTF8
        $created = $true
      }
      Send-Json $response @{ created = $created; id = $id }
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
