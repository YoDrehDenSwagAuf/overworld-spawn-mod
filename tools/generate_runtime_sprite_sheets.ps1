# Build Gen1Recomp-compatible 16x96 runtime SpriteRenderer sheets.
# Prefer Python (cross-platform). Falls back message if Python/Pillow missing.
param(
  [switch]$Force,
  [int]$MaxSpecies = 0
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
$Py = Join-Path $PSScriptRoot "generate_runtime_sprite_sheets.py"

$argsList = @($Py)
if ($Force) { $argsList += "--force" }
if ($MaxSpecies -gt 0) { $argsList += @("--max-species", "$MaxSpecies") }

$python = Get-Command python3 -ErrorAction SilentlyContinue
if (-not $python) { $python = Get-Command python -ErrorAction SilentlyContinue }
if (-not $python) {
  Write-Error "python3/python not found. Install Python + Pillow, then re-run."
}

& $python.Source @argsList
exit $LASTEXITCODE
