-- Gen 2 adapter stub. Intentionally unsupported.
--
-- Do not claim Gold / Silver / Crystal support. Do not guess Johto internals.
-- The next PR replaces this stub with a real adapter and may then set
-- supported = true AND add manifest `"games": ["gen1", "gen2"]`.
--
-- Required future methods (same shapes as lib/game_compat/gen1.lua):
--   speciesId(species, game, mod) → number|nil
--   isSurfing(game, ow)           → boolean
--   isWaterCell(map, x, y)        → boolean
--   party(game)                   → table|nil  (same object as the live party)
--   currentMapId(game, ow)        → map id | nil
--
-- Engine pointers for the next PR (current Gen1Recomp Gold, do not call yet):
--   party:        Gold World still uses game.save.party
--   isSurfing:    src.world.gen2.FieldMoves.isSurfing(playerState)
--                 (PLAYER_SURF / PLAYER_SURF_PIKA — not Gen1 player.surfing)
--   currentMapId: ow.map.id once Gold World is live
--   speciesId:    engine pokemon data; do not copy Gen1 SPECIES_TO_DEX
--
-- Do not add placeholder functions that return guessed Gold/Silver values.
-- GameCompat.current() will keep returning nil until supported == true.
local Gen2 = {}
Gen2.supported = false
Gen2.generation = 2

return Gen2
