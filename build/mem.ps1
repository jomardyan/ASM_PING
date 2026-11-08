param(
  [string]$exePath = (Join-Path $PSScriptRoot '..\ping.exe'),
  [ValidateRange(1, 1000)][int]$runs = 5,
  [string[]]$ArgumentList = @('-n', '2', '127.0.0.1')
)
$ErrorActionPreference = 'Stop'
$resolvedExe = (Resolve-Path -LiteralPath $exePath).Path
$workDir = Split-Path -Parent $resolvedExe
$maxWs = 0L
$maxPriv = 0L
for ($i = 0; $i -lt $runs; $i++) {
  $p = Start-Process -FilePath $resolvedExe -ArgumentList $ArgumentList -WorkingDirectory $workDir -PassThru -WindowStyle Hidden
  try {
    do {
      $p.Refresh()
      if ($p.PeakWorkingSet64 -gt $maxWs) { $maxWs = $p.PeakWorkingSet64 }
      if ($p.PrivateMemorySize64 -gt $maxPriv) { $maxPriv = $p.PrivateMemorySize64 }
    } while (-not $p.WaitForExit(10))
    $p.WaitForExit()
    if ($p.ExitCode -ne 0) { throw "Ping exited with code $($p.ExitCode)." }
  } finally {
    $p.Dispose()
  }
}
"PeakWorkingSet={0} MaxSampledPrivateBytes={1}" -f $maxWs, $maxPriv
