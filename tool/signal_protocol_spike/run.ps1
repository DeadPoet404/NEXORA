$ErrorActionPreference = 'Stop'
Push-Location $PSScriptRoot
try {
    dart --version
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    dart pub get
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    dart format test
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    dart test
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    dart analyze
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
} finally {
    Pop-Location
}
