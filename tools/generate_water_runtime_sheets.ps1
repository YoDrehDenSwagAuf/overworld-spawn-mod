# Build water runtime SpriteRenderer sheets (16x96) from swimming/levitates sources.
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
$Py = Join-Path $PSScriptRoot "generate_water_runtime_sheets.py"
python3 $Py @args
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
