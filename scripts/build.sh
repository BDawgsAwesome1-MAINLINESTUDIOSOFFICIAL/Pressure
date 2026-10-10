#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SDK="$(xcrun --show-sdk-path --sdk macosx)"
ARCH="$(uname -m)"
TARGET="${ARCH}-apple-macosx13.0"
BUILD="$ROOT/build"
APP="$BUILD/Pressure.app"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

SWIFT_FLAGS=(
  -target "$TARGET"
  -sdk "$SDK"
  -swift-version 5
  -parse-as-library
  -framework AppKit
  -framework SwiftUI
  -framework Combine
  -framework UserNotifications
  -framework ServiceManagement
  -framework IOKit
  -framework EventKit
)

echo "Testing decision logic"
swiftc "${SWIFT_FLAGS[@]}" -o "$BUILD/PressureTests" \
  "$ROOT/Pressure/Config/AppConfig.swift" \
  "$ROOT/Pressure/Config/AppPriority.swift" \
  "$ROOT/Pressure/Core/MemorySnapshot.swift" \
  "$ROOT/Pressure/MenuBar/HubLayout.swift" \
  "$ROOT/Pressure/Island/IslandPriority.swift" \
  "$ROOT/Pressure/Island/PowerReader.swift" \
  "$ROOT/Pressure/Island/CursorActivity.swift" \
  "$ROOT/Pressure/Island/MessageInbox.swift" \
  "$ROOT/Pressure/Island/GitHubActions.swift" \
  "$ROOT/Pressure/Island/NowPlaying.swift" \
  "$ROOT/Tests/PressureTests.swift"
"$BUILD/PressureTests"

echo "Building Pressure"
swiftc "${SWIFT_FLAGS[@]}" -O -o "$APP/Contents/MacOS/Pressure" \
  "$ROOT/Pressure/PressureApp.swift" \
  "$ROOT/Pressure/Config/AppConfig.swift" \
  "$ROOT/Pressure/Config/AppPriority.swift" \
  "$ROOT/Pressure/Core/MemorySnapshot.swift" \
  "$ROOT/Pressure/Core/MemoryMonitor.swift" \
  "$ROOT/Pressure/Core/AppCloser.swift" \
  "$ROOT/Pressure/Core/PressureEngine.swift" \
  "$ROOT/Pressure/MenuBar/StatusItemView.swift" \
  "$ROOT/Pressure/MenuBar/SettingsWindow.swift" \
  "$ROOT/Pressure/MenuBar/HubLayout.swift" \
  "$ROOT/Pressure/MenuBar/HubWindow.swift" \
  "$ROOT/Pressure/Island/IslandPriority.swift" \
  "$ROOT/Pressure/Island/PowerReader.swift" \
  "$ROOT/Pressure/Island/NowPlaying.swift" \
  "$ROOT/Pressure/Island/CalendarAgenda.swift" \
  "$ROOT/Pressure/Island/IslandModel.swift" \
  "$ROOT/Pressure/Island/CursorActivity.swift" \
  "$ROOT/Pressure/Island/MessageInbox.swift" \
  "$ROOT/Pressure/Island/GitHubActions.swift"

cp "$ROOT/Pressure/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Pressure/Resources/Pressure.icns" "$APP/Contents/Resources/Pressure.icns"
cp "$ROOT/Pressure/Resources/cursor-hook.py" "$APP/Contents/Resources/cursor-hook.py"
xattr -cr "$APP" 2>/dev/null || true
xattr -d com.apple.FinderInfo "$APP" 2>/dev/null || true
xattr -d com.apple.fileprovider.fpfs#P "$APP" 2>/dev/null || true
codesign --force --sign - --entitlements "$ROOT/Pressure/Pressure.entitlements" "$APP"
echo "Built $APP"
