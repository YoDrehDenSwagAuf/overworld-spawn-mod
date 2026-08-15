-- Lightweight DEV-only performance counters for Wilds of Kanto.
--
-- Nearly allocation-free per frame: numeric fields only, one snapshot log
-- per second when Config.debug / Dev Overlay is on. Disabled in release.
local V = ...
local Config = V.require("config")

local PerfStats = {}
PerfStats.__index = PerfStats

PerfStats.WINDOW_SEC = 1.0

local function now()
  if love and love.timer and love.timer.getTime then
    return love.timer.getTime()
  end
  return os.clock()
end

function PerfStats.new(mod)
  local self = setmetatable({}, PerfStats)
  self.mod = mod
  self:resetWindow()
  self._windowStart = now()
  self._lastSnapshot = nil
  self.enabled = false
  return self
end

function PerfStats:resetWindow()
  self.msTotal = 0
  self.msAi = 0
  self.msOccupancy = 0
  self.msVoxelPresence = 0
  self.msVoxelEntity = 0
  self.msAnim = 0
  self.msFx = 0
  self.msFollowers = 0
  self.msMovement = 0
  self.frames = 0
  self.aiTicks = 0
  self.occupancyRebuilds = 0
  self.voxelPresenceRefreshes = 0
  self.spriteResolves = 0
  self.spriteRendererNews = 0
  self.entitiesSample = 0
  self.followersSample = 0
end

function PerfStats:beginFrame()
  self.enabled = Config.debug(self.mod) == true
  if not self.enabled then return nil end
  return now()
end

function PerfStats:addMs(bucket, startT)
  if not self.enabled or startT == nil then return end
  local elapsed = (now() - startT) * 1000
  if elapsed < 0 then elapsed = 0 end
  self[bucket] = (self[bucket] or 0) + elapsed
end

function PerfStats:count(name, n)
  if not self.enabled then return end
  self[name] = (self[name] or 0) + (n or 1)
end

function PerfStats:sampleCounts(entities, followers)
  if not self.enabled then return end
  local ec = 0
  if type(entities) == "table" then
    for _ in pairs(entities) do ec = ec + 1 end
  end
  self.entitiesSample = ec
  self.followersSample = tonumber(followers) or 0
end

function PerfStats:endFrame(frameStart)
  if not self.enabled then return end
  self.frames = self.frames + 1
  if frameStart then
    self.msTotal = self.msTotal + (now() - frameStart) * 1000
  end
  local t = now()
  if (t - self._windowStart) < PerfStats.WINDOW_SEC then return end
  local frames = math.max(1, self.frames)
  local snap = {
    avgTotal = self.msTotal / frames,
    avgAi = self.msAi / frames,
    avgOcc = self.msOccupancy / frames,
    avgVoxelP = self.msVoxelPresence / frames,
    avgVoxelE = self.msVoxelEntity / frames,
    avgAnim = self.msAnim / frames,
    avgFx = self.msFx / frames,
    avgMove = self.msMovement / frames,
    avgFollowers = self.msFollowers / frames,
    aiTicks = self.aiTicks,
    occRebuilds = self.occupancyRebuilds,
    voxelPresence = self.voxelPresenceRefreshes,
    spriteResolves = self.spriteResolves,
    spriteNews = self.spriteRendererNews,
    entities = self.entitiesSample,
    followers = self.followersSample,
    frames = frames,
  }
  self._lastSnapshot = snap
  local mod = self.mod
  if mod and mod.log and type(mod.log.info) == "function" then
    pcall(function()
      mod.log:info(
        "[Wilds][Perf] wilds=%.2fms ai=%.2f occ=%.2f voxelP=%.2f voxelE=%.2f "
          .. "anim=%.2f fx=%.2f move=%.2f followers=%.2f "
          .. "entities=%d followersN=%d aiTicks=%d occRebuilds=%d "
          .. "voxelPresence=%d spriteNews=%d frames=%d",
        snap.avgTotal, snap.avgAi, snap.avgOcc, snap.avgVoxelP, snap.avgVoxelE,
        snap.avgAnim, snap.avgFx, snap.avgMove, snap.avgFollowers,
        snap.entities, snap.followers, snap.aiTicks, snap.occRebuilds,
        snap.voxelPresence, snap.spriteNews, snap.frames)
    end)
  end
  self:resetWindow()
  self._windowStart = t
end

function PerfStats:lastSnapshot()
  return self._lastSnapshot
end

return PerfStats
