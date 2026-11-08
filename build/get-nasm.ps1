# Returns the pinned NASM executable path; downloads it on the first build.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($env:OS -ne 'Windows_NT') { throw 'The NASM bootstrap requires Windows.' }
$manifest = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'nasm.json') -Raw | ConvertFrom-Json
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$toolRoot = [IO.Path]::GetFullPath((Join-Path $repositoryRoot '.ping-build\tools'))
$versionDirectory = 'nasm-' + $manifest.version
$nasmDirectory = Join-Path $toolRoot $versionDirectory
$nasmExecutable = Join-Path $nasmDirectory 'nasm.exe'
$nasmLicense = Join-Path $nasmDirectory 'LICENSE'

if (Test-Path -LiteralPath $nasmExecutable -PathType Leaf) {
    if ((Get-FileHash -LiteralPath $nasmExecutable -Algorithm SHA256).Hash -ne $manifest.executableSha256) {
        throw "Cached NASM checksum mismatch: $nasmExecutable. Remove that cache directory and rebuild."
    }
    if (Test-Path -LiteralPath $nasmLicense -PathType Leaf) {
        return $nasmExecutable
    }
}

$null = New-Item -ItemType Directory -Force -Path $toolRoot
$downloadId = [Guid]::NewGuid().ToString('N')
$archive = Join-Path $toolRoot ($downloadId + '.zip')
$staging = Join-Path $toolRoot ('extract-' + $downloadId)
try {
    Write-Host "Downloading NASM $($manifest.version) from nasm.us..."
    # Windows PowerShell 5.1 may otherwise negotiate an obsolete TLS version.
    $previousTls = [Net.ServicePointManager]::SecurityProtocol
    try {
        [Net.ServicePointManager]::SecurityProtocol = $previousTls -bor [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $manifest.url -OutFile $archive -UseBasicParsing -TimeoutSec 120
    } finally {
        [Net.ServicePointManager]::SecurityProtocol = $previousTls
    }
    if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $manifest.archiveSha256) {
        throw 'Downloaded NASM archive checksum mismatch; nothing will be executed.'
    }
    Expand-Archive -LiteralPath $archive -DestinationPath $staging
    $extractedDirectory = Join-Path $staging $versionDirectory
    $extractedExecutable = Join-Path $extractedDirectory 'nasm.exe'
    if ((Get-FileHash -LiteralPath $extractedExecutable -Algorithm SHA256).Hash -ne $manifest.executableSha256) {
        throw 'Extracted NASM executable checksum mismatch; nothing will be executed.'
    }
    $null = New-Item -ItemType Directory -Force -Path $nasmDirectory
    Copy-Item -LiteralPath (Join-Path $extractedDirectory 'LICENSE') -Destination $nasmLicense -Force
    Copy-Item -LiteralPath $extractedExecutable -Destination $nasmExecutable -Force
} finally {
    foreach ($temporaryPath in @($archive, $staging)) {
        $absoluteTemporaryPath = [IO.Path]::GetFullPath($temporaryPath)
        if (-not $absoluteTemporaryPath.StartsWith($toolRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to clean a path outside the tool cache: $absoluteTemporaryPath"
        }
        if (Test-Path -LiteralPath $absoluteTemporaryPath) {
            Remove-Item -LiteralPath $absoluteTemporaryPath -Recurse -Force
        }
    }
}
return $nasmExecutable
