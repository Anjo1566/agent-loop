#!/usr/bin/env bash
# Zählt die Tests der Suite und gibt genau eine Zahl auf stdout aus.
#
# Liegt in .agents/hooks/, obwohl es kein Hook ist: dieses Verzeichnis ist das
# einzige unterhalb von .agents/, das versioniert wird, und guard-files.sh
# macht alles darin für den Agenten unveränderbar. Ein Zähler, den der Agent
# umschreiben kann, ist als Wächter wertlos.
#
# Zwei Eigenschaften sind Pflicht, sonst reisst der Zähler den ganzen Lauf ab:
#   1. Immer Exit 0 — auch bei roter Suite. loop.sh liest den Wert mit
#      `$(... || echo 0)`; ein Fehlschlag würde sonst zwei Zeilen liefern und
#      den anschliessenden Zahlenvergleich unter `set -e` sprengen.
#   2. `# tests N` lesen, nicht `# pass N`. Sonst sinkt die Zahl bei jedem
#      roten Lauf und die Bremse "Testanzahl gesunken" schlägt falsch an.

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null || true

# --test-reporter=tap festnageln: TAP ist zwar der Standard, sobald stdout
# keine Konsole ist, aber davon soll der Zähler nicht abhängen.
node --test --test-reporter=tap 2>/dev/null \
  | awk '/^# tests [0-9]+$/ { n = $3 } END { print n + 0 }'

exit 0
