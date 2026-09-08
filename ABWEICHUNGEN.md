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

---

## E. Was ein adversariales Review danach noch fand

Die Fassung aus den Abschnitten A bis D wurde anschliessend von unabhängigen
Prüfern angegriffen, mit der Aufgabe, die Guards zu brechen. Sie fanden
sechzehn Punkte, alle mit reproduzierbarem Befehl, alle nachgestellt und
behoben. `test/guards-regression.test.js` hält jeden einzelnen fest — sie sind
im Betrieb unsichtbar, und ein Guard, der aufgehört hat zu wirken, sieht von
aussen aus wie einer, der wirkt.

### E1 — Ein vorangestelltes `bash -c` schaltete die halbe Prüfung ab

Die linke Wortgrenze der schreibenden Befehle war
`(^|[;&|[:space:]])` — ohne Anführungszeichen und ohne Klammern. Damit traf
`bash -c "sed -i 1d test/x.test.js"` kein einziges Muster, und der gesamte
Pfadcheck wurde übersprungen. Dasselbe für `sh -c '...'`, `(sed ...)` und
`"sed" ...`. Die rechte Wortgrenze hatte denselben Fehler.
**Änderung:** beide Grenzen enthalten jetzt Anführungszeichen, Klammern und
Backticks.

### E2 — Ein Glob mit einem Zeichen umging jedes am Dateinamen verankerte Muster

`rm loop.s?` und `sed -i 1d loop.s[h]` schreiben loop.sh, treffen aber
`loop\.sh$` nicht, weil der Guard das unexpandierte Token sieht.
**Änderung:** Tokens mit Glob-Zeichen werden zusätzlich expandiert — reine
Dateinamenserweiterung, es wird nichts ausgeführt — und zusätzlich ohne
Glob-Zeichen geprüft, falls die Datei noch nicht existiert. Der Guard sieht
damit, was die Shell sehen wird.

### E3 — `git apply` und `patch` tragen ihr Ziel im Diff

Beide schreiben beliebige Dateien, ohne einen Pfad auf der Kommandozeile zu
nennen. Ein Token-Check kann sie prinzipiell nicht prüfen. Reproduziert: eine
bestehende Testdatei wurde damit in Ort und Stelle abgeschwächt, ohne dass eine
der beiden Bremsen ansprang — Suite grün, Testanzahl unverändert.
**Änderung:** `patch`, `git apply`, `git am`, `git checkout-index` und
`find -delete` / `-exec` werden rundheraus abgelehnt statt analysiert. Der
Coder hat für legitime Änderungen das Edit-Werkzeug.

### E4 — Und weil auch das nie vollständig sein wird: eine Prüfung am Ergebnis

Die drei Befunde oben haben dieselbe Wurzel: ein Hook sieht nur die Absicht,
die in der Kommandozeile steht. Die Aufzählung von Werkzeugen wird deshalb nie
fertig. `loop.sh` prüft jetzt nach jeder Runde am Diff, ob eine **versionierte**
Testdatei geändert, gelöscht oder umbenannt wurde, und bricht dann ab. Das
fängt alle Shell-Wege auf einmal — auch die, die niemand aufgezählt hat.

Damit ist die Rollenverteilung sauber: der Guard ist die schnelle Rückmeldung
ans Modell, das Skript ist die Zusage. Das ist genau Prinzip 4 des Konzepts,
»Das Skript urteilt, nicht der Agent«.

### E5 — Löschen, dann neu schreiben

Die Regel »nur bestehende Testdateien sind gesperrt« hing an `[[ -e "$PFAD" ]]`.
Sobald die Datei weg war, war das Schreiben erlaubt. `find … -delete` kam am
Bash-Guard vorbei, weil `find` nicht auf der Liste stand.
**Änderung:** massgeblich ist jetzt, ob **Git** die Datei kennt
(`git ls-files --error-unmatch`), nicht ob sie auf der Platte liegt. Eine
gelöschte, aber versionierte Datei bleibt gesperrt.

### E6 — Ein Symlink oder eine Windows-Junction hebelte jedes Muster aus

`mklink /J cfg .claude` — und `cfg/settings.json` traf kein Muster mehr,
schrieb aber in `.claude/settings.json`. Genau das Szenario, das
`protected-paths.sh` in seinem eigenen Kommentar nennt.
**Änderung:** `guard-files.sh` kanonisiert den Pfad mit `readlink -f` und prüft
den aufgelösten Pfad zusätzlich. Auf Windows zeigt `readlink` dabei
gelegentlich auf einen anderen Mount-Alias (`/tmp` statt
`/c/Users/…/Temp`), deshalb wird sowohl die gekürzte als auch die ungekürzte
Form geprüft — und Git bekommt weiterhin den projektrelativen Pfad, sonst
ordnet es die Datei dem Repository nicht zu und meldet fälschlich »neu«.

### E7 — Der Pfad wurde gegen das falsche Verzeichnis aufgelöst

`[[ -e "$PFAD" ]]` löste relative Pfade gegen das Arbeitsverzeichnis des
Hook-Prozesses auf. Derselbe Payload wurde aus dem Repositorywurzelverzeichnis
blockiert und aus `src/` durchgelassen — die Regel schaltete sich bei einem
`cd` still ab. Abweichung A7 hatte das für den Hook-**Befehl** korrigiert, für
die Prüfung darin aber nicht.
**Änderung:** relative Pfade werden gegen `$CLAUDE_PROJECT_DIR` aufgelöst.

### E8 — Vier weitere Löcher im Bash-Guard

| Umgehung | vorher | jetzt |
|---|---|---|
| `git push` ohne Refspec, auf `main` stehend | ging durch | blockiert, eine Refspec ist Pflicht |
| `git push origin HEAD` | ging durch | blockiert |
| `git push -fu` (f nicht am Ende des Flag-Bündels) | ging durch | blockiert |
| `npm pkg set`, `npm install`, `yarn add`, `npx` | ging durch, schreibt package.json ungenannt | blockiert |

### E9 — Zwei unbewachte Dateien

`~/.claude.json` war von keiner Schicht geschützt, obwohl `~/.claude/**` es
war: dort stehen die MCP-Server, und ein dort eingetragener Server ist ein
beliebiger Befehl, der in jeder folgenden Runde startet. Und `.devcontainer/`
war frei beschreibbar — also auch `init-firewall.sh`, die Grenze, die das
Konzept die eigentliche Sicherheitsgrenze nennt.
**Änderung:** beide in `MUSTER_SELBST` und in die deny-Liste aufgenommen.

### E10 — Vier Falsch-Positive, die im Betrieb wehgetan hätten

Guards, die zu viel blockieren, kosten Runden und Kontingent, und der Agent
lernt daraus, Umwege zu suchen.

| war blockiert | warum das falsch war |
|---|---|
| `node --test test/x.test.js` | der naheliegendste Schritt beim Eingrenzen eines Fehlschlags; Interpreter galten pauschal als schreibend |
| `grep … 2>/dev/null`, `node --test 2>&1` | jedes `>` galt als Schreibzugriff, auch eine Fehlerkanal-Umleitung |
| `Read` auf `.env.example`, `src/auth/credentials.js` | die Geheimnis-Regel gilt für jedes Werkzeug; damit war ausgerechnet das Auth-Modul unlesbar, das der Reviewer prüfen soll |
| `touch test/neu.test.js` über die Shell | der Datei-Guard erlaubte dieselbe Datei — die beiden Guards widersprachen sich |

**Änderung:** Interpreter zählen nur mit einem Inline- oder In-place-Schalter
als schreibend; nur echte Umleitungsziele zählen, nicht jedes `>`;
Vorlagendateien (`.env.example` und Verwandte) sind ausgenommen und
`credentials` ist auf Konfigurationsendungen eingegrenzt; der Bash-Guard fragt
für neue Testdateien dieselbe Git-Frage wie der Datei-Guard.

### E11 — Die Umzugsanleitung stimmte nicht

Das README nennt eine Liste von Dateien für den Umzug in ein anderes Repository
und sagt, das Beispielprojekt sei entbehrlich. Baut man ein Repository aus genau
dieser Liste, fallen fünf Guard-Tests durch: sie verwiesen auf
`test/tasklist.test.js`, eine Datei des Beispielprojekts.
**Änderung:** die Guard-Tests hängen jetzt an der Testdatei, in der sie stehen —
die reist mit. `abnahme.sh` baut seitdem in jedem Durchlauf ein Repository aus
genau der README-Liste und lässt dort die Guards und die Vorprüfung von
`loop.sh` laufen. Eine Anleitung, die niemand ausführt, ist eine Behauptung.

### E12 — Die Abnahme hing am ausgecheckten Branch

`abnahme.sh` klont das Repository; der Klon übernimmt dabei den Branch, auf dem
das Quell-Repository gerade steht. `loop.sh` verzweigt aber von `main` und
brach mit »Branch main existiert nicht« ab, sobald man die Abnahme von einem
Feature-Branch aus startete — also genau dann, wenn man sie am nötigsten
braucht.
**Änderung:** der Klon setzt `main` auf den geklonten Stand.

---

## F. Zyklus 2 — was das zweite adversariale Review umgestossen hat

Das Review liegt als `REVIEW-1.md` im Wurzelverzeichnis. Es hat `agent-loop` mit
5,5 und `agent-cockpit` mit 6,6 bewertet und das 8,5-Tor ausdrücklich für
gescheitert erklärt. Dieser Abschnitt ist der Umbau danach: jeder Punkt mit dem
Befund, der ihn ausgelöst hat, und mit der Prüfung, die ihn festhält.

Zwei Dinge vorweg, weil sie den Rest einordnen.

**Erstens: das Review hatte an zwei Stellen selbst zu viel behauptet.** Beide
sind unten unter F13 aufgeführt und wurden nicht »behoben«, sondern
richtiggestellt. Ein Umbau, der auch die falschen Befunde umsetzt, macht die
Sache nicht besser, nur teurer.

**Zweitens: der schwerste Befund brauchte keine einzige verbotene Operation.**
Das ist die Lehre dieses Zyklus. Die Guards prüfen die Absicht, die in einer
Kommandozeile steht; sie werden nie fertig. Was fehlte, war die Prüfung am
Ergebnis — dieselbe Antwort, die E4 schon für die Tests gegeben hatte, jetzt
auch für die Schutzdateien selbst.

---

### F1 — Beide Schutzschichten waren aus der Runde heraus abräumbar (Blocker)

**Befund B-1.** `Write` auf `tools/helper.js` ist erlaubt. `node tools/helper.js`
ist erlaubt — in-Repo-Skripte sind bewusst erlaubt, weil sie im Diff stehen. Der
Helfer schreibt dann `.claude/settings.json` und `.agents/hooks/guard-bash.sh`
neu. Kein Hook sieht das: nichts davon geht durch `Edit`, `Write` oder ein
Shell-Wort mit dem Pfad darin. Im Review in einem Klon nachgestellt, mit
Vorher/Nachher-Ausgabe.

Der Rauchtest in `loop.sh` lief **einmal**, vor der ersten Runde. Jede weitere
Runde des Laufs lief danach ohne deny-Liste und ohne Guards.

**Änderung.** `loop.sh` bildet vor der ersten Runde eine `sha256`-Prüfsumme über
alles, was den Lauf schützt, und rechnet sie **vor jeder weiteren Runde** nach.
Zusätzlich wird der Rauchtest jede Runde wiederholt, und der Diff der Runde wird
gegen `MUSTER_SELBST` und `MUSTER_DEPS` geprüft — die Prüfsumme fängt, was auf
der Platte liegen bleibt, der Diff benennt, was mitcommittet wurde.

Damit ist der Weg nicht verschlossen, sondern folgenlos: die Runde, in der er
benutzt wird, ist die letzte, und der Grund steht im Pull Request. Das ist die
einzige Zusage, die ein Hook-System dieser Bauart überhaupt geben kann.

Belegt in `abnahme.sh` mit drei Szenarien (ABNAHME Punkt 9), darunter der Fall
ohne Commit, den nur die Prüfsumme sieht.

### F2 — PowerShell war unbewacht, obwohl der Matcher sie führt (Major)

**Befund M-1.** `settings.json` matcht seit A8 auf `Bash|PowerShell`; das Review
hat direkt geprüft, dass der Hook bei einem PowerShell-Aufruf feuert. Das Skript
kannte aber kein einziges PowerShell-Verb. `Set-Content .claude/settings.json`,
`Remove-Item -Recurse -Force .agents/hooks`, `Clear-Content loop.sh` und
`[IO.File]::WriteAllText('loop.sh','')` gaben alle 0 zurück — auf Windows ein
zweiter vollständiger Weg zu F1, ohne Helferdatei und ohne Spur im Diff.

**Änderung.** `SCHREIBEND_PS` mit den Schreibverben und der .NET-Datei-API.
Neun Fälle in `test/guards-cycle2.test.js`.

### F3 — Die Befehlsworte waren case-sensitiv, NTFS ist es nicht (Major)

**Befund M-2.** `type -a SED` liefert auf diesem Rechner `/usr/bin/SED`.
`SED --in-place 1d test/guards.test.js` hat im Review eine verfolgte Testdatei
geändert, während der Guard 0 zurückgab.

**Änderung.** Alle Befehlswortmuster laufen über `im_befehl_i`. Die
**Schalter**muster ausdrücklich nicht: `-e` ist Code, `-E` ist erweiterte
Regex. Diese Unterscheidung ist beim Umbau einmal verlorengegangen, und sofort
war ein völlig gewöhnliches `node --test | grep -E …` blockiert. Der Kommentar
im Skript sagt jetzt, warum die eine Hälfte case-insensitiv ist und die andere
nicht.

### F4 — `sed --in-place` und `bash.exe` (Major)

**Befunde M-3 und M-4.** Das Muster für den In-place-Schalter suchte `(c|e)`
direkt vor Leerzeichen oder `=`; in `--in-place` steht das `e` mitten im Wort.
Und die rechte Wortgrenze endet nicht auf einem Punkt, also traf `bash.exe
/tmp/evil.sh` kein Interpretermuster — die Regel »kein Skript von ausserhalb des
Projekts« war auf der dokumentierten Plattform aus.

**Änderung.** Lange Schreibweisen im Schaltermuster, `${EXE}` in jeder
Interpreterliste. Beim Arbeiten fiel die dritte Variante derselben Lücke auf:
`C:\Program Files\nodejs\node.exe skript.js` traf ebenfalls nichts, weil der
Backslash nicht in der linken Wortgrenze war. Auch das ist behoben.

### F5 — Werkzeuge, deren Ziele nicht im Befehl stehen (Major)

**Befund M-8.** `patch` und `git apply` werden rundheraus abgelehnt, weil der
Guard ihre Pfade nicht sieht. `tar -xf`, `unzip -o`, `cpio -i` und
`xargs -a liste rm` tun dasselbe und standen in keinem Muster. `awk` mit einem
berechneten Umleitungsziel ebenfalls.

**Änderung.** Dieselbe Ablehnung, dieselbe Begründung. `tar -c` bleibt erlaubt:
geprüft wird auf einen Auspack-Schalter, und `--exclude` trifft ihn nicht.

### F6 — `git checkout -f` und Verwandte (Major)

**Befund M-9.** Die Regel gegen »Arbeit wegwerfen« kannte `stash`, `clean`,
`restore`, `reset --hard` und `checkout -- <datei>`, aber nicht `checkout -f`,
`switch -f` oder `switch --discard-changes`.

**Änderung.** Ergänzt. Und in die andere Richtung entschärft: das alte Muster
verlangte hinter dem Ref nur die Zeichen `--`, und die stehen am Anfang jeder
langen Option — `git checkout main --quiet`, ein blosser Branchwechsel, war
blockiert. `--` muss jetzt ein eigenes Wort sein.

### F7 — Der Testbefehl hatte keine Zeitgrenze (Major)

**Befund M-5.** Der Wachhund bewacht die Sitzung und wird beendet, sobald `wait`
zurückkommt. Der Testbefehl läuft **danach** — und führt Code aus, den der Agent
selbst geschrieben hat. Eine neue Testdatei anzulegen ist ausdrücklich erlaubt;
eine, die synchron dreht, hängte `node --test` unbegrenzt. Im Review gemessen:
nach 75 s lief sie noch.

Das ist genau die Havarie, für die der Wachhund geschrieben wurde — vier Stunden
an einem toten Kind —, achtzig Zeilen weiter unten wieder offen.

**Änderung.** `mit_zeitgrenze` (ohne Abhängigkeit von `timeout`, mit demselben
`toete_baum` wie der Wachhund) um `TESTBEFEHL` und `TESTZAEHLER`, gesteuert über
das neue `MAX_TEST`. Rückgabewert 124 unterscheidet den Abbruch von einer roten
Suite.

Dieser Befund hat sich während des Umbaus selbst noch einmal bewiesen: die
Abnahme lief in genau dieses Szenario und blieb hängen, weil der Klon (siehe
F11) noch das alte `loop.sh` ohne `MAX_TEST` hatte.

### F8 — Die Note war eine Selbstauskunft (Major)

**Befund M-6.** `.agents/grade.json` schreibt der Chef selbst, und
`protected-paths.sh` schützt nur `.agents` und `.agents/hooks`. Die
Abbruchbedingung des ganzen Laufs — »Zielnote erreicht« — hing an einer Datei,
die das bewertete Modell schreibt. `CLAUDE.md` behauptete dabei ausdrücklich,
das Skript entscheide.

**Änderung.** `loop.sh` liest die Note aus dem Ereignisstrom der Runde: erst die
`tool_use_id` jedes Subagenten vom Typ `grader` (`system/task_started`), dann das
`tool_result` mit genau dieser id. Beides schreibt die CLI, nicht das Modell.
`grade.json` bleibt als Ablage für das Cockpit; weicht sie ab, wird das benannt
und die Zahl aus dem Strom gewertet.

`CLAUDE.md` und `round.md` sagen jetzt, wie es wirklich funktioniert. Drei
Szenarien in `abnahme.sh` (ABNAHME Punkt 10).

### F9 — Zwei Läufe im selben Arbeitsverzeichnis (Major)

**Befund M-14.** `loop.sh` hatte keine Sperre. Die Sauberkeitsprüfung läuft
**vor** dem Branchwechsel, und ein regelkonformer Lauf hat zwischen zwei Runden
immer alles committet — der zweite Lauf sähe also einen sauberen Baum, führte
`git switch main` aus und zöge dem ersten den Checkout weg. Dessen nächster
Commit landete auf `main`.

**Änderung.** `.agents/loop-laeuft.pid`, geprüft in der Vorprüfung, aufgeräumt
per `trap`. Eine Leiche blockiert nicht, sie wird gemeldet und überschrieben.
Ausserdem bekommen zwei Läufe in derselben Minute nicht mehr denselben
Branchnamen; vorher endete der zweite mit `git`s Rohmeldung, nachdem der
Checkout schon auf `main` stand.

### F10 — Die Guards veralten still in kopierten Projekten (Major)

**Befund M-7**, und der einzige, der schon einen Schaden angerichtet hatte:
`agent-cockpit` lief acht echte Runden mit einer Guard-Fassung, die 10 von 15
gefährlichen Nutzlasten durchliess — darunter `rm -rf .agents/hooks`, nach dem
jeder Hook-Aufruf 127 liefert, und 127 blockiert **nicht**. Von aussen war das
nicht von einem gesunden Projekt zu unterscheiden.

**Änderung, in drei Teilen:**

1. `protected-paths.sh` trägt `SCHUTZ_VERSION`. `loop.sh` kennt die Fassung, die
   es braucht, und verweigert den Start bei Rückstand.
2. Das Cockpit zeigt die Fassung je Projekt in der Projektliste und markiert
   Rückstände.
3. Das Cockpit kann sie nachziehen (`projekte.aktualisiere`). Der Loop war
   vorher eine Einbahnstrasse: einrichten ja, aktualisieren nein.

`agent-cockpit` ist damit von Fassung 0 auf 2 gebracht; dieselben 15 Nutzlasten
werden dort jetzt alle blockiert. Gemessen, beide Fassungen, vorher/nachher.

### F11 — Die Abnahme prüfte den letzten Commit, nicht den Arbeitsstand

Nicht aus dem Review, sondern beim Umbau aufgefallen und schwerer als das meiste
darin: `git clone` von einem lokalen Pfad nimmt den HEAD-Commit. `abnahme.sh`
prüfte damit die zuletzt committete Fassung von `loop.sh`, während das README
sagt »nach jeder Änderung an `loop.sh` einmal laufen lassen«. Genau im Moment,
in dem man sie braucht, prüfte sie das Falsche.

**Änderung.** Jeder Szenarienklon bekommt die Arbeitsstände aller verfolgten
Dateien kopiert und committet.

### F12 — Die Abnahme lief zweieinhalb Stunden statt »ein paar Minuten«

**Befund M-11.** Das README versprach »ein paar Minuten«; gemessen waren es über
zweieinhalb Stunden, und niemand lässt so etwas nach jeder Änderung laufen. Die
Ursache: 55 Guard-Fälle, jeder ein eigener `bash`-Prozess, zusammen 165 s — und
`loop.sh` fährt die Suite einmal vor dem Lauf und einmal je Runde, über 19
Szenarien.

**Änderung, zwei Teile:**

1. Die Szenarienklone lassen die Guard-Tests weg. Sie prüfen die Guards, nicht
   die Schleifenlogik. Bewiesen bleiben die Guards zweimal: `node --test` im
   echten Repository und das Umzugs-Szenario, das ein fremdes Repository aus der
   README-Liste baut und sie dort noch einmal fährt.
2. `count-tests.sh` liest die Testanzahl aus `.agents/testrun.txt` — der
   TAP-Ausgabe des Laufs, den `loop.sh` in derselben Runde ohnehin schon gemacht
   hat — statt die Suite ein zweites Mal zu fahren. Es misst nach, wenn unter
   `test/` etwas jünger ist als diese Datei.

Damit halbiert sich auch die Wartezeit jeder echten Runde. `abnahme.sh` gibt
seine Laufzeit jetzt selbst aus, und in ABNAHME.md steht die gemessene Zahl.

### F13 — Zwei Befunde des Reviews waren falsch, einer war unvollständig

Der Umbau setzt nicht um, was nicht stimmt. Alle drei stehen hier, weil ein
stillschweigend übergangener Befund vom nächsten Review wieder gefunden wird.

**Falsch, B1 »Der GESPERRT-Tafel überlappt den CODER-Knoten bei 1280 px«.** Die
Zeichnung liegt in einem SVG mit `viewBox` und `preserveAspectRatio`; sie
skaliert gleichförmig, eine breitenabhängige Kollision kann es dort gar nicht
geben. Nachgemessen: Tafel endet bei y≈430, der Knoten beginnt bei y≈462. Keine
Überlappung, bei keiner Breite.

**Falsch, B1 »Der Ereignisstrom schneidet die Guard-Meldung mitten im Wort
ab«.** Das war ein Artefakt der Aufnahme: der Screenshot lief mit angehaltener
virtueller Zeit, und die Aufdeck-Animation war mittendrin eingefroren. Mit
`--force-prefers-reduced-motion` steht der Text vollständig da und bricht um.

**Unvollständig, B1 »Ereigniszeilen ohne Text«.** Dieselbe Aufnahme, aber hier
lag ein echter Fehler dahinter: der Ruhezustand von `.zeile .inhalt` war
`clip-path: inset(0 100% 0 0)` — also unsichtbar —, und nur eine Animation, die
wirklich durchläuft, holte den Inhalt zurück. Fällt sie aus, bleibt die Zeile
für immer leer. Die Animationen laufen jetzt **von** unsichtbar **nach**
sichtbar, ohne `forwards`; der Ruhezustand ist der sichtbare. Dasselbe für die
Blätter, die Taktbalken und das Raster.

Und einer, den das Review benannt, aber falsch gelöst hat: **`node --run` gehört
nicht auf die Sperrliste.** `npm exec` und `pnpm dlx` laden ein fremdes Paket und
sind damit `npx` unter anderem Namen — gesperrt. `node --run` und `npm test`
führen aus, was in `package.json` steht, und `package.json` ist für den Agenten
unveränderbar. Sie zu sperren hätte nur den Testlauf des Coders zerschlagen.

Ebenso **die Pflicht zur Freigabe auf `main`** (Befund M-10): auf einem
Ein-Personen-Konto kann niemand den eigenen Pull Request freigeben, der Besitzer
hätte sich ausgesperrt. Was stattdessen geht, ist eine Pflicht zur grünen Suite;
`.github/workflows/tests.yml` liegt bei, der Befehl zum Scharfschalten steht als
Kommentar darin, und ABNAHME.md sagt ausdrücklich, dass der Workflow auf diesem
Rechner nie gelaufen ist.

### F14 — Falschmeldungen, die im Betrieb Runden gekostet haben

**Befund M-13**, und der einzige mit Vorfällen aus dem echten Betrieb: drei
Einträge in `agent-cockpit/QUESTIONS.md`, zweimal musste eine Commit-Botschaft
umformuliert werden. `SCHREIBT` wurde gesetzt, sobald irgendwo ein englisches
Wort aus der Liste stand — auch mitten in einem Satz in Anführungszeichen — und
dann genügte ein `$` irgendwo in der Zeile für eine Absage.

**Änderung.** Die Zeile wird in einfache Befehle zerlegt, an Shell-Operatoren
**und** an Anführungszeichen, und die Frage »ist das Ziel berechnet?« nur für
die Glieder gestellt, die mit einem Schreibwort **anfangen**. Hinter einem
Anführungszeichen steht entweder ein eingebetteter Befehl (`bash -c "sed -i …"`,
`"sed" -i …`) — und der steht dann ganz vorn — oder Prosa, und die fängt nicht
mit `rm` an.

Die Regel selbst bleibt scharf: `sed -i 1d ${TEST}` und `rm $(cat liste)` sind
weiter gesperrt. Fünf Fälle in jede Richtung in `test/guards-cycle2.test.js`.

### F15 — Der Reviewer hatte keinen Grund, etwas zu finden

**Befund A4.** In der beobachteten Runde 8 meldete der Reviewer »PASS, no
blockers« auf einem Repository, das der grader unmittelbar danach mit 6,8 und
sechs benannten Mängeln bewertete.

**Änderung.** `reviewer.md` bekommt drei Dinge, die es vorher nicht hatte: es
liest zuerst den Diff (nicht die Zusammenfassung des Coders), es bekommt seine
eigenen Befunde der letzten Runde zurück und muss zu jedem sagen, was daraus
geworden ist, und es muss einen neuen Test aktiv zum Scheitern zu bringen
versuchen. Ein »NO FINDINGS« muss ausserdem in einer Zeile sagen, was am
härtesten geprüft wurde — damit die nächste Runde weiss, wo nicht hingesehen
wurde. `round.md` gibt ihm den Commit-Bereich und die alten Befunde mit.

### F16 — Grenzen, die nicht greifen konnten

**Befund A2.** `MAX_TURNS=200` und `MAX_BUDGET_USD=15` gegen elf gemessene echte
Runden, deren teuerste 31 Turns und 2,56 USD brauchte: beide »Notbremsen«
konnten gar nicht auslösen, bevor eine andere zuschlug.

**Änderung.** 60 und 4 — etwa das Doppelte des gemessenen Maximums. Die Zahlen
und ihre Herkunft stehen als Kommentar in `loop.sh` und in ABNAHME.md.

Ausserdem prüft `loop.sh` die Suite jetzt **vor** dem Lauf und verweigert den
Start auf roter Ausgangslage: die Reparaturrunde repariert dort etwas, das der
Agent nicht verursacht hat, und verbrennt dafür ein Kontingent.

### F17 — Das Cockpit

Aus demselben Review, kurz:

- **`Origin: null` wurde durchgelassen** (M-15). Ein Sandbox-Iframe hat einen
  undurchsichtigen Ursprung und schickt genau das; zusammen mit einem Formular
  mit `enctype="text/plain"` war das ein vollständiger Weg von einer beliebigen
  Webseite zu `/api/tasks` und `/api/start`. Die Zusicherung im Test stand
  falsch herum und ist ersetzt.
- **Zu grosse Rümpfe rissen die Verbindung ab** (M-16). `anfrage.destroy()`
  zerstört in Node immer den Socket, und Anfrage und Antwort teilen sich diesen
  einen — der Aufrufer bekam ECONNRESET statt der 400. Auch hier stand die
  Zusicherung falsch herum (sie verlangte den `destroy()`-Aufruf) und ist durch
  die strengere ersetzt: der Socket darf **nicht** abgerissen werden. Die
  Meldung nennt jetzt die Grenze.
- **Kein Verlauf der Note** (C-1). `notenband` wurde gesammelt und nirgends
  gezeichnet. Jetzt steht es als Treppe über dem Rundenband, mit der Zielnote
  als gestrichelter Linie — die einzige Ansicht, die sagt, ob ein Lauf
  irgendwohin kommt. Der Probelauf (`?probe=1`) zeigt es mit.
- **Kein Wiederanhängen** (C-4). Ein neu gestartetes Cockpit zeigte »BEREIT«,
  während im Projekt eine Runde lief. Jetzt hängt es sich an — an den eigenen
  Merker oder an `loop.sh`s Sperre — und sagt dabei, dass ihm der Anfang fehlt.
- **Der Ereigniszähler zählte DOM-Knoten** (m-1) und blieb ab der 220. Zeile
  stehen. Jetzt zählt er Ereignisse.
- **Kontrast** (B1). `--text-ghost` lag bei 2,0:1, `--text-low` bei 3,5:1 — beides
  Fliesstext. Jetzt 4,6:1 und 5,6:1.
- **`sonnet · high` passte nicht in seine Zelle** (B1). Eigene Laufweite.
- **Ein offener Dateideskriptor je Lesefehler** (m-2), alle 180 ms. `try/finally`.

### F18 — Was nicht geändert wurde

- **Der Container** ist weiterhin nicht gebaut. Ohne ihn bleibt die
  Sicherheitsgrenze das, was F1 daraus macht: nicht »unmöglich«, sondern
  »folgenlos und benannt«. ABNAHME.md sagt das unverändert.
- **`--allowedTools`** bleibt wirkungslos im Skript stehen, als
  Absichtserklärung. Unverändert seit Abschnitt D.
- **`installiere()` committet mit `--no-verify`** (m-3). Das ist die
  Einrichtung, die der Nutzer selbst auslöst, nicht der Agent; ein pre-commit
  hook des Zielprojekts würde hier über Dateien laufen, die es noch gar nicht
  kennt. Bewusst so gelassen, jetzt mit Kommentar.
- **`git bundle`, `git daemon`, `git send-email`, `git credential`** sind neu
  gesperrt, `git revert`, `git rebase` und `git cherry-pick` nicht: sie schreiben
  Commits, und Commits sieht der Diff der Runde. Die Bremsen greifen dort.
