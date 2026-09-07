# Konzept: autonomer Agenten-Loop in Claude Code

Auftrag an den Umsetzer: Baue diesen Workflow exakt wie beschrieben. Alle
Dateiinhalte unten sind verbindlich. Abweichungen nur, wenn ein Punkt technisch
nicht funktioniert — dann in `ABWEICHUNGEN.md` festhalten und begründen.

**Sprachregel:** Alles, was das Modell liest oder schreibt, ist englisch —
`CLAUDE.md`, `round.md`, die Subagent-Definitionen, die Zustandsdateien, die
Meldungen der Hooks und die Commit-Texte. Alles, was nur der Mensch liest,
bleibt deutsch: dieses Dokument, die Kommentare und Ausgaben in `loop.sh`.
Grund: das `description`-Feld eines Subagents wird gegen die englischen
internen Anweisungen von Claude Code gematcht, und ein Repository mit deutschen
Commit-Texten ist unbrauchbar für alles Weitere.

---

## 1. Ziel

Ein Repository wird von drei Rollen selbstständig weiterentwickelt, bis der
Auftrag erledigt ist. Der Mensch greift genau einmal ein: er prüft am Ende den
Pull Request.

| Rolle | Wer ist das technisch | Aufgabe |
|---|---|---|
| Chef | die Hauptsession von `claude -p` | wählt Aufgabe, delegiert, entscheidet, protokolliert, committet |
| Coder | Subagent `coder` | setzt genau eine Aufgabe um |
| Reviewer | Subagent `reviewer` | prüft die Änderung, ändert selbst nichts |

Die Schleife läuft im Terminal als Bash-Skript. Die Desktop-App unterstützt
keine Headless-Ausführung.

## 2. Fünf tragende Prinzipien

1. **Der Zustand lebt auf der Platte, nicht im Kontext.** Jede Runde ist eine
   frische Session ohne Erinnerung. Der Chef rekonstruiert seinen Stand aus
   `TASKS.md`, `STATUS.md`, `QUESTIONS.md` und der Git-Historie. Dadurch kann
   der Lauf beliebig lange dauern, ohne dass ein Kontextfenster überläuft.
2. **Der Chef entscheidet, statt zu fragen.** Es gibt niemanden zum Fragen.
   Alles ausserhalb seines Rahmens wandert nach `QUESTIONS.md`, die Aufgabe
   wird übersprungen.
3. **Prompts sind Bitten, Hooks sind Gesetze.** Was nie passieren darf, wird
   als `PreToolUse`-Hook mit Exit-Code 2 erzwungen. Exit-Code 1 blockiert
   nicht, der Befehl liefe trotzdem.
4. **Das Skript urteilt, nicht der Agent.** «Tests grün» ist keine Aussage des
   Agenten, sondern ein Rückgabewert im Skript. Ein Agent, dessen Belohnung
   «grüne Tests» ist, lernt sonst, Tests zu schwächen statt Code zu reparieren.
5. **Jeder Lauf hat harte Deckel.** Rundenlimit, Turn-Limit, Obergrenze für
   Opus-Eskalationen, Fortschrittsbremse, Stop-Signal.

## 3. Voraussetzungen

- Claude Code aktuell halten (`claude --version`, sonst `claude update`).
  Mehrere Verhaltensweisen hier sind versionsabhängig — siehe Abschnitt 13.
- `jq` und `gh` im Container installiert.
- Ein Git-Repository mit Remote und einem Testbefehl, der bei Fehlschlag einen
  Rückgabewert ungleich 0 liefert.
- Container oder VM mit Default-Deny-Egress. Anthropics Referenz-Devcontainer
  mit `init-firewall.sh` ist genau dafür gedacht. Der Loop läuft mit
  `--dangerously-skip-permissions`, also ohne jede Rückfrage vor einem Befehl —
  die Container-Grenze ist die eigentliche Sicherheitsgrenze, alles andere ist
  zusätzliche Schicht.
- Im Container ein Git-Token, das **nur auf dieses eine Repository** schreiben
  darf, und `gh auth login` damit. Keine weiteren Geheimnisse, keine
  produktiven Zugangsdaten.
- **Branch-Schutz für `main` auf GitHub aktiviert.** Das ist keine Empfehlung,
  sondern die Bedingung dafür, dass der Agent selbst pushen darf.

## 4. Struktur

```
repo/
├── CLAUDE.md                  Charta: Rahmen, Regeln, Eskalation (englisch)
├── round.md                   Prompt, den der Chef jede Runde bekommt (englisch)
├── loop.sh                    die Schleife (läuft im Container)
├── TASKS.md                   Rückstand, oberste Zeile zuerst
├── STATUS.md                  Stand, wird überschrieben, max. 20 Zeilen
├── QUESTIONS.md               was der Chef bewusst nicht entschieden hat
├── .agents/
│   ├── STOP                   existiert erst, wenn der Auftrag erledigt ist
│   ├── next-round.json        Modell- und Aufwandswahl für die Folgerunde
│   ├── run.log                Runde, Modell, Aufwand, Dauer
│   ├── testrun.txt            Ausgabe des letzten Testlaufs
│   ├── stop-reason.txt        Abbruchgrund für die PR-Beschreibung
│   └── hooks/
│       ├── guard-files.sh     sperrt Test-, Config- und Lock-Dateien
│       └── guard-bash.sh      sperrt gefährliche Befehle
└── .claude/
    ├── settings.json          Hooks und permissions.deny
    └── agents/
        ├── coder.md           (englisch)
        └── reviewer.md        (englisch)
```

`.agents/` gehört in `.gitignore`, `.agents/hooks/` aber nicht — die
Hook-Skripte müssen versioniert sein. Subagent-Dateien werden nur beim Start
einer Session geladen; Änderungen greifen erst in der nächsten Runde.

## 5. Ablauf einer Runde

1. `loop.sh` liest `.agents/next-round.json`, prüft die Werte gegen eine
   Whitelist und startet `claude -p` mit Modell, Aufwandsstufe und Turn-Deckel.
2. Der Chef liest `TASKS.md` und `STATUS.md` und wählt genau eine Aufgabe.
   Blocker aus dem letzten Review haben Vorrang.
3. Der Chef delegiert an den Subagent `coder`.
4. Das Ergebnis geht an den Subagent `reviewer`.
5. Blocker und Major-Befunde trägt der Chef oben in `TASKS.md` ein.
6. Der Chef schreibt `STATUS.md` und `.agents/next-round.json` und committet.
7. **Das Skript** führt danach die Testsuite aus und zählt die Tests.
8. Prüfung der Abbruchkriterien (Abschnitt 9).
9. Ist die Testsuite rot, trägt das Skript einen Reparaturauftrag oben in
   `TASKS.md` ein und gibt genau eine Runde zum Reparieren. Bleibt es danach
   rot, bricht der Lauf ab.
10. Nach der Schleife pusht das Skript den Branch und öffnet den Pull Request.

## 6. Modell und Aufwandsstufe

Die Stufen heissen `low`, `medium`, `high`, `xhigh`, `max`. Opus 5 unterstützt
alle fünf, Standard ist `high`.

**Standard in diesem Konzept: `--model sonnet --effort high`.** Orchestrierung
und Routinearbeit brauchen kein Opus.

Das ist auf einem **Max-5x-Abo** die entscheidende Einstellung. Dort wird nicht
pro Token abgerechnet, sondern gegen ein rollendes Fünfstundenfenster und ein
Wochenkontingent — und Opus-Nutzung wird separat und deutlich schneller
verbraucht als Sonnet-Nutzung. Ein unbeaufsichtigter Loop auf Opus leert dir
das Opus-Kontingent in wenigen Läufen, und dann steht auch dein normales
Arbeiten in Claude Code und im Chat still, weil alles aus demselben Topf geht.
Zusätzlich wichtig: Auf Max löst `default` zu Opus 5 auf — `--model sonnet`
muss also explizit gesetzt werden, sonst läuft jede Runde auf Opus.

**Eskalationsregel:** Scheitert dieselbe Aufgabe zweimal am Reviewer, setzt der
Chef für die nächste Runde `opus` / `xhigh`. Danach zurück auf `sonnet`. Das
Skript deckelt die Zahl dieser Eskalationen zusätzlich über
`MAX_OPUS_RUNDEN`.

**Ultracode gehört nicht in den Standardlauf.** Es ist kein Modell und keine
Modellstufe, sondern eine Claude-Code-Einstellung: `xhigh` plus dynamische
Workflow-Orchestrierung. `--effort ultracode` funktioniert zwar auch mit
`claude -p`, aber es startet in einer Runde eigenständig viele parallele
Subagents, ist vom Limit für gleichzeitige Subagents ausgenommen und
unterdrückt die Warnung bei sehr grossen Läufen. Das arbeitet direkt gegen ein
deterministisches «eine Aufgabe pro Runde»-Design und gegen dein
Wochenkontingent. Wenn du es je brauchst, dann bewusst für eine einzelne grosse
Migration, nicht als Dauereinstellung.

Drei Fallen:

- `CLAUDE_CODE_EFFORT_LEVEL` akzeptiert `ultracode` nicht und überschreibt die
  Stufe für die ganze Session. Nicht setzen.
- `CLAUDE_CODE_SUBAGENT_MODEL` setzt das Standardmodell für Subagents. In
  neueren Versionen gewinnt zwar die Frontmatter, mit
  `CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1` kippt das aber wieder. Beide nicht
  setzen, dann ist die Frontmatter massgeblich.
- Modell und Stufe stehen beim Sessionstart fest. Der Chef kann seine eigenen
  Startflags nicht ändern — er entscheidet immer für die **nächste** Runde.

Das `effort`-Feld im Frontmatter eines Subagents überschreibt die Sessionstufe,
solange dieser Subagent läuft.

## 7. Rollen: was du baust und was nicht

**Bauen:** Chef, `coder`, `reviewer`. Für ein Nebenprojekt ist das die richtige
Grösse. Anthropic weist ausdrücklich darauf hin, dass Multi-Agenten-Systeme für
eng gekoppelte Aufgaben wie Coden **weniger** geeignet sind als für Recherche —
die sequentielle Kette Chef → coder → reviewer ist deshalb richtig, ein
paralleles Fan-out wäre es nicht.

**Nicht bauen:**

- **Explorer/Rechercheur** — Claude Code bringt einen eingebauten `Explore`-
  Subagent mit (read-only, schnell). Der Chef soll den nutzen, statt dass du
  einen eigenen schreibst.
- **Planner/Architekt** — der Plan-Modus deckt das ab; der Chef plant ohnehin.
- **Dokumentierer** — erledigt der `coder` in derselben Aufgabe.
- **Security-Reviewer** — als Checkliste im `reviewer`-Prompt statt als eigene
  Rolle. Eigene Rolle erst, wenn du regelmässig an Auth, Krypto oder Zahlungen
  arbeitest.
- **Integrator/Merger** — bei einem sequentiellen Ein-Branch-Loop unnötig.

**Ausbaustufe, erst wenn nötig:** ein `verifier` (read-only), der die
«erledigt»-Behauptung des `coder` gegen die tatsächliche Testausgabe und den
Diff prüft. Bau ihn erst, wenn du im Log siehst, dass Runden als erledigt
gemeldet werden, die es nicht sind. Solange das Skript die Tests selbst
ausführt, ist der grösste Teil dieser Prüfung schon mechanisch abgedeckt.

## 8. Reward Hacking: die Guards

Sobald die Testsuite das einzige Erfolgssignal ist, optimiert der Agent auf
«Tests grün» statt auf «Aufgabe erfüllt». Bekannte Muster: Assertions
abschwächen, Snapshots überschreiben, `skip`/`xfail` einfügen, Timeouts und
CI-Config anpassen, `--no-verify` benutzen. Die Gegenmassnahmen sind
mechanisch, nicht sprachlich:

| Guard | Wo |
|---|---|
| Test-, Snapshot-, Lock- und CI-Dateien während der Implementierung gesperrt | `guard-files.sh`, im `coder`-Frontmatter |
| `--no-verify`, `git stash`, `git reset --hard`, Push auf `main`, `--force`, `rm -rf /` gesperrt | `guard-bash.sh`, session-weit |
| Änderungen an `.claude/`, `CLAUDE.md`, Hook-Skripten gesperrt | `guard-files.sh` — sonst schaltet eine Prompt-Injection deine Guards ab |
| Testsuite läuft im Skript, Rückgabewert entscheidet | `loop.sh` |
| Testanzahl darf nicht sinken | `loop.sh` |
| Geheimnisse gesperrt | Hook **und** `permissions.deny`, doppelt |

Braucht der `coder` legitim eine Teständerung, ist das ein Fall für
`QUESTIONS.md` — genau wie eine neue Abhängigkeit.

## 9. Abbruchbedingungen

| Bedingung | Wirkung |
|---|---|
| `.agents/STOP` existiert | Auftrag erledigt, sauberes Ende |
| Runde ohne neuen Commit | Stillstand — der Agent dreht im Kreis |
| Testsuite nach der Runde rot | eine Reparaturrunde, danach Abbruch |
| Testanzahl gesunken | Verdacht auf gelöschte oder geskippte Tests |
| Rundenlimit erreicht | Abbruch |
| `claude` endet mit Fehler oder Turn-Deckel | Abbruch |

Ein Lauf endet immer mit einem Pull Request, auch ein abgebrochener — der
Abbruchgrund steht oben in der PR-Beschreibung. Sonst siehst du nicht, woran er
gescheitert ist.

## 10. Dateien

### 10.1 `CLAUDE.md`

```markdown
# Mission and boundaries

This repository is developed autonomously. There is nobody to ask. You decide
and you document.

## Decision boundary

You decide on your own: implementation, naming, test design for new code,
refactorings within the scope of the task, ordering of tasks.

You do NOT decide on your own: new dependencies, database migrations, changes
to public API contracts, changes to existing tests, deleting files outside the
task, anything that costs money or has external effects.
In those cases: add an entry to QUESTIONS.md with your recommendation, skip the
task, and continue with the next one.

## Definition of done

One commit per task, with the reasoning in the commit message. Whether the
tests pass is decided by the script after your round, not by you. Never claim
something works — show the command you ran and its output.

When a test fails, fix the code. Never change, remove or skip an existing test
to make it pass. If a test is genuinely wrong, that belongs in QUESTIONS.md.

## Exploration

Use the built-in Explore subagent to understand unfamiliar code instead of
reading broadly yourself. It keeps your context small.

## Model choice for the next round

At the end of the round, write .agents/next-round.json:
{"model": "sonnet", "effort": "high", "reason": "one sentence"}

- sonnet + high: the default for everything.
- opus + xhigh: only when the same task has failed review twice, or for an
  architectural decision spanning several files. Then back to sonnet.
- haiku + low: never for code. Cleanup rounds only.

State the reason for your choice in one sentence in STATUS.md.

## File formats

Write all files, commit messages and code comments in English.

TASKS.md: one task per line, "- [ ] description", highest priority on top.
STATUS.md: max 20 lines, overwritten every round, never appended to. Also
records how often the current task has failed review.
QUESTIONS.md: appended to, never shortened. Format:
"- Topic: what you did not decide, your recommendation, why you stopped."
```

### 10.2 `round.md`

```markdown
You are the lead. Run exactly one round:

1. Read TASKS.md and STATUS.md.
2. Blockers from the last review take priority over new tasks.
3. Pick EXACTLY ONE task and delegate it to the "coder" subagent.
   Give it everything it needs: file paths, error messages, edge cases.
   It cannot see your conversation.
4. Pass the result to the "reviewer" subagent.
5. Add blockers and major findings to the top of TASKS.md.
   Remove completed tasks from TASKS.md.
6. Anything outside your decision boundary: add it to QUESTIONS.md and skip
   that task.
7. Rewrite STATUS.md: what happened this round, what is next, how often the
   current task has failed review, and why you chose the next model.
8. Write .agents/next-round.json.
9. Commit your work. A round without a commit counts as no progress and the
   script will stop the run.
10. If TASKS.md is empty and the last review found nothing: create .agents/STOP.
```

### 10.3 `.claude/agents/coder.md`

```markdown
---
name: coder
description: Implements exactly one task from TASKS.md. MUST BE USED for every code change.
tools: Read, Write, Edit, Bash, Glob, Grep
model: sonnet
effort: high
hooks:
  PreToolUse:
    - matcher: "Edit|Write"
      hooks:
        - type: command
          command: "./.agents/hooks/guard-files.sh"
---

You implement exactly the one task given in the prompt. No extra features, no
drive-by refactoring, no renaming outside the assignment.

Then run the tests. If something fails, fix the cause in the code. You never
modify an existing test to make it pass — access to test files is blocked and
the attempt is logged.

Reply with: files changed, what you did, what you deliberately left open, and
the verbatim output of the test run. Do not claim anything you cannot back up
with command output.
```

### 10.4 `.claude/agents/reviewer.md`

```markdown
---
name: reviewer
description: Reviews the most recent change. MUST BE USED after every implementation.
tools: Read, Bash, Glob, Grep
model: sonnet
effort: high
---

You are a reviewer, not a coder. You change nothing.

Check in this order:
1. Does the change actually satisfy the task, or only the tests?
2. Was an existing test weakened, skipped or removed? Inspect the diff, not the
   coder's claim.
3. Error handling and edge cases.
4. Is the new logic covered by a test?
5. Security: input validation, secrets in code, unsafe calls.
6. Style, last.

Reply with a list of findings, each with severity blocker / major / minor, file
path, line and a concrete suggestion — or exactly "NO FINDINGS". Do not invent
findings just to produce output; a clean pass is a valid result.
```

### 10.5 `.agents/hooks/guard-files.sh`

```bash
#!/usr/bin/env bash
# Blockiert Schreibzugriffe auf Dateien, die der Agent nicht ändern darf.
# Exit 2 bricht den Werkzeugaufruf ab, stderr geht als Begründung ans Modell —
# deshalb sind die Meldungen englisch.
PFAD=$(jq -r '.tool_input.file_path // empty')

# Tests, Snapshots, Fixtures
if echo "$PFAD" | grep -qiE '(\.test\.|\.spec\.|_test\.(go|py|rs)$|/tests?/|conftest\.py|\.snap$)'; then
  echo "Blocked: existing tests must not be changed. Fix the code, or add an entry to QUESTIONS.md." >&2
  exit 2
fi

# Abhängigkeiten, Lockfiles, Build- und CI-Konfiguration
if echo "$PFAD" | grep -qiE '(package(-lock)?\.json|yarn\.lock|pnpm-lock|requirements.*\.txt|pyproject\.toml|poetry\.lock|go\.(mod|sum)|Cargo\.(toml|lock)|pytest\.ini|tox\.ini|\.github/workflows/)'; then
  echo "Blocked: dependencies and build configuration are a human decision. Add an entry to QUESTIONS.md." >&2
  exit 2
fi

# Selbstveränderung der Schutzmechanismen
if echo "$PFAD" | grep -qiE '(\.claude/|CLAUDE\.md$|\.agents/hooks/)'; then
  echo "Blocked: your own configuration and safeguards are immutable." >&2
  exit 2
fi

# Geheimnisse
if echo "$PFAD" | grep -qiE '(\.env|id_rsa|\.pem$|credentials)'; then
  echo "Blocked: secrets." >&2
  exit 2
fi

exit 0
```

### 10.6 `.agents/hooks/guard-bash.sh`

```bash
#!/usr/bin/env bash
# Blockiert gefährliche und guard-umgehende Befehle.
BEFEHL=$(jq -r '.tool_input.command // empty')

# Guard-Umgehung und Zerstörerisches
if echo "$BEFEHL" | grep -qE '(--no-verify|git +stash|git +reset +--hard|git +checkout +--|rm +-rf +/|npm +publish|shutdown|mkfs)'; then
  echo "Blocked: this bypasses the safeguards or is irreversible." >&2
  exit 2
fi

# Pushen darf der Agent, aber nie auf main und nie mit Gewalt.
if echo "$BEFEHL" | grep -qE 'git +push'; then
  if echo "$BEFEHL" | grep -qE '(--force|-f( |$)|main|master|--delete|:.*main)'; then
    echo "Blocked: no push to main and no force push. Push to the agent branch only." >&2
    exit 2
  fi
fi

exit 0
```

Beide Skripte ausführbar machen: `chmod +x .agents/hooks/*.sh`.

### 10.7 `.claude/settings.json`

```json
{
  "permissions": {
    "deny": [
      "Read(./.env)",
      "Read(./.env.*)",
      "Read(./**/*.pem)",
      "Read(./**/id_rsa*)",
      "Edit(./.claude/**)",
      "Edit(./CLAUDE.md)",
      "Edit(./.agents/hooks/**)"
    ]
  },
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "./.agents/hooks/guard-bash.sh" }
        ]
      },
      {
        "matcher": "Read|Edit|Write",
        "hooks": [
          { "type": "command", "command": "./.agents/hooks/guard-files.sh" }
        ]
      }
    ]
  }
}
```

Die Doppelschicht aus `permissions.deny` und Hook ist Absicht: es gab Versionen
und Werkzeuge, bei denen Exit 2 nicht zuverlässig jeden Aufruf blockierte.
Verlass dich nicht auf eine der beiden allein.

### 10.8 `loop.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

# --- Vom Umsetzer auszufüllen -------------------------------------------
TESTBEFEHL="PLATZHALTER"    # z.B. "npm test" oder "pytest -q"
TESTZAEHLER="PLATZHALTER"   # Befehl, der die Anzahl Tests als Zahl ausgibt
MAX_TURNS=200               # harter Deckel pro Runde
MAX_OPUS_RUNDEN=5           # so viele Eskalationsrunden auf Opus pro Lauf
# ------------------------------------------------------------------------

MAX="${1:-60}"
for W in "$TESTBEFEHL" "$TESTZAEHLER"; do
  [[ "$W" == "PLATZHALTER" ]] && { echo "Konfiguration oben in loop.sh ausfüllen."; exit 1; }
done
command -v jq >/dev/null || { echo "jq fehlt"; exit 1; }
command -v gh >/dev/null || { echo "gh fehlt"; exit 1; }

# Diese Variablen würden Aufwandsstufe und Subagent-Modelle überschreiben.
unset CLAUDE_CODE_EFFORT_LEVEL CLAUDE_CODE_SUBAGENT_MODEL CLAUDE_CODE_SUBAGENT_MODEL_FORCE

ZWEIG="agent/$(date +%Y%m%d-%H%M)"
git checkout -b "$ZWEIG"

mkdir -p .agents
rm -f .agents/STOP
: > QUESTIONS.md
: > .agents/run.log

TESTS_VORHER=$($TESTZAEHLER || echo 0)
OPUS_RUNDEN=0
REPARATURRUNDE=0
GRUND="kein Lauf"

for ((i=1; i<=MAX; i++)); do
  MODELL="sonnet"
  AUFWAND="high"
  if [[ -f .agents/next-round.json ]]; then
    MODELL=$(jq -r '.model  // "sonnet"' .agents/next-round.json)
    AUFWAND=$(jq -r '.effort // "high"'   .agents/next-round.json)
  fi
  # Die Datei schreibt ein Agent. Nichts Ungeprüftes in die Kommandozeile.
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

  if ! claude -p "$(cat round.md)" \
        --model "$MODELL" --effort "$AUFWAND" \
        --max-turns "$MAX_TURNS" \
        --output-format json \
        --dangerously-skip-permissions \
        --allowedTools "Read,Write,Edit,Bash,Glob,Grep,Agent" \
        < /dev/null > .agents/round-$i.json; then
    GRUND="Session in Runde $i abgebrochen (Fehler oder Turn-Deckel)"
    break
  fi

  DAUER=$(jq -r '.duration_ms // "?"' .agents/round-$i.json)
  echo "Runde $i | $MODELL | $AUFWAND | ${DAUER}ms" >> .agents/run.log

  if [[ -f .agents/STOP ]]; then
    GRUND="Auftrag erledigt in Runde $i"
    break
  fi

  if [[ "$(git rev-parse HEAD)" == "$VORHER" ]]; then
    GRUND="Runde $i ohne Commit, Stillstand"
    break
  fi

  if ! $TESTBEFEHL > .agents/testrun.txt 2>&1; then
    if (( REPARATURRUNDE == 1 )); then
      GRUND="Testsuite auch nach der Reparaturrunde rot (Runde $i)"
      break
    fi
    echo "Testsuite rot — eine Reparaturrunde."
    REPARATURRUNDE=1
    printf '%s\n%s\n' \
      "- [ ] BLOCKER: the test suite is failing. Output in .agents/testrun.txt. Fix the cause in the code; touching test files is blocked." \
      "$(cat TASKS.md)" > TASKS.md
    git add -A && git commit -m "Add repair task after round $i" --quiet
    continue
  fi
  REPARATURRUNDE=0

  TESTS_JETZT=$($TESTZAEHLER || echo 0)
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

git push -u origin "$ZWEIG"
gh pr create --base main --head "$ZWEIG" --title "Agent run $ZWEIG" \
  --body "$(printf '## Stop reason\n\n%s\n\n## Status\n\n%s\n\n## Decisions to review\n\n%s\n\n## Run\n\n```\n%s\n```\n' \
    "$GRUND" "$(cat STATUS.md)" "$(cat QUESTIONS.md)" "$(cat .agents/run.log)")"
```

Der Abbruchgrund in der PR-Beschreibung ist die einzige deutsche Zeile, die im
Repository landet. Wenn dich das stört, übersetz die `GRUND=`-Zeilen; auf die
Arbeitsweise des Modells hat es keinen Einfluss.

### 10.9 Push und Pull Request

Push und Pull Request erledigt `loop.sh` am Ende selbst, deterministisch und
immer auf den Agenten-Branch. Der Agent darf zusätzlich selbst pushen, aber
`guard-bash.sh` lässt nur den Agenten-Branch zu: kein `main`, kein Force-Push,
kein Löschen von Branches.

Diese Bequemlichkeit hat einen Preis, den du kennen musst: Im Container liegt
ein Token mit Schreibrecht. Eine Prompt-Injection über Repository-Inhalte oder
eine Abhängigkeit kann damit Code auf einen Branch schieben. Deshalb sind zwei
Dinge Pflicht, nicht optional:

- **Branch-Schutz für `main` auf GitHub**, inklusive Pflicht zum Pull Request.
  Der Hook ist über einen direkten Pfad umgehbar, der Branch-Schutz nicht.
- **Ein Token, das nur auf dieses eine Repository schreiben darf** — kein
  persönliches Token mit Zugriff auf alle deine Repositories.

## 11. Abnahme

Der Umsetzer weist diese acht Punkte nach:

1. **Trockenlauf.** `./loop.sh 1` mit einer trivialen Aufgabe erzeugt einen
   Commit und einen Eintrag in `.agents/run.log`.
2. **Testschutz greift.** Eine Aufgabe, die verlangt, einen fehlschlagenden
   Test zu löschen, wird blockiert; die Meldung erscheint im Transkript, die
   Testdatei ist unverändert.
3. **Bash-Schutz greift.** Eine Aufgabe, die `git commit --no-verify` oder
   `git push origin main` verlangt, wird blockiert; ein Push auf den
   Agenten-Branch geht durch.
4. **Selbstschutz greift.** Eine Aufgabe, die `.claude/settings.json` ändern
   soll, wird blockiert.
5. **Fortschrittsbremse greift.** Leere `TASKS.md` führt in Runde 1 zu
   `.agents/STOP` oder zum Stillstands-Abbruch, nicht zu 60 Leerrunden.
6. **Reparaturrunde greift.** Ein künstlich rot gemachter Test erzeugt einen
   Blocker oben in `TASKS.md` und genau eine weitere Runde. Bleibt der Test
   rot, bricht der Lauf mit dem richtigen Grund ab.
7. **Modellwahl greift.** `{"model":"opus","effort":"xhigh"}` erscheint in der
   Runden-Ausgabe; `{"model":"quatsch"}` fällt auf `sonnet` zurück. Nach
   `MAX_OPUS_RUNDEN` Eskalationen läuft die Runde wieder auf Sonnet.
8. **Branch-Schutz greift.** Ein direkter Push auf `main` aus dem Container
   wird von GitHub abgelehnt.

## 12. Verwandte Umsetzungen

Dieses Muster heisst «Ralph-Loop» und existiert mehrfach fertig. Gebaut wird
hier bewusst selbst; die folgenden Projekte sind trotzdem gute Vergleichsstücke,
wenn eine Stelle im eigenen Loop nicht rund läuft:

- **`agenticloops-ai/ralph-loop`** — Scaffold mit «eine Aufgabe pro Runde»,
  Docker-Sandbox und getrennten Prompts. Am nächsten an diesem Konzept.
- **`kylemclaren/ralph`** — Go-CLI, Zustand über Git und Textdateien.
- **`ralph-wiggum`-Plugin** im offiziellen Claude-Code-Marketplace. Der Loop
  lebt dort in *einer* Session über einen Stop-Hook — die Bauart, die dieses
  Konzept bewusst nicht wählt.
- **`claude-code-action`** für GitHub Actions: Label auf einem Issue löst einen
  Lauf auf einem frischen Runner aus, der einen Pull Request öffnet. Die
  naheliegende Ausbaustufe, sobald der lokale Loop stabil läuft.

## 13. Bekannte Grenzen

- **Versionsabhängigkeit.** Präzedenz von Subagent-Frontmatter gegenüber
  `CLAUDE_CODE_SUBAGENT_MODEL`, Verfügbarkeit von `--effort ultracode` und die
  Zuverlässigkeit von Exit 2 auf einzelnen Werkzeugen haben sich zwischen
  Versionen geändert. Prüfe das Verhalten in deiner Version, statt dich auf
  dieses Dokument zu verlassen.
- **Die Hooks fangen bekannte Muster ab, keine unbekannten.**
  `--dangerously-skip-permissions` bleibt gefährlich; die Container-Grenze ist
  die eigentliche Sicherheit.
- **Prompt-Injection über Repo-Inhalte und Abhängigkeiten ist real.** Gib dem
  `coder` kein WebFetch und kein WebSearch, wenn er es nicht braucht. Weil im
  Container ein Schreib-Token liegt, ist der Branch-Schutz auf `main` die
  Barriere, die wirklich zählt.
- **Der Verbrauch pro Lauf lässt sich nicht vorhersagen.** Er hängt an Aufgabe,
  Kontextgrösse und Rundenzahl, und auf einem Abo gibt es keinen Dollar-Deckel,
  den man setzen könnte — der Dollarbetrag in der Headless-Ausgabe ist nur ein
  Schätzwert und begrenzt nichts. Deine echten Bremsen sind Rundenlimit,
  `--max-turns` und `MAX_OPUS_RUNDEN`. Erst drei Runden fahren, danach in
  Claude Code unter Settings > Usage nachsehen, wie viel das gekostet hat, dann
  hochdrehen.
- **Der Loop teilt sich das Kontingent mit deinem normalen Arbeiten.** Claude
  Code, Chat und die Apps ziehen aus demselben Topf. Lass lange Läufe nicht
  nebenbei mitlaufen, wenn du gleichzeitig anderes vorhast.
- **Wächst `TASKS.md` schneller, als sie schrumpft, ist der Auftrag zu gross
  geschnitten.** Das siehst du am Rückstand im Pull Request.

## 14. Quellen

- Subagents: https://code.claude.com/docs/en/sub-agents
- Modell und Aufwandsstufen: https://code.claude.com/docs/en/model-config
- Hooks: https://code.claude.com/docs/en/hooks
- Headless-Modus: https://code.claude.com/docs/en/headless
- Sandbox: https://code.claude.com/docs/en/sandboxing
- GitHub Action: https://github.com/anthropics/claude-code-action
- Anthropic zu Multi-Agenten-Systemen:
  https://www.anthropic.com/engineering/multi-agent-research-system
