#!/bin/bash
# Launches the app in demo mode for each page and captures screenshots (used by CI).
# Usage: scripts/screenshots.sh dist/MacYTDL.app <out-dir> [language]
set -uo pipefail
APP=$1
OUT=$2
LANG_CODE=${3:-de}
mkdir -p "$OUT"
for spec in home preview queue library search subscriptions settings onboarding home:dark preview:dark; do
  page=${spec%%:*}
  appearance=system
  if [ "$spec" != "$page" ]; then appearance=${spec##*:}; fi
  shot=$page
  [ "$appearance" = system ] || shot="$page-$appearance"
  echo "== $shot"
  rm -f "$OUT/$shot.png" "$OUT/$shot.png.wid"
  "$APP/Contents/MacOS/MacYTDL" -MacYTDLDemo "$page" -MacYTDLSnapshot "$OUT/$shot.png" -appearance "$appearance" -autoAnalyze NO \
    -AppleLanguages "($LANG_CODE)" -NSQuitAlwaysKeepsWindows NO -downloadFolder /tmp/macytdl-demo-downloads \
    -MacYTDLTraceRenders YES \
    >"$OUT/$shot.log" 2>&1 &
  pid=$!
  for _ in $(seq 1 60); do
    [ -f "$OUT/$shot.png.wid" ] && break
    sleep 0.5
  done
  if [ -f "$OUT/$shot.png.wid" ] && [ "$(cat "$OUT/$shot.png.wid")" != 0 ]; then
    screencapture -x -o -l "$(cat "$OUT/$shot.png.wid")" "$OUT/$shot-window.png" 2>/dev/null || true
  else
    echo "no snapshot for $shot – sampling main thread"
    /usr/bin/sample $pid 3 -file "$OUT/$shot-sample.log" >/dev/null 2>&1 || true
  fi
  for _ in $(seq 1 30); do
    kill -0 $pid 2>/dev/null || break
    sleep 0.5
  done
  kill $pid 2>/dev/null || true
  echo "--- $shot.log (render trace summary)"
  sort "$OUT/$shot.log" | uniq -c | sort -rn | head -15
done
screencapture -x "$OUT/desktop.png" 2>/dev/null || true
ls -la "$OUT"
