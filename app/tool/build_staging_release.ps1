param(
  [string]$Drive = 'H:',
  [string]$BackendBaseUrl = 'http://10.0.2.2:18000'
)

$ErrorActionPreference = 'Stop'
$appRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$previousGradleOpts = $env:GRADLE_OPTS
if ($Drive -notmatch '^[A-Z]:$') { throw 'Drive must be a single uppercase drive letter.' }
if (Test-Path -LiteralPath "$Drive\") { throw "$Drive is already in use." }

# Flutter embeds the absolute generated plugin-registrant URI in libapp.so.
# Compile through a short temporary drive so the workspace/user path is absent.
& subst $Drive $appRoot
if ($LASTEXITCODE -ne 0) { throw "Could not map $Drive" }
try {
  # Gradle plugins in the pub cache remain on C:, so Kotlin's incremental
  # cross-root relative-path cache is invalid when this project is on H:.
  $env:GRADLE_OPTS = "$previousGradleOpts -Dkotlin.incremental=false"
  Push-Location "$Drive\"
  try {
    & flutter build apk --release --flavor staging --split-per-abi --no-pub --split-debug-info=build\symbols\staging-shortpath --obfuscate --dart-define=HANA_BACKEND_ENABLED=true --dart-define=HANA_BACKEND_BASE_URL=$BackendBaseUrl
    if ($LASTEXITCODE -ne 0) { throw "Flutter build failed ($LASTEXITCODE)." }
  } finally {
    Pop-Location
  }
} finally {
  $env:GRADLE_OPTS = $previousGradleOpts
  & subst $Drive /D
}
