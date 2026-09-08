#!/usr/bin/env bash
# Abnahme von loop.sh gegen einen claude-Stub.
#
# Der Stub ersetzt die echte Sitzung und spielt genau das Verhalten nach, das
# die jeweilige Abnahmebedingung provozieren soll. Damit ist die Schleifenlogik
# deterministisch pruefbar - ohne Kontingent und ohne Wartezeit.

set -uo pipefail

START_SEKUNDEN=$(date +%s)

QUELLE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASIS="${TMPDIR:-/tmp}/agent-loop-abnahme"

command -v jq   >/dev/null || { echo "jq fehlt."; exit 1; }
command -v node >/dev/null || { echo "node fehlt."; exit 1; }
command -v git  >/dev/null || { echo "git fehlt."; exit 1; }

BESTANDEN=0
GEFALLEN=0

pruefe() {
  local name="$1" erwartet="$2" ausgabe="$3"
  if grep -qF "$erwartet" <<< "$ausgabe"; then
    echo "  OK   $name"
    BESTANDEN=$((BESTANDEN + 1))
  else
    echo "  FAIL $name"
    echo "       erwartet: $erwartet"
    echo "       ---- Ausgabe ----"
    sed 's/^/       /' <<< "$ausgabe" | tail -25
    GEFALLEN=$((GEFALLEN + 1))
  fi
}

nicht() {
  local name="$1" verboten="$2" ausgabe="$3"
  if grep -qF "$verboten" <<< "$ausgabe"; then
    echo "  FAIL $name (unerwartet gefunden: $verboten)"
    GEFALLEN=$((GEFALLEN + 1))
  else
    echo "  OK   $name"
    BESTANDEN=$((BESTANDEN + 1))
  fi
}

# --- Arbeitskopie mit Stub aufsetzen ------------------------------------
neues_repo() {
  local szenario="$1"
  local ziel="$BASIS/$szenario"
  rm -rf "$ziel"
  mkdir -p "$BASIS"
  git clone -q "$QUELLE" "$ziel"
  git -C "$ziel" remote remove origin
  # Der Klon uebernimmt den Branch, auf dem das Quell-Repo gerade steht. loop.sh
  # verzweigt aber von main, also wird main hier auf den geklonten Stand gesetzt
  # -- sonst haengt die Abnahme daran, welchen Branch man gerade ausgecheckt hat.
  git -C "$ziel" switch -q -C main
  git -C "$ziel" config user.name "Abnahme"
  git -C "$ziel" config user.email "abnahme@example.invalid"

  # `git clone` nimmt den HEAD-Commit, nicht das Arbeitsverzeichnis. Geprueft
  # werden soll aber, was gerade auf der Platte liegt -- sonst laeuft die
  # Abnahme gegen die zuletzt committete Fassung, waehrend das README sagt
  # "nach jeder Aenderung an loop.sh einmal laufen lassen".
  while IFS= read -r D; do
    [[ -f "$QUELLE/$D" ]] || continue
    mkdir -p "$ziel/$(dirname "$D")"
    cp "$QUELLE/$D" "$ziel/$D"
  done < <(git -C "$QUELLE" ls-files)
  git -C "$ziel" add -A >/dev/null 2>&1
  git -C "$ziel" commit -q -m "Abnahme: Arbeitsstand statt letztem Commit" >/dev/null 2>&1

  # Die Guard-Tests kommen in den Szenarienklonen weg. Sie pruefen die Guards,
  # nicht die Schleifenlogik, und sie sind teuer: 55 Faelle, jeder ein eigener
  # bash-Prozess, zusammen 165 s -- und loop.sh faehrt die Suite einmal vor dem
  # Lauf und einmal je Runde. Ueber die 19 Szenarien dieser Abnahme waren das
  # gemessen mehr als zwei Stunden, waehrend das README "ein paar Minuten"
  # verspricht und der Besitzer sie deshalb nach einer Aenderung an loop.sh
  # eben nicht laufen laesst.
  #
  # Bewiesen bleiben die Guards trotzdem, und zwar zweimal: `node --test` im
  # echten Repository faehrt alle 75 Faelle, und das Umzugs-Szenario weiter
  # unten baut ein fremdes Repository aus der README-Liste und laesst sie dort
  # noch einmal laufen. Hier bleibt das Beispielprojekt (7 Tests) -- genug, um
  # rote Suite, gesunkene Testanzahl und geaenderte Testdatei auszuloesen.
  git -C "$ziel" rm -q --ignore-unmatch 'test/guards*.test.js' >/dev/null 2>&1
  git -C "$ziel" commit -q -m "Abnahme: Guard-Tests im Szenarienklon weglassen" >/dev/null 2>&1

  # Der Stub selbst darf die Sauberkeitspruefung von loop.sh nicht ausloesen.
  echo ".stub/" >> "$ziel/.git/info/exclude"
  mkdir -p "$ziel/.stub"
  cat > "$ziel/.stub/claude" <<'STUB'
#!/usr/bin/env bash
# claude-Stub: protokolliert Modell und Aufwand, fuehrt die Szenario-Aktion
# aus und gibt einen Ereignisstrom aus, wie --output-format stream-json ihn
# liefert: eine Nachricht je Zeile, die Abschlusszeile zuletzt. Die erste Zeile
# steht bewusst davor -- loop.sh muss die Abschlusszeile herausfischen und darf
# nicht einfach die Datei als Ganzes lesen.
MODELL=""; AUFWAND=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --model)  MODELL="$2"; shift 2 ;;
    --effort) AUFWAND="$2"; shift 2 ;;
    *) shift ;;
  esac
done
RUNDE=$(( $(cat .stub/runde 2>/dev/null || echo 0) + 1 ))
echo "$RUNDE" > .stub/runde
echo "runde=$RUNDE model=$MODELL effort=$AUFWAND" >> .stub/aufrufe
if [[ -f .stub/aktion ]]; then . .stub/aktion; fi
printf '{"type":"system","subtype":"init","session_id":"stub"}\n'
# Zusaetzliche Ereigniszeilen des Szenarios, zum Beispiel ein grader-Subagent
# mitsamt seiner Antwort. loop.sh liest die Note nur von dort.
[[ -f .stub/extra ]] && cat .stub/extra
printf '{"type":"result","subtype":"success","is_error":false,"duration_ms":42,"result":"stub"}\n'
STUB
  chmod +x "$ziel/.stub/claude"
  : > "$ziel/.stub/aufrufe"
  echo "$ziel"
}

# Ein Commit, wie ihn ein regelkonformer Chef jede Runde macht.
AKTION_NORMAL='
echo "// round $RUNDE" >> src/tasklist.js
printf "# Status\n\nRunde %s gelaufen.\n" "$RUNDE" > STATUS.md
printf "{\"model\":\"sonnet\",\"effort\":\"high\",\"reason\":\"stub\"}" > .agents/next-round.json
git add -A >/dev/null 2>&1
git commit -q -m "stub round $RUNDE" >/dev/null 2>&1
'

lauf() {
  local ziel="$1" runden="$2"
  ( cd "$ziel" && PATH="$PWD/.stub:$PATH" bash loop.sh "$runden" 2>&1 )
}

echo "=========================================================="
echo " Abnahme loop.sh (claude-Stub)"
echo "=========================================================="

# --- 1. Trockenlauf: Commit + Eintrag in run.log ------------------------
echo
echo "[1] Trockenlauf"
Z=$(neues_repo trockenlauf)
printf '%s' "$AKTION_NORMAL" > "$Z/.stub/aktion"; chmod +x "$Z/.stub/aktion"
A=$(lauf "$Z" 1)
pruefe "eine Runde gelaufen"        "=== Runde 1/1"            "$A"
pruefe "run.log gefuellt"           "Runde 1 | sonnet | high"  "$A"
pruefe "Grund korrekt"              "Rundenlimit 1 erreicht"   "$A"
pruefe "ohne Remote sauberes Ende"  "Kein Remote"              "$A"
pruefe "Commit entstanden"          "stub round 1"             "$(git -C "$Z" log --oneline)"

# --- 5. Fortschrittsbremse ----------------------------------------------
echo
echo "[5] Fortschrittsbremse"
Z=$(neues_repo stop)
cat > "$Z/.stub/aktion" <<'A'
: > .agents/STOP
git commit -q --allow-empty -m "stub done" >/dev/null 2>&1
A
chmod +x "$Z/.stub/aktion"
A=$(lauf "$Z" 60)
pruefe "STOP beendet sauber"    "Auftrag erledigt in Runde 1"  "$A"
nicht  "keine 60 Leerrunden"    "=== Runde 2/60"               "$A"

Z=$(neues_repo stillstand)
: > "$Z/.stub/aktion"; chmod +x "$Z/.stub/aktion"
A=$(lauf "$Z" 60)
pruefe "kein Commit = Abbruch"  "Runde 1 ohne Commit, Stillstand" "$A"
nicht  "keine zweite Runde"     "=== Runde 2/60"                  "$A"

Z=$(neues_repo leerrunden)
cat > "$Z/.stub/aktion" <<'A'
printf "# Status\n\nRunde %s.\n" "$RUNDE" > STATUS.md
git add -A >/dev/null 2>&1
git commit -q -m "stub bookkeeping $RUNDE" >/dev/null 2>&1
A
chmod +x "$Z/.stub/aktion"
A=$(lauf "$Z" 60)
pruefe "nur Buchhaltung = Abbruch" "Runden ohne Code" "$A"
nicht  "keine dritte Runde"        "=== Runde 3/60"              "$A"

# --- 6. Reparaturrunde --------------------------------------------------
echo
echo "[6] Reparaturrunde"
Z=$(neues_repo reparatur_rot)
cat > "$Z/.stub/aktion" <<'A'
if (( RUNDE == 1 )); then
  echo 'module.exports.openTasks = () => { throw new Error("deliberately broken") }' >> src/tasklist.js
fi
echo "// round $RUNDE" >> src/tasklist.js
git add -A >/dev/null 2>&1
git commit -q -m "stub round $RUNDE" >/dev/null 2>&1
A
chmod +x "$Z/.stub/aktion"
A=$(lauf "$Z" 60)
pruefe "rote Suite erkannt"        "Testsuite rot"                      "$A"
pruefe "genau eine Reparaturrunde" "auch nach der Reparaturrunde rot"   "$A"
pruefe "Blocker in TASKS.md"       "BLOCKER: the test suite is failing" "$(cat "$Z/TASKS.md")"
nicht  "keine dritte Runde"        "=== Runde 3/60"                     "$A"

Z=$(neues_repo reparatur_geheilt)
cat > "$Z/.stub/aktion" <<'A'
if (( RUNDE == 1 )); then
  cp src/tasklist.js .stub/heil.js
  echo 'module.exports.openTasks = () => { throw new Error("deliberately broken") }' >> src/tasklist.js
elif (( RUNDE == 2 )); then
  cp .stub/heil.js src/tasklist.js
fi
echo "// round $RUNDE" >> src/tasklist.js
git add -A >/dev/null 2>&1
git commit -q -m "stub round $RUNDE" >/dev/null 2>&1
A
chmod +x "$Z/.stub/aktion"
A=$(lauf "$Z" 3)
pruefe "Reparatur heilt den Lauf"  "=== Runde 3/3"          "$A"
pruefe "Lauf laeuft danach durch"  "Rundenlimit 3 erreicht" "$A"

# --- 7. Modellwahl ------------------------------------------------------
echo
echo "[7] Modellwahl"
Z=$(neues_repo modellwahl)
cat > "$Z/.stub/aktion" <<'A'
echo "// round $RUNDE" >> src/tasklist.js
printf "{\"model\":\"opus\",\"effort\":\"xhigh\",\"reason\":\"stub\"}" > .agents/next-round.json
git add -A >/dev/null 2>&1
git commit -q -m "stub round $RUNDE" >/dev/null 2>&1
A
chmod +x "$Z/.stub/aktion"
A=$(lauf "$Z" 8)
pruefe "opus/xhigh wird uebernommen"  "Runde 2 | opus | xhigh"              "$A"
pruefe "Deckel greift"                "Opus-Eskalationen aufgebraucht"      "$A"
pruefe "danach wieder sonnet"         "Runde 7 | sonnet | high"             "$A"
pruefe "genau 5 Opus-Runden"          "Opus-Runden in diesem Lauf: 5 von 5" "$A"

Z=$(neues_repo modell_quatsch)
cat > "$Z/.stub/aktion" <<'A'
echo "// round $RUNDE" >> src/tasklist.js
printf "{\"model\":\"quatsch\",\"effort\":\"quatsch\"}" > .agents/next-round.json
git add -A >/dev/null 2>&1
git commit -q -m "stub round $RUNDE" >/dev/null 2>&1
A
chmod +x "$Z/.stub/aktion"
A=$(lauf "$Z" 2)
pruefe "Muellwert faellt auf sonnet"  "Runde 2 | sonnet | high" "$A"

Z=$(neues_repo json_kaputt)
cat > "$Z/.stub/aktion" <<'A'
echo "// round $RUNDE" >> src/tasklist.js
printf "{ das ist kein json" > .agents/next-round.json
git add -A >/dev/null 2>&1
git commit -q -m "stub round $RUNDE" >/dev/null 2>&1
A
chmod +x "$Z/.stub/aktion"
A=$(lauf "$Z" 2)
pruefe "kaputte JSON bricht nicht ab" "Runde 2 | sonnet | high" "$A"

# --- Zusatz: Testanzahl gesunken ----------------------------------------
echo
echo "[+] Testanzahl gesunken"
# Der Zaehler ist keine Dopplung der Diff-Bremse: hier faellt die Testanzahl,
# ohne dass eine Testdatei angefasst wird. test/table.test.js erzeugt einen
# Test je Eintrag aus src/cases.js -- Runde 2 kuerzt nur diese Tabelle.
Z=$(neues_repo testanzahl)
cat > "$Z/.stub/aktion" <<'A'
if (( RUNDE == 1 )); then
  printf 'module.exports = ["a", "b", "c"]
' > src/cases.js
  cat > test/table.test.js <<'T'
const test = require('node:test')
const assert = require('node:assert/strict')
for (const fall of require('../src/cases.js')) {
  test(`case ${fall}`, () => { assert.ok(fall) })
}
T
elif (( RUNDE == 2 )); then
  printf 'module.exports = ["a"]
' > src/cases.js
fi
echo "// round $RUNDE" >> src/tasklist.js
git add -A >/dev/null 2>&1
git commit -q -m "stub round $RUNDE" >/dev/null 2>&1
A
A=$(lauf "$Z" 5)
pruefe "gesunkene Testanzahl erkannt" "Testanzahl gesunken" "$A"
pruefe "ohne dass ein Test angefasst wurde" "10 auf 8" "$A"
nicht  "keine vierte Runde"           "=== Runde 4/5"       "$A"

# Eine geloeschte Testdatei laesst die Suite gruen. Sie faellt jetzt schon eine
# Stufe frueher auf als am Zaehler, naemlich am Diff der Runde.
Z=$(neues_repo testdatei_weg)
cat > "$Z/.stub/aktion" <<'A'
if (( RUNDE == 2 )); then rm -f test/tasklist.test.js; fi
echo "// round $RUNDE" >> src/tasklist.js
git add -A >/dev/null 2>&1
git commit -q -m "stub round $RUNDE" >/dev/null 2>&1
A
A=$(lauf "$Z" 5)
pruefe "geloeschte Testdatei stoppt den Lauf" "hat bestehende Tests ge" "$A"
nicht  "keine vierte Runde"                   "=== Runde 4/5"           "$A"

# Die Zusage aus ABWEICHUNGEN E4: was kein Hook sehen kann, faengt loop.sh am
# Diff. Der Stub aendert einen versionierten Test direkt auf der Platte, also
# an jedem Guard vorbei -- die Suite bleibt gruen und die Testanzahl gleich.
echo
echo "[+] Diff-Bremse fuer bestehende Tests"
Z=$(neues_repo test_geaendert)
cat > "$Z/.stub/aktion" <<'A'
if (( RUNDE == 2 )); then
  sed -i "s/assert.deepEqual(openTasks/assert.ok(openTasks/" test/tasklist.test.js
  sed -i "s/), \['first', 'second'\])/))/" test/tasklist.test.js
fi
echo "// round $RUNDE" >> src/tasklist.js
git add -A >/dev/null 2>&1
git commit -q -m "stub round $RUNDE" >/dev/null 2>&1
A
A=$(lauf "$Z" 5)
pruefe "geaenderter Test faellt am Diff auf" "hat bestehende Tests ge" "$A"
pruefe "Datei wird genannt"                  "test/tasklist.test.js"          "$A"
nicht  "keine dritte Runde"                  "=== Runde 3/5"                  "$A"

# Das README nennt eine Liste von Dateien fuer den Umzug in ein anderes Repo und
# behauptet, das Beispielprojekt sei entbehrlich. Hier wird genau diese Liste
# gebaut -- nichts sonst -- und geprueft, ob Guards und Vorpruefung dort laufen.
echo
echo "[+] Umzug in ein fremdes Repo"
ZIEL="$BASIS/umzug"
rm -rf "$ZIEL"; mkdir -p "$ZIEL/test" "$ZIEL/src"
for D in CLAUDE.md round.md loop.sh TASKS.md STATUS.md QUESTIONS.md \
         .gitattributes .gitignore abnahme.sh; do cp "$QUELLE/$D" "$ZIEL/"; done
cp -r "$QUELLE/.agents" "$QUELLE/.claude" "$ZIEL/"
cp "$QUELLE"/test/guards*.test.js "$ZIEL/test/"
echo 'module.exports = (a, b) => a + b' > "$ZIEL/src/add.js"
{ echo "const t = require('node:test')"
  echo "const a = require('node:assert/strict')"
  echo "t('adds', () => { a.equal(require('../src/add.js')(2, 2), 4) })"
} > "$ZIEL/test/add.test.js"
( cd "$ZIEL"
  git init -q -b main
  git config user.name Abnahme
  git config user.email abnahme@example.invalid
  git add -A >/dev/null
  git update-index --chmod=+x .agents/hooks/*.sh loop.sh abnahme.sh
  git commit -qm "initial" )
A=$( cd "$ZIEL" && node --test --test-reporter=tap 2>&1 )
pruefe "Guards laufen ohne das Beispielprojekt" "# fail 0" "$A"
mkdir -p "$ZIEL/.stub"
echo ".stub/" >> "$ZIEL/.git/info/exclude"
{ echo '#!/usr/bin/env bash'
  echo 'echo "{\"type\":\"result\",\"is_error\":false,\"duration_ms\":1}"'
} > "$ZIEL/.stub/claude"
chmod +x "$ZIEL/.stub/claude"
sed -i 's|^TESTBEFEHL=.*|TESTBEFEHL="node --test --test-reporter=tap test/add.test.js"|' "$ZIEL/loop.sh"
sed -i 's|^TESTZAEHLER=.*|TESTZAEHLER="node --test --test-reporter=tap test/add.test.js"|' "$ZIEL/loop.sh"
git -C "$ZIEL" commit -q -am "Testbefehl auf das Miniprojekt setzen"
A=$(lauf "$ZIEL" 1)
pruefe "Vorpruefung besteht im fremden Repo" "=== Runde 1/1" "$A"

echo
echo "[+] Vorpruefungen"
Z=$(neues_repo vor_dreckig)
printf '%s' "$AKTION_NORMAL" > "$Z/.stub/aktion"; chmod +x "$Z/.stub/aktion"
echo "dreck" > "$Z/offen.txt"
A=$(lauf "$Z" 1)
pruefe "dreckiger Baum blockiert" "Arbeitsverzeichnis nicht sauber" "$A"

Z=$(neues_repo vor_settings)
printf '%s' "$AKTION_NORMAL" > "$Z/.stub/aktion"; chmod +x "$Z/.stub/aktion"
printf '{ kaputt' > "$Z/.claude/settings.json"
git -C "$Z" commit -q -am "break settings"
A=$(lauf "$Z" 1)
pruefe "kaputte settings.json blockiert" "settings.json ist kein" "$A"

Z=$(neues_repo vor_guardweg)
printf '%s' "$AKTION_NORMAL" > "$Z/.stub/aktion"; chmod +x "$Z/.stub/aktion"
rm "$Z/.agents/hooks/guard-bash.sh"
git -C "$Z" commit -q -am "remove guard"
A=$(lauf "$Z" 1)
pruefe "fehlender Guard blockiert" "guard-bash.sh fehlt" "$A"

Z=$(neues_repo vor_guardstumpf)
printf '%s' "$AKTION_NORMAL" > "$Z/.stub/aktion"; chmod +x "$Z/.stub/aktion"
printf '#!/usr/bin/env bash\nexit 0\n' > "$Z/.agents/hooks/guard-files.sh"
git -C "$Z" commit -q -am "blunt guard"
A=$(lauf "$Z" 1)
pruefe "stumpfer Guard blockiert" "guard-files.sh blockiert nicht" "$A"

Z=$(neues_repo vor_zahl)
printf '%s' "$AKTION_NORMAL" > "$Z/.stub/aktion"; chmod +x "$Z/.stub/aktion"
A=$(lauf "$Z" abc)
pruefe "Muellargument blockiert" "positive ganze Zahl" "$A"
nicht  "kein Branch angelegt"    "=== Runde"           "$A"

# Die Schutzdateien sind ab Zyklus 2 nicht mehr nur vor der ersten Runde
# geprueft, sondern vor jeder. Der Anlass steht in REVIEW-1.md als Befund B-1:
# ein Write auf eine Helferdatei und ein Aufruf dieser Helferdatei mit node
# sind beide erlaubt, und der Helfer schreibt dann settings.json und die
# Guards neu. Kein Hook sieht das. Die Runde, in der es passiert, ist jetzt
# die letzte.
echo
echo "[+] Schutzdateien waehrend des Laufs"
Z=$(neues_repo schutz_veraendert)
cat > "$Z/.stub/aktion" <<'A'
if (( RUNDE == 1 )); then
  printf '{"permissions":{"deny":[]},"hooks":{}}' > .claude/settings.json
fi
echo "// round $RUNDE" >> src/tasklist.js
git add -A >/dev/null 2>&1
git commit -q -m "stub round $RUNDE" >/dev/null 2>&1
A
A=$(lauf "$Z" 5)
pruefe "veraenderte Schutzdatei stoppt den Lauf" "geschützte Dateien geändert" "$A"
nicht  "keine dritte Runde"                     "=== Runde 3/5"       "$A"

# Dieselbe Tat ohne Commit: dann sieht der Diff nichts, und nur die Pruefsumme
# faellt darauf herein. Genau der Weg aus B-1.
Z=$(neues_repo schutz_ohne_commit)
cat > "$Z/.stub/aktion" <<'A'
echo "// round $RUNDE" >> src/tasklist.js
git add -A >/dev/null 2>&1
git commit -q -m "stub round $RUNDE" >/dev/null 2>&1
if (( RUNDE == 1 )); then
  printf '#!/usr/bin/env bash\nexit 0\n' > .agents/hooks/guard-bash.sh
fi
A
A=$(lauf "$Z" 5)
pruefe "abgeraeumter Guard stoppt den Lauf" "vor Runde 2" "$A"
nicht  "keine dritte Runde"                 "=== Runde 3/5" "$A"

# Eine geschuetzte Datei, die in der Runde mitcommittet wurde. Die Pruefsumme
# sieht sie auch, aber der Diff nennt sie beim Namen -- und der Name landet im
# Pull Request, statt in einem Diff von dreissig Dateien unterzugehen.
echo
echo "[+] Geschuetzte Datei im Commit"
Z=$(neues_repo schutz_committet)
cat > "$Z/.stub/aktion" <<'A'
echo "// round $RUNDE" >> src/tasklist.js
if (( RUNDE == 1 )); then
  printf '{\n  "name": "abnahme",\n  "private": true\n}\n' > package.json
fi
git add -A >/dev/null 2>&1
git commit -q -m "stub round $RUNDE" >/dev/null 2>&1
A
A=$(lauf "$Z" 5)
pruefe "geschuetzte Datei faellt am Diff auf" "geschützte Dateien geändert" "$A"
pruefe "Datei wird genannt"                   "package.json"           "$A"

# Der Testbefehl hat jetzt eine eigene Zeitgrenze. Vorher lief er ohne, und der
# Wachhund war zu diesem Zeitpunkt schon beendet -- eine Endlosschleife in
# einer Quelldatei haette den Lauf unbegrenzt haengen lassen.
echo
echo "[+] Zeitgrenze des Testbefehls"
Z=$(neues_repo test_haengt)
sed -i "s|^MAX_TEST=.*|MAX_TEST=10|" "$Z/loop.sh"
git -C "$Z" commit -q -am "MAX_TEST fuer die Abnahme verkuerzen"
cat > "$Z/.stub/aktion" <<'A'
echo "// round $RUNDE" >> src/tasklist.js
if (( RUNDE == 1 )); then
  {
    echo "const t = require('node:test')"
    echo "t('spins', () => { for (;;) { Math.sqrt(2) } })"
  } > test/spin.test.js
fi
git add -A >/dev/null 2>&1
git commit -q -m "stub round $RUNDE" >/dev/null 2>&1
A
A=$(lauf "$Z" 3)
pruefe "haengender Testbefehl wird beendet" "länger als MAX_TEST" "$A"
nicht  "keine zweite Runde"                 "=== Runde 2/3"        "$A"

# Das Notentor liest ab jetzt den Ereignisstrom, nicht die Datei, die der Chef
# selbst schreibt. Erster Fall: die Datei behauptet eine 10, im Strom steht
# kein grader -- der Lauf darf nicht enden.
echo
echo "[+] Notentor"
Z=$(neues_repo note_nur_datei)
cat > "$Z/.stub/aktion" <<'A'
echo "// round $RUNDE" >> src/tasklist.js
printf '{"gesamt": 10, "begruendung": "selbst ausgestellt"}' > .agents/grade.json
git add -A >/dev/null 2>&1
git commit -q -m "stub round $RUNDE" >/dev/null 2>&1
A
A=$(lauf "$Z" 2)
pruefe "Note ohne grader zaehlt nicht" "Die Note zählt nicht"  "$A"
pruefe "Lauf laeuft weiter"            "Rundenlimit 2 erreicht" "$A"
nicht  "kein falsches Ende"            "Zielnote erreicht"      "$A"

# Zweiter Fall: der grader lief wirklich, seine Antwort steht im Strom.
Z=$(neues_repo note_aus_strom)
cat > "$Z/.stub/extra" <<'E'
{"type":"system","subtype":"task_started","subagent_type":"grader","tool_use_id":"tu_1"}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tu_1","content":[{"type":"text","text":"{\"gesamt\": 9.1}"}]}]}}
E
cat > "$Z/.stub/aktion" <<'A'
echo "// round $RUNDE" >> src/tasklist.js
printf '{"gesamt": 9.1, "begruendung": "vom grader"}' > .agents/grade.json
git add -A >/dev/null 2>&1
git commit -q -m "stub round $RUNDE" >/dev/null 2>&1
A
A=$(lauf "$Z" 5)
pruefe "Note aus dem Strom zaehlt" "Zielnote erreicht in Runde 1: 9.1" "$A"
nicht  "keine zweite Runde"        "=== Runde 2/5"                     "$A"

# Und der Fall dazwischen: der grader lief, aber die Datei nennt eine andere
# Zahl. Gewertet wird die aus dem Strom, und die Abweichung wird benannt.
Z=$(neues_repo note_weicht_ab)
cat > "$Z/.stub/extra" <<'E'
{"type":"system","subtype":"task_started","subagent_type":"grader","tool_use_id":"tu_1"}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tu_1","content":[{"type":"text","text":"{\"gesamt\": 4.2}"}]}]}}
E
cat > "$Z/.stub/aktion" <<'A'
echo "// round $RUNDE" >> src/tasklist.js
printf '{"gesamt": 9.9, "begruendung": "aufgehuebscht"}' > .agents/grade.json
git add -A >/dev/null 2>&1
git commit -q -m "stub round $RUNDE" >/dev/null 2>&1
A
A=$(lauf "$Z" 2)
pruefe "Abweichung wird benannt" "der grader selbst 4.2" "$A"
nicht  "kein falsches Ende"      "Zielnote erreicht"     "$A"

echo
echo "[+] Weitere Vorpruefungen"
# Zwei Laeufe im selben Arbeitsverzeichnis ziehen einander den Checkout weg.
Z=$(neues_repo zwei_laeufe)
printf '%s' "$AKTION_NORMAL" > "$Z/.stub/aktion"; chmod +x "$Z/.stub/aktion"
mkdir -p "$Z/.agents"
echo "$$" > "$Z/.agents/loop-laeuft.pid"
A=$(lauf "$Z" 1)
pruefe "zweiter Lauf blockiert" "läuft bereits ein Lauf" "$A"
nicht  "kein Branch angelegt"   "=== Runde"               "$A"

# Auf roter Ausgangslage repariert die Reparaturrunde etwas, das der Agent gar
# nicht verursacht hat -- und verbrennt dafuer ein Kontingent.
Z=$(neues_repo rot_vor_dem_start)
printf '%s' "$AKTION_NORMAL" > "$Z/.stub/aktion"; chmod +x "$Z/.stub/aktion"
echo 'module.exports.openTasks = () => { throw new Error("broken before the run") }' >> "$Z/src/tasklist.js"
git -C "$Z" commit -q -am "rote Ausgangslage"
A=$(lauf "$Z" 1)
pruefe "rote Suite vor dem Lauf blockiert" "schon vor dem Lauf rot" "$A"
nicht  "kein Branch angelegt"              "=== Runde"              "$A"

# Ein zurueckgebliebener Schutzsatz ist von aussen nicht zu sehen. Genau so
# lief agent-cockpit acht Runden mit Guards, die das Loeschen des
# Hook-Verzeichnisses durchliessen.
Z=$(neues_repo schutz_veraltet)
printf '%s' "$AKTION_NORMAL" > "$Z/.stub/aktion"; chmod +x "$Z/.stub/aktion"
sed -i "s/^SCHUTZ_VERSION=.*/SCHUTZ_VERSION=1/" "$Z/.agents/hooks/protected-paths.sh"
git -C "$Z" commit -q -am "alten Schutzsatz nachstellen"
A=$(lauf "$Z" 1)
pruefe "veralteter Schutzsatz blockiert" "älter als dieses loop.sh" "$A"
nicht  "kein Branch angelegt"            "=== Runde"                 "$A"

echo
echo "=========================================================="
echo " bestanden: $BESTANDEN    gefallen: $GEFALLEN    Dauer: $(( $(date +%s) - START_SEKUNDEN )) s"
echo "=========================================================="
(( GEFALLEN == 0 ))
