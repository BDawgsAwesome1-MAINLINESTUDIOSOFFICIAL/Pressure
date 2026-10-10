#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Pressure.app"
OUT="$ROOT/docs/Pressure.dmg"
STAGE="$(mktemp -d)"

if [[ ! -d "$APP" ]]; then
  echo "Build the app first: scripts/build.sh" >&2
  exit 1
fi

mkdir -p "$ROOT/docs"
cp -R "$APP" "$STAGE/Pressure.app"
ln -s /Applications "$STAGE/Applications"

rm -f "$OUT"
hdiutil create \
  -volname Pressure \
  -srcfolder "$STAGE" \
  -ov \
  -format UDZO \
  "$OUT"

xattr -cr "$OUT" || true
xattr -d com.apple.FinderInfo "$OUT" 2>/dev/null || true
rm -rf "$STAGE"
echo "Built $OUT"
