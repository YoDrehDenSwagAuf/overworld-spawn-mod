#!/usr/bin/env pwsh
# Generate assets/enhanced_overworld/followsprites_mapping/followsprites_mapping.json
# from individual follow-sprite PNGs. Does not modify any PNG files.
#
# Real sheet layout (verified against images + atlasdata.txt):
#   rows = directions (0=down, 1=left, 2=right, 3=up)
#   columns = animation frames (0..3)
# Idle uses column 0; walk loops columns 0..3.
# Animation templates live once in "layout"; species entries only store files/sizes.
$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $PSScriptRoot
$SpriteDir = Join-Path $Root "assets/enhanced_overworld/followsprites"
$OutDir = Join-Path $Root "assets/enhanced_overworld/followsprites_mapping"
$OutFile = Join-Path $OutDir "followsprites_mapping.json"
$CurrentGameMax = 151

if (-not (Test-Path $SpriteDir)) {
  throw "Sprite folder missing: $SpriteDir"
}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
Add-Type -AssemblyName System.Drawing

function Read-PngSize([string]$path) {
  $img = [System.Drawing.Image]::FromFile($path)
  try {
    return @{ Width = [int]$img.Width; Height = [int]$img.Height }
  } finally {
    $img.Dispose()
  }
}

function Escape-Json([string]$s) {
  if ($null -eq $s) { return "" }
  return ($s -replace '\\', '\\' -replace '"', '\"')
}

$bucket = @{}
$invalidFilenames = New-Object System.Collections.Generic.List[string]
$invalidGrids = New-Object System.Collections.Generic.List[string]
$altFormFiles = New-Object System.Collections.Generic.List[string]
$normalCount = 0
$shinyCount = 0
$sizeCounts = @{}

$pngs = @(Get-ChildItem -Path $SpriteDir -File | Where-Object {
  $_.Extension -ieq ".png"
})

foreach ($f in $pngs) {
  $name = $f.Name
  $speciesId = $null
  $form = $null
  $variant = $null
  $alt = $null

  if ($name -match '^(\d+)-([A-Za-z]+)-([nsNS])(?:-(.+))?\.png$') {
    $speciesId = [int]$Matches[1]
    $form = $Matches[2].ToLower()
    $variant = $Matches[3].ToLower()
    if ($Matches[4]) { $alt = $Matches[4] }
  } elseif ($name -match '^(\d+)-([nsNS])-(.+)\.png$') {
    $speciesId = [int]$Matches[1]
    $form = "b"
    $variant = $Matches[2].ToLower()
    $alt = $Matches[3]
  } else {
    $invalidFilenames.Add($name)
    continue
  }

  if ($alt) {
    $altFormFiles.Add($name)
    continue
  }

  try {
    $sz = Read-PngSize $f.FullName
  } catch {
    $invalidGrids.Add("$name (read failed: $($_.Exception.Message))")
    continue
  }

  $w = $sz.Width
  $h = $sz.Height
  $sizeKey = "${w}x${h}"
  if (-not $sizeCounts.ContainsKey($sizeKey)) { $sizeCounts[$sizeKey] = 0 }
  $sizeCounts[$sizeKey]++

  if (($w % 4) -ne 0 -or ($h % 4) -ne 0) {
    $invalidGrids.Add("$name (${w}x${h} not divisible by 4)")
    continue
  }

  $tileW = [int]($w / 4)
  $tileH = [int]($h / 4)
  $rel = "assets/enhanced_overworld/followsprites/$name"

  if (-not $bucket.ContainsKey($speciesId)) { $bucket[$speciesId] = @{} }
  if (-not $bucket[$speciesId].ContainsKey($form)) { $bucket[$speciesId][$form] = @{} }
  if ($bucket[$speciesId][$form].ContainsKey($variant)) {
    Write-Warning ("Duplicate {0} form={1} variant={2}: keeping first ({3}), skipping {4}" -f `
      $speciesId, $form, $variant, $bucket[$speciesId][$form][$variant].file, $name)
    continue
  }

  $bucket[$speciesId][$form][$variant] = @{
    file = $name
    relPath = $rel
    imageWidth = $w
    imageHeight = $h
    tileWidth = $tileW
    tileHeight = $tileH
    form = $form
  }

  if ($variant -eq "n") { $normalCount++ } else { $shinyCount++ }
}

function Pick-Form($forms) {
  foreach ($pref in @("b", "m", "f")) {
    if ($forms.ContainsKey($pref)) { return $pref }
  }
  return @($forms.Keys | Sort-Object)[0]
}

function Variant-Json($meta) {
  return ('{{"file":"{0}","path":"{1}","form":"{2}","imageWidth":{3},"imageHeight":{4},"tileWidth":{5},"tileHeight":{6}}}' -f `
    (Escape-Json $meta.file),
    (Escape-Json $meta.relPath),
    (Escape-Json $meta.form),
    $meta.imageWidth, $meta.imageHeight, $meta.tileWidth, $meta.tileHeight)
}

$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('{')
[void]$sb.AppendLine('  "schemaVersion": 1,')
[void]$sb.AppendLine('  "format": "individual-follow-sprites",')
[void]$sb.AppendLine('  "layout": {')
[void]$sb.AppendLine('    "columns": 4,')
[void]$sb.AppendLine('    "rows": 4,')
[void]$sb.AppendLine('    "coordinateBase": 0,')
[void]$sb.AppendLine('    "interpretation": "rows-are-directions-columns-are-frames",')
[void]$sb.AppendLine('    "directions": { "down": 0, "left": 1, "right": 2, "up": 3 },')
[void]$sb.AppendLine('    "idleColumn": 0,')
[void]$sb.AppendLine('    "walkColumns": [0, 1, 2, 3],')
[void]$sb.AppendLine('    "notes": [')
[void]$sb.AppendLine('      "Verified against real PNGs. Rows are directions; columns are animation frames.",')
[void]$sb.AppendLine('      "Idle uses column 0 of the direction row; walk loops columns 0-3 of the same row.",')
[void]$sb.AppendLine('      "The draft that put directions in columns does not match these assets."')
[void]$sb.AppendLine('    ],')
[void]$sb.AppendLine('    "animations": {')
[void]$sb.AppendLine('      "idle": {')
[void]$sb.AppendLine('        "down":  [{ "col": 0, "row": 0, "w": 1, "h": 1 }],')
[void]$sb.AppendLine('        "left":  [{ "col": 0, "row": 1, "w": 1, "h": 1 }],')
[void]$sb.AppendLine('        "right": [{ "col": 0, "row": 2, "w": 1, "h": 1 }],')
[void]$sb.AppendLine('        "up":    [{ "col": 0, "row": 3, "w": 1, "h": 1 }]')
[void]$sb.AppendLine('      },')
[void]$sb.AppendLine('      "walk": {')
[void]$sb.AppendLine('        "down":  [{ "col": 0, "row": 0, "w": 1, "h": 1 }, { "col": 1, "row": 0, "w": 1, "h": 1 }, { "col": 2, "row": 0, "w": 1, "h": 1 }, { "col": 3, "row": 0, "w": 1, "h": 1 }],')
[void]$sb.AppendLine('        "left":  [{ "col": 0, "row": 1, "w": 1, "h": 1 }, { "col": 1, "row": 1, "w": 1, "h": 1 }, { "col": 2, "row": 1, "w": 1, "h": 1 }, { "col": 3, "row": 1, "w": 1, "h": 1 }],')
[void]$sb.AppendLine('        "right": [{ "col": 0, "row": 2, "w": 1, "h": 1 }, { "col": 1, "row": 2, "w": 1, "h": 1 }, { "col": 2, "row": 2, "w": 1, "h": 1 }, { "col": 3, "row": 2, "w": 1, "h": 1 }],')
[void]$sb.AppendLine('        "up":    [{ "col": 0, "row": 3, "w": 1, "h": 1 }, { "col": 1, "row": 3, "w": 1, "h": 1 }, { "col": 2, "row": 3, "w": 1, "h": 1 }, { "col": 3, "row": 3, "w": 1, "h": 1 }]')
[void]$sb.AppendLine('      }')
[void]$sb.AppendLine('    }')
[void]$sb.AppendLine('  },')
[void]$sb.AppendLine('  "spriteDir": "assets/enhanced_overworld/followsprites",')
[void]$sb.AppendLine(('  "currentGameSpeciesMax": {0},' -f $CurrentGameMax))
[void]$sb.AppendLine('  "species": {')

$mapped = 0
$aboveGame = 0
$hasShiny = 0
$missingNormal = New-Object System.Collections.Generic.List[int]
$ids = @($bucket.Keys | Sort-Object)
for ($i = 0; $i -lt $ids.Count; $i++) {
  $id = $ids[$i]
  $forms = $bucket[$id]
  $formKey = Pick-Form $forms
  $variants = $forms[$formKey]

  $parts = New-Object System.Collections.Generic.List[string]
  $parts.Add(('    "{0}": {{' -f $id))
  $parts.Add(('      "speciesId": {0},' -f $id))
  $parts.Add(('      "preferredForm": "{0}",' -f (Escape-Json $formKey)))

  $hasN = $variants.ContainsKey("n")
  $hasS = $variants.ContainsKey("s")
  if (-not $hasN) { $missingNormal.Add($id) }
  if ($hasS) { $hasShiny++ }

  if ($hasN) {
    $comma = if ($hasS) { "," } else { "" }
    $parts.Add(('      "normal": {0}{1}' -f (Variant-Json $variants["n"]), $comma))
  }
  if ($hasS) {
    $parts.Add(('      "shiny": {0}' -f (Variant-Json $variants["s"])))
  }

  # Alternate gendered forms (file names only).
  $altParts = New-Object System.Collections.Generic.List[string]
  foreach ($fk in ($forms.Keys | Sort-Object)) {
    if ($fk -eq $formKey) { continue }
    $nFile = if ($forms[$fk].ContainsKey("n")) { $forms[$fk]["n"].file } else { $null }
    $sFile = if ($forms[$fk].ContainsKey("s")) { $forms[$fk]["s"].file } else { $null }
    if (-not $nFile -and -not $sFile) { continue }
    $inner = New-Object System.Collections.Generic.List[string]
    if ($nFile) { $inner.Add(('"normal":"{0}"' -f (Escape-Json $nFile))) }
    if ($sFile) { $inner.Add(('"shiny":"{0}"' -f (Escape-Json $sFile))) }
    $altParts.Add(('"{0}":{{{1}}}' -f (Escape-Json $fk), ($inner -join ",")))
  }
  if ($altParts.Count -gt 0) {
    # Insert comma after last variant line.
    $last = $parts[$parts.Count - 1]
    if (-not $last.EndsWith(",")) {
      $parts[$parts.Count - 1] = $last + ","
    }
    $parts.Add(('      "alternateForms": {{{0}}}' -f ($altParts -join ",")))
  }

  $mapped++
  if ($id -gt $CurrentGameMax) { $aboveGame++ }

  $closing = if ($i -lt ($ids.Count - 1)) { "    }," } else { "    }" }
  $parts.Add($closing)
  foreach ($line in $parts) { [void]$sb.AppendLine($line) }
}

[void]$sb.AppendLine('  }')
[void]$sb.AppendLine('}')

[System.IO.File]::WriteAllText($OutFile, $sb.ToString(), (New-Object System.Text.UTF8Encoding $false))

Write-Host "Found sprite PNGs: $($pngs.Count)"
Write-Host "Normal variants: $normalCount"
Write-Host "Shiny variants: $shinyCount"
Write-Host "Mapped species: $mapped"
Write-Host "Species with shiny: $hasShiny"
Write-Host "Species above current game range: $aboveGame"
Write-Host "Invalid filenames: $($invalidFilenames.Count)"
Write-Host "Alternate-form files skipped (kept on disk): $($altFormFiles.Count)"
Write-Host "Invalid image grids: $($invalidGrids.Count)"
Write-Host "Missing normal: $($missingNormal.Count)"
Write-Host "Size distribution:"
$sizeCounts.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object {
  Write-Host ("  {0}: {1}" -f $_.Key, $_.Value)
}
Write-Host ("Output bytes: {0}" -f (Get-Item $OutFile).Length)
Write-Host "Output: assets/enhanced_overworld/followsprites_mapping/followsprites_mapping.json"
