param(
    [string]$LinkerPath,
    [string]$NasmPath,
    [string]$OutputDirectory = $PSScriptRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not $NasmPath) {
    $NasmPath = Join-Path $PSScriptRoot 'build\nasm-3.02\nasm.exe'
}
if (-not (Test-Path -LiteralPath $NasmPath -PathType Leaf)) {
    throw "NASM not found: $NasmPath. Supply -NasmPath."
}
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

$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
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

$object = Join-Path $OutputDirectory 'ping.obj'
$exe = Join-Path $OutputDirectory 'ping.exe'
# COFF relocations are intentional: RIP-relative code and loader-relocated tables.
& $NasmPath -f win64 -Wall -w-reloc -Werror (Join-Path $PSScriptRoot 'ping_win64.asm') -o $object
if ($LASTEXITCODE -ne 0) { throw 'Assembly failed.' }
& $LinkerPath /nologo /machine:x64 /subsystem:console /entry:main /nodefaultlib /dynamicbase /highentropyva /nxcompat /incremental:no "/out:$exe" $object @libraries
if ($LASTEXITCODE -ne 0) { throw 'Link failed.' }
Write-Output "Built $exe"
