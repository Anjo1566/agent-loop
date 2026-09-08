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
#
# Zuerst wird .agents/testrun.txt gelesen. Dort steht die TAP-Ausgabe des
# Testlaufs, den loop.sh in derselben Runde ohnehin schon gemacht hat. Vorher
# fuhr dieses Skript die Suite ein zweites Mal — bei 62 Tests und 165 s auf
# diesem Rechner war das die Hälfte der Wartezeit je Runde, und über sechzig
# Runden mehr als drei Stunden für nichts.
#
# Die Datei muss neuer sein als die jüngste Datei unter test/: sonst zählte
# eine Runde, die Tests angelegt oder gelöscht hat, noch den alten Stand, und
# genau darauf schaut die Bremse. Passt sie nicht, wird gemessen statt geraten.

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null || true

zaehle_aus() {
  awk '/^# tests [0-9]+$/ { n = $3 } END { if (n != "") print n + 0 }' "$1"
}

frisch() {
  local lauf=".agents/testrun.txt" neuer
  [[ -s "$lauf" ]] || return 1
  # Gibt es unter test/ etwas, das jünger ist als der Testlauf?
  neuer=$(find test -newer "$lauf" -type f -print -quit 2>/dev/null)
  [[ -z "$neuer" ]]
}

if frisch; then
  AUS=$(zaehle_aus .agents/testrun.txt)
  if [[ "$AUS" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$AUS"
    exit 0
  fi
fi

# --test-reporter=tap festnageln: TAP ist zwar der Standard, sobald stdout
# keine Konsole ist, aber davon soll der Zähler nicht abhängen.
node --test --test-reporter=tap 2>/dev/null \
  | awk '/^# tests [0-9]+$/ { n = $3 } END { print n + 0 }'

exit 0
