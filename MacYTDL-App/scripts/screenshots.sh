#!/bin/bash
# Launches the app in demo mode for each page and captures screenshots (used by CI).
# Usage: scripts/screenshots.sh dist/MacYTDL.app <out-dir> [language]
set -uo pipefail
APP=$1
OUT=$2
LANG_CODE=${3:-de}
mkdir -p "$OUT"
for page in home preview queue library search subscriptions settings onboarding; do
  echo "== $page"
  rm -f "$OUT/$page.png" "$OUT/$page.png.wid"
  "$APP/Contents/MacOS/MacYTDL" -MacYTDLDemo "$page" -MacYTDLSnapshot "$OUT/$page.png" \
    -AppleLanguages "($LANG_CODE)" -NSQuitAlwaysKeepsWindows NO -downloadFolder /tmp/macytdl-demo-downloads \
    >"$OUT/$page.log" 2>&1 &
  pid=$!
  for _ in $(seq 1 60); do
    [ -f "$OUT/$page.png.wid" ] && break
    sleep 0.5
  done
  if [ -f "$OUT/$page.png.wid" ] && [ "$(cat "$OUT/$page.png.wid")" != 0 ]; then
    screencapture -x -o -l "$(cat "$OUT/$page.png.wid")" "$OUT/$page-window.png" 2>/dev/null || true
  else
    echo "no snapshot for $page – sampling main thread"
    /usr/bin/sample $pid 3 -file "$OUT/$page-sample.log" >/dev/null 2>&1 || true
    grep -A40 "Thread_.*DispatchQueue_1: com.apple.main-thread" "$OUT/$page-sample.log" | head -60 || true
  fi
  for _ in $(seq 1 30); do
    kill -0 $pid 2>/dev/null || break
    sleep 0.5
  done
  kill $pid 2>/dev/null || true
  cat "$OUT/$page.log"
done
screencapture -x "$OUT/desktop.png" 2>/dev/null || true
ls -la "$OUT"
