# ASAF in REAPER

Tools for authoring and exporting Apple Spatial Audio Format (ASAF) in REAPER, built on the
AudioUnits that ship with Apple's ASAF Production Suite.

Apple's ASAF AudioUnits are hidden from normal plug-in scans, have no editor and publish no
parameters. This project wraps them so they can be used like ordinary plug-ins, and adds a REAPER
extension for panning, session setup and export.

This is an unofficial project. It is not affiliated with or supported by Apple, and it depends on
the internals of specific builds of Apple's plug-ins (see [Limitations](#limitations)).

## What's here

| Folder | Builds | What it is |
|---|---|---|
| `asaf_clap/` | `ASAF.clap` | The nine ASAF units as CLAP plug-ins with SwiftUI editors, plus a REAPER video overlay |
| `reaper_asaf/` | `reaper_asaf.dylib` | REAPER extension: panner window, session setup, ASAF/APAC render format, Extensions menu |
| `templates/` | `.RPP` files | REAPER project templates modelled on Apple's Pro Tools session templates |
| `shim/` | `ASAFShim.component` | The original AudioUnit wrapper. Superseded by `ASAF.clap`; kept for projects that use it |
| `modules/` | | Submodules: the REAPER SDK (with WDL merged in) and the CLAP SDK |

## Requirements

- macOS 12 or later, on Apple silicon. Intel/Rosetta builds are produced but untested, and APAC
  export does not work there.
- Apple's ASAF AudioUnits in `/Library/Audio/Plug-Ins/Components` (`ASAF Object.component` and
  friends) and `/usr/local/lib/libASAF.dylib`. Developed against versions 2.1.8 and 2.1.13.
- REAPER 7 (developed against 7.83).
- Xcode, for `clang` and `swiftc`.

## Building

Clone with submodules, then run the build scripts. Each one builds a universal binary and installs
it.

```sh
git submodule update --init
asaf_clap/build.sh     # -> ~/Library/Audio/Plug-Ins/CLAP/ASAF.clap
reaper_asaf/build.sh   # -> ~/Library/Application Support/REAPER/UserPlugins/reaper_asaf.dylib
```

Restart REAPER afterwards. Both scripts take an optional install directory as their first argument.

The templates in `templates/` are ready to use: copy the `.RPP` files to
`~/Library/Application Support/REAPER/ProjectTemplates`.

`shim/build.sh` builds the AudioUnit wrapper, if you want it.

### Releases and CI

`.github/workflows/build.yml` builds every component on each push. Pushing a tag such as `v0.1.0`
also publishes the builds as a GitHub release. Release builds are ad-hoc signed, not notarised, so
clear the quarantine flag after downloading (`xattr -dr com.apple.quarantine <file>`).

## Using it

### Plug-ins

After a rescan the units appear in REAPER as "CLAP: ASAF Object (ASAF Bridge)" and so on:

| Plug-in | In → out | Purpose |
|---|---|---|
| ASAF Object | 1 → 1 | Positions one mono object |
| ASAF Channels | 16 → 16 | Channel-bed metadata |
| ASAF Scene | 64 → 64 | Ambisonic scene, up to 7th order |
| ASAF Object to Scene | 64 → 64 | Converts objects to an ambisonic scene |
| ASAF Object / Channels / Scene Renderer | 64 (or 16) + 1 → 64 | Monitoring |
| ASAF Export | 12 → 8 | Emits metadata for bouncing; converts bounces to ASAF and APAC |
| ASAF Panner | 1 → 1 | Controls the first 32 objects, beds and scenes from one plug-in |
| ASAF Video Overlay | 2 → 2 | REAPER only: draws object positions over an equirectangular video |

Channel counts are fixed at each unit's largest layout; smaller layouts use the first channels.

- **Editors.** ASAF Object has a top-down panner; ASAF Export has arm, loudness and convert
  controls; the others list their parameters, with named options shown as menus.
- **Track and mixer panel.** ASAF Object draws a small panner in REAPER's TCP and MCP. Drag to set
  azimuth and distance, scroll for elevation, double-click to reset.
- **Colours.** Markers follow the track colour. Uncoloured tracks get one of ten colours chosen by
  object number.
- **Conventions.** Azimuth is positive to the listener's left. Only azimuth, elevation and distance
  move the sound; the X/Y/Z parameters do not affect rendering.

Renderer "Channel Output Type" values: 1 Binaural, 2 Stereo, 3 LCR, 4 Quad, 5 5.0, 6 5.1, 7 7.0,
8 5.1.2, 9 7.1, 10 5.1.4, 11 7.1.2, 12 7.1.4, 13 7.1.6, 14 9.1.6, 15 Custom Layout.

### REAPER extension

Everything is under **Extensions > ASAF** and in the action list:

- **Show panner / Dock panner** — one window showing every ASAF Object in the project.
- **Set up session...** — creates object tracks, optionally an ambisonic scene track, binaural
  monitor busses and an export bus.
- **Export project...** — renders the project to an ASAF BWF (and optionally APAC) in one step. It
  is the only way to export a project made from a template; see below.
- **New project from template** — opens one of the templates below.

Script functions: `ASAF_SetupSession(objectCount)`,
`ASAF_SetupSceneSession(objectCount, sceneOrder)`, `ASAF_RenderChannels()`,
`ASAF_ExportProject(path, apac)`,
`ASAF_AddUnit(track, unitName)` and
`ASAF_ShowEmbeddedUI(track)`.

### Exporting ASAF and APAC

The quick way is **Extensions > ASAF > Export project...**: choose a file, tick the APAC box if you
want an `.mp4` as well, and it sets up and runs the render for you, using the project's render
bounds. Your render settings and track selection are put back afterwards. For a session made by
**Set up session...** you can also render by hand:

1. Run **Set up session...**, put audio on the object tracks and position the objects. If you asked
   for a scene, put ACN/SN3D ambisonic audio of that order on the scene track.
2. In File > Render choose:
   - Source: Selected tracks (stems), with "ASAF Export Bus" selected
   - Sample rate: 48000 Hz
   - Channels: scene channels + number of objects + 8. The ASAF format options show the number
     for the current project, e.g. "This project: set Channels to 28 (16 scene + 4 objects + 8
     metadata)"
   - Format: ASAF (Apple Spatial Audio Format)
3. Tick "Also create an APAC file (.mp4)" in the format options if you want one.

The render writes a bounce file (the scene's channels, then one channel per object, then ASAF
Export's eight metadata channels) and ASAF Export converts it in place to an ASAF BWF, plus an
`.mp4` beside it for APAC.

For sessions with an ambisonic scene, see the next section.

The render block size must be 1024 samples (Preferences > Audio > Rendering). **Set up session...**
sets this for you.

### Ambisonic scenes

A scene is an ambisonic recording or mix (ACN channel order, SN3D normalisation) carried in the
ASAF file alongside the objects, or on its own.

**Setting one up.** In **Set up session...** enter a scene order from 0 to 7 (leave it blank for no
scene; objects may be 0). From a script, call `ASAF_SetupSceneSession(objectCount, sceneOrder)`.
This adds, besides the object tracks:

| Track | What it does |
|---|---|
| Scene (order n) | Holds the ambisonic audio. ASAF Scene on it, with Index 0 and Order n, registers the scene with ASAF Export |
| ASAF Scene Monitor | ASAF Scene Renderer set to binaural, fed from the scene track and sent to the master |
| ASAF Export Bus | The scene's channels first, then one channel per object, then the 8 metadata channels |

Put the ambisonic file on the scene track. Its channel count must match the order:

| Order | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 |
|---|---|---|---|---|---|---|---|---|
| Channels | 1 | 4 | 9 | 16 | 25 | 36 | 49 | 64 |

Scene channels and objects together must not exceed 120, so a 7th-order scene leaves room for 56
objects and a 3rd-order one for 104.

**Rendering.** As for objects, with Channels set to scene channels + objects + 8: a third-order
scene on its own is 24, and with four objects 28.

**What ends up in the file.**

- A scene on its own exports as plain ambisonics: for third order, 16 channels tagged "High-Order
  Ambisonics, ACN/SN3D", in both the BWF and the APAC `.mp4`. The BWF's audio is identical to what
  was on the scene track.
- A scene with objects exports with the scene's channels first and the objects after them, labelled
  that way in the BWF.
- ASAF Scene's rotation (Yaw, Pitch, Roll, with Rotation Enable on) and Gain (with Gain Enable on)
  change the exported audio. They are not stored as metadata, so a player cannot undo them. The
  mirror and spatial-filter parameters have not been checked.

**Building it by hand.** The order matters: ASAF Export lists scenes before objects, and it labels
the channels of the render in that order whatever is actually on them. If the objects are routed to
the first channels of the export bus and the scene after them, the file is written without an error
but the ambisonic labels land on the object channels. Also turn off anticipative FX on the scene
track (track performance options), as for object tracks.

### Templates

"ASAF - Up to 64 / 128 / 192 / 256 Objects + 1 Scene" mirror Apple's Pro Tools templates: object
folders that double as 64-channel busses, object-to-scene converters, a 7th-order scene, binaural
renderers, and Panner and Export tracks. Each has project notes (File > Project settings > Notes)
that explain the layout, how to export and what not to change.

**Exporting from a template project.** A template has a 64-channel scene and 64 or more objects,
which is more than the 128 channels one REAPER track can carry, so it cannot be rendered as a single
stem and File > Render will not work (the ASAF format options say so). Use **Export project...**
instead. It renders "Scene 1", each "ASAF Objects a-b" bus and the "ASAF Export" track as separate
files in one pass, joins them into one file (scene, then objects, then metadata) and converts that.
The result always has all the template's channels: 128 for the 64-object template, 320 for the
256-object one, with unused objects silent.

The tracks to render are marked in the template (track ext state `ASAF_EXPORT`, set by
`make_template.lua`). Projects made from the earlier, unmarked templates are recognised by those
track names, so do not rename them there.

`templates/make_template.lua` regenerates them and `templates/ptx_unxor.py` decodes the Pro Tools
originals.

## How it works

- **Loading the units.** Apple's components are flagged "unsearchable", so hosts that enumerate
  AudioUnits never see them. `ASAF.clap` instantiates them directly by exact description.
- **Parameters.** The units keep their controls in JUCE parameter objects that are never published
  to the host. The wrapper finds those objects in memory and reads and writes them directly. Ranges
  come from `shim/params.json`, which was produced by probing (`shim/tools/probe.m`).
- **Export.** ASAF Export's headless build converts a bounce file when a hidden parameter is set,
  taking the path from a preference. APAC encoding is only reachable through a dialog button that is
  never shown, so the wrapper calls that button's handler.
- **Metadata.** ASAF Object and ASAF Scene do not send their settings along the audio path. They
  register with a bus shared by every ASAF unit in the process, and ASAF Export writes what it finds
  there as one packet per 1024-sample block on its last output channel. Each packet lists the scenes
  first and then the objects, and the converter assigns the render's audio channels in that same
  order, which is why the export bus is laid out scene first. `tools/export_test/asaf_inspect.py`
  documents the packet layout as far as it has been worked out.
- **Video overlay.** REAPER exposes its video-processor interface to CLAP plug-ins through a host
  extension.

## Limitations

- **Tied to Apple's builds.** Parameter access relies on JUCE and libc++ object layout. If a unit
  isn't recognised it still passes audio but has no controls. APAC export only works with ASAF
  Export 2.1.8 and 2.1.13 on Apple silicon; each new release has to be added by hand.
- **Export size.** One REAPER track carries 128 channels, so a session from **Set up session...**
  holds at most 120 object and scene channels. Larger projects have to be laid out like the
  templates and exported with **Export project...**.
- **APAC from large projects.** ASAF Export's APAC encoder wrote 51 channels for a 7th-order scene
  with 64 objects, and for 64 objects alone; a 7th-order scene on its own came out as 36 channels
  (5th order). With 256 objects it wrote no file. What it drops, and whether that is intended, is
  unknown. The ASAF BWF keeps every channel.
- **More than 127 objects.** The object number in the metadata is a 7-bit field and wraps at 128 in
  the 192- and 256-object exports. Positions and channel order are still correct in the file;
  whether players cope has not been tested.
- **Object to Scene in an export.** The templates' "Convert To HOA" path has not been exported.
- **One project at a time.** ASAF Export must be the only one loaded, so a second open project tab
  that also has one stops the export.
- **Objects and one third-order scene are tested.** Other orders, more than one scene and channel
  beds have not been exported, and the scene monitor's output has not been checked. Whether a player
  renders an APAC file with both a scene and objects correctly is unknown: `afinfo` shows no channel
  layout for it.
- **Large files.** Bounces over 4 GB are written as RF64; whether ASAF Export accepts that is
  untested.
- **REAPER blocks while converting.** The window is unresponsive until the APAC encode finishes.
- **Not reproduced from Pro Tools:** the renderers' mono sidechain input, and the AAX suite's Scene
  Compressor and Video Player.
- **Other hosts are untested.** The CLAP plug-ins should load elsewhere, but the embedded panel,
  video overlay and render format are REAPER-specific.

## Development

Each component has small test tools that run without a DAW:

- `asaf_clap/tools/clap_test.mm` — loads `ASAF.clap` and exercises every plug-in.
- `asaf_clap/tools/state_test.mm`, `text_test.mm`, `labels.mm`, `tables.mm` — state, value text and
  the layout tables inside the renderer.
- `reaper_asaf/tools/core_test.mm` — renders objects through ASAF Export and converts the result.

Set `ASAF_DEBUG=1` (extension) or `ASAF_CLAP_DEBUG=1` (plug-ins) in REAPER's environment to log to
stderr.

### Export test

`tools/export_test/` checks that an export carries the object metadata that was set. It renders one
known scenario (four tones; objects at fixed positions, one with azimuth automation) and reads the
positions back out of the result:

```sh
tools/export_test/run.sh            # ASAF.clap hosted without a DAW, like REAPER's offline render
tools/export_test/run.sh --reaper   # then the same scenario built and rendered by REAPER
tools/export_test/run.sh --matrix   # the harness with other block sizes, transport states, ...
tools/export_test/run.sh --scene FILE   # also a scene from FILE, alone and ahead of the objects
tools/export_test/run.sh --template 64  # a project from the installed template, via Export project
```

`FILE` is ACN/SN3D ambisonic audio with (order+1)² channels in anything `afconvert` reads; combine
`--scene` with `--reaper` to render it from REAPER too.

- `asaf_inspect.py FILE [--expect] [--scene=SOURCE.wav]` decodes the per-block object positions from a bounce file or an
  ASAF BWF and, with `--expect`, compares them with the scenario; `--scene=` checks for one scene
  carrying that file's audio. It works on any export, not only the test's.
- `asaf_clap/tools/export_test.mm` is the DAW-less harness; `reaper_export_test.lua` is the REAPER
  side (it can also be run from the action list).
- `ASAF_KEEP_BOUNCE=1` in REAPER's environment keeps each render as it was before conversion
  (`<name>.bounce.wav`); `ASAF_NO_DIALOGS=1` logs the exporter's problems instead of showing them.

Both stages are checked at two points, which is what narrows a failure down:

| Result | Where the problem is |
|---|---|
| Harness fails | ASAF.clap or Apple's units, independent of REAPER |
| REAPER bounce: last channel silent | ASAF Export not armed or not processed, or its outputs are not routed to the last 8 channels |
| REAPER bounce: packets off the block boundary, or not every 1024 frames | Render block size, or delay compensation shifting the metadata channel |
| REAPER bounce: data present but no packets ("scaled by ...") | Gain, pan law or dither applied to the metadata channel |
| REAPER bounce: positions wrong or frozen | Parameters or automation not reaching ASAF Object during the render |
| Bounce passes, ASAF BWF fails | The conversion step |
