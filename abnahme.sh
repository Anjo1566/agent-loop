#!/usr/bin/env bash
# Abnahme von loop.sh gegen einen claude-Stub.
#
# Der Stub ersetzt die echte Sitzung und spielt genau das Verhalten nach, das
# die jeweilige Abnahmebedingung provozieren soll. Damit ist die Schleifenlogik
# deterministisch pruefbar - ohne Kontingent und ohne Wartezeit.

set -uo pipefail

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
  git -C "$ziel" config user.name "Abnahme"
  git -C "$ziel" config user.email "abnahme@example.invalid"

  # Der Stub selbst darf die Sauberkeitspruefung von loop.sh nicht ausloesen.
  echo ".stub/" >> "$ziel/.git/info/exclude"
  mkdir -p "$ziel/.stub"
  cat > "$ziel/.stub/claude" <<'STUB'
#!/usr/bin/env bash
# claude-Stub: protokolliert Modell und Aufwand, fuehrt die Szenario-Aktion
# aus und gibt eine Runden-JSON aus, wie --output-format json sie liefert.
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
# Der realistische Weg: der Agent legt Tests an und raeumt sie spaeter
# wieder weg. Die Suite bleibt dabei gruen, nur die Zahl sinkt.
Z=$(neues_repo testanzahl)
cat > "$Z/.stub/aktion" <<'A'
if (( RUNDE == 1 )); then
  cat > test/extra.test.js <<'T'
const test = require('node:test')
const assert = require('node:assert/strict')
test('extra a', () => { assert.ok(true) })
test('extra b', () => { assert.ok(true) })
test('extra c', () => { assert.ok(true) })
T
elif (( RUNDE == 2 )); then
  rm -f test/extra.test.js
fi
echo "// round $RUNDE" >> src/tasklist.js
git add -A >/dev/null 2>&1
git commit -q -m "stub round $RUNDE" >/dev/null 2>&1
A
A=$(lauf "$Z" 5)
pruefe "gesunkene Testanzahl erkannt" "Testanzahl gesunken" "$A"
pruefe "Suite war dabei gruen"        "27 auf 24"           "$A"
nicht  "keine vierte Runde"           "=== Runde 4/5"       "$A"

# Eine geloeschte Testdatei laesst die Suite gruen -- gerade deshalb braucht es
# die zweite Bremse. Sie nennt auch gleich die Zahlen.
Z=$(neues_repo testdatei_weg)
cat > "$Z/.stub/aktion" <<'A'
if (( RUNDE == 2 )); then rm -f test/tasklist.test.js; fi
echo "// round $RUNDE" >> src/tasklist.js
git add -A >/dev/null 2>&1
git commit -q -m "stub round $RUNDE" >/dev/null 2>&1
A
A=$(lauf "$Z" 5)
pruefe "geloeschte Testdatei stoppt den Lauf" "Testanzahl gesunken (24 auf 17)" "$A"
nicht  "keine vierte Runde"                   "=== Runde 4/5"                    "$A"

# --- Zusatz: Vorpruefungen ----------------------------------------------
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

echo
echo "=========================================================="
echo " bestanden: $BESTANDEN    gefallen: $GEFALLEN"
echo "=========================================================="
(( GEFALLEN == 0 ))
