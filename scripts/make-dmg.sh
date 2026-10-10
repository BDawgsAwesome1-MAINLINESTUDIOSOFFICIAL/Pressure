#!/bin/bash
# Builds docs/Pressure.dmg as a small Finder window: Pressure on the left,
# Applications on the right, and a cream background that says to drag across.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Pressure.app"
OUT="$ROOT/docs/Pressure.dmg"
ICON="$ROOT/Pressure/Resources/Pressure.icns"
VOLUME="Pressure"
MOUNT="/Volumes/$VOLUME"
WORK="$(mktemp -d)"
RW="$WORK/Pressure-rw.dmg"

cleanup() {
  if [[ -d "$MOUNT" ]]; then
    hdiutil detach "$MOUNT" -force >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

if [[ ! -d "$APP" ]]; then
  echo "Build the app first: scripts/build.sh" >&2
  exit 1
fi

if [[ -d "$MOUNT" ]]; then
  hdiutil detach "$MOUNT" -force >/dev/null 2>&1 || true
fi

cat > "$WORK/draw.swift" << 'SWIFT'
import AppKit
import Foundation

let outPath = CommandLine.arguments[1]
let width = 660
let height = 420

func rgb(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
    NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
}

func rounded(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    if let descriptor = base.fontDescriptor.withDesign(.rounded),
       let font = NSFont(descriptor: descriptor, size: size) {
        return font
    }
    return base
}

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: width,
    pixelsHigh: height,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fputs("Could not create the disk image background.\n", stderr)
    exit(1)
}
rep.size = NSSize(width: width, height: height)

let cream = rgb(255, 248, 231)
let ink = rgb(30, 26, 20)
let coral = rgb(255, 107, 107)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

cream.setFill()
NSRect(x: 0, y: 0, width: width, height: height).fill()

let frame = NSBezierPath(roundedRect: NSRect(x: 18, y: 18, width: 624, height: 384), xRadius: 28, yRadius: 28)
frame.lineWidth = 6
ink.setStroke()
frame.stroke()

let title = "Pressure" as NSString
let titleFont = rounded(28, .heavy)
let titleAttrs: [NSAttributedString.Key: Any] = [.font: titleFont, .foregroundColor: ink]
let titleSize = title.size(withAttributes: titleAttrs)
title.draw(
    at: NSPoint(x: (CGFloat(width) - titleSize.width) / 2, y: 348),
    withAttributes: titleAttrs
)

let shaft = NSBezierPath()
shaft.move(to: NSPoint(x: 268, y: 214))
shaft.line(to: NSPoint(x: 392, y: 214))
shaft.lineWidth = 12
shaft.lineCapStyle = .round
coral.setStroke()
shaft.stroke()

let head = NSBezierPath()
head.move(to: NSPoint(x: 378, y: 240))
head.line(to: NSPoint(x: 424, y: 214))
head.line(to: NSPoint(x: 378, y: 188))
head.close()
coral.setFill()
head.fill()

let label = "drag into Applications" as NSString
let labelFont = rounded(20, .bold)
let labelAttrs: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: ink]
let labelSize = label.size(withAttributes: labelAttrs)
let sticker = NSRect(
    x: (CGFloat(width) - labelSize.width) / 2 - 16,
    y: 46,
    width: labelSize.width + 32,
    height: labelSize.height + 16
)
ink.setFill()
NSBezierPath(roundedRect: sticker.offsetBy(dx: 4, dy: -4), xRadius: 16, yRadius: 16).fill()
cream.setFill()
let stickerPath = NSBezierPath(roundedRect: sticker, xRadius: 16, yRadius: 16)
stickerPath.fill()
ink.setStroke()
stickerPath.lineWidth = 3
stickerPath.stroke()
label.draw(
    at: NSPoint(x: sticker.minX + 16, y: sticker.minY + 8),
    withAttributes: labelAttrs
)

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    fputs("Could not encode the disk image background.\n", stderr)
    exit(1)
}
try png.write(to: URL(fileURLWithPath: outPath))
SWIFT

swift "$WORK/draw.swift" "$WORK/background.png"

APP_KB="$(du -sk "$APP" | awk '{print $1}')"
SIZE_MB="$(( APP_KB / 1024 + 48 ))"
if [[ "$SIZE_MB" -lt 64 ]]; then
  SIZE_MB=64
fi

hdiutil create \
  -size "${SIZE_MB}m" \
  -fs HFS+ \
  -volname "$VOLUME" \
  "$RW" >/dev/null

hdiutil attach -readwrite -noverify -noautoopen -mountpoint "$MOUNT" "$RW" >/dev/null

ditto "$APP" "$MOUNT/Pressure.app"
ln -s /Applications "$MOUNT/Applications"
mkdir -p "$MOUNT/.background"
cp "$WORK/background.png" "$MOUNT/.background/background.png"
SetFile -a V "$MOUNT/.background"
chflags hidden "$MOUNT/.background"

layout_ok=0
for _attempt in 1 2 3; do
if osascript << EOF
tell application "Finder"
  tell disk "$VOLUME"
    open
    delay 2
    set current view of container window to icon view
    delay 1
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 860, 540}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 128
    set text size of viewOptions to 14
    set background picture of viewOptions to file ".background:background.png"
    set position of item "Pressure.app" of container window to {140, 160}
    set position of item "Applications" of container window to {480, 160}
    set extension hidden of item "Pressure.app" to true
    close
    open
    update without registering applications
    delay 2
    set position of item "Pressure.app" of container window to {140, 160}
    set position of item "Applications" of container window to {480, 160}
    close
  end tell
end tell
EOF
then
  layout_ok=1
  break
fi
echo "Finder was not ready to place the icons. Trying again." >&2
sleep 1
done
if [[ "$layout_ok" -ne 1 ]]; then
  exit 1
fi

sync
sleep 1
if [[ ! -f "$MOUNT/.DS_Store" ]]; then
  echo "Finder did not save the drag-into-Applications window." >&2
  exit 1
fi

if [[ -f "$ICON" ]]; then
  cp "$ICON" "$MOUNT/.VolumeIcon.icns"
  SetFile -a V "$MOUNT/.VolumeIcon.icns"
  SetFile -a C "$MOUNT"
fi
if [[ ! -f "$MOUNT/.VolumeIcon.icns" ]]; then
  echo "The volume icon was not copied onto the disk image." >&2
  exit 1
fi

hdiutil detach "$MOUNT" >/dev/null
mkdir -p "$ROOT/docs"
rm -f "$WORK/Pressure.dmg"
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$WORK/Pressure.dmg" >/dev/null
xattr -cr "$WORK/Pressure.dmg" || true
xattr -d com.apple.FinderInfo "$WORK/Pressure.dmg" 2>/dev/null || true
mv -f "$WORK/Pressure.dmg" "$OUT"
echo "Built $OUT"
