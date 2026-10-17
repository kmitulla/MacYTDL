#!/bin/bash
# Packs dist/MacYTDL.app into dist/MacYTDL.dmg (drag-to-Applications layout).
set -euo pipefail
cd "$(dirname "$0")/.."

STAGE=$(mktemp -d)/MacYTDL
mkdir -p "$STAGE"
cp -R dist/MacYTDL.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp "Resources/Bitte zuerst lesen.txt" "$STAGE/" 2>/dev/null || true
rm -f dist/MacYTDL.dmg
for attempt in 1 2 3; do
  if hdiutil create -volname "MacYTDL" -srcfolder "$STAGE" -ov -format ULFO dist/MacYTDL.dmg; then break; fi
  echo "hdiutil failed (attempt $attempt), retrying…" >&2
  sleep 5
done
hdiutil verify dist/MacYTDL.dmg
ls -lh dist/MacYTDL.dmg
shasum -a 256 dist/MacYTDL.dmg | tee dist/MacYTDL.dmg.sha256
