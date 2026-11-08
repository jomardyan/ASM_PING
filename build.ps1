param(
    [string]$LinkerPath,
    [string]$NasmPath,
    [string]$OutputDirectory = $PSScriptRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($env:OS -ne 'Windows_NT') { throw 'This build requires Windows x64.' }
if (-not $LinkerPath) {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path -LiteralPath $vswhere) {
        $matches = @(& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -find 'VC\Tools\MSVC\**\bin\Hostx64\x64\link.exe')
        if ($matches.Count) { $LinkerPath = $matches[0] }
    }
    if (-not $LinkerPath) {
        $linkCommand = Get-Command link.exe -ErrorAction SilentlyContinue
        if ($linkCommand) { $LinkerPath = $linkCommand.Source }
    }
}
if (-not $LinkerPath -or -not (Test-Path -LiteralPath $LinkerPath -PathType Leaf)) {
    throw 'Microsoft x64 linker not found. Install Visual Studio C++ Build Tools or supply -LinkerPath.'
}
if (-not $NasmPath) {
    $NasmPath = & (Join-Path $PSScriptRoot 'build\get-nasm.ps1')
}
if (-not (Test-Path -LiteralPath $NasmPath -PathType Leaf)) {
    throw "NASM not found: $NasmPath. Supply -NasmPath."
}
$NasmPath = (Resolve-Path -LiteralPath $NasmPath).ProviderPath
$LinkerPath = (Resolve-Path -LiteralPath $LinkerPath).ProviderPath

$OutputDirectory = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
$null = New-Item -ItemType Directory -Force -Path $OutputDirectory
$intermediate = Join-Path $OutputDirectory '.ping-build'
$null = New-Item -ItemType Directory -Force -Path $intermediate
$libraries = @()
foreach ($library in @('kernel32', 'ws2_32', 'iphlpapi', 'shell32')) {
    $definition = Join-Path $PSScriptRoot "build\$library.def"
    $importLibrary = Join-Path $intermediate "$library.lib"
    & $LinkerPath /lib /nologo /machine:x64 "/def:$definition" "/out:$importLibrary"
    if ($LASTEXITCODE -ne 0) { throw "Import library generation failed: $library" }
    $libraries += $importLibrary
}

$object = Join-Path $intermediate 'ping.obj'
$exe = Join-Path $OutputDirectory 'ping.exe'
# COFF relocations are intentional: RIP-relative code and loader-relocated tables.
$includeDirectory = $PSScriptRoot.Replace('\', '/') + '/'
& $NasmPath -f win64 -Wall -w-reloc -Werror -I $includeDirectory (Join-Path $PSScriptRoot 'ping_win64.asm') -o $object
if ($LASTEXITCODE -ne 0) { throw 'Assembly failed.' }
& $LinkerPath /nologo /machine:x64 /subsystem:console /entry:main /nodefaultlib /dynamicbase /highentropyva /nxcompat /incremental:no "/out:$exe" $object @libraries
if ($LASTEXITCODE -ne 0) { throw 'Link failed.' }
Write-Output "Built $exe"
