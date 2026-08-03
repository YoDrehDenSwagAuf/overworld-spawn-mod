# Release test checklist — Wilds of Kanto 1.0.2

Use this checklist before publishing a GitHub release and when verifying Mod
Manager update detection.

## A. Local / CI packaging

1. Set versions consistently to `1.0.2` in `manifest.json` and `main.lua`.
2. Ensure `CHANGELOG.md` has a `## 1.0.2` section.
3. Create and push the tag:

```sh
git tag v1.0.2
git push origin v1.0.2
```

4. Confirm `.github/workflows/release.yml` runs on the tag.
5. Confirm the GitHub Release appears with asset:

```text
wilds-of-kanto-v1.0.2.zip
```

6. Download the ZIP and verify `manifest.json` is at the archive root
   (not inside a wrapping folder).

## B. Gen1Recomp Mod Manager update path

1. Install an older packaged build (or temporarily set the installed mod to an
   older `version` while keeping id `overworld_wild_spawns`).
2. Publish a newer GitHub Release (for example `v1.0.2` after a `1.0.0` install).
3. Open or refresh the Gen1Recomp Mod Manager.
4. Confirm the manager associates the mod with
   `YoDrehDenSwagAuf/overworld-spawn-mod` via the manifest `github` field.
5. Confirm the newer release is listed / offered as an update.
6. Install the update.
7. Confirm:

   - Mod id remains `overworld_wild_spawns`
   - Saved settings that still use the same internal keys remain intact
   - `manifest.json` version is `1.0.2`
   - Wild Pokemon still render via native SpriteRenderer sheets

## C. Option label smoke test

1. Open Mod Manager options for Wilds of Kanto.
2. Confirm every visible option label and choice name is fully readable
   (no truncation at 14 characters).
3. Confirm only the simplified 1.0 public options are shown.
4. Toggle `Sprite Style`, `Spawn Amount`, `Grass View`, `Roam Mons`,
   `Chase Mons`, `Hidden Mons`, and `Dev Mode` and verify each still affects
   runtime behaviour.
