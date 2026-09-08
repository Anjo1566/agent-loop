#!/usr/bin/env bash
set -euo pipefail

# --- Vom Umsetzer auszufüllen -------------------------------------------
TESTBEFEHL="node --test --test-reporter=tap"  # muss bei Fehlschlag != 0 liefern
TESTZAEHLER="./.agents/hooks/count-tests.sh"  # gibt die Anzahl Tests als Zahl aus
MAX_TURNS=60                # harter Deckel pro Runde
MAX_OPUS_RUNDEN=5           # so viele Eskalationsrunden auf Opus pro Lauf
MAX_BUDGET_USD=4            # dritte Notbremse pro Runde, Listenpreis-Schätzung
MAX_LEERRUNDEN=2            # so viele Runden ohne Codeänderung, dann Abbruch
BASIS_BRANCH="main"         # Zielbranch des Pull Requests
ZIELNOTE=8.5                # ab dieser Gesamtnote ist der Auftrag erledigt
MAX_STILLE=600              # so lange darf der Ereignisstrom stillstehen
MAX_RUNDE=3600              # harte Zeitgrenze pro Runde, egal wie fleissig
MAX_TEST=1800               # Zeitgrenze für Testbefehl und Testzähler
# ------------------------------------------------------------------------
#
# MAX_TURNS und MAX_BUDGET_USD standen auf 200 und 15. Gemessen an elf echten
# Runden (drei hier, acht in agent-cockpit) brauchte die teuerste 31 Turns und
# 2,56 USD; die beiden "Notbremsen" konnten also gar nicht greifen, bevor eine
# der anderen zuschlug. Jetzt liegen sie etwa beim Doppelten des gemessenen
# Maximums — weit genug für eine ungewöhnliche Runde, eng genug, um eine
# entgleiste zu beenden. Die Zahlen stehen in ABNAHME.md.
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

jq -n --argjson z "$ZIELNOTE" 'if ($z|type) == "number" and $z >= 0 and $z <= 10 then empty else error("x") end' >/dev/null 2>&1 \
  || fehler "ZIELNOTE muss eine Zahl von 0 bis 10 sein, war '$ZIELNOTE'."

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

command -v sha256sum >/dev/null || fehler "sha256sum fehlt. Ohne Prüfsumme lässt sich nicht feststellen, ob eine Runde die Schutzdateien verändert hat."

# Dieselben Muster wie die Guards. Sie werden unten am Diff der Runde gebraucht.
# shellcheck source=.agents/hooks/protected-paths.sh
. ./.agents/hooks/protected-paths.sh || fehler "Die Pfadmuster liessen sich nicht laden."

# Der Schutzsatz wird kopiert, wenn der Loop in ein anderes Repository zieht,
# und veraltet dort still. Genau das ist passiert: agent-cockpit lief acht
# echte Runden mit einer Fassung, die `rm -rf .agents/hooks` durchliess — was
# jeden weiteren Hook-Aufruf auf 127 laufen lässt, und 127 blockiert nicht.
# Von aussen war das nicht zu sehen. Deshalb trägt protected-paths.sh eine
# Versionsnummer, und loop.sh weiss, welche es braucht.
SCHUTZ_VERSION_ERWARTET=2
if [[ "${SCHUTZ_VERSION:-0}" -lt "$SCHUTZ_VERSION_ERWARTET" ]]; then
  fehler "Die Schutzdateien in .agents/hooks/ sind älter als dieses loop.sh (Version ${SCHUTZ_VERSION:-0}, gebraucht $SCHUTZ_VERSION_ERWARTET). Hol dir .agents/hooks/ und .claude/ aus dem Scaffold nach — im Cockpit macht das der Knopf 'Aktualisieren'."
fi

# --- Nur ein Lauf je Arbeitsverzeichnis ---------------------------------
# Zwei Läufe im selben Arbeitsbaum kommen sich nicht bloss in die Quere: die
# Sauberkeitsprüfung unten läuft VOR dem Branchwechsel, und ein regelkonformer
# Lauf hat zwischen zwei Runden immer alles committet. Der zweite Lauf sähe
# also einen sauberen Baum, würde `git switch main` ausführen und dem ersten
# den Checkout unter den Füssen wegziehen — dessen nächster Commit landete auf
# main. Das Cockpit hatte dafür längst einen Merker; loop.sh hatte keinen.
SPERRE=".agents/loop-laeuft.pid"
if [[ -f "$SPERRE" ]]; then
  ALT=$(cat "$SPERRE" 2>/dev/null || echo)
  if [[ -n "$ALT" ]] && kill -0 "$ALT" 2>/dev/null; then
    fehler "In diesem Arbeitsverzeichnis läuft bereits ein Lauf (Prozess $ALT). Warte, bis er fertig ist, oder beende ihn."
  fi
  echo "Hinweis: $SPERRE stammt von einem abgebrochenen Lauf (Prozess ${ALT:-?}) und wird überschrieben."
fi

# Rauchtest: ein fingierter Payload muss Exit 2 liefern. Ein Guard, der 126
# oder 127 liefert (Datei weg, Interpreter weg, jq weg), blockiert NICHT —
# und genau das würde man im Lauf nicht bemerken.
pruefe_guard_still() {
  local skript="$1" payload="$2" rc=0
  printf '%s' "$payload" | bash ".agents/hooks/$skript" >/dev/null 2>&1 || rc=$?
  (( rc == 2 ))
}
pruefe_guard() {
  local skript="$1" payload="$2" name="$3"
  pruefe_guard_still "$skript" "$payload" \
    || fehler "$name blockiert nicht. Die Schutzmechanismen sind aus."
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

# Zwei Läufe in derselben Minute bekamen denselben Namen; `git checkout -b`
# endete dann mit 128, und `set -e` beendete das Skript mit git's Rohmeldung —
# nachdem der Checkout schon auf main stand. Jetzt wird durchgezählt.
ZWEIG="agent/$(date +%Y%m%d-%H%M)"
if git show-ref --verify --quiet "refs/heads/$ZWEIG"; then
  for N in 2 3 4 5 6 7 8 9; do
    git show-ref --verify --quiet "refs/heads/$ZWEIG-$N" || { ZWEIG="$ZWEIG-$N"; break; }
  done
fi
git checkout -b "$ZWEIG" --quiet \
  || fehler "Branch $ZWEIG liess sich nicht anlegen. Der Checkout steht jetzt auf $BASIS_BRANCH."

mkdir -p .agents
rm -f .agents/STOP .agents/next-round.json .agents/grade.json
: > .agents/run.log

echo "$$" > "$SPERRE"
aufraeumen() { rm -f "$SPERRE"; }
trap aufraeumen EXIT

# --- Die Schutzdateien, wie sie beim Start aussahen ----------------------
#
# Das schwerste Loch des Reviews (Befund B-1) brauchte keine einzige verbotene
# Operation: `Write` auf tools/helper.js ist erlaubt, `node tools/helper.js`
# ist erlaubt — und der Helfer schreibt dann .claude/settings.json und
# .agents/hooks/guard-bash.sh neu. Kein Hook sieht das, weil nichts davon
# durch Edit, Write oder ein Shell-Wort mit dem Pfad darin geht. Danach lief
# jede weitere Runde ohne deny-Liste und ohne Guards, weil der Rauchtest oben
# nur EINMAL läuft.
#
# Die Antwort ist dieselbe wie bei E4: nicht die Absicht prüfen, sondern das
# Ergebnis. Vor der ersten Runde wird eine Prüfsumme über alles gebildet, was
# den Lauf schützt; vor jeder weiteren Runde wird sie nachgerechnet. Ein
# Helfer, der die Guards abräumt, beendet damit den Lauf, statt ihn zu
# übernehmen — und der Grund steht im Pull Request.
schutzdateien() {
  { git ls-files -- '.agents/hooks/*' '.claude/*' 'CLAUDE.md' 'round.md' \
                    'loop.sh' 'abnahme.sh' '.gitattributes' '.mcp.json' \
                    '.devcontainer/*' 2>/dev/null
    # Nicht versioniert, aber massgeblich: eine settings.local.json überschreibt
    # settings.json, und ohne sie hier wäre der teuerste Weg der unbewachte.
    ls .claude/settings.local.json 2>/dev/null
  } | sort -u
}

schutz_pruefsumme() {
  local d
  while IFS= read -r d; do
    [[ -f "$d" ]] || { printf 'FEHLT %s\n' "$d"; continue; }
    sha256sum -- "$d"
  done < <(schutzdateien)
}

SCHUTZ_ANFANG=$(schutz_pruefsumme)
[[ -n "$SCHUTZ_ANFANG" ]] \
  || fehler "Es liess sich keine Prüfsumme über die Schutzdateien bilden."

# QUESTIONS.md wird NICHT geleert. Die Charta erklärt sie für "appended to,
# never shortened" — ein Lauf, der sie abschneidet, löscht die Entscheidungen
# des vorigen Laufs. Stattdessen merken wir uns die Länge und zeigen im Pull
# Request nur, was dieser Lauf ergänzt hat.
FRAGEN_VORHER=$(wc -l < QUESTIONS.md)

zaehle_tests() {
  local roh
  roh=$(mit_zeitgrenze "$MAX_TEST" "$TESTZAEHLER" 2>/dev/null | tr -dc '0-9\n' | tail -1)
  [[ "$roh" =~ ^[0-9]+$ ]] && printf '%s' "$roh" || printf ''
}

# Der Testbefehl schreibt seine Ausgabe immer nach .agents/testrun.txt: die
# Reparaturrunde zeigt sie dem Agenten, und der Zähler liest die Testanzahl
# daraus, statt die Suite ein zweites Mal zu fahren. Bei 62 Tests, die auf
# diesem Rechner 165 s brauchen, war das die Hälfte der gemessenen Wartezeit
# je Runde.
tests_ausfuehren() {
  mit_zeitgrenze "$MAX_TEST" "$TESTBEFEHL" > .agents/testrun.txt 2>&1
}

# Die Note des graders aus dem Ereignisstrom der Runde.
#
# Gesucht wird zuerst die tool_use_id jedes Subagenten vom Typ "grader" und
# dann das tool_result mit genau dieser id. Nur dessen Text wird nach "gesamt"
# durchsucht — sonst genügte es, die Zahl irgendwo in eine Datei zu schreiben,
# die der Chef anschliessend vorliest. Beides schreibt die CLI, nicht das
# Modell.
note_aus_strom() {
  local datei="$1" ids text
  [[ -s "$datei" ]] || return 0
  ids=$(jq -r 'select(.type == "system" and .subtype == "task_started"
                      and .subagent_type == "grader") | .tool_use_id // empty' \
        "$datei" 2>/dev/null | grep -v '^$' | sort -u)
  [[ -n "$ids" ]] || return 0
  text=$(jq -r --arg ids "$ids" '
      ($ids | split("\n")) as $g
      | select(.type == "user")
      | (.message.content // [])[]?
      | select(.type == "tool_result" and ((.tool_use_id // "") | IN($g[])))
      | (.content // [])[]?
      | select(.type == "text") | .text' "$datei" 2>/dev/null)
  printf '%s' "$text" \
    | grep -oE '"gesamt"[[:space:]]*:[[:space:]]*[0-9]+(\.[0-9]+)?' \
    | grep -oE '[0-9]+(\.[0-9]+)?' | tail -1
}

# --- Der Wachhund -------------------------------------------------------
# Die Bremsen --max-turns und --max-budget-usd sitzen IM Modell: sie greifen
# nur, solange die Sitzung noch antwortet. Stirbt der Prozess von aussen oder
# haengt er an einer Leitung, zaehlt niemand mehr etwas hoch, und `wait` unten
# wartet bis in alle Ewigkeit. Genau das ist passiert: der grader schoss mit
# `taskkill //F //IM node.exe` alle node-Prozesse ab -- sich selbst, das
# Cockpit und die Sitzung -- und dieses Skript hing danach vier Stunden an
# einem toten Kind. Von aussen sah der Lauf die ganze Zeit gesund aus.
#
# Deshalb urteilt der Wachhund nicht an der Absicht, sondern am Ergebnis, so
# wie die Testpruefung weiter unten: waechst der Ereignisstrom nicht mehr,
# passiert nichts mehr. Das gilt fuer jede Ursache, auch fuer die, an die
# hier niemand gedacht hat.

# Einen Prozessbaum beenden -- nach PID, nie nach Abbildname. Der Unterschied
# ist genau der, an dem dieser Lauf gestorben ist.
toete_baum () {
  local pid="$1" winpid=""
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
      # Unter Windows kennt `kill` nur die MSYS-PID und laesst die Enkel am
      # Leben. taskkill //T raeumt den ganzen Baum ab, braucht dafuer aber die
      # Windows-PID -- Spalte 4 bei `ps -W`.
      winpid=$(ps -W 2>/dev/null | awk -v p="$pid" '$1 == p { print $4; exit }')
      [[ -n "$winpid" && "$winpid" != "0" ]] \
        && taskkill //PID "$winpid" //T //F >/dev/null 2>&1
      ;;
    *) kill -TERM "-$pid" 2>/dev/null ;;
  esac
  kill -TERM "$pid" 2>/dev/null
  ( sleep 5; kill -KILL "$pid" 2>/dev/null ) >/dev/null 2>&1 &
}

# Ein Befehl mit harter Zeitgrenze, ohne von `timeout` abzuhängen.
#
# Es gibt das, weil der Wachhund oben nur die Sitzung bewacht: er wird
# beendet, sobald `wait` auf die Runde zurückkommt. Der Testbefehl läuft
# DANACH — und er führt Code aus, den der Agent selbst geschrieben hat. Eine
# Endlosschleife in einer Quelldatei, die ein Test aufruft, hängt `node --test`
# unbegrenzt; nachgestellt mit einem neu angelegten Test (neue Testdateien
# sind ausdrücklich erlaubt), der synchron dreht: nach 75 s lief er noch. Der
# Lauf hätte gewartet, bis jemand hinsieht. Genau der Fall, für den der
# Wachhund geschrieben wurde, achtzig Zeilen weiter unten wieder offen.
#
# Rückgabewert 124 wie bei `timeout`, damit die Auswertung unten den Abbruch
# von einer roten Suite unterscheiden kann.
mit_zeitgrenze() {
  local grenze="$1" befehl="$2" pid rc=0 wartend=0
  bash -c "$befehl" &
  pid=$!
  while (( wartend < grenze )); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 2; wartend=$((wartend + 2))
  done
  if kill -0 "$pid" 2>/dev/null; then
    toete_baum "$pid"
    wait "$pid" 2>/dev/null || true
    return 124
  fi
  wait "$pid" || rc=$?
  return "$rc"
}

# Der Grund steht in einer Datei, nicht im Rueckgabewert: ein abgeschossener
# Prozess meldet unter Windows auch mal 0, und dann haette die Runde als
# gelungen gegolten.
wachhund () {
  local pid="$1" datei="$2" start jetzt letzte groesse alt=-1
  start=$(date +%s); letzte=$start
  while sleep 15; do
    kill -0 "$pid" 2>/dev/null || return 0
    jetzt=$(date +%s)
    groesse=$(wc -c < "$datei" 2>/dev/null || echo 0)
    if [[ "$groesse" != "$alt" ]]; then alt="$groesse"; letzte="$jetzt"; fi
    if (( jetzt - letzte >= MAX_STILLE )); then
      printf 'der Ereignisstrom stand %s s still\n' "$((jetzt - letzte))" \
        > .agents/wachhund.txt
      toete_baum "$pid"; return 0
    fi
    if (( jetzt - start >= MAX_RUNDE )); then
      printf 'die Runde ueberschritt die Zeitgrenze von %s s\n' "$MAX_RUNDE" \
        > .agents/wachhund.txt
      toete_baum "$pid"; return 0
    fi
  done
}

# Die Suite einmal vor dem Lauf. Zwei Dinge auf einmal: die Ausgangszahl für
# die Bremse "Testanzahl gesunken", und die Gewissheit, dass die Suite
# überhaupt grün startet. Auf einer roten Ausgangslage ist die Reparaturrunde
# sinnlos — sie repariert dann etwas, das der Agent gar nicht verursacht hat,
# und verbrennt dafür ein Kontingent.
echo "Testsuite vor dem Lauf…"
TEST_RC=0
tests_ausfuehren || TEST_RC=$?
if (( TEST_RC == 124 )); then
  fehler "Der Testbefehl lief länger als MAX_TEST=$MAX_TEST s und wurde beendet. Ausgabe in .agents/testrun.txt."
fi
if (( TEST_RC != 0 )); then
  fehler "Die Testsuite ist schon vor dem Lauf rot (Rückgabewert $TEST_RC). Ausgabe in .agents/testrun.txt. Erst reparieren, dann starten."
fi

TESTS_VORHER=$(zaehle_tests)
[[ -n "$TESTS_VORHER" ]] \
  || fehler "TESTZAEHLER liefert keine Zahl. Die Bremse 'Testanzahl gesunken' wäre wirkungslos."
echo "Ausgangslage: $TESTS_VORHER Tests, Suite grün."

OPUS_RUNDEN=0
REPARATUREN=0
LEERRUNDEN=0
GRUND="Rundenlimit $MAX erreicht"

for ((i=1; i<=MAX; i++)); do
  # Vor jeder Runde: sind die Schutzdateien noch die vom Anfang, und blockieren
  # die Guards noch wirklich? Der Rauchtest lief bisher nur einmal, vor der
  # ersten Runde — eine Runde, die ihn abräumt, hätte den Rest des Laufs für
  # sich gehabt. Beides zusammen kostet knapp eine Sekunde je Runde.
  if [[ "$(schutz_pruefsumme)" != "$SCHUTZ_ANFANG" ]]; then
    # `diff` liefert 1, sobald es Unterschiede findet, und unter pipefail wird
    # das der Status der Zuweisung -- `set -e` beendete das Skript dann mitten
    # im Abbruchgrund, bevor er in stop-reason.txt stand.
    VERAENDERT=$({ diff <(printf '%s\n' "$SCHUTZ_ANFANG") <(schutz_pruefsumme) || true; } \
                 | grep -oE '[^ ]+' | grep -vE '^[0-9a-f]{64}' | sort -u | tr '\n' ' ' || true)
    GRUND="Schutzdateien seit Rundenbeginn verändert (vor Runde $i): $VERAENDERT"
    break
  fi

  if ! pruefe_guard_still guard-files.sh \
        "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$PWD/.claude/settings.json\"}}" \
     || ! pruefe_guard_still guard-bash.sh \
        '{"tool_name":"Bash","tool_input":{"command":"git push --force origin main"}}'; then
    GRUND="Die Guards blockieren vor Runde $i nicht mehr (Rauchtest fehlgeschlagen)"
    break
  fi

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

  # stream-json schreibt jede Nachricht als eigene Zeile, sobald sie entsteht.
  # Genau das liest das Cockpit in .agents/round-N.ndjson live mit. Mit
  # --output-format json entstuende die Datei erst am Rundenende, und das
  # Dashboard saehe die ganze Runde lang nichts: Rollenwechsel, Werkzeuge,
  # Guard-Blockaden und Kosten kamen dort nie an. --verbose ist dabei Pflicht.
  # --bare würde Hooks, Subagents und CLAUDE.md abschalten, also genau die
  # Schutzmechanismen. Das gehört hier niemals hin.
  RUNDE_RC=0
  rm -f .agents/wachhund.txt
  claude -p "$(cat round.md)" \
        --model "$MODELL" --effort "$AUFWAND" \
        --max-turns "$MAX_TURNS" \
        --max-budget-usd "$MAX_BUDGET_USD" \
        --output-format stream-json --verbose \
        --dangerously-skip-permissions \
        --allowedTools "Read,Write,Edit,Bash,Glob,Grep,Agent" \
        < /dev/null > ".agents/round-$i.ndjson" &
  RUNDE_PID=$!
  wachhund "$RUNDE_PID" ".agents/round-$i.ndjson" &
  WACHHUND_PID=$!
  wait "$RUNDE_PID" || RUNDE_RC=$?
  kill "$WACHHUND_PID" 2>/dev/null || true
  wait "$WACHHUND_PID" 2>/dev/null || true

  # Fuer die Auswertung hier zaehlt nur die Abschlusszeile. Sie traegt dieselben
  # Felder, die vorher im Rundenjson standen -- alles unten bleibt deshalb
  # unveraendert. Fehlt sie, ist die Runde abgebrochen.
  jq -c 'select(.type == "result")' ".agents/round-$i.ndjson" 2>/dev/null \
    | tail -1 > ".agents/round-$i.json" || true
  [[ -s ".agents/round-$i.json" ]] \
    || echo '{"is_error":true,"subtype":"kein Abschluss im Ereignisstrom"}' > ".agents/round-$i.json"

  # Ein Ereignisstrom enthaelt jeden Werkzeugaufruf mitsamt Ergebnis und wird
  # dadurch gross. Ueber dreissig Runden laeuft sonst die Systemplatte voll.
  # Das Cockpit liest immer nur die laufende Runde mit, die vorletzte ist
  # Kulanz fuer den Fall, dass jemand nachschauen will.
  if (( i > 2 )); then rm -f ".agents/round-$((i - 2)).ndjson"; fi

  DAUER=$(jq -r '.duration_ms // "?"' ".agents/round-$i.json" 2>/dev/null || echo "?")
  echo "Runde $i | $MODELL | $AUFWAND | ${DAUER}ms" >> .agents/run.log

  # Der Wachhund zuerst: hat er zugeschlagen, ist jeder andere Befund an
  # dieser Runde eine Folge davon und wuerde nur vom Grund ablenken.
  if [[ -s .agents/wachhund.txt ]]; then
    GRUND="Runde $i vom Wachhund beendet, $(cat .agents/wachhund.txt)"
    break
  fi

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

  # Dieselbe Prüfung am Ergebnis, jetzt für die Schutzdateien statt für die
  # Tests. Die Prüfsumme oben fängt eine Änderung, die auf der Platte liegen
  # bleibt; diese hier fängt sie auch dann, wenn die Runde sie mitcommittet
  # hat — und benennt sie im Pull Request, statt sie in einem Diff von
  # dreissig Dateien untergehen zu lassen.
  ANGEFASSTER_SCHUTZ=$(git diff --name-only --diff-filter=ACMDRT "$VORHER" HEAD \
                       | grep -iE "$MUSTER_SELBST|$MUSTER_DEPS" || true)
  if [[ -n "$ANGEFASSTER_SCHUTZ" ]]; then
    GRUND="Runde $i hat geschützte Dateien geändert: $(tr '\n' ' ' <<< "$ANGEFASSTER_SCHUTZ")"
    break
  fi

  TEST_RC=0
  tests_ausfuehren || TEST_RC=$?
  if (( TEST_RC == 124 )); then
    GRUND="Der Testbefehl in Runde $i lief länger als MAX_TEST=$MAX_TEST s und wurde beendet"
    break
  fi
  if (( TEST_RC != 0 )); then
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

  # Das Notentor.
  #
  # Die Note stand bisher in .agents/grade.json — einer Datei, die der Chef
  # selbst schreibt und die von keinem Muster geschützt ist. Damit war die
  # Abbruchbedingung des ganzen Laufs eine Selbstauskunft: `{"gesamt": 10}`
  # hinein, und das Skript meldete "Zielnote erreicht". Der Rest dieses
  # Entwurfs steht auf "das Skript urteilt, nicht der Agent"; genau hier tat
  # es das nicht.
  #
  # Massgeblich ist deshalb der Ereignisstrom. Den schreibt die CLI, nicht das
  # Modell: `system/task_started` mit `subagent_type: "grader"` belegt, dass
  # der grader wirklich lief, und seine Antwort kommt als tool_result mit
  # derselben tool_use_id zurück. Aus dieser Antwort wird die Zahl gelesen.
  # grade.json bleibt als Ablage für das Cockpit bestehen, entscheidet aber
  # nichts mehr; weicht sie ab, wird das benannt.
  NOTE=$(note_aus_strom ".agents/round-$i.ndjson")
  NOTE_DATEI=$(jq -r 'select(.gesamt | numbers) | .gesamt' .agents/grade.json 2>/dev/null || true)

  if [[ -z "$NOTE" ]]; then
    if [[ -n "$NOTE_DATEI" ]]; then
      echo "Runde $i: .agents/grade.json nennt $NOTE_DATEI, aber im Ereignisstrom steht keine Bewertung des graders. Die Note zählt nicht."
    else
      echo "Runde $i hat keine Note hinterlassen (kein grader im Ereignisstrom)."
    fi
  else
    if [[ -n "$NOTE_DATEI" && "$NOTE_DATEI" != "$NOTE" ]]; then
      echo "Achtung: .agents/grade.json nennt $NOTE_DATEI, der grader selbst $NOTE. Gewertet wird $NOTE."
    fi
    BEGRUENDUNG=$(jq -r '.begruendung // ""' .agents/grade.json 2>/dev/null || true)
    echo "Note nach Runde $i: $NOTE von 10 (Ziel $ZIELNOTE) — $BEGRUENDUNG"
    if jq -n --argjson n "$NOTE" --argjson z "$ZIELNOTE" '$n >= $z' | grep -q true; then
      GRUND="Zielnote erreicht in Runde $i: $NOTE von 10 (Ziel $ZIELNOTE)"
      break
    fi
  fi

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
