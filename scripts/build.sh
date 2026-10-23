#!/bin/zsh
# dumper.m -> dumper.dylib (arm64, iOS 15+)
# 前置：Xcode command line tools（xcrun 可用）
set -e
cd "$(dirname "$0")"
SDK="$(xcrun -sdk iphoneos --show-sdk-path)"
xcrun -sdk iphoneos clang -arch arm64 -isysroot "$SDK" -mios-version-min=15.0 \
  -fobjc-arc -dynamiclib \
  -framework Foundation -framework UIKit \
  -o dumper.dylib dumper.m
echo "OK -> $(pwd)/dumper.dylib"
