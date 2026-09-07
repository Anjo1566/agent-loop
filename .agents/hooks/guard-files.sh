#!/usr/bin/env bash
# Blockiert Schreibzugriffe auf Dateien, die der Agent nicht ändern darf.
#
# Exit 2 bricht den Werkzeugaufruf ab, stderr geht als Begründung ans Modell —
# deshalb sind die Meldungen englisch. Jeder andere Rückgabewert blockiert
# NICHT: Exit 1 loggt nur, Exit 126/127 (Datei fehlt, nicht ausführbar,
# Interpreter weg) ebenfalls. Deshalb ist dieses Skript fail-closed gebaut:
# kann es nicht urteilen, blockiert es.
#
# Dieser Guard sieht nur Edit/Write/NotebookEdit. Alles, was über die Shell
# schreibt, ist Sache von guard-bash.sh; was beide nicht sehen können, prüft
# loop.sh nach der Runde am Diff.

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

PROJEKT="${CLAUDE_PROJECT_DIR:-$PWD}"
PROJEKT="${PROJEKT//\\//}"

# Relative Pfade gegen das Projektverzeichnis auflösen, nicht gegen das
# Arbeitsverzeichnis des Hook-Prozesses: das kann in einem Unterverzeichnis
# liegen, und dann liefe jede Prüfung ins Leere.
case "$PFAD" in
  /*|[A-Za-z]:/*) ABSOLUT="$PFAD" ;;
  *)              ABSOLUT="$PROJEKT/$PFAD" ;;
esac

# Geprüft wird gegen den projektrelativen Pfad — sonst würde ein Projekt, das
# selbst unterhalb von .../test/ liegt, sich komplett sperren.
relativieren() {
  local pfad="$1" basis="$2"
  if [[ -n "$basis" && "$pfad" == "$basis/"* ]]; then
    printf '%s' "${pfad#"$basis"/}"
  else
    printf '%s' "$pfad"
  fi
}

REL=$(relativieren "$ABSOLUT" "$PROJEKT")
KANDIDATEN=("$REL")

# Kanonisieren, sonst hebelt ein Symlink oder eine Windows-Junction jedes
# Muster aus: `mklink /J cfg .claude`, und cfg/settings.json trifft kein Muster
# mehr, schreibt aber in .claude/settings.json.
#
# Der aufgelöste Pfad kommt nur dann zusätzlich in die Prüfung, wenn er sich
# vom ursprünglichen unterscheidet — also genau dann, wenn ein Alias im Spiel
# war. Auf Windows kann readlink dabei auf einen anderen Mount-Alias zeigen
# (/tmp statt /c/Users/.../Temp), deshalb wird er auch ungekürzt geprüft.
KANON=$(readlink -f -- "$ABSOLUT" 2>/dev/null) || KANON=""
[[ -z "$KANON" ]] && KANON="$ABSOLUT"
if [[ "$KANON" != "$ABSOLUT" ]]; then
  PROJEKT_KANON=$(readlink -f -- "$PROJEKT" 2>/dev/null) || PROJEKT_KANON="$PROJEKT"
  KANDIDATEN+=("$(relativieren "$KANON" "$PROJEKT_KANON")" "$KANON")
fi

trifft() {
  local kandidat
  for kandidat in "${KANDIDATEN[@]}"; do
    printf '%s' "$kandidat" | grep -qiE "$1" && return 0
  done
  return 1
}

# Geheimnisse gelten für JEDES Werkzeug, auch fürs Lesen — Vorlagendateien
# ausgenommen, die tragen per Konvention keine.
if trifft "$MUSTER_GEHEIM" && ! trifft "$MUSTER_GEHEIM_HARMLOS"; then
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
#
# Massgeblich ist, ob Git die Datei kennt, nicht ob sie auf der Platte liegt.
# Sonst genügt Löschen-dann-neu-schreiben, um die Regel auszuhebeln.
if trifft "$MUSTER_TESTS"; then
  # git bekommt den projektrelativen Pfad: einen aufgelösten Alias-Pfad kann es
  # dem Repository unter Umständen nicht zuordnen und meldete dann fälschlich
  # "unbekannt", also "neue Datei".
  if git -C "$PROJEKT" ls-files --error-unmatch -- "$REL" >/dev/null 2>&1; then
    echo "Blocked: existing tests must not be changed. Fix the code, or add an entry to QUESTIONS.md. Writing a NEW test file is allowed." >&2
    exit 2
  fi
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
