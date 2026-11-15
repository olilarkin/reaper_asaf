-- Step 2 of converting an ambiX-panned REAPER project to ASAF objects. Run inside REAPER (with
-- reaper_asaf and ASAF.clap installed) after prepare.py:
--
--   ASAF_PROJECT=<prepared.RPP> ASAF_OBJECTS=<objects.lua> [ASAF_LOG=<file>] REAPER convert.lua
--
-- Opens the prepared project, and for every entry in the objects table puts ASAF Object plug-ins on
-- the track (two for a stereo source: left and right, spread by the encoder's width), recreates the
-- encoder's automation as azimuth envelopes, and routes the track to 64-channel object busses that
-- feed binaural renderers. Saves the project in place.

local PROJECT, OBJECTS, LOG = os.getenv("ASAF_PROJECT"), os.getenv("ASAF_OBJECTS"), os.getenv("ASAF_LOG")
local log = LOG and io.open(LOG, "w")
local function L(...) if log then log:write(table.concat({...}, " ") .. "\n"); log:flush() end end
local objects = dofile(OBJECTS)
local problems = 0
local function problem(...) problems = problems + 1; L("PROBLEM:", ...) end

reaper.Main_openProject("noprompt:" .. PROJECT)

local function paramIndex(tr, fx, name)
  for i = 0, reaper.TrackFX_GetNumParams(tr, fx) - 1 do
    local _, pn = reaper.TrackFX_GetParamName(tr, fx, i)
    if pn == name then return i end
  end
end

local function newTrack(name, nch, mainSend, depth)
  local i = reaper.CountTracks(0)
  reaper.InsertTrackAtIndex(i, false)
  local tr = reaper.GetTrack(0, i)
  reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", name, true)
  reaper.SetMediaTrackInfo_Value(tr, "I_NCHAN", nch)
  reaper.SetMediaTrackInfo_Value(tr, "B_MAINSEND", mainSend and 1 or 0)
  reaper.SetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH", depth or 0)
  return tr
end

-- ---------------------------------------------------------------- azimuth over time

-- Adds an envelope for an unwrapped, piecewise-linear azimuth. ASAF azimuth runs -180..180, so each
-- segment is split wherever it crosses the back of the head.
local function writeAzimuth(env, segments)
  local lastT, lastV, count = nil, nil, 0
  local function add(t, v)
    if lastT and math.abs(t - lastT) < 1e-9 and math.abs(v - lastV) < 1e-9 then return end
    if lastT and t <= lastT then t = lastT + 1e-6 end
    reaper.InsertEnvelopePoint(env, t, v, 0, 0, false, true)
    lastT, lastV, count = t, v, count + 1
  end
  local function wrap(a, approachingFrom) -- approachingFrom: +1 if the value is reached while rising, -1 falling
    local w = ((a + 180) % 360) - 180
    if w == -180 and approachingFrom > 0 then w = 180 end
    return w
  end
  for _, s in ipairs(segments) do
    local t0, a0, t1, a1 = s[1], s[2], s[3], s[4]
    local dir = a1 > a0 and 1 or (a1 < a0 and -1 or 0)
    add(t0, wrap(a0, -dir))
    if dir ~= 0 and t1 > t0 then
      local k = dir > 0 and math.floor((a0 + 180) / 360) + 1 or math.ceil((a0 + 180) / 360) - 1
      while true do
        local b = 360 * k - 180
        if (dir > 0 and b >= a1) or (dir < 0 and b <= a1) then break end
        local tc = t0 + (b - a0) / (a1 - a0) * (t1 - t0)
        add(tc, dir > 0 and 180 or -180)
        add(tc + 1e-6, dir > 0 and -180 or 180)
        k = k + dir
      end
    end
    add(t1, wrap(a1, dir))
  end
  reaper.Envelope_SortPoints(env)
  return count
end

-- Unwrapped azimuth segments {t0, a0, t1, a1} for one side of a source (side: +1 left, -1 right, 0 mono).
local function azimuthSegments(o, side, projectEnd)
  local segs = {}
  if #o.azPts > 1 then
    if #o.wPts > 1 then problem(o.name, "has both azimuth and width automation; width automation ignored") end
    local half = side * o.w / 2
    for i = 1, #o.azPts - 1 do
      local p, q = o.azPts[i], o.azPts[i + 1]
      if q[1] > p[1] then segs[#segs + 1] = { p[1], p[2] + o.azOffset + half, q[1], q[2] + o.azOffset + half } end
    end
  elseif #o.wPts > 1 and side ~= 0 then
    for i = 1, #o.wPts - 1 do
      local p, q = o.wPts[i], o.wPts[i + 1]
      if q[1] > p[1] then segs[#segs + 1] = { p[1], o.az + side * p[2] / 2, q[1], o.az + side * q[2] / 2 } end
    end
  elseif o.rot ~= 0 then
    local a0 = o.az + side * o.w / 2
    segs[1] = { 0, a0, projectEnd, a0 + o.rot * projectEnd }
  end
  return segs
end

local function azimuthAtStart(o, side)
  local a = o.az + side * o.w / 2
  if #o.azPts > 1 then a = o.azPts[1][2] + o.azOffset + side * o.w / 2
  elseif #o.wPts > 1 then a = o.az + side * o.wPts[1][2] / 2 end
  return ((a + 180) % 360) - 180
end

-- ---------------------------------------------------------------- build

local created = {}   -- { track, fx, side, o, index }
local renderers = {}

local function build()
  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)
  local total = 0
  for _, o in ipairs(objects) do total = total + (o.stereo and 2 or 1) end
  local blocks = math.ceil(total / 64)

  -- Object busses and binaural monitoring, in a folder at the end of the project.
  newTrack("ASAF", 2, true, 1)
  local bus = {}
  for b = 0, blocks - 1 do
    bus[b] = newTrack(string.format("ASAF Objects %d-%d", b * 64 + 1, b * 64 + 64), 64, false, 0)
  end
  for b = 0, blocks - 1 do
    local tr = newTrack(string.format("Objects %d-%d Binaural Renderer", b * 64 + 1, b * 64 + 64), 64, true, b == blocks - 1 and -1 or 0)
    reaper.SetMediaTrackInfo_Value(tr, "C_MAINSEND_NCH", 2)
    local fx = reaper.ASAF_AddUnit(tr, "ASAF Object Renderer")
    if fx < 0 then problem("could not add ASAF Object Renderer") end
    local s = reaper.CreateTrackSend(bus[b], tr)
    reaper.SetTrackSendInfo_Value(bus[b], 0, s, "I_SRCCHAN", 32 << 10)   -- 64 channels
    reaper.SetTrackSendInfo_Value(bus[b], 0, s, "I_DSTCHAN", 0)
    reaper.SetTrackSendInfo_Value(bus[b], 0, s, "I_MIDIFLAGS", 31)
    renderers[#renderers + 1] = { tr, fx, b }
  end

  -- Stereo sources take an even/odd pair of object indices so one stereo send reaches both channels.
  local nextIndex = 0
  local function place(o)
    local tr = reaper.GetTrack(0, o.track - 1)
    local _, name = reaper.GetTrackName(tr)
    if name ~= o.name then problem("track " .. o.track .. " is '" .. name .. "', expected '" .. o.name .. "'") end
    -- Positions reach ASAF Export through a shared metadata bus, not along the audio path, so object
    -- tracks must not be processed ahead of the export bus: no anticipative FX. (An export bus added
    -- later needs the same; "ASAF: Set up session" does it for the tracks it creates.)
    reaper.SetMediaTrackInfo_Value(tr, "I_PERFFLAGS", reaper.GetMediaTrackInfo_Value(tr, "I_PERFFLAGS") | 2)
    local index = nextIndex
    nextIndex = nextIndex + (o.stereo and 2 or 1)
    local sides = o.stereo and { 1, -1 } or { 0 }
    for n, side in ipairs(sides) do
      local fx = reaper.ASAF_AddUnit(tr, "ASAF Object")
      if fx < 0 then problem("could not add ASAF Object to " .. o.name)
      else
        if n == 2 then   -- second instance works on the track's right channel
          reaper.TrackFX_SetPinMappings(tr, fx, 0, 0, 2, 0)
          reaper.TrackFX_SetPinMappings(tr, fx, 1, 0, 2, 0)
        end
        created[#created + 1] = { tr = tr, fx = fx, side = side, o = o, index = index + n - 1 }
      end
    end
    local b, c = index // 64, index % 64
    local s = reaper.CreateTrackSend(tr, bus[b])
    reaper.SetTrackSendInfo_Value(tr, 0, s, "I_SRCCHAN", o.stereo and 0 or 1024)
    reaper.SetTrackSendInfo_Value(tr, 0, s, "I_DSTCHAN", o.stereo and c or (c | 1024))
    reaper.SetTrackSendInfo_Value(tr, 0, s, "D_VOL", o.gain)          -- the gain of the folders it used to sum through
    reaper.SetTrackSendInfo_Value(tr, 0, s, "I_MIDIFLAGS", 31)
  end
  for _, o in ipairs(objects) do if o.stereo then place(o) end end
  for _, o in ipairs(objects) do if not o.stereo then place(o) end end

  reaper.PreventUIRefresh(-1)
  reaper.TrackList_AdjustWindows(false)
  reaper.Undo_EndBlock("Convert ambiX encoders to ASAF objects", -1)
  L("built:", #created, "objects on", #objects, "tracks;", blocks, "object busses")
end

local function setParameters()
  for _, c in ipairs(created) do
    local p = { Index = c.index, Azimuth = azimuthAtStart(c.o, c.side), Elevation = c.o.el }
    for name, value in pairs(p) do
      local i = paramIndex(c.tr, c.fx, name)
      if i then reaper.TrackFX_SetParam(c.tr, c.fx, i, value) else problem("no parameter " .. name) end
    end
  end
  for _, r in ipairs(renderers) do
    if r[2] >= 0 then
      reaper.TrackFX_SetParam(r[1], r[2], paramIndex(r[1], r[2], "Input Index"), r[3])
      reaper.TrackFX_SetParam(r[1], r[2], paramIndex(r[1], r[2], "Channel Output Type"), 1)   -- Binaural
    end
  end
end

local function finish()
  local wrong, seen = 0, {}
  for _, c in ipairs(created) do
    local idx = reaper.TrackFX_GetParam(c.tr, c.fx, paramIndex(c.tr, c.fx, "Index"))
    local az = reaper.TrackFX_GetParam(c.tr, c.fx, paramIndex(c.tr, c.fx, "Azimuth"))
    local el = reaper.TrackFX_GetParam(c.tr, c.fx, paramIndex(c.tr, c.fx, "Elevation"))
    local wantAz = azimuthAtStart(c.o, c.side)
    local dAz = math.abs(((az - wantAz + 180) % 360) - 180)
    if math.abs(idx - c.index) > 0.01 or dAz > 0.05 or math.abs(el - c.o.el) > 0.05 or seen[math.floor(idx + 0.5)] then wrong = wrong + 1 end
    seen[math.floor(idx + 0.5)] = true
  end
  L("parameters verified; wrong:", wrong)
  problems = problems + wrong

  local projectEnd = reaper.GetProjectLength(0) + 10
  local envs, points = 0, 0
  for _, c in ipairs(created) do
    local segs = azimuthSegments(c.o, c.side, projectEnd)
    if #segs > 0 then
      local env = reaper.GetFXEnvelope(c.tr, c.fx, paramIndex(c.tr, c.fx, "Azimuth"), true)
      if env then
        local _, _, _, _, _, _ = reaper.GetEnvelopePoint(env, 0)
        reaper.DeleteEnvelopePointRange(env, -1, projectEnd + 1000)
        points = points + writeAzimuth(env, segs); envs = envs + 1
      else problem("could not create an azimuth envelope on " .. c.o.name) end
    end
  end
  L("azimuth envelopes:", envs, "points:", points, "project length:", string.format("%.1f", projectEnd - 10))
  reaper.UpdateArrange()
  reaper.Main_SaveProject(0, false)
  L("saved", PROJECT)
  L(problems == 0 and "DONE OK" or ("DONE with " .. problems .. " problems"))
  if log then log:close() end
end

local t0, stage = reaper.time_precise(), 0
local function step()
  local t = reaper.time_precise() - t0
  if stage == 0 and t > 3 then
    L("opened:", reaper.CountTracks(0), "tracks")
    build(); stage = 1; t0 = reaper.time_precise()
  elseif stage == 1 and t > 3 then
    setParameters(); stage = 2; t0 = reaper.time_precise()
  elseif stage == 2 and t > 4 then
    finish(); return
  end
  reaper.defer(step)
end
step()
