#!/usr/bin/env pwsh
# Validate release tag / manifest / export / ZIP filename version alignment.
# Prefer the Python twin in CI; this script mirrors it for Windows/local use.
param(
  [string]$Tag = $env:RELEASE_TAG
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
$ManifestPath = Join-Path $Root "manifest.json"
$MainPath = Join-Path $Root "main.lua"
$CardPath = Join-Path $Root "mod.card"
$ChangelogPath = Join-Path $Root "CHANGELOG.md"

function Fail([string]$Message) {
  Write-Error $Message
  exit 1
}

if (-not (Test-Path $ManifestPath)) { Fail "missing manifest.json" }
$manifest = Get-Content -Raw -Path $ManifestPath | ConvertFrom-Json
$manifestVersion = [string]$manifest.version
if ([string]::IsNullOrWhiteSpace($manifestVersion)) {
  Fail "ERROR: Release tag and manifest version do not match."
}

$mainText = Get-Content -Raw -Path $MainPath
if ($mainText -notmatch 'mod\.exports\.version\s*=\s*"([^"]+)"') {
  Fail "main.lua missing mod.exports.version"
}
$mainVersion = $Matches[1]

$cardVersion = $null
if (Test-Path $CardPath) {
  $cardText = Get-Content -Raw -Path $CardPath
  if ($cardText -match 'version\s*=\s*"([^"]+)"') {
    $cardVersion = $Matches[1]
  }
}

Write-Host ("Manifest: {0}" -f $manifestVersion)
Write-Host ("main.lua: {0}" -f $mainVersion)
if ($null -ne $cardVersion) {
  Write-Host ("mod.card: {0}" -f $cardVersion)
} else {
  Write-Host "mod.card: (no version field)"
}

if ($mainVersion -ne $manifestVersion) {
  Fail "ERROR: Release tag and manifest version do not match."
}
if ($null -ne $cardVersion -and $cardVersion -ne $manifestVersion) {
  Fail "ERROR: Release tag and manifest version do not match."
}

$zipName = "wilds-of-kanto-v{0}.zip" -f $manifestVersion
Write-Host ("ZIP filename: {0}" -f $zipName)

$changelog = Get-Content -Raw -Path $ChangelogPath
if ($changelog -notmatch ("(?m)^##\s+{0}\b" -f [regex]::Escape($manifestVersion))) {
  Fail ("CHANGELOG.md missing section for {0}" -f $manifestVersion)
}

if (-not [string]::IsNullOrWhiteSpace($Tag)) {
  if ($Tag -notmatch '^v(\d+\.\d+\.\d+)$') {
    Fail ("Release tag must look like vMAJOR.MINOR.PATCH, got: {0}" -f $Tag)
  }
  $tagVersion = $Matches[1]
  Write-Host ("Tag: {0}" -f $Tag)
  if ($tagVersion -ne $manifestVersion) {
    Fail "ERROR: Release tag and manifest version do not match."
  }
} else {
  Write-Host "Tag: (not provided; consistency-only check)"
}

Write-Host "validate_release_version: ok"
