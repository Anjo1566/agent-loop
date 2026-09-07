#!/usr/bin/env bash
# Blockiert gefährliche und guard-umgehende Befehle.
#
# Dieser Guard ist der wichtigere der beiden. guard-files.sh sieht nur
# Edit/Write/NotebookEdit — jeder Schreibzugriff über die Shell (`sed -i`,
# `cat > datei`, `rm`) läuft daran vorbei. Deshalb prüft dieses Skript
# dieselben geschützten Pfade noch einmal, aus derselben Musterdatei.
#
# Fail-closed wie guard-files.sh: kann es nicht urteilen, blockiert es.

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

BEFEHL=$(printf '%s' "$EINGABE" | jq -r '.tool_input.command // empty' 2>/dev/null) || {
  echo "Blocked: the guard could not parse the hook payload." >&2
  exit 2
}

[[ -z "$BEFEHL" ]] && exit 0

im_befehl() { printf '%s' "$BEFEHL" | grep -qE "$1"; }

# --- 1. Guard-Umgehung und Unumkehrbares --------------------------------
# `git commit -n` ist die Kurzform von --no-verify und muss mitgefangen
# werden; bei `git push` heisst -n dagegen --dry-run und ist harmlos.
if im_befehl '(--no-verify|git[[:space:]]+(commit|merge)([[:space:]]+[^[:space:]|;&]+)*[[:space:]]+-[a-zA-Z]*n([[:space:]]|$))'; then
  echo "Blocked: skipping the commit hooks bypasses the safeguards." >&2
  exit 2
fi

if im_befehl '(git[[:space:]]+stash|git[[:space:]]+reset[[:space:]]+--(hard|merge|keep)|git[[:space:]]+clean|git[[:space:]]+restore|git[[:space:]]+checkout[[:space:]]+(--|[^-][^[:space:]]*[[:space:]]+--))'; then
  echo "Blocked: this discards work irreversibly and is the usual way to hide a change. Commit instead." >&2
  exit 2
fi

if im_befehl '(rm[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*-[a-zA-Z]*[rf][a-zA-Z]*[[:space:]]+(/|~|\.\.?)([[:space:]]|$)|mkfs|shutdown|reboot|:\(\)\{|npm[[:space:]]+publish|(^|[[:space:]])yarn[[:space:]]+publish|pip[[:space:]]+.*upload)'; then
  echo "Blocked: this is irreversible or has external effects." >&2
  exit 2
fi

# --- 2. Pushen: nur auf den Agenten-Branch, nie mit Gewalt ---------------
# Am Verb ankern, damit `git -c foo=bar push` nicht am Muster vorbeiläuft.
if im_befehl '(^|[;&|[:space:]])git\b[^;&|]*\bpush\b'; then
  # Refspec statt Substring: sonst blockiert der Guard Branchnamen wie
  # "agent/maintenance" oder "agent/20260907-domain-fix".
  if im_befehl '(--force|--force-with-lease|--mirror|--delete|(^|[[:space:]])-[a-zA-Z]*f([[:space:]]|$)|(^|[[:space:]])\+[^[:space:]]*:|(^|[[:space:]:/])(refs/heads/)?(main|master)([[:space:]]|$))'; then
    echo "Blocked: no push to main and no force push. Push to the agent branch only." >&2
    exit 2
  fi
fi

# --- 3. Schreibzugriff auf geschützte Pfade über die Shell ---------------
# Den Befehl in Tokens zerlegen, damit die Pfadmuster aus protected-paths.sh
# (die mit `$` ankern) gegen einzelne Pfade greifen und nicht gegen die ganze
# Zeile. Backslashes vorher normalisieren.
TOKENS=$(printf '%s' "$BEFEHL" \
  | tr '\\' '/' \
  | tr -s ' \t\n"'"'"'()`;&|<>=' '\n')

token_trifft() {
  local muster="$1" token
  while IFS= read -r token; do
    [[ -z "$token" ]] && continue
    if printf '%s' "$token" | grep -qiE "$muster"; then
      return 0
    fi
  done <<< "$TOKENS"
  return 1
}

# Geheimnisse: in einem Shell-Befehl gibt es dafür hier keinen legitimen Grund.
if token_trifft "$MUSTER_GEHEIM"; then
  echo "Blocked: secrets." >&2
  exit 2
fi

# Schreibende Werkzeuge und Ausgabeumleitungen.
SCHREIBEND='((^|[;&|[:space:]])(sed|perl|awk|python[0-9.]*|node|ruby|php|tee|patch|cp|mv|rm|dd|truncate|ed|ex|install|rsync|touch|chmod|chown|shred)([[:space:]]|$)|>)'

if im_befehl "$SCHREIBEND"; then
  if token_trifft "$MUSTER_TESTS"; then
    echo "Blocked: existing tests must not be changed through the shell. Fix the code, or add an entry to QUESTIONS.md." >&2
    exit 2
  fi
  if token_trifft "$MUSTER_DEPS"; then
    echo "Blocked: dependencies and build configuration are a human decision. Add an entry to QUESTIONS.md." >&2
    exit 2
  fi
  if token_trifft "$MUSTER_SELBST"; then
    echo "Blocked: your own configuration and safeguards are immutable." >&2
    exit 2
  fi
fi

exit 0
