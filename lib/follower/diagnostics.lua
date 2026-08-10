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
  -- Control engine: which re-seed branch parked/placed the pack last.
  -- This is the key Yellow door-exit diagnostic (parked_at_player is the
  -- healthy "spawn at the door" state; anything else means the pack was
  -- re-placed instead of walking out from under the player).
  local ctl = follower.control
  if ctl and ctl.diag then
    lines[#lines + 1] = "Seed=" .. tostring(ctl.diag.lastSeed)
    lines[#lines + 1] = "Seed parks=" .. tostring(ctl.diag.entryParks or 0)
    lines[#lines + 1] = "Seed reforms=" .. tostring(ctl.diag.trailReforms or 0)
    lines[#lines + 1] = "Seed water=" .. tostring(ctl.diag.behindWaterSeeds or 0)
  end
  return lines
end

return Diagnostics
