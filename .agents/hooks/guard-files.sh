#!/usr/bin/env bash
# Blockiert Schreibzugriffe auf Dateien, die der Agent nicht ändern darf.
#
# Exit 2 bricht den Werkzeugaufruf ab, stderr geht als Begründung ans Modell —
# deshalb sind die Meldungen englisch. Jeder andere Rückgabewert blockiert
# NICHT: Exit 1 loggt nur, Exit 126/127 (Datei fehlt, nicht ausführbar,
# Interpreter weg) ebenfalls. Deshalb ist dieses Skript fail-closed gebaut:
# kann es nicht urteilen, blockiert es.

set -uo pipefail

VERZEICHNIS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=protected-paths.sh
. "$VERZEICHNIS/protected-paths.sh" 2>/dev/null || {
  echo "Blocked: the guard could not load its path patterns." >&2
  exit 2
}

command -v jq >/dev/null 2>&1 || {
  echo "Blocked: the guard cannot evaluate this call because jq is missing." >&2
  exit 2
}

EINGABE=$(cat)

WERKZEUG=$(printf '%s' "$EINGABE" | jq -r '.tool_name // empty' 2>/dev/null) || {
  echo "Blocked: the guard could not parse the hook payload." >&2
  exit 2
}
[[ -z "$WERKZEUG" ]] && {
  echo "Blocked: the hook payload carried no tool name." >&2
  exit 2
}

# NotebookEdit trägt den Pfad unter einem anderen Schlüssel als Edit/Write.
PFAD=$(printf '%s' "$EINGABE" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null)

# Windows-Pfade normalisieren, sonst greift kein einziges Muster.
PFAD="${PFAD//\\//}"

# Ein Aufruf ohne Pfad geht diesen Guard nichts an.
[[ -z "$PFAD" ]] && exit 0

trifft() { printf '%s' "$PFAD" | grep -qiE "$1"; }

# Geheimnisse gelten für JEDES Werkzeug, auch fürs Lesen.
if trifft "$MUSTER_GEHEIM"; then
  echo "Blocked: secrets." >&2
  exit 2
fi

# Alle weiteren Regeln gelten nur fürs Schreiben. Der Reviewer muss Tests,
# Lockfiles und die Charta LESEN dürfen — sonst kann er seinen zweiten
# Prüfpunkt ("wurde ein bestehender Test abgeschwächt?") nicht erfüllen.
case "$WERKZEUG" in
  Edit|Write|NotebookEdit|MultiEdit) ;;
  *) exit 0 ;;
esac

# Bestehende Tests sind gesperrt, neue anzulegen ist erlaubt. Die Charta
# verlangt beides: "test design for new code" darf der Agent entscheiden,
# "never change, remove or skip an existing test" darf er nicht.
if trifft "$MUSTER_TESTS" && [[ -e "$PFAD" ]]; then
  echo "Blocked: existing tests must not be changed. Fix the code, or add an entry to QUESTIONS.md. Writing a NEW test file is allowed." >&2
  exit 2
fi

if trifft "$MUSTER_DEPS"; then
  echo "Blocked: dependencies and build configuration are a human decision. Add an entry to QUESTIONS.md." >&2
  exit 2
fi

if trifft "$MUSTER_SELBST"; then
  echo "Blocked: your own configuration and safeguards are immutable." >&2
  exit 2
fi

exit 0
