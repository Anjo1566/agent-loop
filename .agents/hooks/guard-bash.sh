#!/usr/bin/env bash
# Blockiert gefährliche und guard-umgehende Befehle.
#
# guard-files.sh sieht nur Edit/Write/NotebookEdit — jeder Schreibzugriff über
# die Shell (`sed -i`, `cat > datei`, `rm`) läuft daran vorbei. Deshalb prüft
# dieses Skript dieselben geschützten Pfade noch einmal, aus derselben
# Musterdatei.
#
# Was dieser Guard NICHT leisten kann: Werkzeuge, die ihr Ziel nicht auf der
# Kommandozeile tragen, sondern in einer Datei (`git apply`, `patch`, ein
# Shell-Skript). Die werden deshalb rundheraus abgelehnt, statt sie zu
# analysieren. Und weil auch das nie vollständig sein wird, prüft loop.sh nach
# jeder Runde am Diff nach, ob ein versionierter Test angefasst wurde. Der
# Guard ist die schnelle Rückmeldung ans Modell, das Skript ist die Zusage.
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

PROJEKT="${CLAUDE_PROJECT_DIR:-$PWD}"
PROJEKT="${PROJEKT//\\//}"

# Linke Wortgrenze eines Befehlsworts. Anführungszeichen, Klammern und
# Backticks gehören dazu: ohne sie schaltet ein vorangestelltes `bash -c "` die
# gesamte Pfadprüfung ab.
G='(^|[;&|(){}[:space:]"'"'"'`])'
# Rechte Wortgrenze. `"sed" -i ...` endet auf einem Anführungszeichen, nicht auf
# einem Leerzeichen — ohne diese Klasse trifft kein Befehlswort in Anführung.
GR='([;&|(){}[:space:]"'"'"'`]|$)'

im_befehl() { printf '%s' "$BEFEHL" | grep -qE "$1"; }

# --- 1. Guard-Umgehung und Unumkehrbares --------------------------------
# `git commit -n` ist die Kurzform von --no-verify und muss mitgefangen
# werden; bei `git push` heisst -n dagegen --dry-run und ist harmlos.
if im_befehl '(--no-verify|git[[:space:]]+(commit|merge)([[:space:]]+[^[:space:]|;&]+)*[[:space:]]+-[a-zA-Z]*n([[:space:]]|$))'; then
  echo "Blocked: skipping the commit hooks bypasses the safeguards." >&2
  exit 2
fi

if im_befehl "${G}git[[:space:]]+(stash|clean|restore)|git[[:space:]]+reset[[:space:]]+--(hard|merge|keep)|git[[:space:]]+checkout[[:space:]]+(--|[^-][^[:space:]]*[[:space:]]+--)"; then
  echo "Blocked: this discards work irreversibly and is the usual way to hide a change. Commit instead." >&2
  exit 2
fi

# Werkzeuge, deren Ziel im Inhalt einer Datei steht statt auf der
# Kommandozeile. Sie lassen sich nicht prüfen, nur ablehnen.
if im_befehl "${G}(patch|git[[:space:]]+(apply|am|checkout-index))${GR}"; then
  echo "Blocked: applying a diff hides which files it writes. Use the Edit tool for code changes." >&2
  exit 2
fi

if im_befehl "${G}find([[:space:]]|$).*[[:space:]]-(delete|exec|execdir|ok)([[:space:]]|$)"; then
  echo "Blocked: find with -delete or -exec can reach any file without naming it. Name the file directly." >&2
  exit 2
fi

# Abhängigkeiten sind laut Charta eine menschliche Entscheidung. Diese
# Unterbefehle schreiben package.json und das Lockfile, ohne sie zu nennen.
if im_befehl "${G}(npm|pnpm|bun)[[:space:]]+(i|install|add|uninstall|remove|rm|update|pkg)([[:space:]]|$)" \
   || im_befehl "${G}yarn[[:space:]]+(add|remove|upgrade)([[:space:]]|$)" \
   || im_befehl "${G}npx[[:space:]]" \
   || im_befehl "${G}(pip[0-9.]*|poetry|cargo|go)[[:space:]]+(install|add|remove|uninstall|get)([[:space:]]|$)"; then
  echo "Blocked: dependencies and build configuration are a human decision. Add an entry to QUESTIONS.md." >&2
  exit 2
fi

if im_befehl "${G}(mkfs|shutdown|reboot)([[:space:]]|$)|:\(\)\{|${G}(npm|yarn|pnpm)[[:space:]]+publish|${G}rm[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*-[a-zA-Z]*[rf][a-zA-Z]*[[:space:]]+(/|~|\.\.?)([[:space:]]|$)"; then
  echo "Blocked: this is irreversible or has external effects." >&2
  exit 2
fi

# --- 2. Pushen: nur auf den Agenten-Branch, nie mit Gewalt ---------------
# Am Verb ankern, damit `git -c foo=bar push` nicht am Muster vorbeiläuft.
if im_befehl "${G}git\b[^;&|]*[[:space:]]push([[:space:]]|$)"; then
  # `-fu` ist dasselbe wie `-uf`: das f darf irgendwo im Flag-Bündel stehen.
  if im_befehl '(--force|--force-with-lease|--mirror|--delete|(^|[[:space:]])-[a-zA-Z]*f[a-zA-Z]*([[:space:]]|$)|(^|[[:space:]])\+[^[:space:]]*:|(^|[[:space:]:/])(refs/heads/)?(main|master)([[:space:]]|$))'; then
    echo "Blocked: no push to main and no force push. Push to the agent branch only." >&2
    exit 2
  fi
  # Ohne ausdrückliche Refspec pusht git den aktuellen Branch — und der kann
  # main sein, ohne dass das Wort im Befehl vorkommt.
  ZIEL=$(printf '%s' "$BEFEHL" \
    | sed -E 's/.*[[:space:]]push([[:space:]]|$)/ /' \
    | tr ' \t' '\n\n' \
    | grep -vE '^(-|$)' \
    | tail -n +2)
  if [[ -z "$ZIEL" ]] || printf '%s' "$ZIEL" | grep -qE '^(HEAD|main|master)$'; then
    echo "Blocked: push must name the agent branch explicitly, e.g. 'git push -u origin agent/<name>'." >&2
    exit 2
  fi
fi

# --- 3. Schreibzugriff auf geschützte Pfade über die Shell ---------------
# Den Befehl in Tokens zerlegen, damit die Pfadmuster aus protected-paths.sh
# (die mit `$` ankern) gegen einzelne Pfade greifen und nicht gegen die ganze
# Zeile.
zerlegen() {
  printf '%s' "$1" \
    | tr '\\' '/' \
    | tr -s ' \t\n"'"'"'()`;&|<>=' '\n'
}

# Zusätzlich eine Fassung ohne Anführungszeichen: `.e""nv` würde sonst in zwei
# harmlose Tokens zerfallen.
OHNE_QUOTES="${BEFEHL//\"/}"
OHNE_QUOTES="${OHNE_QUOTES//\'/}"
ROH=$({ zerlegen "$BEFEHL"; zerlegen "$OHNE_QUOTES"; } | grep -v '^$' | sort -u)

# Globs muss der Guard sehen, wie die Shell sie sehen wird: `rm loop.s?` und
# `sed -i ... loop.s[h]` treffen sonst kein einziges Muster, schreiben aber
# loop.sh. Deshalb jeden Token mit Glob-Zeichen zusätzlich expandieren — reine
# Dateinamenserweiterung, es wird nichts ausgeführt — und ihn zusätzlich ohne
# Glob-Zeichen aufnehmen, falls die Datei noch nicht existiert.
TOKENS=$(
  {
    printf '%s\n' "$ROH"
    printf '%s\n' "$ROH" | sed -E 's/\[([^]]*)\]/\1/g; s/[?*]//g'
    while IFS= read -r TOKEN; do
      case "$TOKEN" in
        *[\*\?\[]*)
          ( cd "$PROJEKT" 2>/dev/null || exit 0
            shopt -s nullglob dotglob
            # shellcheck disable=SC2086
            for TREFFER in $TOKEN; do printf '%s\n' "$TREFFER"; done ) | head -50
          ;;
      esac
    done <<< "$ROH"
  } | grep -v '^$' | sort -u
)

# Ziele von Ausgabeumleitungen. Nur die zählen als Schreiben — `2>/dev/null`
# und `2>&1` sind keine, und ein Befehl, der einen geschützten Pfad nur LIEST
# und die Ausgabe woanders hinschreibt, ist erlaubt.
UMLEITUNGSZIELE=$(
  printf '%s' "$BEFEHL" \
    | tr '\\' '/' \
    | grep -oE '[0-9]?>>?[[:space:]]*[^[:space:]|;&<>]+' \
    | sed -E 's/^[0-9]?>>?[[:space:]]*//' \
    | grep -v '^$' || true
)

treffer() {
  local muster="$1" liste="$2" token
  while IFS= read -r token; do
    [[ -z "$token" ]] && continue
    if printf '%s' "$token" | grep -qiE "$muster"; then
      printf '%s' "$token"
      return 0
    fi
  done <<< "$liste"
  return 1
}

# Geheimnisse: in einem Shell-Befehl gibt es dafür hier keinen legitimen Grund.
if GEHEIM=$(treffer "$MUSTER_GEHEIM" "$TOKENS"); then
  if ! printf '%s' "$GEHEIM" | grep -qiE "$MUSTER_GEHEIM_HARMLOS"; then
    echo "Blocked: secrets." >&2
    exit 2
  fi
fi

# Umleitungsziele werden immer geprüft, unabhängig vom Befehlswort.
for MUSTER in "$MUSTER_TESTS:existing tests must not be changed through the shell. Fix the code, or add an entry to QUESTIONS.md." \
              "$MUSTER_DEPS:dependencies and build configuration are a human decision. Add an entry to QUESTIONS.md." \
              "$MUSTER_SELBST:your own configuration and safeguards are immutable."; do
  M="${MUSTER%%:*}"; T="${MUSTER#*:}"
  if ZIEL=$(treffer "$M" "$UMLEITUNGSZIELE"); then
    # Eine NEUE Testdatei anzulegen ist erlaubt, genau wie beim Datei-Guard.
    if [[ "$M" == "$MUSTER_TESTS" ]] \
       && ! git -C "$PROJEKT" ls-files --error-unmatch -- "$ZIEL" >/dev/null 2>&1; then
      continue
    fi
    echo "Blocked: $T" >&2
    exit 2
  fi
done

# Schreibende Befehlsworte. Interpreter zählen nur mit einem Inline- oder
# In-place-Schalter — sonst wäre `node --test test/foo.test.js`, der
# naheliegendste Schritt beim Eingrenzen eines Fehlschlags, gesperrt.
SCHREIBEND_IMMER="${G}(tee|dd|truncate|shred|install|rsync|ed|ex|xargs)${GR}"
SCHREIBEND_PFAD="${G}(rm|mv|cp|touch|chmod|chown|ln|mkdir)${GR}"
INTERPRETER="${G}(sed|perl|awk|python[0-9.]*|node|ruby|php)${GR}"
INLINE_SCHALTER='(^|[[:space:]])--?[a-zA-Z]*(i|c|e)([[:space:]]|=|$)'

SCHREIBT=0
im_befehl "$SCHREIBEND_IMMER" && SCHREIBT=1
im_befehl "$SCHREIBEND_PFAD"  && SCHREIBT=1
if im_befehl "$INTERPRETER" && im_befehl "$INLINE_SCHALTER"; then SCHREIBT=1; fi

if (( SCHREIBT )); then
  if ZIEL=$(treffer "$MUSTER_TESTS" "$TOKENS"); then
    if git -C "$PROJEKT" ls-files --error-unmatch -- "$ZIEL" >/dev/null 2>&1; then
      echo "Blocked: existing tests must not be changed through the shell. Fix the code, or add an entry to QUESTIONS.md." >&2
      exit 2
    fi
  fi
  if treffer "$MUSTER_DEPS" "$TOKENS" >/dev/null; then
    echo "Blocked: dependencies and build configuration are a human decision. Add an entry to QUESTIONS.md." >&2
    exit 2
  fi
  if treffer "$MUSTER_SELBST" "$TOKENS" >/dev/null; then
    echo "Blocked: your own configuration and safeguards are immutable." >&2
    exit 2
  fi
fi

exit 0
