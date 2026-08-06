$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add('http://localhost:8765/')
$listener.Start()
Write-Output 'Serving HTTP on http://localhost:8765/'
while ($listener.IsListening) {
  $context = $listener.GetContext()
  $request = $context.Request
  $response = $context.Response
  $localPath = $request.Url.LocalPath
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
  $response.Close()
}
