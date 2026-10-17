#!/bin/bash
# Downloads the helper programs that ship inside Lasso.app and builds universal (arm64 + x86_64) binaries.
#   yt-dlp  – https://github.com/yt-dlp/yt-dlp (Unlicense)
#   deno    – https://github.com/denoland/deno (MIT)          – JavaScript runtime yt-dlp needs for YouTube
#   ffmpeg  – https://ffmpeg.martin-riedl.de (GPL static builds), fallback: ffmpeg-static on GitHub
# Usage: [TOOLS_ARCH=arm64|universal] scripts/fetch_tools.sh <vendor-dir>
# Default: Apple Silicon helpers only (half the size); Lasso downloads Intel helpers itself when needed.
set -euo pipefail

TOOLS_ARCH=${TOOLS_ARCH:-arm64}

VENDOR=${1:-vendor}
OUT="$VENDOR/Tools"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT"

dl() {
  curl -fL --retry 6 --retry-all-errors --retry-delay 4 --connect-timeout 30 --max-time 900 -sS -o "$2" "$1"
}

unzip_find() { # zip name dest
  local dir="$WORK/unz-$RANDOM"
  mkdir -p "$dir"
  ditto -x -k "$1" "$dir"
  local found
  found=$(find "$dir" -type f -name "$2" | head -1)
  [ -n "$found" ] || { echo "no $2 in $1" >&2; return 1; }
  mv "$found" "$3"
  chmod 755 "$3"
}

echo "== yt-dlp"
dl https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos "$OUT/yt-dlp"
chmod 755 "$OUT/yt-dlp"
lipo -info "$OUT/yt-dlp" || true
codesign -dv "$OUT/yt-dlp" 2>&1 | grep -E "Signature|Identifier" || true
if ! codesign --verify "$OUT/yt-dlp" 2>/dev/null; then
  echo "yt-dlp is unsigned - signing ad-hoc"
  codesign --force --sign - "$OUT/yt-dlp"
fi
YTDLP_VERSION=$("$OUT/yt-dlp" --version)
echo "yt-dlp $YTDLP_VERSION"

echo "== deno"
dl "https://github.com/denoland/deno/releases/latest/download/deno-aarch64-apple-darwin.zip" "$WORK/deno-aarch64.zip"
unzip_find "$WORK/deno-aarch64.zip" deno "$WORK/deno-aarch64"
if [ "$TOOLS_ARCH" = universal ]; then
  dl "https://github.com/denoland/deno/releases/latest/download/deno-x86_64-apple-darwin.zip" "$WORK/deno-x86_64.zip"
  unzip_find "$WORK/deno-x86_64.zip" deno "$WORK/deno-x86_64"
  lipo -create "$WORK/deno-aarch64" "$WORK/deno-x86_64" -output "$OUT/deno"
else
  cp "$WORK/deno-aarch64" "$OUT/deno"
fi
DENO_VERSION=$("$OUT/deno" --version | head -1 | awk '{print $2}')
echo "deno $DENO_VERSION"

fetch_ffmpeg() { # tool arch(arm64|amd64) dest
  local tool=$1 arch=$2 dest=$3
  for attempt in 1 2 3 4 5 6 7 8; do
    if curl -fL --retry 2 --connect-timeout 30 --max-time 600 -sS -o "$WORK/$tool-$arch.zip" \
        "https://ffmpeg.martin-riedl.de/redirect/latest/macos/$arch/release/$tool.zip"; then
      unzip_find "$WORK/$tool-$arch.zip" "$tool" "$dest" && return 0
    fi
    echo "martin-riedl $tool/$arch attempt $attempt failed, retrying…" >&2
    sleep $((attempt * 5))
  done
  echo "falling back to ffmpeg-static for $tool/$arch" >&2
  local suffix=$([ "$arch" = arm64 ] && echo arm64 || echo x64)
  dl "https://github.com/eugeneware/ffmpeg-static/releases/latest/download/$tool-darwin-$suffix.gz" "$WORK/$tool-$arch.gz"
  gunzip -c "$WORK/$tool-$arch.gz" > "$dest"
  chmod 755 "$dest"
}

echo "== ffmpeg / ffprobe"
for tool in ffmpeg ffprobe; do
  fetch_ffmpeg "$tool" arm64 "$WORK/$tool-arm64"
  if [ "$TOOLS_ARCH" = universal ]; then
    fetch_ffmpeg "$tool" amd64 "$WORK/$tool-amd64"
    lipo -create "$WORK/$tool-arm64" "$WORK/$tool-amd64" -output "$OUT/$tool"
  else
    cp "$WORK/$tool-arm64" "$OUT/$tool"
  fi
done
FFMPEG_VERSION=$("$OUT/ffmpeg" -version | head -1 | awk '{print $3}')
echo "ffmpeg $FFMPEG_VERSION"

# lipo keeps each slice's signature, but make sure every binary has a valid one (arm64 requires it).
for tool in deno ffmpeg ffprobe; do
  if ! codesign --verify "$OUT/$tool" 2>/dev/null; then
    codesign --force --sign - "$OUT/$tool"
  fi
  lipo -info "$OUT/$tool"
done

cat > "$OUT/manifest.json" <<JSON
{
  "yt-dlp": "$YTDLP_VERSION",
  "deno": "$DENO_VERSION",
  "ffmpeg": "$FFMPEG_VERSION",
  "ffprobe": "$FFMPEG_VERSION"
}
JSON
cat "$OUT/manifest.json"
du -sh "$OUT"/*
