$pp = Get-PackageParameters

$silentArgs = "/S"
if ($pp['InstallPath']) {
  $silentArgs += " /D=$($pp['InstallPath'])"
}

$ErrorActionPreference = 'Stop';

$packageArgs = @{
  packageName   = 'Steam'
  fileType      = 'EXE'
  url           = 'https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe'
  softwareName  = 'Steam'
  checksum      = ''
  checksumType  = 'sha256'
  checksum64    = ''
  checksumType64= 'sha256'
  silentArgs    = $silentArgs
  validExitCodes= @(0)
}

Install-ChocolateyPackage @packageArgs
