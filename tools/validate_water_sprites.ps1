# Validate swimming / levitates water sprite assets and runtime sheets.
$ErrorActionPreference = "Stop"
$Py = Join-Path $PSScriptRoot "validate_water_sprites.py"
python3 $Py @args
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
