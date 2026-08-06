# Feature Inventory — Standalone Follower Follow-up

```text
Feature                         | Followers EX source              | PokéPC source           | Wilds now                         | Missing? | Standalone dep | Integration action              | Test
--------------------------------+----------------------------------+------------------------+-----------------------------------+----------+----------------+---------------------------------+--------------------
SPRITE_PIKACHU registration     | ControlEngine load patch         | main register/patch     | sprite_service:registerLoadPhase  | No       | Wilds sheets   | Register before freeze          | standalone_boot
151 walker sheets               | PokePC asset pack                | assets/sprites/*        | followsprites_runtime (reuse)     | No*      | Wilds assets   | Reuse HGSS/PokeMMO; no copy     | resolveFollowerSprite
Party selection UI              | LEADER / modes                   | FOLLOWER submenu        | FOLLOWER + LEADER                 | Partial† | none           | Ported                          | core + manual
Fingerprint                    | species|lvl|nick|ot|dvs          | ot:dvs:catchRate        | species:ot:dvs:catchRate          | No       | none           | Improved                        | core
Persist selection               | pokepcLeader                     | selected_mon/slot       | follower_selected_* v1            | No       | none           | Migrate legacy                  | core
Control Mode                    | control_mode option              | n/a                     | follow_control                    | No       | none           | Wilds Mod Settings              | standalone_boot
Trainer Trail                   | trainer_follows                  | n/a                     | trainer_trail                     | No       | none           | Wilds Mod Settings              | standalone_boot
Follower Count 0–6              | follower_count                   | n/a                     | follower_count                    | No       | none           | Wilds Mod Settings              | standalone_boot
Modes follow/pokemon/pack/lead  | ControlEngine                    | n/a                     | settings.engineMode + CE          | No       | none           | Ported ControlEngine            | settings mapping
syncTrailers / syncAll          | ControlEngine                    | n/a                     | control_engine.lua                | No       | none           | Ported                          | unit smoke
makeTrailer / pack trailers     | ControlEngine                    | n/a                     | control_engine.lua                | No       | NPC engine     | Ported + Wilds markers          | manual
Player-as-pokemon               | applyPlayerAsPokemon             | n/a                     | control_engine.lua                | No       | SpriteRenderer | Ported                          | manual R/B/Y
Bike / Surf                     | restore trainer visual           | shouldSpawn false       | CE + lifecycle guards             | No       | none           | Combined                        | core + manual
Yellow stock Pikachu            | yellowStockFollowActive          | vanilla talk            | CE + interaction                   | No       | none           | Ported                          | manual Yellow
Talk                            | interact wrap                    | wrappedTalk             | CE talk + lifecycle               | No       | none           | Ported                          | manual
Box LEADER                      | BoxMenu inject                   | n/a                     | Not in this follow-up             | Yes†     | —              | PR 1b candidate                 | —
show_in_menu                    | Start menu FLL EX                | n/a                     | Not needed (settings in Wilds)    | Dropped  | —              | Documented                      | —
wilds_town_spawns               | WildsExtras                      | n/a                     | Not duplicated                    | Future   | —              | Document as future Wilds feat   | —
wilds_grass_lift                | maps to Grass View               | n/a                     | Existing Grass View               | No       | —              | Do not duplicate                | —
Water follower sprites          | n/a                              | despawn                 | followers_water_compat            | No       | none           | Kept                            | water compat
Shared sprite resolver          | n/a                              | global mutate           | resolveFollowerSprite service     | PR2      | none           | Prepared API                    | standalone_boot
Icon global mutate              | n/a                              | generated.icons         | Not adopted                       | Dropped  | —              | Avoid global mutation           | —
```

\* "Poke Followers" style without external pack falls back to HGSS/PokeMMO sheets.
† Box LEADER / full EX party mode menu remains a documented deviation (PR 1b).

## Assets

| Source | Action |
|--------|--------|
| Wilds `assets/generated/followsprites_runtime/*.png` | **Reused** as standalone walker sheets (16×96, frames=6) |
| PokéPC `follower_NNN.png` | **Not copied** — optional via style `followers` when pack installed; otherwise fallback chain |
| Credits | ShockSlayer / Pokémon Crystal Clear (via PokéPC lineage); Wilds HGSS follow-sprites under existing THIRD_PARTY_NOTICES |

## Crash root cause (fixed)

Missing `SPRITE_PIKACHU` registration + unguarded `shouldSpawn`. See `STANDALONE_CRASH.md`.
