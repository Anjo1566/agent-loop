# agent-loop

Ein Repository, das sich selbst weiterentwickelt. Drei Rollen, eine Schleife im
Terminal, ein Pull Request am Ende. Du greifst genau einmal ein: du prüfst den
Pull Request.

Umsetzung von `konzept.md`. Was davon abweicht und warum, steht vollständig in
[ABWEICHUNGEN.md](ABWEICHUNGEN.md); die acht Abnahmepunkte mit ihren Belegen in
[ABNAHME.md](ABNAHME.md) — alle acht erfüllt.

| Rolle | technisch | Aufgabe |
|---|---|---|
| Chef | die Hauptsession von `claude -p` | wählt Aufgabe, delegiert, entscheidet, protokolliert, committet |
| Coder | Subagent `coder` | setzt genau eine Aufgabe um |
| Reviewer | Subagent `reviewer` | prüft die Änderung, ändert selbst nichts |

## Der schnellste Weg

```bash
./loop.sh 3      # drei Runden, dann Pull Request
```

Fang mit drei Runden an, sieh unter Settings > Usage nach, was das gekostet hat,
und dreh erst dann hoch. Der Verbrauch pro Lauf lässt sich nicht vorhersagen,
und der Loop zieht aus demselben Kontingent wie dein normales Arbeiten in Claude
Code und im Chat.

`loop.sh` bricht ab, bevor es einen Branch anlegt, wenn etwas fehlt. Die
Meldung sagt jeweils, was.

## Voraussetzungen

- `jq`, `gh`, `git`, `node` ≥ 20, `claude`
- `gh auth login`
- ein sauberes Arbeitsverzeichnis auf `main`
- **Branch-Schutz für `main`** — hier aktiv, mit Pflicht zum Pull Request und
  `enforce_admins`. Das ist der Grund, warum dieses Repository öffentlich ist:
  privat verlangt GitHub dafür Pro. Ohne Branch-Schutz hängt der Schutz von
  `main` allein an `guard-bash.sh`, und die ist umgehbar.
  Zurücknehmen: `gh api -X DELETE repos/<owner>/<repo>/branches/main/protection/enforce_admins`

Auf Windows läuft alles direkt in der Git Bash; Claude Code führt auch die Hooks
darüber aus. Der Container in `.devcontainer/` ist die eigentlich vorgesehene
Umgebung — er kappt den Netzzugang bis auf Anthropic, GitHub und npm. Er ist
mitgeliefert, aber ungetestet (Docker Desktop lief hier nicht).

## Was du kontrollierst

Oben in `loop.sh`:

```bash
TESTBEFEHL="node --test"                      # muss bei Fehlschlag != 0 liefern
TESTZAEHLER="./.agents/hooks/count-tests.sh"  # gibt die Anzahl Tests als Zahl aus
MAX_TURNS=200          # harter Deckel pro Runde
MAX_OPUS_RUNDEN=5      # so viele Eskalationsrunden auf Opus pro Lauf
MAX_BUDGET_USD=15      # dritte Notbremse pro Runde
MAX_LEERRUNDEN=2       # so viele Runden ohne Codeänderung, dann Abbruch
```

Und `TASKS.md` — das ist der eigentliche Auftrag. Eine Zeile pro Aufgabe,
`- [ ] Beschreibung`, wichtigste oben.

## Wie eine Runde abläuft

1. `loop.sh` liest `.agents/next-round.json`, prüft Modell und Aufwandsstufe
   gegen eine Whitelist und startet `claude -p`.
2. Der Chef liest `TASKS.md` und `STATUS.md` und wählt **eine** Aufgabe.
   Blocker aus dem letzten Review haben Vorrang.
3. Er delegiert an `coder`, gibt das Ergebnis an `reviewer`.
4. Er trägt Befunde oben in `TASKS.md` ein, schreibt `STATUS.md` und
   `.agents/next-round.json`, und committet.
5. **Das Skript** führt danach die Tests aus und zählt sie. Nicht der Agent —
   ein Agent, dessen Belohnung »grüne Tests« ist, lernt sonst, Tests zu
   schwächen statt Code zu reparieren.
6. Ist die Suite rot, kommt genau eine Reparaturrunde. Bleibt sie rot: Abbruch.

Der Zustand lebt auf der Platte, nicht im Kontext. Jede Runde ist eine frische
Session ohne Erinnerung; der Chef rekonstruiert seinen Stand aus `TASKS.md`,
`STATUS.md`, `QUESTIONS.md` und der Git-Historie. Deshalb kann ein Lauf beliebig
lange dauern, ohne dass ein Kontextfenster überläuft.

## Wann er aufhört

| Bedingung | Wirkung |
|---|---|
| `.agents/STOP` existiert | Auftrag erledigt, sauberes Ende |
| Runde ohne neuen Commit | Stillstand |
| zwei Runden ohne Codeänderung | der Agent dreht im Kreis |
| Testsuite rot | eine Reparaturrunde, danach Abbruch |
| Testanzahl gesunken | Verdacht auf gelöschte oder geskippte Tests |
| Rundenlimit erreicht | Abbruch |
| `claude` endet mit Fehler, Turn-Deckel oder Budget-Deckel | Abbruch |

Jeder Lauf endet mit einem Pull Request, auch ein abgebrochener. Der
Abbruchgrund steht oben in der Beschreibung — sonst siehst du nicht, woran er
gescheitert ist.

## Die Guards

Sobald die Testsuite das einzige Erfolgssignal ist, optimiert ein Agent auf
»Tests grün« statt auf »Aufgabe erfüllt«. Die Gegenmassnahmen sind mechanisch,
nicht sprachlich — Prompts sind Bitten, Hooks sind Gesetze.

| Was gesperrt ist | Wo |
|---|---|
| bestehende Tests, Snapshots, Fixtures ändern | `guard-files.sh` + `guard-bash.sh` |
| Lockfiles, Abhängigkeiten, CI-Konfiguration | dieselben |
| `.claude/`, `CLAUDE.md`, `loop.sh`, `round.md`, die Guards selbst | dieselben |
| Geheimnisse lesen oder schreiben | Hook **und** `permissions.deny`, doppelt |
| `--no-verify`, `git stash/clean/restore/reset --hard`, Push auf `main`, Force-Push | `guard-bash.sh` |
| Tests laufen im Skript, der Rückgabewert entscheidet | `loop.sh` |
| Testanzahl darf nicht sinken | `loop.sh` |

Eine neue Testdatei **anzulegen** ist erlaubt — nur eine bestehende zu ändern
nicht. Braucht der Coder legitim eine Teständerung oder eine neue Abhängigkeit,
ist das ein Fall für `QUESTIONS.md`: er notiert seine Empfehlung und
überspringt die Aufgabe.

`test/guards.test.js` prüft all das bei jedem Testlauf — 17 Fälle, inklusive
der Umgehungswege. Die Guards sind das Einzige, was den Loop davon abhält,
seinen eigenen Erfolg zu fälschen; ein Guard, der still aufhört zu wirken, sieht
von aussen aus wie ein Guard, der wirkt. Deshalb prüft `loop.sh` vor der ersten
Runde zusätzlich mit einem fingierten Payload nach, dass beide Guards wirklich
Exit 2 liefern — ein fehlendes oder stumpfes Skript blockiert **nicht**, es
läuft nur ins Leere.

## Prüfen, ohne Kontingent zu verbrennen

```bash
node --test     # 24 Tests, davon 17 fuer die Guards
./abnahme.sh    # 34 Pruefungen der Schleifenlogik gegen einen claude-Stub
```

`abnahme.sh` ersetzt `claude` durch einen Stub, der genau das Verhalten
nachspielt, das die jeweilige Bedingung provozieren soll: rote Suite,
gelöschte Tests, Stillstand, Müll in `next-round.json`, aufgebrauchte
Opus-Eskalationen. Läuft in ein paar Minuten durch und kostet nichts. Nach
jeder Änderung an `loop.sh` einmal laufen lassen.

## Auf ein anderes Projekt umhängen

1. Diese Dateien ins Zielrepo kopieren: `CLAUDE.md`, `round.md`, `loop.sh`,
   `TASKS.md`, `STATUS.md`, `QUESTIONS.md`, `.gitattributes`, `.gitignore`,
   `.agents/hooks/`, `.claude/`.
2. `TESTBEFEHL` und `TESTZAEHLER` oben in `loop.sh` anpassen. Der Zähler muss
   **immer** eine Zahl ausgeben und **immer** mit 0 enden, auch bei roter Suite.
   `.agents/hooks/count-tests.sh` als Vorlage nehmen.
3. Testpfade in `.agents/hooks/protected-paths.sh` prüfen, falls das Projekt
   eine ungewöhnliche Struktur hat.
4. `TASKS.md` mit dem echten Auftrag füllen.
5. `./loop.sh 1` als Trockenlauf.

`src/tasklist.js` und seine Tests sind nur das Beispielprojekt, an dem der Loop
hier arbeitet — die kannst du weglassen. `test/guards.test.js` und `abnahme.sh`
solltest du mitnehmen; beide hängen nicht am Beispielprojekt.

## Was hier bewusst fehlt

Kein Explorer (Claude Code bringt `Explore` mit), kein Planner (der Chef plant),
kein Dokumentierer (macht der Coder), kein eigener Security-Reviewer (steht als
Checkliste im `reviewer`-Prompt), kein Integrator (ein Branch, sequentiell).

Ein `verifier`, der die »erledigt«-Behauptung des Coders gegen Diff und
Testausgabe prüft, kommt erst dazu, wenn du im Log siehst, dass Runden als
erledigt gemeldet werden, die es nicht sind. Solange das Skript die Tests selbst
ausführt, ist der grösste Teil dieser Prüfung schon mechanisch abgedeckt.
