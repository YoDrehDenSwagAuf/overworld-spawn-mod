-- In-memory compatibility adapter: Potato Voxel SpriteBillboards.mesh
-- consumes Wilds / Gen1Recomp variable SpriteDef geometry.
--
-- Potato Voxel (manifest id potato_voxel, inspected 1.4.0) exposes
-- exports.lib = V with V.require — the same public module table VoxelScene
-- already uses. Wilds wraps SpriteBillboards.mesh / shadowQuad on that
-- table. Potato source is not copied and is not patched on disk.
--
-- Potato's dedicated low-end contact shadow (SpriteBillboards.shadowBlob)
-- is independent of the animated sprite mesh and is left unchanged.
-- HIGH-quality sun / occlusion still use mesh / shadowQuad.
--
-- Pivot: VoxelScene.billboardMatrix / Voxel3D.casterMatrix apply T(-8,0,0),
-- same convention as Battle Art. Variable quads land the SpriteDef anchor
-- on that pivot.
local V = ...
local Factory = V.require("compat/voxel_sprite_billboards_adapter")

return Factory.create({
  providerId = "potato_voxel",
  displayName = "Potato Voxel",
  failLog = "Potato Voxel variable geometry unavailable; using Classic",
  okInstalled = "Potato Voxel variable geometry: adapter installed",
  okNative = "Potato Voxel variable geometry: native",
})
