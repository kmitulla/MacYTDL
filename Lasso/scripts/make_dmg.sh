#!/bin/bash
# Packs dist/Lasso.app into dist/Lasso.dmg (drag-to-Applications layout).
set -euo pipefail
cd "$(dirname "$0")/.."

STAGE=$(mktemp -d)/Lasso
mkdir -p "$STAGE"
cp -R dist/Lasso.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp "Resources/Bitte zuerst lesen.txt" "$STAGE/" 2>/dev/null || true
rm -f dist/Lasso.dmg
for attempt in 1 2 3; do
  if hdiutil create -volname "Lasso" -srcfolder "$STAGE" -ov -format ULFO dist/Lasso.dmg; then break; fi
  echo "hdiutil failed (attempt $attempt), retrying…" >&2
  sleep 5
done
hdiutil verify dist/Lasso.dmg
ls -lh dist/Lasso.dmg
shasum -a 256 dist/Lasso.dmg | tee dist/Lasso.dmg.sha256
