#!/bin/bash
# Builds reaper_asaf.dylib (universal) and installs it to REAPER's UserPlugins folder.
# Restart REAPER to load it. Optional argument: a different install directory.
set -euo pipefail
cd "$(dirname "$0")"
SDK=../modules/reaper-sdk/sdk
WDL=../modules/reaper-sdk/WDL   # merged into the reaper-sdk submodule
MIN=12.0                 # SwiftUI Canvas
SDKROOT_PATH=$(xcrun --show-sdk-path)
TOOLCHAIN=$(dirname "$(dirname "$(xcrun --find swiftc)")")
rm -rf build/arm64 build/x86_64
for ARCH in arm64 x86_64; do
  mkdir -p build/$ARCH
  xcrun swiftc -target $ARCH-apple-macos$MIN -sdk "$SDKROOT_PATH" -swift-version 5 -O -parse-as-library \
    -module-name ASAFPannerUI -import-objc-header panner_bridge.h \
    -emit-objc-header-path build/$ARCH/ASAFPannerUI-Swift.h \
    -emit-object -o build/$ARCH/PannerUI.o PannerUI.swift
  clang++ -std=c++17 -fobjc-arc -O2 -arch $ARCH -mmacosx-version-min=$MIN \
    -dynamiclib -fvisibility=hidden -Wno-deprecated-declarations \
    -I"$SDK" -I"$WDL" -Ibuild/$ARCH -DSWELL_PROVIDED_BY_APP \
    -framework Foundation -framework Cocoa -framework SwiftUI \
    -L"$SDKROOT_PATH/usr/lib/swift" -L"$TOOLCHAIN/lib/swift/macosx" -Wl,-rpath,/usr/lib/swift \
    -o build/$ARCH/reaper_asaf.dylib \
    main.mm asaf_core.mm panner.mm "$WDL/swell/swell-modstub.mm" build/$ARCH/PannerUI.o
done
lipo -create build/arm64/reaper_asaf.dylib build/x86_64/reaper_asaf.dylib -output build/reaper_asaf.dylib
codesign -f -s - build/reaper_asaf.dylib
DEST="${1:-$HOME/Library/Application Support/REAPER/UserPlugins}"
mkdir -p "$DEST"; cp build/reaper_asaf.dylib "$DEST/"
echo "Installed $DEST/reaper_asaf.dylib"
