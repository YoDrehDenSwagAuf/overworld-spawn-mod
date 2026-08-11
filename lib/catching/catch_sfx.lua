-- Native Gen1Recomp catch SFX for overworld catching.
-- Keys verified from Gen1Recomp BattleState / AnimPlayer / rom_manifest
-- (Red/Blue/Yellow share the same names). No audio files are bundled.
local CatchSfx = {}

-- Role → engine data.audio.sfx key. `click` has no distinct Gen1 SFX.
CatchSfx.KEYS = {
  throw = "Ball_Toss",
  impact = "Ball_Poof",
  wobble = "Tink",
  ["break"] = "Ball_Poof",
  click = nil,
  caught = "Caught_Mon",
}

function CatchSfx.keyFor(role)
  return CatchSfx.KEYS[role]
end

--- Play a verified native catch SFX via Sound.play (fanfare ducking included).
-- Safe no-op when game/data/audio/key/Sound are missing (headless/tests).
-- @return true if Sound.play was invoked for a known key
function CatchSfx.playNativeCatchSfx(game, role)
  local key = CatchSfx.KEYS[role]
  if type(key) ~= "string" or key == "" then
    return false
  end
  if not (game and game.data) then
    return false
  end
  local audio = game.data.audio
  local sfx = audio and audio.sfx
  if not (type(sfx) == "table" and sfx[key] ~= nil) then
    return false
  end
  local ok, Sound = pcall(require, "src.core.Sound")
  if not (ok and Sound and type(Sound.play) == "function") then
    return false
  end
  local played = false
  pcall(function()
    Sound.play(game.data, key)
    played = true
  end)
  return played
end

return CatchSfx
