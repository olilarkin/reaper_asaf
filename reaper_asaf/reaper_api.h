// REAPER API used by reaper_asaf. Exactly one translation unit defines REAPERAPI_IMPLEMENT before
// including this.
#pragma once
#include <string>
#include <cstring>
#include <cctype>

#define REAPERAPI_MINIMAL
#define REAPERAPI_WANT_plugin_register
#define REAPERAPI_WANT_CountTracks
#define REAPERAPI_WANT_GetTrack
#define REAPERAPI_WANT_InsertTrackAtIndex
#define REAPERAPI_WANT_GetSetMediaTrackInfo_String
#define REAPERAPI_WANT_SetMediaTrackInfo_Value
#define REAPERAPI_WANT_GetTrackName
#define REAPERAPI_WANT_GetTrackColor
#define REAPERAPI_WANT_ColorFromNative
#define REAPERAPI_WANT_ValidatePtr2
#define REAPERAPI_WANT_TrackFX_AddByName
#define REAPERAPI_WANT_TrackFX_Delete
#define REAPERAPI_WANT_TrackFX_GetCount
#define REAPERAPI_WANT_TrackFX_GetFXName
#define REAPERAPI_WANT_TrackFX_GetFXGUID
#define REAPERAPI_WANT_TrackFX_GetNumParams
#define REAPERAPI_WANT_TrackFX_GetParamName
#define REAPERAPI_WANT_TrackFX_GetParam
#define REAPERAPI_WANT_TrackFX_SetParam
#define REAPERAPI_WANT_TrackFX_EndParamEdit
#define REAPERAPI_WANT_TrackFX_SetPinMappings
#define REAPERAPI_WANT_TrackFX_GetIOSize
#define REAPERAPI_WANT_CreateTrackSend
#define REAPERAPI_WANT_SetTrackSendInfo_Value
#define REAPERAPI_WANT_GetUserInputs
#define REAPERAPI_WANT_ShowMessageBox
#define REAPERAPI_WANT_ShowConsoleMsg
#define REAPERAPI_WANT_Undo_BeginBlock
#define REAPERAPI_WANT_Undo_EndBlock
#define REAPERAPI_WANT_PreventUIRefresh
#define REAPERAPI_WANT_TrackList_AdjustWindows
#define REAPERAPI_WANT_UpdateArrange
#define REAPERAPI_WANT_get_config_var
#define REAPERAPI_WANT_SetOnlyTrackSelected
#define REAPERAPI_WANT_GetMainHwnd
#define REAPERAPI_WANT_AddExtensionsMainMenu
#define REAPERAPI_WANT_Main_openProject
#define REAPERAPI_WANT_GetResourcePath
#define REAPERAPI_WANT_GetTrackStateChunk
#define REAPERAPI_WANT_SetTrackStateChunk
#define REAPERAPI_WANT_DockWindowAddEx
#define REAPERAPI_WANT_DockWindowActivate
#define REAPERAPI_WANT_DockWindowRemove
#define REAPERAPI_WANT_GetExtState
#define REAPERAPI_WANT_SetExtState
#include "reaper_plugin.h"
#include "reaper_plugin_functions.h"

// "CLAP: ASAF Object (ASAF Bridge)" / "AU: ASAF Object (Apple)" -> "ASAF Object"
static inline std::string fxBaseName(MediaTrack *tr, int fx)
{
  char buf[256] = ""; TrackFX_GetFXName(tr, fx, buf, sizeof buf);
  std::string s = buf;
  for (const char *prefix : { "CLAP: ", "CLAPi: ", "AU: ", "AUi: " })
    if (s.rfind(prefix, 0) == 0) { s = s.substr(strlen(prefix)); break; }
  size_t p = s.rfind(" (");
  if (p != std::string::npos) s = s.substr(0, p);
  return s;
}

// Parameters are named by the unit's raw id in the AU shim ("playbackEnabled", "r") and by a display
// name in the CLAP plug-ins ("Playback Enabled", "Distance"). Match either.
static inline bool paramNameIs(const char *name, const char *rawId)
{
  if (!strcmp(name, rawId)) return true;
  if (!strcmp(rawId, "r")) return !strcmp(name, "Distance");
  const char *a = name, *b = rawId;
  for (;;) {
    while (*a == ' ') a++;
    if (!*a || !*b) return !*a && !*b;
    if (tolower((unsigned char)*a) != tolower((unsigned char)*b)) return false;
    a++; b++;
  }
}

// Index of a parameter by raw id, or -1.
static inline int findFXParam(MediaTrack *tr, int fx, const char *rawId)
{
  const int n = TrackFX_GetNumParams(tr, fx);
  for (int i = 0; i < n; i++) { char buf[128] = ""; TrackFX_GetParamName(tr, fx, i, buf, sizeof buf); if (paramNameIs(buf, rawId)) return i; }
  return -1;
}

// panner.mm
void ASAF_TogglePanner(HINSTANCE hInst);
void ASAF_ClosePanner();
bool ASAF_PannerVisible();
bool ASAF_PannerDocked();
void ASAF_SetPannerDocked(bool docked); // re-creates the window in or out of REAPER's docker
