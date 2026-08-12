-- In-memory compatibility adapter: DRAMALESS_SHAPE SpriteBillboards.mesh
-- consumes Wilds / Gen1Recomp variable SpriteDef geometry.
--
-- Dramaless (manifest id DRAMALESS_SHAPE, inspected 1.6.4) exposes
-- exports.lib = V with V.require. VoxelScene.drawEntity uses
-- SpriteBillboards.mesh; drawGhost / drawShadow / the sun sprite layer use
-- shadowQuad (an alias of mesh at load). Wilds wraps mesh and re-points
-- shadowQuad so body, occlusion silhouette, and sprite-mesh shadows agree.
-- Dramaless source is not copied and is not patched on disk.
--
-- Pivot: billboardMatrix applies T(-8,0,0), same convention as Battle Art.
local V = ...
local Factory = V.require("compat/voxel_sprite_billboards_adapter")

return Factory.create({
  providerId = "DRAMALESS_SHAPE",
  displayName = "Dramaless",
  failLog = "Dramaless variable geometry unavailable; using Classic",
  okInstalled = "Dramaless variable geometry: adapter installed",
  okNative = "Dramaless variable geometry: native",
})
