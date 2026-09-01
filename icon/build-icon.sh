#!/usr/bin/env bash
#
# Régénère l'icône de l'application depuis sa source vectorielle.
#
#   brew install librsvg && pip3 install pillow
#   ./icon/build-icon.sh
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="AppleMusicPresenceLocal/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png"

rsvg-convert -w 1024 -h 1024 icon/AppIcon.svg -o /tmp/icon-raw.png

# iOS refuse toute transparence dans une icône d'application : on aplatit sur
# la couleur de départ du dégradé.
python3 - "$OUT" <<'PY'
import sys
from PIL import Image

source = Image.open("/tmp/icon-raw.png").convert("RGBA")
flat = Image.new("RGB", source.size, (17, 18, 25))
flat.paste(source, mask=source.split()[3])
flat.save(sys.argv[1], "PNG")
print(f"→ {sys.argv[1]} ({flat.size[0]}×{flat.size[1]}, {flat.mode})")
PY
