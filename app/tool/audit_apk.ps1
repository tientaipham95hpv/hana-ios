param(
  [Parameter(Mandatory = $true)][string]$Apk,
  [string]$SourceAssetMap = "..\..\..\assets_processed\hana\source_asset_map.json"
)

$ErrorActionPreference = "Stop"
if (-not [IO.Path]::IsPathRooted($SourceAssetMap)) {
  $SourceAssetMap = Join-Path $PSScriptRoot $SourceAssetMap
}
Add-Type -AssemblyName System.IO.Compression.FileSystem
$resolvedApk = (Resolve-Path -LiteralPath $Apk).Path
$archive = [IO.Compression.ZipFile]::OpenRead($resolvedApk)
try {
  $entries = @($archive.Entries)
  $failures = [Collections.Generic.List[string]]::new()
  $videoEntries = @($entries | Where-Object { $_.FullName -match '(?i)\.(mp4|mov|mkv|webm)$' })
  if ($videoEntries.Count -ne 0) {
    $failures.Add("production/video entries: $($videoEntries.FullName -join ', ')")
  }

  $sourceNames = @()
  if (-not (Test-Path -LiteralPath $SourceAssetMap)) {
    throw "Phase 4 source map missing; cannot verify source filenames: $SourceAssetMap"
  }
  $rawMap = Get-Content -Raw -Encoding UTF8 -LiteralPath $SourceAssetMap
  $sourceNames = @([regex]::Matches($rawMap, '[A-Za-z0-9_-]+\.MP4') | ForEach-Object Value | Sort-Object -Unique)
  if ($sourceNames.Count -ne 43) { throw "Expected 43 Phase 4 source stems; found $($sourceNames.Count)." }

  $forbidden = @(
    'source_asset_map', 'assets_source', 'assets_processed', 'Downloads/Hana',
    'private session (mock)', 'Private developer harness', 'Character Lab',
    'debug-session', 'per-clip-policy-mock', 'keyPassword=', 'storePassword=',
    'BEGIN PRIVATE KEY'
  ) + $sourceNames

  foreach ($entry in $entries) {
    foreach ($needle in $forbidden) {
      if ($entry.FullName.Contains($needle)) {
        $failures.Add("forbidden entry '$needle' in $($entry.FullName)")
      }
    }
  }

  foreach ($entry in $entries | Where-Object {
    $_.FullName -match '(?i)(lib/.*\.so$|classes\d*\.dex$|resources\.arsc$|AndroidManifest\.xml$|flutter_assets/)'
  }) {
    $stream = $entry.Open()
    try {
      $memory = [IO.MemoryStream]::new()
      $stream.CopyTo($memory)
      $bytes = $memory.ToArray()
      $utf8 = [Text.Encoding]::UTF8.GetString($bytes)
      $utf16 = [Text.Encoding]::Unicode.GetString($bytes)
      foreach ($needle in $forbidden) {
        if ($utf8.Contains($needle) -or $utf16.Contains($needle)) {
          $failures.Add("forbidden string '$needle' in $($entry.FullName)")
        }
      }
    } finally {
      $stream.Dispose()
    }
  }

  $largest = $entries | Sort-Object Length -Descending | Select-Object -First 15 FullName,Length,CompressedLength
  [pscustomobject]@{
    apk = $resolvedApk
    bytes = (Get-Item -LiteralPath $resolvedApk).Length
    entries = $entries.Count
    video_entries = $videoEntries.Count
    source_names_checked = $sourceNames.Count
    failures = $failures.Count
  } | Format-List
  $largest | Format-Table -AutoSize
  if ($failures.Count -ne 0) {
    $failures | ForEach-Object { Write-Error $_ }
    exit 1
  }
  Write-Output 'APK AUDIT PASS'
} finally {
  $archive.Dispose()
}
