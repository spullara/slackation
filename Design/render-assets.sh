#!/bin/bash
# Requires librsvg and ImageMagick: brew install librsvg imagemagick
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="/opt/homebrew/bin:$PATH"
command -v rsvg-convert >/dev/null
command -v magick >/dev/null
assets=Slackation/Assets.xcassets
rsvg-convert -w 1024 -h 1024 Design/logo.svg | magick png:- -background '#182C40' -alpha remove -alpha off "$assets/AppIcon.appiconset/AppIcon.png"
# A 160-point logo at each iPhone scale. The background matches the launch color.
for scale in 1 2 3; do
  size=$((160 * scale))
  rsvg-convert -w "$size" -h "$size" Design/logo.svg > "$assets/LaunchLogo.imageset/LaunchLogo@${scale}x.png"
done
