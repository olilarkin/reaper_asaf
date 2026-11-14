#!/bin/bash
# Builds ASAF.clap (universal) and installs it to ~/Library/Audio/Plug-Ins/CLAP.
# Optional argument: a different install directory.
set -euo pipefail
cd "$(dirname "$0")"
CLAP=../modules/clap/include
WDL=../modules/reaper-sdk/WDL   # merged into the reaper-sdk submodule
RSDK=../modules/reaper-sdk/sdk
MIN=12.0
SDKROOT_PATH=$(xcrun --show-sdk-path)
TOOLCHAIN=$(dirname "$(dirname "$(xcrun --find swiftc)")")
OUT=build/ASAF.clap
rm -rf build; mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
for ARCH in arm64 x86_64; do
  mkdir -p build/$ARCH
  xcrun swiftc -target $ARCH-apple-macos$MIN -sdk "$SDKROOT_PATH" -swift-version 5 -O -parse-as-library \
    -module-name ASAFClapUI -import-objc-header ui_bridge.h \
    -emit-objc-header-path build/$ARCH/ASAFClapUI-Swift.h \
    -emit-object -o build/$ARCH/UI.o UI.swift
  # LICE (software drawing for the REAPER embedded UI); no SWELL window-system parts needed
  for f in lice lice_line lice_arc lice_text; do
    clang++ -std=c++17 -O2 -arch $ARCH -mmacosx-version-min=$MIN -fvisibility=hidden -Wno-everything \
      -DSWELL_PROVIDED_BY_APP -D_LICE_NO_SYSBITMAPS_ -I"$WDL" -c "$WDL/lice/$f.cpp" -o build/$ARCH/$f.o
  done
  clang++ -std=c++17 -O2 -arch $ARCH -mmacosx-version-min=$MIN -fvisibility=hidden -Wno-deprecated-declarations \
    -DSWELL_PROVIDED_BY_APP -I"$WDL" -I"$RSDK" -I"$CLAP" -c embed.cpp -o build/$ARCH/embed.o
  # the REAPER video overlay needs REAPER's SDK headers (and through them SWELL's type definitions)
  clang++ -std=c++17 -fobjc-arc -O2 -arch $ARCH -mmacosx-version-min=$MIN -fvisibility=hidden -Wno-deprecated-declarations -Wno-multichar \
    -DSWELL_PROVIDED_BY_APP -I"$WDL" -I"$RSDK" -I"$CLAP" -c video.mm -o build/$ARCH/video.o
  clang++ -std=c++17 -fobjc-arc -O2 -arch $ARCH -mmacosx-version-min=$MIN \
    -bundle -fvisibility=hidden -Wno-deprecated-declarations \
    -I"$CLAP" -Ibuild/$ARCH \
    -framework Foundation -framework Cocoa -framework SwiftUI -framework AudioToolbox -framework CoreAudio -framework CoreText -framework CoreGraphics \
    -L"$SDKROOT_PATH/usr/lib/swift" -L"$TOOLCHAIN/lib/swift/macosx" -Wl,-rpath,/usr/lib/swift \
    -o build/$ARCH/ASAF plugin.mm unit.mm ../reaper_asaf/asaf_core.mm build/$ARCH/UI.o \
    build/$ARCH/video.o build/$ARCH/embed.o build/$ARCH/lice.o build/$ARCH/lice_line.o build/$ARCH/lice_arc.o build/$ARCH/lice_text.o
done
lipo -create build/arm64/ASAF build/x86_64/ASAF -output "$OUT/Contents/MacOS/ASAF"
cp ../shim/params.json "$OUT/Contents/Resources/"
cat > "$OUT/Contents/Info.plist" <<X
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>ASAF</string>
  <key>CFBundleIdentifier</key><string>com.asafbridge.clap</string>
  <key>CFBundleName</key><string>ASAF</string>
  <key>CFBundlePackageType</key><string>BNDL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>$MIN</string>
</dict></plist>
X
printf 'BNDL????' > "$OUT/Contents/PkgInfo"
codesign -f -s - "$OUT"
DEST="${1:-$HOME/Library/Audio/Plug-Ins/CLAP}"
mkdir -p "$DEST"; rm -rf "$DEST/ASAF.clap"; cp -R "$OUT" "$DEST/"
echo "Installed $DEST/ASAF.clap"
