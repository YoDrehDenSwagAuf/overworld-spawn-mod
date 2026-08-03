#!/usr/bin/env pwsh
# Build dist/wilds-of-kanto-v<version>.zip for Gen1Recomp import.
# Repo root IS the mod (DramaticShapeVoxelMod layout). Prefers modkit pack.
# Also writes technical-id aliases: overworld_wild_spawns-<version>.zip / .zip
$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $PSScriptRoot
$ModDir = $Root
$Dist = Join-Path $Root "dist"
$Engine = Join-Path $Root ".deps/gen1recomp"
$ManifestPath = Join-Path $ModDir "manifest.json"

if (-not (Test-Path $ManifestPath)) {
  throw "missing $ManifestPath (repo root must be the mod)"
}

$AsciiGuard = Join-Path $PSScriptRoot "validate-manager-ascii.py"
if (-not (Test-Path $AsciiGuard)) {
  throw "missing ASCII guard: $AsciiGuard"
}
Write-Host "==> python3 scripts/validate-manager-ascii.py"
& python3 $AsciiGuard
if ($LASTEXITCODE -ne 0) { throw "validate-manager-ascii failed" }

$manifest = Get-Content -Raw -Path $ManifestPath | ConvertFrom-Json
if ($manifest.id -ne "overworld_wild_spawns") {
  throw "manifest id must be overworld_wild_spawns"
}
$entry = if ($manifest.entry) { $manifest.entry } else { "main.lua" }
if (-not (Test-Path (Join-Path $ModDir $entry))) {
  throw "entry file missing: $entry"
}

if (Test-Path $Dist) { Remove-Item -Recurse -Force $Dist }
New-Item -ItemType Directory -Path $Dist | Out-Null

$OutZip = Join-Path $Dist ("wilds-of-kanto-v{0}.zip" -f $manifest.version)
$Modkit = Join-Path $Engine "tools/modkit.py"

if (Test-Path $Modkit) {
  $Link = Join-Path $Engine "mods/overworld_wild_spawns"
  New-Item -ItemType Directory -Force -Path (Split-Path $Link) | Out-Null
  if (Test-Path $Link) { Remove-Item -Force $Link }
  New-Item -ItemType SymbolicLink -Path $Link -Target $ModDir | Out-Null
  Write-Host "==> python3 tools/modkit.py pack mods/overworld_wild_spawns"
  Push-Location $Engine
  try {
    & python3 $Modkit --repo $Engine pack mods/overworld_wild_spawns -o $OutZip
    if ($LASTEXITCODE -ne 0) { throw "modkit pack failed" }
  } finally {
    Pop-Location
  }
} else {
  Write-Host "==> modkit unavailable; packing manually from repo root"
  $stage = Join-Path $Dist "_stage"
  New-Item -ItemType Directory -Path $stage | Out-Null
  $include = @(
    "manifest.json", "main.lua", "options.lua", "mod.card",
    "LICENSE", "THIRD_PARTY_NOTICES.md",
    "README.md", "CHANGELOG.md"
  )
  foreach ($name in $include) {
    $src = Join-Path $ModDir $name
    if (Test-Path $src) {
      Copy-Item $src (Join-Path $stage $name)
    }
  }
  foreach ($dir in @("lib", "assets", "data")) {
    $src = Join-Path $ModDir $dir
    if (Test-Path $src) {
      Copy-Item -Recurse $src (Join-Path $stage $dir)
    }
  }
  Compress-Archive -Path (Join-Path $stage "*") -DestinationPath $OutZip -Force
  Remove-Item -Recurse -Force $stage
}

if (-not (Test-Path $OutZip)) { throw "expected output missing: $OutZip" }

Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::OpenRead($OutZip)
try {
  $names = @($zip.Entries | ForEach-Object { $_.FullName.Replace("\", "/") })
} finally {
  $zip.Dispose()
}

if ($names -notcontains "manifest.json") {
  throw "ZIP missing manifest.json at archive root"
}
if ($names -notcontains $entry) {
  throw "ZIP missing entry $entry at archive root"
}
if ($names -notcontains "mod.card") {
  throw "ZIP missing mod.card at archive root"
}
if ($names -notcontains "LICENSE") {
  throw "ZIP missing LICENSE at archive root"
}
$schema = $manifest.options_schema
if ($schema -and ($names -notcontains $schema)) {
  throw "ZIP missing options_schema file: $schema"
}
foreach ($name in $names) {
  if ($name -like ".git/*" -or $name -like ".github/*" -or
      $name -like "tests/*" -or $name -like "scripts/*" -or
      $name -like "mods/*" -or $name -eq ".git" -or
      $name -eq "ARCHITECTURE.md") {
    throw "ZIP contains forbidden path: $name"
  }
  # Commercial Anima atlas must never be packaged.
  if ($name -eq "assets/enhanced_overworld/Pokemon_Sprites/POKEMON 1.png" -or
      $name -like "*/POKEMON 1.png") {
    throw "ERROR: old commercial POKEMON 1.png is included: $name"
  }
}

$requiredFollow = @(
  "assets/enhanced_overworld/followsprites_mapping/followsprites_mapping.json"
)
foreach ($req in $requiredFollow) {
  if ($names -notcontains $req) {
    throw "ZIP missing required follow-sprite asset: $req"
  }
}
$followPng = @($names | Where-Object {
  $_ -like "assets/enhanced_overworld/followsprites/*.png" -or
  $_ -like "assets/enhanced_overworld/followsprites/*.PNG"
})
if ($followPng.Count -lt 1) {
  Write-Warning "ZIP contains no follow-sprite PNGs (license/local-import mode?)"
} else {
  Write-Host ("  follow-sprite PNGs: {0}" -f $followPng.Count)
}

$IdVersioned = Join-Path $Dist ("{0}-{1}.zip" -f $manifest.id, $manifest.version)
$IdAlias = Join-Path $Dist ("{0}.zip" -f $manifest.id)
Copy-Item $OutZip $IdVersioned -Force
Copy-Item $OutZip $IdAlias -Force

Write-Host "verify ok:"
Write-Host "  manifest.json at ZIP root: yes"
Write-Host ("  files: {0}" -f $names.Count)
$names | Sort-Object | ForEach-Object { Write-Host ("  - {0}" -f $_) }
Write-Host "wrote $OutZip"
Write-Host "wrote $IdVersioned"
Write-Host "wrote $IdAlias"
