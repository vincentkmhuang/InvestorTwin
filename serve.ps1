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
