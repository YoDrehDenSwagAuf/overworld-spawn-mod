# v2.1.6 Defender diagnosis: Trojan:Script/Wacatac.B!ml

Diagnosis of the published Wilds of Kanto v2.1.6 release ZIP. This is not an
antivirus-evasion note. No strings were obfuscated, no Defender settings were
changed, and no runtime Wilds behavior was rewritten to "beat" a signature.

## 1. Affected release / tag

- Product: Wilds of Kanto
- Tag: `v2.1.6`
- Release URL: https://github.com/YoDrehDenSwagAuf/overworld-spawn-mod/releases/tag/v2.1.6
- Published asset: `Wilds.of.Kanto.v2.1.6.zip`
- Detection reported: `Trojan:Script/Wacatac.B!ml`

## 2. Release commit SHA

- Tag commit: `f237bdc796db3f44434447bd75327c670f3650d0`
  (`Bump version to 2.1.6 (#79)`)
- Current main at investigation time: `a0913bd54903f803da384450613204bb3f3e7607`
  (Stadium2 True Size + catch-control commits after the tag)

## 3. How `Wilds.of.Kanto.v2.1.6.zip` was produced

The repository's intended packer is **not** what produced the published asset.

Intended path (`.github/workflows/release.yml`):

1. Tag `v*.*.*`
2. `python3 tools/validate_release_version.py`
3. option-label + manager-ASCII guards
4. unit tests
5. `python3 scripts/build-mod.py`
6. upload `dist/wilds-of-kanto-v<version>.zip`

What actually happened:

- Workflow run `31917733146` for tag `v2.1.6` **failed** after 15s.
- Failure: `scripts/validate-manager-ascii.py` rejected
  `manifest.description` non-ASCII `U+00E9` (`é` in `Pokémon`).
- The workflow never reached `scripts/build-mod.py`.
- The same workflow has failed on every tag since `v1.5.0`. Only `v1.0.0`
  and `v1.0.2` ever produced a CI-packed ZIP.
- The published asset name is `Wilds.of.Kanto.v2.1.6.zip`, not the workflow
  name `wilds-of-kanto-v2.1.6.zip`.
- Archive root is `overworld-spawn-mod-main/` — GitHub's
  **Code → Download ZIP** / `.../archive/refs/heads/main.zip` wrapper.
- Every file byte-matches `git show v2.1.6:<path>`. Zero extra payloads,
  zero content mismatches.

Conclusion: the user-facing v2.1.6 ZIP is a **manual GitHub source archive
of the repo**, not `scripts/build-mod.py` / modkit output.

v2.1.5 and v2.1.0 assets use the same `overworld-spawn-mod-main/` wrapper
and also include `scripts/`, `tools/`, and `tests/`.

## 4. Official ZIP SHA-256

```
0269644c2fefdf7bc83e873f8b842ff72dfd950e2e442a297e2f372a25f20ba2
```

Size: 16,405,425 bytes. 13,526 tracked files + 48 directory entries
(13,574 ZIP entries).

## 5. Rebuilt ZIP SHA-256

Official packer fallback `scripts/build-mod.py` → `pack_manual()`
(modkit unavailable in this environment; same include/exclude rules).

From tag `v2.1.6` (`/tmp/wilds_release_rebuilt_v2.1.6.zip`):

```
8433ca2e882cdd0dc46998124497239a12226a42ca343a1a54ff68e33022b458
```

Size: 15,174,387 bytes. 13,422 files. Flat root (`manifest.json` at top).

From current main after this packaging/metadata branch
(`/tmp/wilds_release_rebuilt.zip`):

```
afaae1e71e7cc5e03584851615fab22fbc56cd33f1a8185f53fd696dbcc0a789
```

Size: 15,188,945 bytes. 13,425 files. Adds
`lib/catching/bindings.lua`, `lib/compat/stadium2_variable_geometry.lua`,
and `docs/release-av-diagnosis-v2.1.6.md` versus the v2.1.6 clean pack.

## 6. Do hashes match?

No. Official ≠ rebuilt. Expected: different compression, timestamps, and
**different file sets**.

## 7. Unexpected files found?

Yes — in the official ZIP only. The official packer already excludes them.

| Path | Type | Why it must not ship |
| --- | --- | --- |
| `scripts/bootstrap.sh` | shell | `git clone` of Gen1Recomp + Voxel from GitHub |
| `scripts/build-mod.ps1` | PowerShell | host packer; `subprocess` / `Compress-Archive` |
| `scripts/build-mod.py` | Python | host packer; `subprocess.check_call` |
| `tools/*.ps1` (6 files) | PowerShell | image/mapping generators; `Add-Type` / file writes |
| `tools/*.py` (11 files) | Python | Pillow generators / validators |
| `tests/` (81 files) | Lua | unit tests, not runtime |
| `.github/workflows/release.yml` | YAML | CI |
| `.gitignore`, `.modkitignore`, `ARCHITECTURE.md` | meta | repo-only |

Official ZIP extensions: 13148 png, 170 json, 161 lua, 22 md, **11 py**,
**6 ps1**, 1 sh, 1 yml, plus LICENSE/card/txt.

Rebuilt ZIP extensions: 13148 png, 169 json, 82 lua, 21 md, 1 card, 1 txt,
LICENSE. **No .ps1 / .py / .sh / .exe / .dll.**

All 13,148 official PNGs have a valid `\x89PNG\r\n\x1a\n` signature.
No PE (`MZ`), ELF, or nested ZIP payloads were found.

## 8. Defender reproduced?

**Not in this environment.** The investigation host is Linux. Microsoft
Defender is not available. This result was not faked.

Windows checklist (do not change Defender settings, do not add exclusions):

```text
MpCmdRun.exe -Scan -ScanType 3 -File C:\path\Wilds.of.Kanto.v2.1.6.zip
MpCmdRun.exe -Scan -ScanType 3 -File C:\path\wilds-of-kanto-v2.1.6-clean.zip
```

Isolation order if the official ZIP still flags:

1. Official ZIP as published
2. Official ZIP with `scripts/` + `tools/` + `tests/` + `.github/` removed
3. ZIP of only `scripts/bootstrap.sh`
4. ZIP of only `tools/*.ps1`
5. ZIP of only `scripts/build-mod.ps1`
6. Clean `pack_manual` ZIP
7. `main.lua` alone, then inside a one-file ZIP
8. `lib/wilds_fs.lua` alone, then inside a one-file ZIP

Record: detection name, affected path, timestamp, full CLI output.

## 9. Exact detected file

Not confirmed by a live Defender scan.

Most likely official-ZIP contents, in order:

1. `scripts/bootstrap.sh` — downloads/clones remote git repos
2. `scripts/build-mod.ps1` and `tools/*.ps1` — PowerShell inside a
   downloaded ZIP (Wacatac.B!ml is a script ML heuristic)
3. `tools/*.py` / `scripts/build-mod.py` — host Python that writes files
   and calls `subprocess`

These files are **not** in a correctly packed Wilds ZIP.

Lua runtime files that heuristics sometimes dislike, but that belong in
a legitimate pack:

- `main.lua` — `mod:read` + `loadstring or load` module loader
- `lib/config.lua` — same pattern for `options.lua`
- `lib/species_geometry.lua` — `loadstring or load` of generated
  `species_table.lua`
- `lib/wilds_fs.lua` — sandbox-safe `mod:read` / `io.open` fallback
  (introduced in v2.1.5)

Do not rewrite those patterns unless a Windows isolation scan names one
of them as the sole trigger.

## 10. Does the file alone trigger?

Unknown here. The official archive as a whole is the only sample users
downloaded. Isolation requires Windows Defender (step 8).

## 11. First triggering commit

Packaging method did **not** start at v2.1.6. v2.1.0 and v2.1.5 GitHub
assets are the same source-archive wrapper with the same `.ps1` / `.py` /
`.sh` set.

Lua deltas that are **not** the published extra files:

- v2.1.0 → v2.1.5: `lib/wilds_fs.lua` added; `main.lua` sandbox loader
- v2.1.5 → v2.1.6: species-asset identity + perf; **no new**
  `loadstring` / `os.execute` / PowerShell / download code

If older source-archive releases were never flagged, the v2.1.6 report
may be a Defender cloud-ML update, higher download volume (3399 at
investigation time), or the same heuristic finally surfacing. That cannot
be proven without scanning v2.1.5 and v2.1.0 on Windows.

## 12. Most likely cause

**Packaging:** the published ZIP is the full git tree, including host
PowerShell/Python and a `git clone` bootstrap script. Wacatac.B!ml is a
machine-learning script heuristic commonly associated with archives that
contain PowerShell and download/execute-style scripts.

Not:

- a renamed executable
- a generated binary blob
- a compromised PNG
- a file that is not in git
- an official `build-mod.py` ZIP (that ZIP was never published)

## 13. Security assessment

**Packaging problem.** No evidence of a malicious implant.

- Official ZIP file bytes == git `v2.1.6` tree
- No unexpected binaries
- Included scripts are the repo's own generators and packers
- `bootstrap.sh` clones known public repos for local development only
- Dynamic Lua `load` is the existing `V.require` / options / geometry
  loader, not remote code

Classification: **likely false positive on a legitimate-but-wrong archive**
(source tree uploaded as the user-facing mod). Not "definitely false
positive" until Windows isolation names the exact member.

## 14. Recommended fix

1. **Republish** a ZIP built by `python3 scripts/build-mod.py`
   (`wilds-of-kanto-v<version>.zip`, `manifest.json` at root).
2. Do **not** upload GitHub "Source code" / `overworld-spawn-mod-main.zip`
   as the playable release asset.
3. Keep the ASCII manager-metadata guard; use ASCII in
   `manifest.description`, `mod.card`, and `options.lua` visible strings
   so CI can reach the packer.
4. Keep the ZIP hygiene check so `.ps1` / `.py` / `.sh` / `tests/` /
   `tools/` / `.github/` cannot ship.

Not acceptable: obfuscating `loadstring`, splitting strings, disabling
Defender, or adding exclusions.

## 15. Are code changes necessary?

- **Runtime Wilds Lua: no.** Do not change `V.require`, `wilds_fs`, or
  geometry loading unless a Windows scan isolates one of those files.
- **Release packaging / CI: yes.** Behavior-preserving. Prevents shipping
  authoring scripts again. Unblocks the official packer.

## 16. Microsoft false-positive submission

Recommended **in addition to republishing a clean ZIP**, so already-downloaded
v2.1.6 copies can be reclassified.

Submit:

| Field | Value |
| --- | --- |
| Product | Wilds of Kanto |
| Version | v2.1.6 |
| Detection | Trojan:Script/Wacatac.B!ml |
| Release URL | https://github.com/YoDrehDenSwagAuf/overworld-spawn-mod/releases/tag/v2.1.6 |
| Commit | `f237bdc796db3f44434447bd75327c670f3650d0` |
| ZIP SHA-256 | `0269644c2fefdf7bc83e873f8b842ff72dfd950e2e442a297e2f372a25f20ba2` |
| Likely members | `scripts/bootstrap.sh`, `scripts/build-mod.ps1`, `tools/*.ps1` |

SHA-256 of those members at v2.1.6:

```
6b4dc7f72c1d6fa45f778672a5c8e6009779f6a5ac229b5135a1e24dadb02966  scripts/bootstrap.sh
6df437e2971de273dedb95959e50a78fc27b363acd7e2ae2cbdd3e0b68e86e4e  scripts/build-mod.ps1
1ed65ea1761f1b88c2f97175b2dd3fbe1846ee41f03d2eddd03943ab3aab3be1  scripts/build-mod.py
70c3b4713494a0c95fdb5cb0462a59cec7fef619eba62340ddf9edad625f20c6  tools/generate_followsprites_mapping.ps1
e4267fcb03c049e1abc22d8d106f410dd23d6e506a9b1fc48995326f976bc49f  tools/generate_runtime_sprite_sheets.ps1
1139f8c1d1318bbd0b70dd1899c62ff0559b8284ce2888a1e6d2b20bf959272f  tools/generate_water_runtime_sheets.ps1
2cccc5a68e7bc580460dcb797d739b79bf6340944402ed2b5f99e0e78b1678d1  tools/validate_release_version.ps1
2b881a1dc55dd4093b147e8cb5a3e5a0cc50517f23c3140b8d0566797b9cae13  tools/validate_water_sprites.ps1
```

Explanation to include: the sample is a Lua LÖVE/Gen1Recomp game mod plus
its development generators. The published ZIP accidentally included those
generators because it was a GitHub source download, not the packed mod.

Portal: https://www.microsoft.com/en-us/wdsi/filesubmission

## 17. Tests run

See the PR / investigation log. Hygiene self-test and official-vs-clean
ZIP checks are required. Full Lua suite is unchanged by this packaging
work (no runtime files edited except ASCII in `manifest.description`).

## 18. Remaining uncertainty

- Defender was not executed here. The exact member Defender names is
  unconfirmed.
- A correctly packed ZIP might still be flagged later for Lua `load` /
  `io.open`. That would be a separate, file-level investigation.
- Current main still fails `tools/validate_option_labels.py` because
  **Ball Switch Key** is 15 characters (added after v2.1.6). That is a
  separate CI blocker; it does not affect `scripts/build-mod.py` locally.
- Manual multi-engine verification (VirusTotal) is recommended on the
  **public** official ZIP and the clean rebuild. It was not automated.

## Windows isolation checklist (copy/paste)

Do not disable Defender. Do not add exclusions. Do not rename or encode
files to hide them.

```text
A. Scan official:  Wilds.of.Kanto.v2.1.6.zip
B. Scan clean:     wilds-of-kanto-v2.1.6.zip from scripts/build-mod.py
C. If A flags and B is clean: packaging is sufficient. Republish B.
D. If A and B both flag: isolate Lua files in step 8 above.
E. If only bootstrap.sh or *.ps1 flag: do not ship them (already the packer rule).
```
