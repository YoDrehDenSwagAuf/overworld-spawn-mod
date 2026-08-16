-- In-memory compatibility adapter: STADIUM2_OVERWORLD_MODELS SpriteBillboards.mesh
-- consumes Wilds / Gen1Recomp variable SpriteDef geometry.
--
-- Stadium2 (manifest id STADIUM2_OVERWORLD_MODELS) is the Gen 2 voxel
-- renderer. Current versions expose exports.lib = V with V.require, the
-- same public SpriteBillboards / Voxel3D / VoxelScene contract as Battle
-- Art, Potato, and Dramaless. Wilds wraps mesh() and re-points shadowQuad
-- so body, occlusion silhouette, and sprite-mesh shadows agree.
-- Stadium2 source is not copied and is not patched on disk.
--
-- Pivot: VoxelScene billboard / caster matrices apply T(-8,0,0), same
-- convention as Battle Art. Variable quads land the SpriteDef anchor on
-- that pivot. Classic 16×16 + anchor 8,16 stays on the original mesh().
--
-- Embedded Wilds: some Stadium2 builds have shipped their own Wilds
-- runtime. This adapter only talks to SpriteBillboards. It does not
-- disable Stadium2 event handlers or rewrite Stadium2 files. See
-- Adapter.detectEmbeddedWilds() for a public-export probe only.
local V = ...
local Factory = V.require("compat/voxel_sprite_billboards_adapter")

local Adapter = Factory.create({
  providerId = "STADIUM2_OVERWORLD_MODELS",
  displayName = "Stadium2 Voxel",
  failLog = "Stadium2 Voxel variable geometry unavailable; using Classic",
  okInstalled = "Stadium2 Voxel variable geometry: adapter installed",
  okNative = "Stadium2 Voxel variable geometry: native",
})

--- Public-API probe only. Never disables another mod's handlers.
function Adapter.detectEmbeddedWilds(mod)
  local ds = Adapter.findProvider(mod)
  if not ds then
    return false, "provider_absent"
  end
  local ex = ds.exports
  if type(ex) ~= "table" then
    return false, "no_public_embedded_wilds_signal"
  end
  if ex.embeddedWilds == true
      or ex.embedsWilds == true
      or ex.wildsRuntime == true then
    return true, "exports_flag"
  end
  if type(ex.wilds) == "table"
      or type(ex.overworldWildSpawns) == "table"
      or type(ex.overworld_wild_spawns) == "table" then
    return true, "exports_wilds_table"
  end
  return false, "no_public_embedded_wilds_signal"
end

return Adapter
