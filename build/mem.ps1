param([string]$exePath, [int]$runs = 5)
$workDir = Split-Path $exePath
$maxWs = 0L; $maxPriv = 0L
for ($i = 0; $i -lt $runs; $i++) {
  $p = Start-Process -FilePath $exePath -WorkingDirectory $workDir -PassThru -WindowStyle Hidden
  while (-not $p.HasExited) {
    try {
      $p.Refresh()
      if ($p.PeakWorkingSet64 -gt $maxWs) { $maxWs = $p.PeakWorkingSet64 }
      if ($p.PrivateMemorySize64 -gt $maxPriv) { $maxPriv = $p.PrivateMemorySize64 }
    } catch { break }
  }
}
"PeakWorkingSet={0} PeakPrivateBytes={1}" -f $maxWs, $maxPriv
