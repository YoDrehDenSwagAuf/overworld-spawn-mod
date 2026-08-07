-- Lightweight follower diagnostics for HUD / tests.
local V = ...

local Diagnostics = {}

function Diagnostics.lines(follower)
  if not follower then
    return { "Follower: n/a" }
  end
  local snap = follower:snapshot()
  local lines = {
    string.format("Follower owner=%s", tostring(snap.ownerMode)),
    string.format("Follower mode=%s count=%s",
                  tostring(snap.engineMode), tostring(snap.followerCount)),
    string.format("Follower surface=%s", tostring(snap.surface)),
    string.format("Follower slot=%s key=%s",
                  tostring(snap.selected_slot),
                  tostring(snap.selected_mon)),
    string.format("Follower SpriteRenderer.new=%s",
                  tostring(snap.spriteRendererNews)),
    string.format("Follower SPRITE_PIKACHU=%s",
                  tostring(snap.spriteRegistered)),
  }
  if snap.externalMods and #snap.externalMods > 0 then
    local ids = {}
    for i = 1, #snap.externalMods do
      ids[#ids + 1] = snap.externalMods[i].id
    end
    lines[#lines + 1] = "Follower legacy=" .. table.concat(ids, ",")
  end
  if snap.lastRefreshReason then
    lines[#lines + 1] = "Follower refresh=" .. tostring(snap.lastRefreshReason)
  end
  return lines
end

return Diagnostics
