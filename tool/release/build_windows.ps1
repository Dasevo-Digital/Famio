# Builds the Windows package on a Windows machine with Flutter on the PATH:
#   powershell -File build_windows.ps1 -V <version> [-Flutter <flutter>]
# (famio-src.tgz from tool/release.sh in the user folder). Stops if Flutter
# is not <flutter>. Leaves Famio-<version>-windows-x86_64.zip in the user
# folder.
param([string]$V, [string]$Flutter)
$ErrorActionPreference = 'Stop'
if ($Flutter -and -not ("$(flutter --version | Select-Object -First 1)".StartsWith("Flutter $Flutter "))) {
  throw "Flutter ist nicht $Flutter"
}
Set-Location $env:USERPROFILE
if (Test-Path famio) { Remove-Item famio -Recurse -Force }; New-Item -ItemType Directory famio | Out-Null; tar -xzf famio-src.tgz -C famio
Set-Location famio\app
flutter pub get | Out-Null
flutter build windows --release 2>&1 | Select-Object -Last 2
$zip = "$env:USERPROFILE\Famio-$V-windows-x86_64.zip"
if (Test-Path $zip) { Remove-Item $zip }
Compress-Archive -Path build\windows\x64\runner\Release\* -DestinationPath $zip
Write-Output ("zipped " + (Get-Item build\windows\x64\runner\Release\famio.exe).VersionInfo.ProductVersion)
