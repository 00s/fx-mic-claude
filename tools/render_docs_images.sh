#!/bin/zsh
# Re-renders docs/images/ from the app's own views: the hero (a laptop and the mic, transparent), the island states
# and gesture rails (light and dark), and the gesture demos as GIFs.
# Needs ffmpeg for the GIFs. Run after `swift build -c release` so FXMicCore is built.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
swift build -c release --product FXMic >/dev/null
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
swiftc -O -I .build/release/Modules -module-name DocsImages -o "$WORK/render" \
  tools/docs_images/main.swift tools/docs_images/DocsImages.swift $(ls Sources/FXMic/*.swift | grep -v '/main.swift') \
  .build/release/FXMicCore.build/*.o -framework AppKit -framework SwiftUI -framework AVFoundation -framework Speech \
  -framework CoreAudio -framework Carbon 2>&1 | grep -E 'error:' && exit 1
"$WORK/render" "$WORK" 2>/dev/null
"$WORK/render" "$WORK/hero.png" hero 2>/dev/null
OUT=docs/images
mkdir -p "$OUT"
cp "$WORK/hero.png" "$OUT/hero.png"; sips -Z 2000 "$OUT/hero.png" >/dev/null       # transparent: one image for light and dark
for f in states gestures how; do
  for s in light dark; do cp "$WORK/$f-$s.png" "$OUT/"; sips -Z 1800 "$OUT/$f-$s.png" >/dev/null; done
done
for g in send queue draft cancel; do
  ffmpeg -loglevel error -y -framerate 12 -i "$WORK/frames-$g/%04d.png" \
    -vf "scale=400:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=96:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" \
    -loop 0 "$OUT/gesture-$g.gif"
done
echo "rendered $(ls "$OUT" | wc -l | tr -d ' ') images into $OUT"
