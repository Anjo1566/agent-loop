# Abweichungen vom Konzept

Das Konzept erlaubt Abweichungen nur, wenn ein Punkt technisch nicht
funktioniert. Jede hier steht deshalb mit Begründung und mit dem Beleg, der sie
ausgelöst hat.

Grundlage ist eine Prüfung gegen **Claude Code 2.1.263** (Windows-Build,
`C:\Users\anjog\.local\bin\claude`) am 07.09.2026 — Abschnitt 13 des Konzepts
verlangt genau das, statt sich auf das Dokument zu verlassen. Belegt wurde
gegen die offizielle Dokumentation und gegen die Zeichenketten im Binary.

Was das Konzept richtig beschreibt und **nicht** geändert wurde: Exit 2
blockiert zuverlässig und die stderr-Zeile erreicht das Modell; `exit 1`
blockiert nicht; `permissions.deny` gewinnt gegen
`--dangerously-skip-permissions`; `Agent` ist der korrekte Werkzeugname;
`--max-turns` existiert und `claude -p` endet dabei mit Rückgabewert 1;
`< /dev/null` ist Pflicht; `--model sonnet` ist die richtige Schreibweise;
`effort:` und ein `hooks:`-Block im Subagent-Frontmatter werden unterstützt;
Frontmatter schlägt `CLAUDE_CODE_SUBAGENT_MODEL`, solange loop.sh die
Umgebungsvariablen leert.

---

## A. Guards, die still ausgefallen wären

### A1 — Beide Guards liessen ohne `jq` alles durch

**Konzept:** `PFAD=$(jq -r '.tool_input.file_path // empty')` als erste Zeile,
ohne Prüfung.
**Problem:** Fehlt `jq`, ist die Variable leer, kein `grep` trifft, das Skript
erreicht `exit 0` — der Werkzeugaufruf geht durch. Auf diesem Rechner war `jq`
nicht installiert. Ein Trockenlauf hätte grüne Guards gezeigt, die nichts
blockieren. Dasselbe gilt für einen kaputten Payload.
**Änderung:** Beide Guards sind fail-closed: fehlendes `jq`, nicht lesbare
Musterdatei, unparsbarer Payload oder fehlender `tool_name` führen zu Exit 2.
`jq` wurde per `winget install --id jqlang.jq` nachinstalliert.

### A2 — Der Datei-Guard blockierte das *Lesen* von Tests

**Konzept:** `settings.json` registriert `guard-files.sh` unter dem Matcher
`Read|Edit|Write`, das Skript prüft aber nur den Pfad, nicht das Werkzeug.
**Problem:** Damit ist auch `Read` auf jede Testdatei, jedes Lockfile und auf
`CLAUDE.md` gesperrt. Der Reviewer hat als Prüfpunkt 2 ausdrücklich »Was an
existing test weakened, skipped or removed? Inspect the diff« — das wäre
unmöglich. Der Coder könnte nicht einmal `package.json` lesen.
**Änderung:** Der Guard liest `tool_name` aus dem Payload. Die Geheimnis-Regel
gilt für jedes Werkzeug; Test-, Abhängigkeits- und Selbstschutzregeln greifen
nur bei `Edit|Write|NotebookEdit|MultiEdit`.

### A3 — Neue Tests waren unmöglich

**Problem:** Das Muster sperrt jede Testdatei. Die Charta erlaubt dem Agenten
aber ausdrücklich »test design for new code«, und Reviewer-Prüfpunkt 4 fragt
»Is the new logic covered by a test?«. Zusätzlich könnte die Testanzahl damit
nur noch sinken oder gleich bleiben — die Bremse »Testanzahl darf nicht sinken«
wäre der einzige noch mögliche Ausgang.
**Änderung:** Gesperrt ist nur das Überschreiben einer **bestehenden**
Testdatei (`[[ -e "$PFAD" ]]`). Eine neue anzulegen ist erlaubt. Das ist genau
der Wortlaut der Charta: »never change, remove or skip an existing test«.

### A4 — Jeder Dateischutz war über die Shell umgehbar

**Problem:** `guard-files.sh` sieht nur Edit/Write/NotebookEdit. Der Coder hat
`Bash`. `sed -i`, `cat > datei`, `rm`, `chmod -x` auf ein Guard-Skript — nichts
davon erreicht den Datei-Guard. Das ist kein Randfall: `coder.md` sagt dem
Modell »access to test files is blocked«, womit `sed` der naheliegende nächste
Schritt ist.
**Änderung:** `guard-bash.sh` prüft dieselben Pfade. Der Befehl wird in Tokens
zerlegt; enthält er ein schreibendes Werkzeug oder eine Ausgabeumleitung und
zugleich einen geschützten Pfad, blockiert er. Beide Guards teilen sich dafür
eine Musterdatei `.agents/hooks/protected-paths.sh`, damit sie nicht
auseinanderdriften.

### A5 — Vier Umgehungen im Bash-Guard

| Umgehung | Konzept | jetzt |
|---|---|---|
| `git commit -n` (Kurzform von `--no-verify`) | ging durch | blockiert |
| `git -c foo=bar push --force origin main` | ging durch, weil das Muster `git +push` wörtlich verlangte | am Verb verankert |
| `git push origin +agent/x:agent/x` | ging durch | blockiert |
| `git clean -fdx`, `git restore`, `git checkout <ref> -- <datei>` | ging durch | blockiert |

Umgekehrt blockierte der Substring `main` legitime Branchnamen wie
`agent/maintenance` — jetzt wird auf eine Refspec verankert.

### A6 — Selbstschutz griff auf Windows nicht

**Problem:** Claude Code liefert Pfade auf Windows mit Backslashes. Das Muster
`(\.claude/|CLAUDE\.md$|\.agents/hooks/)` trifft dann nichts. Ausgerechnet die
Regel, die eine Prompt-Injection am Abschalten der Guards hindern soll, war auf
dem Rechner des Nutzers wirkungslos.
**Änderung:** `PFAD="${PFAD//\\//}"` normalisiert zuerst; alle Muster sind
zusätzlich an `^` oder `/` verankert, damit sie nicht auf gewöhnliche
Quelldateien falsch anschlagen.

### A7 — Relativer Hook-Pfad und fehlendes Exec-Bit

**Konzept:** `"command": "./.agents/hooks/guard-files.sh"`.
**Problem:** Hooks laufen im aktuellen Arbeitsverzeichnis der Sitzung, nicht
zwingend im Projektwurzelverzeichnis; ein `cd` im Bash-Werkzeug bricht den
relativen Pfad. Ein nicht gefundenes oder nicht ausführbares Skript endet mit
126/127 — und das blockiert **nicht**. Auf Windows ist `chmod` ausserdem
wirkungslos, die Skripte wären als `100644` committet und im Linux-Container
nicht ausführbar.
**Änderung:** `bash "$CLAUDE_PROJECT_DIR/.agents/hooks/guard-files.sh"` in
`settings.json` und im `coder`-Frontmatter — interpreterexplizit,
verzeichnisunabhängig, ohne Exec-Bit-Abhängigkeit. Zusätzlich wurde
`git update-index --chmod=+x` gesetzt und `.gitattributes` mit
`* text=auto eol=lf` angelegt (CRLF bricht die Skripte im Container, auf
Windows aber nicht — der Fehler wäre erst nach dem Klonen aufgetaucht).

### A8 — `NotebookEdit` fehlte im Matcher

`NotebookEdit` ist in 2.1.263 ein aktives Schreibwerkzeug, wird von beiden
Matchern des Konzepts nicht erfasst und trägt den Pfad unter `notebook_path`
statt `file_path`. Matcher erweitert, Guard liest beide Schlüssel. Der
Bash-Matcher heisst jetzt `Bash|PowerShell`, weil das PowerShell-Werkzeug auf
Windows ein zweiter Weg zur Shell ist.

---

## B. `loop.sh`

### B1 — Testbefehl und Testzähler über `bash -c`

**Konzept:** `$TESTBEFEHL` und `$TESTZAEHLER` unquoted expandiert.
**Problem:** Das zerlegt nur in Wörter — Pipes, Anführungszeichen und
Umleitungen werden als Argumente durchgereicht. Ein Zähler ohne Pipe gibt es
praktisch nicht. `$($TESTZAEHLER || echo 0)` machte daraus die Zahl 0, und die
Bremse »Testanzahl darf nicht sinken« war damit für den ganzen Lauf aus — eine
der beiden mechanischen Gegenmassnahmen aus Abschnitt 8.
**Änderung:** beide laufen über `bash -c`.

### B2 — Der Zähler konnte den Lauf mitten in der Schleife töten

`(( TESTS_JETZT < TESTS_VORHER ))` mit einem nicht-numerischen Wert ist unter
`set -u` tödlich, auch innerhalb von `if`. Der Lauf wäre **nach** der Runde und
**vor** Abbruchgrund, Push und Pull Request gestorben. Jetzt wird der Wert
gefiltert (`tr -dc '0-9\n' | tail -1`) und gegen `^[0-9]+$` geprüft; liefert
der Zähler beim Start keine Zahl, bricht die Vorprüfung ab, statt still
weiterzulaufen.

### B3 — Der Abbruchgrund im Pull Request log

`GRUND="Rundenlimit erreicht"` stand am Schleifenende und wurde vom `continue`
der Reparaturrunde übersprungen. `./loop.sh 1` auf roter Suite hätte »kein
Lauf« berichtet. Der Grund wird jetzt vor der Schleife gesetzt, in jedem
Ausgang überschrieben und im Fehlerfall aus der Runden-JSON gelesen: `.is_error`
ist das einzige verlässliche Merkmal, weil ein API- oder Kontingentfehler als
`subtype: "success"` mit `is_error: true` zurückkommt.

### B4 — Kein Pull Request bei frühem Abbruch

Bricht der Lauf vor dem ersten Commit ab, pusht das Konzept einen leeren Branch
und `gh pr create` scheitert; unter `set -e` endet das Skript dort. Jetzt wird
auf Commits gegenüber `main` geprüft, ein fehlendes `origin` sauber gemeldet,
und ein gescheitertes `gh pr create` verschluckt den Abbruchgrund nicht mehr.

### B5 — `QUESTIONS.md` wird nicht mehr geleert

`: > QUESTIONS.md` schneidet eine versionierte Datei ab, die die Charta als
»appended to, never shortened« führt — und committet die Löschung in der
nächsten Runde unter fremder Botschaft. Stattdessen merkt sich der Lauf die
Zeilenzahl beim Start und zeigt im Pull Request nur, was dieser Lauf ergänzt
hat.

### B6 — `git add -A` in der Reparaturrunde

Das nahm jede Datei mit, die der Agent bewusst offen gelassen hatte, unter der
Botschaft »Add repair task«. Jetzt wird nur `TASKS.md` committet, und ein
Fehlschlag beendet den Lauf mit Grund statt über `set -e` ohne Pull Request.

### B7 — Stillstandserkennung war fast wirkungslos

Erkannt wurde nur »HEAD hat sich nicht bewegt«. `round.md` verlangt aber jede
Runde ein neues `STATUS.md` und einen Commit — ein regelkonformer Agent bewegt
HEAD also immer, und der Lauf hätte alle 60 Runden Kontingent verbraucht, ohne
dass etwas passiert. Jetzt zählt zusätzlich, ob sich ausserhalb von
`STATUS.md`, `TASKS.md`, `QUESTIONS.md` und `.agents/` etwas geändert hat; nach
`MAX_LEERRUNDEN` solchen Runden bricht der Lauf ab.

### B8 — Reparaturrunden waren nicht auf eine begrenzt

`REPARATURRUNDE=0` nach jeder grünen Runde machte den Zähler
aufeinanderfolgend statt laufweit: rot/grün/rot/grün hätte bis zu `MAX/2`
Reparaturrunden gekauft. Abschnitt 9 liest sich als »eine Reparaturrunde,
danach Abbruch«; der Zähler ist jetzt laufweit.

### B9 — Vorprüfungen

Neu, weil jeder dieser Fälle sonst erst nach dem Anlegen des Branches und
mitten im Kontingentverbrauch aufgefallen wäre: Rundenzahl numerisch;
`jq`/`gh`/`git`/`claude` vorhanden; `.claude/settings.json` ist gültiges JSON
(ein Syntaxfehler lässt Claude Code die Datei im `-p`-Modus **still**
verwerfen — mitsamt deny-Liste und beiden Hooks); Guard-Skripte vorhanden;
**Rauchtest**, der je einen fingierten Payload durch beide Guards schickt und
Exit 2 verlangt; sauberes Arbeitsverzeichnis; alle Zustandsdateien vorhanden.
Ausserdem wird von `main` aus verzweigt (`git switch` + `git pull --ff-only`),
statt von einem beliebigen HEAD.

### B10 — `--max-budget-usd` als dritte Bremse

Abschnitt 13 sagt, auf einem Abo gebe es keinen Dollar-Deckel. Den Schalter
gibt es, er funktioniert ohne API-Schlüssel, zählt Subagenten mit und beendet
die Runde über `subtype: "error_max_budget_usd"` mit Rückgabewert 1. Er misst
keine echte Kontingentnutzung, sondern eine Listenpreis-Schätzung — als
deterministischer Deckel pro Runde ist er trotzdem nützlich.

### B11 — `.gitignore`

Abschnitt 4 verlangt, `.agents/` zu ignorieren, `.agents/hooks/` aber nicht.
So ist das nicht ausdrückbar: Git steigt in ein ausgeschlossenes Verzeichnis
nicht hinab, eine Rückausnahme darunter greift nie. Wörtlich umgesetzt wären
die Guards **nicht versioniert** — ein frischer Klon hätte keine Guards, und
die Hooks zeigten ins Leere, was nicht blockiert. Umgesetzt als `/.agents/*`
plus `!/.agents/hooks/`.

---

## C. Was nicht erfüllt werden konnte

### C1 — Branch-Schutz für `main` (Abnahmepunkt 8) — nachträglich gelöst

Das Konzept nennt ihn »Pflicht, nicht optional«. Auf privaten Repositories dieses
Kontos ist er nicht verfügbar:
`gh api repos/.../branches/main/protection` antwortete mit HTTP 403 »Upgrade to
GitHub Pro or make this repository public to enable this feature«.

Gelöst, indem `Anjo1566/agent-loop` **öffentlich** angelegt wurde. Der Schutz ist
mit Pflicht zum Pull Request und `enforce_admins` aktiv; ein direkter Push auf
`main` wird von GitHub mit `GH006 — Changes must be made through a pull request`
abgewiesen, auch für den Eigentümer. Beleg in ABNAHME.md, Punkt 8.

Wer das Repository privat braucht, hat weiterhin nur die Wahl zwischen GitHub Pro
und dem bewussten Verzicht — und dann ist `guard-bash.sh` die einzige Sperre
gegen einen Push auf `main`, die das Konzept selbst ausdrücklich für
unzureichend erklärt.

### C2 — Repository-gebundenes Token

Das hinterlegte `gh`-Token hat den Scope `repo`, also Schreibrecht auf alle 17
Repositories des Kontos. Das Konzept verlangt ein Token, das nur auf dieses eine
Repository schreiben darf. Abhilfe: ein fine-grained PAT nur für `agent-loop`,
im Container als `GH_TOKEN` gesetzt.

### C3 — Der Container ist ungetestet

`.devcontainer/` ist mitgeliefert, weil Abschnitt 3 einen Container mit
Default-Deny-Egress als Voraussetzung nennt und Abschnitt 10.9 die
Containergrenze »die eigentliche Sicherheitsgrenze« nennt. Docker Desktop ist
auf diesem Rechner installiert, der Daemon lief bei der Umsetzung aber nicht —
das Image wurde **nicht gebaut und nicht gestartet**. `init-firewall.sh` prüft
sich am Ende selbst (example.com muss blockiert, api.github.com erreichbar
sein); dieser Selbsttest ist der Beleg, den der erste echte Start liefert.

Zwei Punkte, die dort zuerst auffallen werden: Claude Code verweigert
`--dangerously-skip-permissions` als root ausserhalb einer erkannten Sandbox —
deshalb läuft der Container als Benutzer `node`. Und ein frisch geklontes
Verzeichnis hat keinen Trust-Eintrag in `~/.claude.json`; dann wird der
zusätzliche Hook aus dem `coder`-Frontmatter übersprungen. Die Hooks aus
`.claude/settings.json` laufen unabhängig davon — deshalb sind sie hier die
tragende Schicht und das Frontmatter nur die zweite. `loop.sh` weist beim Start
darauf hin.

### C4 — Kein Zielprojekt vorgegeben

Das Konzept nennt kein Repository. Kein bestehendes Projekt des Nutzers war
geeignet (nur drei haben einen Remote, keines davon einen sauberen Branch mit
lauffähiger Testsuite). Deshalb ist dieses Repository selbst das Ziel: es
enthält ein kleines, echtes Beispielprojekt (`src/tasklist.js` plus Tests), an
dem der Loop arbeiten kann. `TESTBEFEHL` und `TESTZAEHLER` sind darauf gesetzt.
Zum Umhängen auf ein anderes Projekt siehe README.

---

## D. Kleinere Korrekturen

- **`node --test test/` ist kaputt** in Node 22.16: das Verzeichnis wird als
  Modul geladen, der Lauf meldet dauerhaft einen fehlschlagenden Test. Der
  Testbefehl ist deshalb das blosse `node --test`.
- **Der Zähler liest `# tests N`, nicht `# pass N`.** Sonst sinkt die Zahl bei
  jedem roten Lauf, und die Bremse »Testanzahl gesunken« schlüge falsch an,
  statt die Reparaturrunde greifen zu lassen. Er endet immer mit 0, sonst
  liefert `$(... || echo 0)` zwei Zeilen und der Vergleich sprengt den Lauf.
- **`.agents/hooks/count-tests.sh`** liegt im Hook-Verzeichnis, obwohl es kein
  Hook ist: nur dieses Verzeichnis unterhalb von `.agents/` wird versioniert,
  und der Selbstschutz macht alles darin für den Agenten unveränderbar. Ein
  Zähler, den der Agent umschreiben kann, ist als Wächter wertlos.
- **deny-Liste erweitert** um `loop.sh`, `round.md`, `.mcp.json`,
  `.gitattributes` und `~/.claude/**`. Unter `bypassPermissions` werden Schreib-
  zugriffe ausserhalb des Arbeitsverzeichnisses zu »ask« und damit automatisch
  erlaubt; ein Agent, der `round.md` umschreibt, ändert seine eigenen
  Anweisungen für die nächste Runde. Nicht ergänzt wurden `Write(...)`-Regeln:
  `Edit(...)` deckt Write, MultiEdit und NotebookEdit bereits ab, und eine
  `Write(...)`-Pfadregel wird von Claude Code angenommen, aber nie ausgewertet.
- **`--allowedTools` bleibt drin, wirkt aber nicht.** Der Schalter genehmigt
  nur vorab, er schränkt nicht ein; unter `--dangerously-skip-permissions` ist
  er wirkungslos. Wer den Chef wirklich einschränken will, braucht `--tools`.
  Als Absichtserklärung im Skript ist er stehengeblieben.
- **`--verbose` und `--bare` sind verboten** und im Skript kommentiert:
  `--verbose` macht aus der JSON-Ausgabe ein Array und bricht jeden `jq`-Zugriff;
  `--bare` schaltet Hooks, Subagents und `CLAUDE.md` ab, also genau die
  Schutzmechanismen — und benutzt das Abo-Login nicht.
- **Abschnitt 4 ist an einer Stelle zu stark formuliert:** Subagent-Dateien
  werden in 2.1.263 von einem Dateiwächter überwacht, nicht nur beim
  Sitzungsstart geladen. Für diesen Loop ist das folgenlos, weil jede Runde ein
  frischer Prozess ist — aber »lädt nie neu« ist keine Sicherheitseigenschaft,
  auf die man bauen sollte.
- **Der Chef kann die Modellwahl der Subagenten überstimmen**, indem er beim
  `Agent`-Aufruf ein `model` mitgibt; die Frontmatter-Angabe verliert dann. Wer
  `coder` und `reviewer` hart auf Sonnet nageln will, setzt
  `CLAUDE_CODE_SUBAGENT_MODEL=sonnet` **und**
  `CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1`, statt beide zu leeren — dann gilt aber
  auch keine Frontmatter-Angabe mehr. Hier ist es beim Leeren geblieben, wie im
  Konzept.
