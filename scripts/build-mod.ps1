#!/usr/bin/env pwsh
# Build dist/overworld_wild_spawns-<version>.zip for Gen1Recomp import.
# Repo root IS the mod (DramaticShapeVoxelMod layout). Prefers modkit pack.
$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $PSScriptRoot
$ModDir = $Root
$Dist = Join-Path $Root "dist"
$Engine = Join-Path $Root ".deps/gen1recomp"
$ManifestPath = Join-Path $ModDir "manifest.json"

if (-not (Test-Path $ManifestPath)) {
  throw "missing $ManifestPath (repo root must be the mod)"
}

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

$OutZip = Join-Path $Dist ("{0}-{1}.zip" -f $manifest.id, $manifest.version)
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
}

$Alias = Join-Path $Dist ("{0}.zip" -f $manifest.id)
Copy-Item $OutZip $Alias -Force

Write-Host "verify ok:"
Write-Host "  manifest.json at ZIP root: yes"
Write-Host ("  files: {0}" -f $names.Count)
$names | Sort-Object | ForEach-Object { Write-Host ("  - {0}" -f $_) }
Write-Host "wrote $OutZip"
Write-Host "wrote $Alias"
