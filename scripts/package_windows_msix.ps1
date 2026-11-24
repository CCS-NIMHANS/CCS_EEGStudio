<#
.SYNOPSIS
  Packages a Flutter Windows Release directory into a Microsoft Store-ready .msix.
#>
param(
  [Parameter(Mandatory = $true)][string]$ReleaseDir,
  [Parameter(Mandatory = $true)][string]$OutputPath,
  [Parameter(Mandatory = $true)][string]$AppName,
  [Parameter(Mandatory = $true)][string]$ExeName,
  [Parameter(Mandatory = $true)][string]$Version,
  [Parameter(Mandatory = $true)][string]$IconPath,
  [string]$IdentityName = $env:MS_STORE_IDENTITY_NAME,
  [string]$PublisherId = $env:MS_STORE_PUBLISHER_ID,
  [string]$PublisherDisplayName = $env:MS_STORE_PUBLISHER_DISPLAY_NAME,
  [string]$Description = "Desktop neuroimaging and electrophysiology analysis suite."
)

$ErrorActionPreference = "Stop"

function Resolve-OrDefault([string]$val, [string]$fallback) {
  if ([string]::IsNullOrWhiteSpace($val)) { return $fallback }
  return $val.Trim()
}

$safeId = ($AppName -replace '[^A-Za-z0-9]', '')
$IdentityName = Resolve-OrDefault $IdentityName "ArunSasidharan.$safeId"
$PublisherId = Resolve-OrDefault $PublisherId "CN=ArunSasidharan"
$PublisherDisplayName = Resolve-OrDefault $PublisherDisplayName "Arun Sasidharan"

# MSIX requires a 4-part version (Major.Minor.Build.Revision).
if ($Version -match '^(\d+)\.(\d+)\.(\d+)') {
  $MsixVersion = "$($Matches[1]).$($Matches[2]).$($Matches[3]).0"
} else {
  $MsixVersion = "1.0.0.0"
}

$MakeAppx = Get-ChildItem -Path "C:\Program Files (x86)\Windows Kits\10\bin\*\x64\makeappx.exe" -ErrorAction SilentlyContinue |
  Sort-Object FullName -Descending |
  Select-Object -First 1 -ExpandProperty FullName
if (-not $MakeAppx) {
  throw "makeappx.exe not found under Windows Kits 10 bin\*\x64."
}

$StageDir = Join-Path ([System.IO.Path]::GetTempPath()) ("msix-stage-" + [Guid]::NewGuid().ToString("N"))
$AssetsDir = Join-Path $StageDir "Assets"
New-Item -ItemType Directory -Force -Path $StageDir, $AssetsDir | Out-Null

try {
  Copy-Item -Path (Join-Path $ReleaseDir "*") -Destination $StageDir -Recurse -Force

  Add-Type -AssemblyName System.Drawing
  $absIcon = (Resolve-Path $IconPath).Path
  $srcIcon = New-Object System.Drawing.Icon($absIcon, 256, 256)
  $srcBmp = $srcIcon.ToBitmap()

  function Write-TilePng([int]$w, [int]$h, [string]$destFile) {
    $bmp = New-Object System.Drawing.Bitmap($w, $h)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $g.Clear([System.Drawing.Color]::Transparent)
    $size = [Math]::Min($w, $h)
    $pad = [int]([Math]::Round($size * 0.1))
    $drawSize = [Math]::Max(1, $size - (2 * $pad))
    $x = [int](($w - $drawSize) / 2)
    $y = [int](($h - $drawSize) / 2)
    $g.DrawImage($srcBmp, $x, $y, $drawSize, $drawSize)
    $g.Dispose()
    $bmp.Save($destFile, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
  }

  Write-TilePng 50 50 (Join-Path $AssetsDir "StoreLogo.png")
  Write-TilePng 44 44 (Join-Path $AssetsDir "Square44x44Logo.png")
  Write-TilePng 150 150 (Join-Path $AssetsDir "Square150x150Logo.png")
  Write-TilePng 310 150 (Join-Path $AssetsDir "Wide310x150Logo.png")
  $srcBmp.Dispose()
  $srcIcon.Dispose()

  $xmlEsc = { param([string]$s) [System.Security.SecurityElement]::Escape($s) }
  $manifest = @"
<?xml version="1.0" encoding="utf-8"?>
<Package
  xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10"
  xmlns:uap="http://schemas.microsoft.com/appx/manifest/uap/windows10"
  xmlns:rescap="http://schemas.microsoft.com/appx/manifest/foundation/windows10/restrictedcapabilities"
  IgnorableNamespaces="uap rescap">
  <Identity
    Name="$(& $xmlEsc $IdentityName)"
    Publisher="$(& $xmlEsc $PublisherId)"
    Version="$MsixVersion"
    ProcessorArchitecture="x64" />
  <Properties>
    <DisplayName>$(& $xmlEsc $AppName)</DisplayName>
    <PublisherDisplayName>$(& $xmlEsc $PublisherDisplayName)</PublisherDisplayName>
    <Logo>Assets\StoreLogo.png</Logo>
  </Properties>
  <Dependencies>
    <TargetDeviceFamily Name="Windows.Desktop" MinVersion="10.0.19041.0" MaxVersionTested="10.0.26100.0" />
  </Dependencies>
  <Resources>
    <Resource Language="en-us" />
  </Resources>
  <Applications>
    <Application Id="App" Executable="$(& $xmlEsc $ExeName)" EntryPoint="Windows.FullTrustApplication">
      <uap:VisualElements
        DisplayName="$(& $xmlEsc $AppName)"
        Description="$(& $xmlEsc $Description)"
        BackgroundColor="transparent"
        Square150x150Logo="Assets\Square150x150Logo.png"
        Square44x44Logo="Assets\Square44x44Logo.png">
        <uap:DefaultTile Wide310x150Logo="Assets\Wide310x150Logo.png" />
      </uap:VisualElements>
    </Application>
  </Applications>
  <Capabilities>
    <rescap:Capability Name="runFullTrust" />
  </Capabilities>
</Package>
"@

  $manifestPath = Join-Path $StageDir "AppxManifest.xml"
  [System.IO.File]::WriteAllText($manifestPath, $manifest, [System.Text.UTF8Encoding]::new($false))

  $outDir = Split-Path -Parent $OutputPath
  if ($outDir) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
  if (Test-Path $OutputPath) { Remove-Item -Force $OutputPath }

  & $MakeAppx pack /d $StageDir /p $OutputPath /o
  if ($LASTEXITCODE -ne 0 -or -not (Test-Path $OutputPath)) {
    throw "makeappx pack failed with exit code $LASTEXITCODE"
  }
  Write-Host "Created MSIX package: $OutputPath (Identity=$IdentityName, Version=$MsixVersion)"
} finally {
  if (Test-Path $StageDir) { Remove-Item -Recurse -Force $StageDir -ErrorAction SilentlyContinue }
}
