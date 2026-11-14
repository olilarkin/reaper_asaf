#!/bin/bash
# Builds ASAFShim.component and installs it to ~/Library/Audio/Plug-Ins/Components
set -euo pipefail
cd "$(dirname "$0")"
OUT=build/ASAFShim.component
rm -rf build; mkdir -p "$OUT/Contents/MacOS"
clang -arch arm64 -arch x86_64 -mmacosx-version-min=11.0 -O2 -bundle -fvisibility=hidden \
  -fobjc-arc -framework Foundation -framework AudioToolbox -o "$OUT/Contents/MacOS/ASAFShim" shim.m
mkdir -p "$OUT/Contents/Resources"; cp params.json "$OUT/Contents/Resources/"
entry() { # factory name subtype
cat <<X
    <dict>
      <key>type</key><string>aufx</string>
      <key>subtype</key><string>$3</string>
      <key>manufacturer</key><string>ASFs</string>
      <key>name</key><string>Apple: $2</string>
      <key>description</key><string>$2 (shim)</string>
      <key>factoryFunction</key><string>${1}Shim</string>
      <key>version</key><integer>131336</integer>
      <key>sandboxSafe</key><true/>
    </dict>
X
}
{
cat <<X
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>ASAFShim</string>
  <key>CFBundleIdentifier</key><string>com.local.ASAFShim</string>
  <key>CFBundleName</key><string>ASAFShim</string>
  <key>CFBundlePackageType</key><string>BNDL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>AudioComponents</key><array>
X
entry AppleChannelsRendererAUFactory "ASAF Channels Renderer" CRdr
entry AppleChannelsAUFactory         "ASAF Channels"          Chan
entry AppleExportAUFactory           "ASAF Export"            Expt
entry AppleObjectRendererAUFactory   "ASAF Object Renderer"   ORdr
entry AppleObjectToSceneAUFactory    "ASAF Object to Scene"   Ob2S
entry AppleObjectAUFactory           "ASAF Object"            Objt
entry ApplePannerAUFactory           "ASAF Panner"            Pnnr
entry AppleSceneRendererAUFactory    "ASAF Scene Renderer"    SRdr
entry AppleSceneAUFactory            "ASAF Scene"             Scen
echo "  </array></dict></plist>"
} > "$OUT/Contents/Info.plist"
printf 'BNDL????' > "$OUT/Contents/PkgInfo"
codesign -f -s - "$OUT"
DEST="$HOME/Library/Audio/Plug-Ins/Components"
mkdir -p "$DEST"; rm -rf "$DEST/ASAFShim.component"; cp -R "$OUT" "$DEST/"
echo "Installed $DEST/ASAFShim.component"
