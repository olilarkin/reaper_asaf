-- Builds a REAPER project laid out like Apple's Pro Tools session templates
-- ("Up to N Objects + 1 Scene", from the ASAF Production Suite) and saves it as a project template.
--
-- Run inside REAPER with reaper_asaf and ASAF.clap installed. Settings come from the environment:
--   ASAF_TEMPLATE_OBJECTS = 64 | 128 | 192 | 256      ASAF_TEMPLATE_OUT = path of the .RPP to write
--
-- Structure and plug-in settings were read out of the Pro Tools templates.

local N = tonumber(os.getenv("ASAF_TEMPLATE_OBJECTS") or "64")
local OUT = os.getenv("ASAF_TEMPLATE_OUT")
local LOG = os.getenv("ASAF_TEMPLATE_LOG")
local log = LOG and io.open(LOG, "w")
local function L(...) if log then log:write(table.concat({...}, " ") .. "\n"); log:flush() end end
local problems = 0

local function track(name, nch, mainSend, depth)
  local i = reaper.CountTracks(0)
  reaper.InsertTrackAtIndex(i, false)
  local tr = reaper.GetTrack(0, i)
  reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", name, true)
  reaper.SetMediaTrackInfo_Value(tr, "I_NCHAN", nch)
  reaper.SetMediaTrackInfo_Value(tr, "B_MAINSEND", mainSend and 1 or 0)
  if depth then reaper.SetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH", depth) end
  return tr
end

-- Metadata reaches ASAF Export (and the object-to-scene converters) through a shared metadata bus,
-- not along the audio path, so every track that writes or reads it for the export must be processed
-- in step: no anticipative FX. Otherwise REAPER runs some tracks a varying few blocks ahead of others
-- and automation lands early in the export.
local function inStep(tr)
  reaper.SetMediaTrackInfo_Value(tr, "I_PERFFLAGS", reaper.GetMediaTrackInfo_Value(tr, "I_PERFFLAGS") | 2)
end

local function unit(tr, name)
  local fx = reaper.ASAF_AddUnit(tr, name)
  if fx < 0 then problems = problems + 1; L("could not add", name) end
  return fx
end

-- parameters are applied a moment later, once every plug-in has been (re)loaded
local pending = {}
local function set(tr, fx, param, value) if fx >= 0 then pending[#pending + 1] = { tr, fx, param, value } end end

-- multichannel send: nch channels from src (starting at channel 0) to dst starting at dstChan
local function send(src, dst, nch, dstChan)
  local s = reaper.CreateTrackSend(src, dst)
  reaper.SetTrackSendInfo_Value(src, 0, s, "I_SRCCHAN", nch == 1 and 1024 or ((nch // 2) << 10))
  reaper.SetTrackSendInfo_Value(src, 0, s, "I_DSTCHAN", (nch == 1 and 1024 or 0) + (dstChan or 0))
  reaper.SetTrackSendInfo_Value(src, 0, s, "I_MIDIFLAGS", 31)
end

local function color(tr, r, g, b) reaper.SetTrackColor(tr, reaper.ColorToNative(r, g, b)) end

reaper.Undo_BeginBlock()
reaper.PreventUIRefresh(1)
reaper.GetSetProjectInfo(0, "PROJECT_SRATE", 48000, true)
reaper.GetSetProjectInfo(0, "PROJECT_SRATE_USE", 1, true)

local blocks = N // 64
local objectBus = {}

-- ASAF Objects a-b: a folder that is also the 64-channel object bus. Each "Object n" plays into its
-- own channel of the folder (Pro Tools: "Route Object n to ASAF Object Renderer Feeds").
for b = 0, blocks - 1 do
  local a, z = b * 64 + 1, b * 64 + 64
  local bus = track(string.format("ASAF Objects %d-%d", a, z), 64, false, 1)
  color(bus, 90, 150, 110)
  objectBus[b] = bus
  for n = a, z do
    local tr = track("Object " .. n, 2, true, n == z and -1 or 0)
    reaper.SetMediaTrackInfo_Value(tr, "C_MAINSEND_OFFS", n - a)   -- channel of the folder bus
    reaper.SetMediaTrackInfo_Value(tr, "C_MAINSEND_NCH", 1)
    inStep(tr)
    local fx = unit(tr, "ASAF Object")
    if fx >= 0 then reaper.ASAF_ShowEmbeddedUI(tr) end
    set(tr, fx, "Index", n - 1)
  end
end

-- ASAF 7OA: the scene bus (created first so the converters can send to it; moved into place by order below)
-- ASAF Objects > Scene: converts objects flagged "Convert To HOA" into the scene
local sceneFolderFirst = reaper.CountTracks(0)
local o2sFolder = track("ASAF Objects > Scene", 2, false, 1)
color(o2sFolder, 150, 120, 80)
local converters = {}
for b = 0, blocks - 1 do
  local a, z = b * 64 + 1, b * 64 + 64
  local tr = track(string.format("Object %d-%d to Scene", a, z), 64, false, b == blocks - 1 and -1 or 0)
  inStep(tr)
  local fx = unit(tr, "ASAF Object to Scene")
  set(tr, fx, "First Input Object Index", b)
  send(objectBus[b], tr, 64, 0)
  converters[b] = tr
end

local sceneFolder = track("ASAF 7OA", 2, false, 1)
color(sceneFolder, 80, 120, 170)
local scene = track("Scene 1", 64, false, -1)
inStep(scene)
do
  local fx = unit(scene, "ASAF Scene")
  set(scene, fx, "Order", 7)
  set(scene, fx, "Index", 0)
end
for b = 0, blocks - 1 do send(converters[b], scene, 64, 0) end   -- "Convert Objects a-b to Scene & Route to Scene 1 In"

-- ASAF Binaural Renderers: monitoring. The folder sums the renderers' stereo outputs to the master.
local rendFolder = track("ASAF Binaural Renderers", 2, true, 1)
color(rendFolder, 170, 90, 150)
for b = 0, blocks - 1 do
  local a, z = b * 64 + 1, b * 64 + 64
  local tr = track(string.format("Objects %d-%d Binaural Renderer", a, z), 64, true, 0)
  reaper.SetMediaTrackInfo_Value(tr, "C_MAINSEND_NCH", 2)
  local fx = unit(tr, "ASAF Object Renderer")
  set(tr, fx, "Input Index", b)
  set(tr, fx, "Channel Output Type", 1)
  send(objectBus[b], tr, 64, 0)                                    -- "Feed ASAF Objects a-b to Binaural Monitor Out"
end
do
  local tr = track("7OA Binaural Renderer", 64, true, -1)
  reaper.SetMediaTrackInfo_Value(tr, "C_MAINSEND_NCH", 2)
  local fx = unit(tr, "ASAF Scene Renderer")
  set(tr, fx, "Input Index", 0)
  set(tr, fx, "Channel Output Type", 1)
  send(scene, tr, 64, 0)                                           -- "Feed ASAF 7OA to Binaural Monitor Out"
end

local panner = track("ASAF Panner", 2, false)
color(panner, 120, 120, 120)
unit(panner, "ASAF Panner")

local export = track("ASAF Export", 12, false)
color(export, 200, 70, 70)
inStep(export)
unit(export, "ASAF Export")

reaper.PreventUIRefresh(-1)
reaper.TrackList_AdjustWindows(false)
reaper.Undo_EndBlock("ASAF template", -1)
L("built", tostring(reaper.CountTracks(0)), "tracks; problems:", tostring(problems))

-- Let the plug-ins settle, apply settings, let those arrive, then save.
local t0, stage = reaper.time_precise(), 0
local function step()
  local t = reaper.time_precise() - t0
  if stage == 0 and t > 2 then
    stage = 1
    local missing = 0
    for _, p in ipairs(pending) do
      local tr, fx, name, value = p[1], p[2], p[3], p[4]
      local found = false
      for i = 0, reaper.TrackFX_GetNumParams(tr, fx) - 1 do
        local _, pn = reaper.TrackFX_GetParamName(tr, fx, i)
        if pn == name then reaper.TrackFX_SetParam(tr, fx, i, value); found = true; break end
      end
      if not found then missing = missing + 1 end
    end
    L("parameters set:", tostring(#pending - missing), "missing:", tostring(missing))
    problems = problems + missing
    t0 = reaper.time_precise()
  elseif stage == 1 and t > 3 then
    stage = 2
    local wrong = 0
    for _, p in ipairs(pending) do
      local tr, fx, name, value = p[1], p[2], p[3], p[4]
      for i = 0, reaper.TrackFX_GetNumParams(tr, fx) - 1 do
        local _, pn = reaper.TrackFX_GetParamName(tr, fx, i)
        if pn == name then if math.abs(reaper.TrackFX_GetParam(tr, fx, i) - value) > 0.01 then wrong = wrong + 1 end; break end
      end
    end
    L("parameters verified; wrong:", tostring(wrong))
    problems = problems + wrong
    if OUT then reaper.Main_SaveProjectEx(0, OUT, 0); L("saved", OUT) end
    L(problems == 0 and "DONE OK" or ("DONE with " .. problems .. " problems"))
    if log then log:close() end
    return
  end
  reaper.defer(step)
end
step()
