# Pre-implementation analysis — OPTIONS menus, Sprite Color/Fade, Town Pokémon

## 1. Where the two submenus are inserted today

`lib/settings_menus.lua` wraps `ui.start_menu.items` and inserts
`POKE FOLLOW EX` / `WILDS OF KANTO` **before** the Start Menu `OPTION` row via
`mod.ui.insertBefore(out, "OPTION", row)`.

## 2. Why they are not under START → OPTIONS

They were added as Start Menu entries (same pattern as Followers EX optional
`FLL EX`), not as `ui.options.rows` activate rows. Gen1Recomp OPTIONS uses
`ui.options.rows` (see Followers EX and `lib/preview_browser.lua` Test Spawn).

## 3. Integrated PokéPC / Followers EX settings

| Setting | Key | Status |
|---------|-----|--------|
| Control Mode | `follow_control` | Integrated |
| Trainer Trail | `trainer_trail` | Integrated |
| Followers | `follower_count` | Integrated |
| Leader | party submenu | Integrated (hint in menu) |
| Box Leader | — | Not implemented (do not show) |
| Sprite Color | — | Missing (restore from PokéPC) |

## 4. Upstream Sprite Color semantics (PokéPC)

- Key: `color_mode`
- `"gbc"` → `trueColor = false` (Classic / GBC palette path)
- otherwise → `trueColor = true` (Colored)
- Affects follower SpriteDefs (`trueColor` flag); uses native SpriteRenderer

## 5. Sprite Fade code status

- Public option `sprite_opacity` (Solid 1.0 / Tucked 0.88 / Faint 0.72) removed in 1.0.0
- Runtime still reads `Config.get(mod, "sprite_opacity")` in `spawn_render.lua`
- Default in `Config.DEFAULTS` is `1.0`
- Restore as public `sprite_fade` Solid/Faded; Solid ⇒ alpha 1.0; Faded ⇒ 0.72

## 6. Map classification already present

- `EncounterIndex.mapTypeOf`: town / building / route / cave / water / overworld
- `Surface.isIndoorEncounterMap`: cave/tower/mansion indoor encounter maps
- Followers EX `wilds_town_spawns` was battleable wild borrow — **not** ambient NPCs

## 7. Interact hooks to reuse

- Normal path: `OverworldState:interact` → `talkTo(npc)` for non-moving NPCs
- Extend `talkTo` once for `wildsAmbientPokemon` (no parallel A-button poll)
- Yellow follower talk stays on stock `PikachuFollower.talk`

## 8. Textual cry data in Gen1Recomp

- `Sound.playCry` / cry pitch-base-length are **audio**, not text
- Yellow TalkToPikachu uses emotion bubbles + PCM clips, not string cries
- No usable species cry-string table found → curated short table + `[...]`
