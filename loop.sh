#!/usr/bin/env bash
set -euo pipefail

# --- Vom Umsetzer auszufüllen -------------------------------------------
TESTBEFEHL="node --test"                      # muss bei Fehlschlag != 0 liefern
TESTZAEHLER="./.agents/hooks/count-tests.sh"  # gibt die Anzahl Tests als Zahl aus
MAX_TURNS=200               # harter Deckel pro Runde
MAX_OPUS_RUNDEN=5           # so viele Eskalationsrunden auf Opus pro Lauf
MAX_BUDGET_USD=15           # dritte Notbremse pro Runde, Listenpreis-Schätzung
MAX_LEERRUNDEN=2            # so viele Runden ohne Codeänderung, dann Abbruch
BASIS_BRANCH="main"         # Zielbranch des Pull Requests
# ------------------------------------------------------------------------
#
# Beide Befehle laufen über `bash -c`, dürfen also Pipes, Anführungszeichen und
# Umleitungen enthalten. Der Zähler muss immer eine Zahl ausgeben und immer mit
# 0 enden — auch bei roter Suite.

MAX="${1:-60}"

# --- Vorprüfungen -------------------------------------------------------
# Alles, was den Lauf sonst mitten in der Schleife killen würde, wird hier
# geprüft — bevor ein Branch angelegt und ein Kontingent verbraucht ist.

fehler() { echo "Abbruch vor dem Start: $*" >&2; exit 1; }

[[ "$MAX" =~ ^[1-9][0-9]*$ ]] || fehler "Rundenzahl muss eine positive ganze Zahl sein, war '$MAX'."

for W in "$TESTBEFEHL" "$TESTZAEHLER"; do
  [[ "$W" == "PLATZHALTER" ]] && fehler "Konfiguration oben in loop.sh ausfüllen."
done

command -v jq  >/dev/null || fehler "jq fehlt. Ohne jq blockieren die Guards jeden Werkzeugaufruf."
command -v gh  >/dev/null || fehler "gh fehlt."
command -v git >/dev/null || fehler "git fehlt."
command -v claude >/dev/null || fehler "claude fehlt."

git rev-parse --git-dir >/dev/null 2>&1 || fehler "Das ist kein Git-Repository."
git rev-parse HEAD >/dev/null 2>&1 || fehler "Das Repository hat noch keinen Commit."

# Ein Syntaxfehler in settings.json lässt Claude Code die Datei im -p-Modus
# STILL verwerfen — mitsamt deny-Liste und beiden Hooks. Der Lauf sähe normal
# aus und liefe ohne jeden Schutz.
jq -e . .claude/settings.json >/dev/null 2>&1 \
  || fehler ".claude/settings.json ist kein gültiges JSON. Ohne sie laufen beide Guards nicht."

for H in guard-files guard-bash protected-paths; do
  [[ -r ".agents/hooks/$H.sh" ]] || fehler ".agents/hooks/$H.sh fehlt oder ist nicht lesbar."
done

# Dieselben Muster wie die Guards. Sie werden unten am Diff der Runde gebraucht.
# shellcheck source=.agents/hooks/protected-paths.sh
. ./.agents/hooks/protected-paths.sh || fehler "Die Pfadmuster liessen sich nicht laden."

# Rauchtest: ein fingierter Payload muss Exit 2 liefern. Ein Guard, der 126
# oder 127 liefert (Datei weg, Interpreter weg, jq weg), blockiert NICHT —
# und genau das würde man im Lauf nicht bemerken.
pruefe_guard() {
  local skript="$1" payload="$2" name="$3" rc=0
  printf '%s' "$payload" | bash ".agents/hooks/$skript" >/dev/null 2>&1 || rc=$?
  (( rc == 2 )) || fehler "$name blockiert nicht (Rückgabewert $rc statt 2). Die Schutzmechanismen sind aus."
}
pruefe_guard guard-files.sh \
  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$PWD/.claude/settings.json\"}}" \
  "guard-files.sh"
pruefe_guard guard-bash.sh \
  '{"tool_name":"Bash","tool_input":{"command":"git push --force origin main"}}' \
  "guard-bash.sh"

[[ -z "$(git status --porcelain)" ]] \
  || fehler "Arbeitsverzeichnis nicht sauber. Der Agent würde deine offenen Änderungen mitcommitten."

for D in TASKS.md STATUS.md QUESTIONS.md round.md CLAUDE.md; do
  [[ -f "$D" ]] || fehler "$D fehlt."
done

# Ein frisch geklontes Repo hat keinen Trust-Eintrag; dann lädt Claude Code die
# Hooks aus dem coder-Frontmatter nicht. Die Hooks aus .claude/settings.json
# laufen trotzdem — das ist die eigentliche Schicht. Deshalb nur ein Hinweis.
if ! jq -e --arg p "$PWD" '.projects[$p].hasTrustDialogAccepted == true' \
     ~/.claude.json >/dev/null 2>&1; then
  echo "Hinweis: dieses Verzeichnis ist in ~/.claude.json nicht als vertraut markiert."
  echo "         Der zusätzliche Hook im coder-Frontmatter wird deshalb übersprungen."
  echo "         Die Guards aus .claude/settings.json laufen unabhängig davon."
fi

# Diese Variablen würden Aufwandsstufe und Subagent-Modelle überschreiben.
unset CLAUDE_CODE_EFFORT_LEVEL CLAUDE_CODE_SUBAGENT_MODEL CLAUDE_CODE_SUBAGENT_MODEL_FORCE

# --- Branch anlegen -----------------------------------------------------
if git show-ref --verify --quiet "refs/heads/$BASIS_BRANCH"; then
  git switch "$BASIS_BRANCH" --quiet
  if git remote get-url origin >/dev/null 2>&1; then
    git pull --ff-only --quiet || fehler "git pull --ff-only auf $BASIS_BRANCH fehlgeschlagen."
  fi
else
  fehler "Branch $BASIS_BRANCH existiert nicht."
fi

ZWEIG="agent/$(date +%Y%m%d-%H%M)"
git checkout -b "$ZWEIG" --quiet

mkdir -p .agents
rm -f .agents/STOP .agents/next-round.json
: > .agents/run.log

# QUESTIONS.md wird NICHT geleert. Die Charta erklärt sie für "appended to,
# never shortened" — ein Lauf, der sie abschneidet, löscht die Entscheidungen
# des vorigen Laufs. Stattdessen merken wir uns die Länge und zeigen im Pull
# Request nur, was dieser Lauf ergänzt hat.
FRAGEN_VORHER=$(wc -l < QUESTIONS.md)

zaehle_tests() {
  local roh
  roh=$(bash -c "$TESTZAEHLER" 2>/dev/null | tr -dc '0-9\n' | tail -1)
  [[ "$roh" =~ ^[0-9]+$ ]] && printf '%s' "$roh" || printf ''
}

TESTS_VORHER=$(zaehle_tests)
[[ -n "$TESTS_VORHER" ]] \
  || fehler "TESTZAEHLER liefert keine Zahl. Die Bremse 'Testanzahl gesunken' wäre wirkungslos."

OPUS_RUNDEN=0
REPARATUREN=0
LEERRUNDEN=0
GRUND="Rundenlimit $MAX erreicht"

for ((i=1; i<=MAX; i++)); do
  MODELL="sonnet"
  AUFWAND="high"
  if [[ -f .agents/next-round.json ]] && jq -e . .agents/next-round.json >/dev/null 2>&1; then
    MODELL=$(jq -r '.model  // "sonnet"' .agents/next-round.json)
    AUFWAND=$(jq -r '.effort // "high"'   .agents/next-round.json)
  fi
  # Die Datei schreibt ein Agent. Nichts Ungeprüftes in die Kommandozeile.
  # Die Whitelist ist nicht kosmetisch: Claude Code lehnt ein unbekanntes
  # --model NICHT ab, sondern fällt still auf das Kontomodell zurück — auf
  # einem Max-Abo also auf Opus.
  case "$MODELL"  in opus|sonnet|haiku) ;; *) MODELL="sonnet" ;; esac
  case "$AUFWAND" in low|medium|high|xhigh|max) ;; *) AUFWAND="high" ;; esac

  # Schutz des Opus-Wochenkontingents: der Chef darf nicht dauerhaft eskalieren.
  if [[ "$MODELL" == "opus" ]]; then
    if (( OPUS_RUNDEN >= MAX_OPUS_RUNDEN )); then
      echo "Opus-Eskalationen aufgebraucht, Runde läuft auf Sonnet."
      MODELL="sonnet"; AUFWAND="high"
    else
      OPUS_RUNDEN=$((OPUS_RUNDEN + 1))
    fi
  fi

  VORHER="$(git rev-parse HEAD)"
  echo "=== Runde $i/$MAX — $MODELL / $AUFWAND ==="

  # --verbose würde die JSON-Ausgabe in ein Array verwandeln und jeden jq-Lesen
  # unten brechen. --bare würde Hooks, Subagents und CLAUDE.md abschalten,
  # also genau die Schutzmechanismen. Beides gehört hier niemals hin.
  RUNDE_RC=0
  claude -p "$(cat round.md)" \
        --model "$MODELL" --effort "$AUFWAND" \
        --max-turns "$MAX_TURNS" \
        --max-budget-usd "$MAX_BUDGET_USD" \
        --output-format json \
        --dangerously-skip-permissions \
        --allowedTools "Read,Write,Edit,Bash,Glob,Grep,Agent" \
        < /dev/null > ".agents/round-$i.json" || RUNDE_RC=$?

  DAUER=$(jq -r '.duration_ms // "?"' ".agents/round-$i.json" 2>/dev/null || echo "?")
  echo "Runde $i | $MODELL | $AUFWAND | ${DAUER}ms" >> .agents/run.log

  # Ein API-Fehler oder eine erreichte Nutzungsgrenze kommt als
  # subtype "success" mit is_error=true zurück. .is_error ist deshalb das
  # einzige verlässliche Unterscheidungsmerkmal.
  if (( RUNDE_RC != 0 )) || jq -e '.is_error == true' ".agents/round-$i.json" >/dev/null 2>&1; then
    DETAIL=$(jq -r 'if .subtype and .subtype != "success" then .subtype
                    elif .result then (.result | tostring | .[0:200])
                    elif .errors then (.errors | join("; ") | .[0:200])
                    else "unbekannt" end' ".agents/round-$i.json" 2>/dev/null || echo "keine Ausgabe")
    GRUND="Session in Runde $i abgebrochen (Rückgabewert $RUNDE_RC): $DETAIL"
    break
  fi

  if [[ -f .agents/STOP ]]; then
    GRUND="Auftrag erledigt in Runde $i"
    break
  fi

  if [[ "$(git rev-parse HEAD)" == "$VORHER" ]]; then
    GRUND="Runde $i ohne Commit, Stillstand"
    break
  fi

  # Ein Commit allein ist kein Fortschritt: round.md verlangt jede Runde ein
  # neues STATUS.md, der Agent committet also immer. Gezählt wird deshalb, ob
  # sich ausserhalb der Buchhaltungsdateien etwas bewegt hat.
  if [[ -z "$(git diff --name-only "$VORHER" HEAD -- . \
                ':(exclude)STATUS.md' ':(exclude)TASKS.md' \
                ':(exclude)QUESTIONS.md' ':(exclude).agents')" ]]; then
    LEERRUNDEN=$((LEERRUNDEN + 1))
    echo "Runde $i hat nur Buchhaltung geändert ($LEERRUNDEN/$MAX_LEERRUNDEN)."
    if (( LEERRUNDEN >= MAX_LEERRUNDEN )); then
      GRUND="$MAX_LEERRUNDEN Runden ohne Codeänderung (Runde $i), der Agent dreht im Kreis"
      break
    fi
  else
    LEERRUNDEN=0
  fi

  # Ein Hook sieht nur, was in der Kommandozeile steht. Ein Diff-Applizierer,
  # ein Shell-Skript oder ein Umweg über eine Alias-Datei tragen ihr Ziel
  # woanders. Die Aufzählung von Werkzeugen in guard-bash.sh wird deshalb nie
  # vollständig sein — hier urteilt das Skript am Ergebnis statt an der
  # Absicht: kein versionierter Test darf sich in dieser Runde geändert haben.
  # Neue Tests sind erlaubt, deshalb nur M/D/R und nicht A.
  ANGEFASSTE_TESTS=$(git diff --name-only --diff-filter=MDR "$VORHER" HEAD \
                     | grep -iE "$MUSTER_TESTS" || true)
  if [[ -n "$ANGEFASSTE_TESTS" ]]; then
    GRUND="Runde $i hat bestehende Tests geändert: $(tr '\n' ' ' <<< "$ANGEFASSTE_TESTS")"
    break
  fi

  if ! bash -c "$TESTBEFEHL" > .agents/testrun.txt 2>&1; then
    REPARATUREN=$((REPARATUREN + 1))
    if (( REPARATUREN > 1 )); then
      GRUND="Testsuite auch nach der Reparaturrunde rot (Runde $i)"
      break
    fi
    echo "Testsuite rot — eine Reparaturrunde."
    printf '%s\n%s\n' \
      "- [ ] BLOCKER: the test suite is failing. Output in .agents/testrun.txt. Fix the cause in the code; touching existing test files is blocked." \
      "$(cat TASKS.md)" > TASKS.md
    # Nur TASKS.md committen. `git add -A` würde alles mitnehmen, was der Agent
    # bewusst offen gelassen hat, unter einer fremden Commit-Botschaft.
    if ! git commit --quiet -m "Add repair task after round $i" -- TASKS.md; then
      GRUND="Reparaturauftrag liess sich nicht committen (Runde $i)"
      break
    fi
    GRUND="Runde $i rot, Reparaturrunde angesetzt"
    continue
  fi

  TESTS_JETZT=$(zaehle_tests)
  if [[ -z "$TESTS_JETZT" ]]; then
    GRUND="TESTZAEHLER lieferte in Runde $i keine Zahl mehr"
    break
  fi
  if (( TESTS_JETZT < TESTS_VORHER )); then
    GRUND="Testanzahl gesunken ($TESTS_VORHER auf $TESTS_JETZT) in Runde $i"
    break
  fi
  TESTS_VORHER=$TESTS_JETZT
  GRUND="Rundenlimit $MAX erreicht"
done

echo "$GRUND" | tee .agents/stop-reason.txt
echo "Opus-Runden in diesem Lauf: $OPUS_RUNDEN von $MAX_OPUS_RUNDEN"
cat .agents/run.log

# --- Push und Pull Request ----------------------------------------------
if ! git remote get-url origin >/dev/null 2>&1; then
  echo "Kein Remote 'origin' — kein Push, kein Pull Request. Branch: $ZWEIG"
  exit 0
fi

if [[ -z "$(git rev-list "$BASIS_BRANCH..HEAD")" ]]; then
  echo "Keine Commits gegenüber $BASIS_BRANCH — kein Push, kein Pull Request."
  exit 0
fi

git push -u origin "$ZWEIG"
gh pr create --base "$BASIS_BRANCH" --head "$ZWEIG" --title "Agent run $ZWEIG" \
  --body "$(printf '## Stop reason\n\n%s\n\n## Status\n\n%s\n\n## Decisions to review\n\n%s\n\n## Run\n\n```\n%s\n```\n' \
    "$GRUND" \
    "$(cat STATUS.md)" \
    "$(tail -n +$((FRAGEN_VORHER + 1)) QUESTIONS.md)" \
    "$(cat .agents/run.log)")" \
  || echo "PR-Erstellung fehlgeschlagen — der Grund steht in .agents/stop-reason.txt, der Branch ist gepusht."
