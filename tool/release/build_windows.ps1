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
# The SQLite library of earlier builds instead of a download from github.com
# (as tool/hook_cache.sh does elsewhere); the sqlite3 build hook checks its
# SHA-256 and downloads it again if it does not match.
$hookCache = "$env:LOCALAPPDATA\famio\sqlite3-hook"
$hookDir = '.dart_tool\hooks_runner\shared\sqlite3\build'
if (Test-Path $hookCache) {
  New-Item -ItemType Directory -Force $hookDir | Out-Null
  Copy-Item "$hookCache\*" $hookDir -Recurse -Force
}
flutter pub get | Out-Null
flutter build windows --release 2>&1 | Select-Object -Last 2
if (Test-Path $hookDir) {
  Get-ChildItem $hookDir -Directory -Filter 'download-*' | ForEach-Object {
    Get-ChildItem $_.FullName -File | Where-Object { $_.Extension -ne '.tmp' } | ForEach-Object {
      $kept = Join-Path $hookCache (Join-Path $_.Directory.Name $_.Name)
      if (-not (Test-Path $kept) -or (Get-FileHash $kept).Hash -ne (Get-FileHash $_.FullName).Hash) {
        New-Item -ItemType Directory -Force (Split-Path $kept) | Out-Null
        Copy-Item $_.FullName $kept -Force
      }
    }
  }
}
$zip = "$env:USERPROFILE\Famio-$V-windows-x86_64.zip"
if (Test-Path $zip) { Remove-Item $zip }
Compress-Archive -Path build\windows\x64\runner\Release\* -DestinationPath $zip
Write-Output ("zipped " + (Get-Item build\windows\x64\runner\Release\famio.exe).VersionInfo.ProductVersion)
