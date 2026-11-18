#!/usr/bin/env bash
# Renders docs/assets/social-preview.svg to the 1280x640 PNG that GitHub shows in link previews.
# GitHub has no API for it: upload the PNG in Settings > General > Social preview.
# Needs rsvg-convert (librsvg) and the Inter font.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
command -v rsvg-convert >/dev/null || { echo "social-preview: install rsvg-convert (librsvg)" >&2; exit 1; }
fc-match -f '%{family}' Inter | grep -q '^Inter' || echo "social-preview: Inter not installed, a fallback font is used" >&2
rsvg-convert -w 1280 -h 640 docs/assets/social-preview.svg -o docs/assets/social-preview.png
echo "docs/assets/social-preview.png"
