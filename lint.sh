#!/usr/bin/env bash
# Analyse statique de l'app iOS.
#
# SwiftLint charge sourcekitd, normalement fourni par Xcode. Quand seul le
# paquet Command Line Tools est installé, on lui indique où le trouver.
set -euo pipefail
cd "$(dirname "$0")"

if ! xcode-select -p 2>/dev/null | grep -q "Xcode.app"; then
  export DYLD_FRAMEWORK_PATH="/Library/Developer/CommandLineTools/usr/lib"
fi

echo "── SwiftLint ──"
swiftlint lint --quiet --reporter emoji AppleMusicPresenceLocal

echo
echo "── Analyse syntaxique ──"
find AppleMusicPresenceLocal -name '*.swift' -print0 | xargs -0 -n1 swiftc -parse >/dev/null

echo "✅ Analyse terminée."
