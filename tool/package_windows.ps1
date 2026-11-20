<#
 Empacota o gravadoC para Windows.
   .\tool\package_windows.ps1                 # build + pasta + zip + instalador
   .\tool\package_windows.ps1 -SkipBuild      # reaproveita o ultimo build
   .\tool\package_windows.ps1 -FfmpegDir C:\ffmpeg\bin

 Saidas em dist\:
   gravadoC\                       pasta pronta para uso (portatil)
   gravadoC-<versao>-portable.zip  mesma pasta compactada
   gravadoC-Setup-<versao>.exe     instalador (requer Inno Setup 6)
#>
param(
  [string]$FfmpegDir = '',
  [switch]$SkipBuild
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$version = (Select-String -Path pubspec.yaml -Pattern '^version:\s*(\d+\.\d+\.\d+)').Matches[0].Groups[1].Value

if (-not $SkipBuild) {
  flutter build windows --release
  if ($LASTEXITCODE -ne 0) { throw 'flutter build windows falhou.' }
}

$release = Join-Path $root 'build\windows\x64\runner\Release'
if (-not (Test-Path (Join-Path $release 'gravadoC.exe'))) { throw "gravadoC.exe nao encontrado em $release" }

$dist = Join-Path $root 'dist'
$stage = Join-Path $dist 'gravadoC'
Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $stage | Out-Null
Copy-Item "$release\*" $stage -Recurse

# FFmpeg embutido: o app procura em <pasta do app>\ffmpeg\ffmpeg.exe primeiro.
if (-not $FfmpegDir) {
  $cmd = Get-Command ffmpeg -ErrorAction SilentlyContinue
  if ($cmd) { $FfmpegDir = Split-Path $cmd.Source }
}
if (-not $FfmpegDir -or -not (Test-Path (Join-Path $FfmpegDir 'ffmpeg.exe')) -or -not (Test-Path (Join-Path $FfmpegDir 'ffprobe.exe'))) {
  throw 'ffmpeg.exe/ffprobe.exe nao encontrados. Informe -FfmpegDir.'
}
$ffDest = Join-Path $stage 'ffmpeg'
New-Item -ItemType Directory -Force $ffDest | Out-Null
Copy-Item (Join-Path $FfmpegDir 'ffmpeg.exe'), (Join-Path $FfmpegDir 'ffprobe.exe') $ffDest
$license = Join-Path (Split-Path $FfmpegDir) 'LICENSE'
if (Test-Path $license) { Copy-Item $license (Join-Path $ffDest 'LICENSE.txt') }

# Runtime do Visual C++ junto do app (nao exige instalar o redistribuivel).
foreach ($dll in 'vcruntime140.dll', 'vcruntime140_1.dll', 'msvcp140.dll') {
  Copy-Item (Join-Path $env:WINDIR "System32\$dll") $stage
}

$zip = Join-Path $dist "gravadoC-$version-portable.zip"
Remove-Item $zip -ErrorAction SilentlyContinue
Compress-Archive -Path "$stage\*" -DestinationPath $zip -CompressionLevel Optimal
Write-Host "Pasta : $stage"
Write-Host "Zip   : $zip"

$iscc = (Get-Command ISCC.exe -ErrorAction SilentlyContinue).Source
if (-not $iscc) {
  foreach ($dir in "$env:LOCALAPPDATA\Programs\Inno Setup 6", "$env:ProgramFiles\Inno Setup 6", "${env:ProgramFiles(x86)}\Inno Setup 6") {
    if (Test-Path (Join-Path $dir 'ISCC.exe')) { $iscc = Join-Path $dir 'ISCC.exe'; break }
  }
}
if ($iscc) {
  & $iscc "/DAppVersion=$version" (Join-Path $PSScriptRoot 'installer.iss')
  if ($LASTEXITCODE -ne 0) { throw 'ISCC falhou.' }
  Write-Host "Setup : $(Join-Path $dist "gravadoC-Setup-$version.exe")"
} else {
  Write-Warning 'Inno Setup 6 nao encontrado: instalador nao gerado (winget install JRSoftware.InnoSetup).'
}
