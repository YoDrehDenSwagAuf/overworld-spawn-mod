# Standalone Crash Analysis (PR #38 follow-up)

## Reproduction

```text
Installed: overworld_wild_spawns only
Not installed: FOLLOWERS_EX, PokePCFollowers_VoxelMerge
```

Observed in playtests: immediate crash with only Wilds active.

## Root cause (precise)

1. **Load phase:** `SpawnRender:registerContent()` registers only `SPRITE_OW_WILD_*` /
   placeholder / fallback. It never registers **`SPRITE_PIKACHU`**.
2. PokéPC previously did this during mod entry (before content freeze):
   `mod.content.sprites:register/patch("SPRITE_PIKACHU", { walker, frames=6, … })`.
3. Wilds `Lifecycle:shouldSpawn` returns `true` for any healthy party mon and
   **does not** check `game.data.sprites["SPRITE_PIKACHU"]` (PokéPC did).
4. With no external mods, `resolveOwnerMode()` → `wilds`, hooks install, stock
   `PikachuFollower` attempts to spawn an NPC with `sprite = "SPRITE_PIKACHU"`.
5. **Crash:** engine looks up a never-registered sprite id (especially Red/Blue).

### Timing

| Phase | Result |
|-------|--------|
| Mod load / `registerContent` | Missing `SPRITE_PIKACHU` |
| Content freeze | Too late to register |
| `mods.loaded` / `game.ready` | Hooks reasserted; still no sprite |
| First map enter / `PikachuFollower.update` | `shouldSpawn` true → spawn → **crash** |

### First Wilds stack frames (expected)

```text
Lifecycle:shouldSpawn → true
PikachuFollower.update / onMapEntered (stock)
NPC / SpriteRenderer resolve SPRITE_PIKACHU → nil / error
```

## Fix requirements

1. Register/patch `SPRITE_PIKACHU` in load phase using Wilds walker sheets
   (`assets/generated/followsprites_runtime/` — already 16×96, frames=6).
2. Guard `shouldSpawn` if sprite def missing.
3. Prefer entity-local rebinds afterward; do not mutate global def every update.
4. Automated standalone boot test with `mod:find` always nil.
