-- Export test inside REAPER: builds the same scenario as asaf_clap/tools/export_test.mm in a new
-- project tab, renders it through the "ASAF" render format and logs what happened. Run it with
-- run.sh, or by hand:
--
--   ASAF_TEST_OUT=<dir> ASAF_KEEP_BOUNCE=1 ASAF_NO_DIALOGS=1 ASAF_DEBUG=1 [ASAF_TEST_QUIT=1] \
--     /Applications/REAPER.app/Contents/MacOS/REAPER -newinst -nosplash -new reaper_export_test.lua
--
-- or from the action list (Actions > Load ReaScript); output then goes to ~/asaf_export_test unless
-- ASAF_TEST_OUT is set, and the bounce is only kept if REAPER was started with ASAF_KEEP_BOUNCE=1.
--
-- Writes into <dir>:
--   reaper_export.wav          the render: an ASAF BWF if conversion worked, else the bounce
--   reaper_export.bounce.wav   the render before conversion (with ASAF_KEEP_BOUNCE=1)
--   reaper_export_test.RPP     the project that was rendered
--   reaper_export_test.log     this script's log
-- (reaper_scene.* and reaper_scene_test.* with ASAF_TEST_SCENE)
-- Check the .wav files with asaf_inspect.py --expect.
--
-- ASAF_TEST_PERFFLAGS=<n> sets I_PERFFLAGS on every track before rendering (2 = no anticipative FX),
-- to see whether REAPER processing tracks ahead of one another affects the result.
--
-- ASAF_TEST_SCENE=<file> adds an ambisonic scene ahead of the objects: an ACN/SN3D file with
-- (order+1)^2 channels, placed on a scene track made by ASAF_SetupSceneSession.
--
-- ASAF_TEST_TEMPLATE=<objects> (64, 128, 192 or 256) runs the scenario in a project made from that
-- template instead, with ASAF_TEST_SCENE (64 channels) on its scene track, and exports it with
-- ASAF_ExportProject, which renders the template's busses separately and joins them.
--
-- Scenario (4 s, 48 kHz): four objects with 220/440/660/880 Hz tones at -12 dB;
--   1: azimuth +90   2: azimuth -90   3: elevation 45, distance 2   4: azimuth automated -90 -> +90

local OUT = os.getenv("ASAF_TEST_OUT") or ((os.getenv("HOME") or "/tmp") .. "/asaf_export_test")
local QUIT = os.getenv("ASAF_TEST_QUIT") == "1"
local NOBJ, SECONDS, RATE = 4, 4, 48000


local SCENE = os.getenv("ASAF_TEST_SCENE")
if SCENE == "" then SCENE = nil end
local TEMPLATE = tonumber(os.getenv("ASAF_TEST_TEMPLATE") or "")
local NAME = TEMPLATE and "reaper_template" or SCENE and "reaper_scene" or "reaper_export"
local sceneCh = 0

reaper.RecursiveCreateDirectory(OUT, 0)
local log = io.open(OUT .. "/" .. NAME .. "_test.log", "w")
local function L(...)
  local t = {}
  for _, v in ipairs({...}) do t[#t + 1] = tostring(v) end
  local s = table.concat(t, " ")
  if log then log:write(s .. "\n"); log:flush() end
  if not QUIT then reaper.ShowConsoleMsg(s .. "\n") end
end
local problems = 0
local function problem(...) problems = problems + 1; L("PROBLEM:", ...) end

local function writeTone(path, hz)
  local f = assert(io.open(path, "wb"))
  local n = SECONDS * RATE
  f:write("RIFF", string.pack("<I4", 36 + n * 2), "WAVEfmt ", string.pack("<I4I2I2I4I4I2I2", 16, 1, 1, RATE, RATE * 2, 2, 16), "data", string.pack("<I4", n * 2))
  local buf = {}
  for i = 0, n - 1 do
    buf[#buf + 1] = string.pack("<i2", math.floor(0.25 * 32767 * math.sin(2 * math.pi * ((i * hz / RATE) % 1)) + 0.5))
    if #buf == 4096 then f:write(table.concat(buf)); buf = {} end
  end
  f:write(table.concat(buf)); f:close()
end

local function findFX(tr, name)
  for fx = 0, reaper.TrackFX_GetCount(tr) - 1 do
    local _, n = reaper.TrackFX_GetFXName(tr, fx, "")
    if n:find(name, 1, true) and not n:find(name .. " Renderer", 1, true) then return fx, n end
  end
end
local function paramIndex(tr, fx, name)
  for i = 0, reaper.TrackFX_GetNumParams(tr, fx) - 1 do
    local _, pn = reaper.TrackFX_GetParamName(tr, fx, i)
    if pn == name then return i end
  end
end
local function setParam(tr, fx, name, v)
  local i = paramIndex(tr, fx, name)
  if not i then problem("no parameter", name); return end
  reaper.TrackFX_SetParam(tr, fx, i, v)
end
local function getParam(tr, fx, name)
  local i = paramIndex(tr, fx, name)
  return i and reaper.TrackFX_GetParam(tr, fx, i) or 0 / 0
end

local objTracks, bus = {}, nil
local POS = { { 90, 0, 1 }, { -90, 0, 1 }, { 0, 45, 2 }, { -90, 0, 1 } }

local function logObjects(when)
  for i, tr in ipairs(objTracks) do
    local fx = findFX(tr, "ASAF Object")
    if fx then
      L(string.format("  %s: object %d index %g azimuth %+.2f elevation %+.2f distance %.3f enabled %g", when, i,
        getParam(tr, fx, "Index"), getParam(tr, fx, "Azimuth"), getParam(tr, fx, "Elevation"), getParam(tr, fx, "Distance"), getParam(tr, fx, "Playback Enabled")))
    end
  end
end

local function build()
  L("REAPER", reaper.GetAppVersion(), "output", OUT)
  if not reaper.ASAF_SetupSession then problem("reaper_asaf is not loaded (no ASAF_SetupSession)"); return false end
  -- From run.sh REAPER starts with an empty project (-new) and quits afterwards: build there, since a
  -- second tab would leave the first to ask about saving at quit. By hand, leave the open project alone.
  if not QUIT then reaper.Main_OnCommand(40859, 0) end -- new project tab
  local sceneSrc, rc
  if TEMPLATE then
    if not reaper.ASAF_ExportProject then problem("reaper_asaf has no ASAF_ExportProject"); return false end
    local path = reaper.GetResourcePath() .. "/ProjectTemplates/ASAF - Up to " .. TEMPLATE .. " Objects + 1 Scene.RPP"
    if not reaper.file_exists(path) then problem("no template at", path); return false end
    reaper.Main_openProject("template:" .. path)
    L("template:", path)
    if SCENE then
      sceneSrc = reaper.PCM_Source_CreateFromFile(SCENE)
      if not sceneSrc then problem("could not open the scene file", SCENE); return false end
      sceneCh = reaper.GetMediaSourceNumChannels(sceneSrc)
      if sceneCh ~= 64 then problem("the template's scene needs a 64-channel file; this one has", sceneCh); return false end
    end
    rc = 0
  elseif SCENE then
    if not reaper.ASAF_SetupSceneSession then problem("reaper_asaf has no ASAF_SetupSceneSession"); return false end
    sceneSrc = reaper.PCM_Source_CreateFromFile(SCENE)
    if not sceneSrc then problem("could not open the scene file", SCENE); return false end
    sceneCh = reaper.GetMediaSourceNumChannels(sceneSrc)
    local order = math.floor(math.sqrt(sceneCh) + 0.5) - 1
    if (order + 1) * (order + 1) ~= sceneCh or order > 7 then problem("scene file has", sceneCh, "channels, not (order+1)^2"); return false end
    rc = reaper.ASAF_SetupSceneSession(NOBJ, order)
    L("scene:", SCENE, sceneCh, "channels, order", order)
  else
    rc = reaper.ASAF_SetupSession(NOBJ)
  end
  L("ASAF_SetupSession ->", rc, "tracks:", reaper.CountTracks(0))
  if rc ~= 0 then problem("ASAF_SetupSession reported problems (see REAPER's console)") end
  for t = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, t)
    local _, name = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
    local fxn = {}
    for fx = 0, reaper.TrackFX_GetCount(tr) - 1 do local _, n = reaper.TrackFX_GetFXName(tr, fx, ""); fxn[#fxn + 1] = n end
    if not TEMPLATE or not name:match("^Object %d+$") or tonumber(name:match("%d+")) <= NOBJ then
      L(string.format("  track %d '%s' channels %g fx [%s]", t + 1, name, reaper.GetMediaTrackInfo_Value(tr, "I_NCHAN"), table.concat(fxn, "; ")))
    end
    local i = tonumber(name:match("^Object (%d+)$"))
    if i and i <= NOBJ then objTracks[i] = tr end
    if name == "ASAF Export Bus" or (TEMPLATE and name == "ASAF Export") then bus = tr end
    if sceneSrc and (name:match("^Scene %(order") or (TEMPLATE and name == "Scene 1")) then
      local item = reaper.AddMediaItemToTrack(tr)
      local take = reaper.AddTakeToMediaItem(item)
      reaper.SetMediaItemTake_Source(take, sceneSrc)
      reaper.SetMediaItemInfo_Value(item, "D_POSITION", 0)
      reaper.SetMediaItemInfo_Value(item, "D_LENGTH", SECONDS)
      reaper.SetMediaItemInfo_Value(item, "D_FADEINLEN", 0); reaper.SetMediaItemInfo_Value(item, "D_FADEOUTLEN", 0)
      reaper.SetMediaItemInfo_Value(item, "D_FADEINLEN_AUTO", 0); reaper.SetMediaItemInfo_Value(item, "D_FADEOUTLEN_AUTO", 0)
      sceneSrc = nil
      L("  scene item added to", name)
    end
  end
  if SCENE and sceneSrc then problem("no scene track in the session") end
  if #objTracks ~= NOBJ or not bus then problem("session does not have the expected tracks"); return false end

  for i, tr in ipairs(objTracks) do
    local path = string.format("%s/tone%d.wav", OUT, i)
    writeTone(path, 220 * i)
    local item = reaper.AddMediaItemToTrack(tr)
    local take = reaper.AddTakeToMediaItem(item)
    reaper.SetMediaItemTake_Source(take, reaper.PCM_Source_CreateFromFile(path))
    reaper.SetMediaItemInfo_Value(item, "D_POSITION", 0)
    reaper.SetMediaItemInfo_Value(item, "D_LENGTH", SECONDS)
    reaper.SetMediaItemInfo_Value(item, "D_FADEINLEN", 0); reaper.SetMediaItemInfo_Value(item, "D_FADEOUTLEN", 0)
    reaper.SetMediaItemInfo_Value(item, "D_FADEINLEN_AUTO", 0); reaper.SetMediaItemInfo_Value(item, "D_FADEOUTLEN_AUTO", 0)
  end
  local perf = tonumber(os.getenv("ASAF_TEST_PERFFLAGS") or "")
  if perf then
    for t = 0, reaper.CountTracks(0) - 1 do reaper.SetMediaTrackInfo_Value(reaper.GetTrack(0, t), "I_PERFFLAGS", perf) end
    L("I_PERFFLAGS set to", perf, "on every track")
  end
  reaper.UpdateArrange()
  return true
end

local function position()
  for i, tr in ipairs(objTracks) do
    local fx = findFX(tr, "ASAF Object")
    if not fx then problem("no ASAF Object on object track", i)
    else
      setParam(tr, fx, "Azimuth", POS[i][1]); setParam(tr, fx, "Elevation", POS[i][2]); setParam(tr, fx, "Distance", POS[i][3])
      if i == 4 then
        local env = reaper.GetFXEnvelope(tr, fx, paramIndex(tr, fx, "Azimuth"), true)
        if not env then problem("could not create the azimuth envelope")
        else
          reaper.DeleteEnvelopePointRange(env, -1, SECONDS + 1000)
          reaper.InsertEnvelopePoint(env, 0, -90, 0, 0, false, true)
          reaper.InsertEnvelopePoint(env, SECONDS, 90, 0, 0, false, true)
          reaper.Envelope_SortPoints(env)
          L("azimuth envelope on object 4:", reaper.CountEnvelopePoints(env), "points")
        end
      end
    end
  end
  reaper.UpdateArrange()
end

local target
local function render()
  logObjects("before render")
  local exFx, exName = findFX(bus, "ASAF Export")
  L("export bus fx:", exName or "(none)")
  if TEMPLATE then
    reaper.GetSetProjectInfo(0, "RENDER_BOUNDSFLAG", 0, true) -- custom time bounds
    reaper.GetSetProjectInfo(0, "RENDER_STARTPOS", 0, true)
    reaper.GetSetProjectInfo(0, "RENDER_ENDPOS", SECONDS, true)
    reaper.GetSetProjectInfo(0, "RENDER_TAILFLAG", 0, true)
    target = OUT .. "/" .. NAME .. ".wav"
    os.remove(target); os.remove((target:gsub("%.wav$", ".bounce.wav")))
    reaper.Main_SaveProjectEx(0, OUT .. "/" .. NAME .. "_test.RPP", 0)
    local t0 = reaper.time_precise()
    local rc = reaper.ASAF_ExportProject(target, false)
    L(string.format("ASAF_ExportProject -> %d after %.2f s", rc, reaper.time_precise() - t0))
    if rc ~= 0 then problem("ASAF_ExportProject failed (see the stderr log)") end
    return
  end
  local nch = sceneCh + NOBJ + 8
  local advised = reaper.ASAF_RenderChannels and reaper.ASAF_RenderChannels() or -1
  L("ASAF_RenderChannels ->", advised)
  if advised ~= nch then problem("the render panel would advise", advised, "channels; the session needs", nch) end
  reaper.SetOnlyTrackSelected(bus)
  reaper.GetSetProjectInfo(0, "RENDER_SETTINGS", 3, true)   -- stems, selected tracks only
  reaper.GetSetProjectInfo(0, "RENDER_BOUNDSFLAG", 0, true) -- custom time bounds
  reaper.GetSetProjectInfo(0, "RENDER_STARTPOS", 0, true)
  reaper.GetSetProjectInfo(0, "RENDER_ENDPOS", SECONDS, true)
  reaper.GetSetProjectInfo(0, "RENDER_TAILFLAG", 0, true)
  reaper.GetSetProjectInfo(0, "RENDER_CHANNELS", nch, true)
  reaper.GetSetProjectInfo(0, "RENDER_SRATE", RATE, true)
  reaper.GetSetProjectInfo(0, "RENDER_DITHER", 0, true)
  reaper.GetSetProjectInfo(0, "RENDER_NORMALIZE", 0, true)
  reaper.GetSetProjectInfo(0, "RENDER_ADDTOPROJ", 0, true)
  reaper.GetSetProjectInfo_String(0, "RENDER_FILE", OUT, true)
  reaper.GetSetProjectInfo_String(0, "RENDER_PATTERN", NAME, true)
  reaper.GetSetProjectInfo_String(0, "RENDER_FORMAT", "ZmFzYQAAAAA=", true) -- the sink's config: 'asaf', flags 0
  reaper.GetSetProjectInfo_String(0, "RENDER_FORMAT2", "", true)
  local _, fmt = reaper.GetSetProjectInfo_String(0, "RENDER_FORMAT", "", false)
  local _, targets = reaper.GetSetProjectInfo_String(0, "RENDER_TARGETS", "", false)
  target = targets:match("^[^;]+") or (OUT .. "/" .. NAME .. ".wav")
  L("render format:", fmt, "channels:", nch, "targets:", targets)
  if fmt ~= "ZmFzYQAAAAA=" then problem("REAPER did not accept the ASAF render format (is reaper_asaf loaded?)") end
  local _, bs = reaper.get_config_var_string("renderbsnew")
  L("render block size (renderbsnew):", bs)
  os.remove(target); os.remove((target:gsub("%.wav$", ".bounce.wav")))
  reaper.Main_SaveProjectEx(0, OUT .. "/" .. NAME .. "_test.RPP", 0)
  local t0 = reaper.time_precise()
  reaper.Main_OnCommand(42230, 0) -- render with the most recent settings, close the dialog when done
  L(string.format("render returned after %.2f s", reaper.time_precise() - t0))
end

local function finish()
  logObjects("after render")
  local _, bs = reaper.get_config_var_string("renderbsnew")
  L("render block size after render:", bs)
  local f = target and io.open(target, "rb")
  if not target then L("nothing was rendered")
  elseif not f then problem("no render output at " .. target)
  else
    local size = f:seek("end"); f:close()
    L("output:", target, size, "bytes")
  end
  reaper.Main_SaveProjectEx(0, OUT .. "/" .. NAME .. "_test.RPP", 0)
  L(problems == 0 and "DONE" or ("DONE with " .. problems .. " problem(s)"))
  if log then log:close(); log = nil end
  if QUIT then
    -- The plug-ins can report a late parameter change after the save above, and REAPER then asks about
    -- saving at quit, which hangs an unattended run. Let things settle, save again, quit straight away.
    local t = reaper.time_precise()
    local function quit()
      if reaper.time_precise() - t < 1.5 then reaper.defer(quit); return end
      reaper.Main_SaveProjectEx(0, OUT .. "/" .. NAME .. "_test.RPP", 0)
      reaper.Main_OnCommand(40004, 0) -- File: Quit
    end
    quit()
  end
end

-- Leave time between the stages: plug-ins load, and apply parameters, on REAPER's main loop.
local stages = { { 2, build }, { 2, position }, { 2, render }, { 1, finish } }
local stage, t0 = 1, reaper.time_precise()
local function step()
  if reaper.time_precise() - t0 >= stages[stage][1] then
    local ok, res = pcall(stages[stage][2])
    if not ok then problem("script error: " .. tostring(res)); res = false end
    if res == false or stage == #stages then
      if stage ~= #stages then pcall(finish) end
      return
    end
    stage = stage + 1; t0 = reaper.time_precise()
  end
  reaper.defer(step)
end
step()
