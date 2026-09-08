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

# --- Der Befehl in drei Fassungen ---------------------------------------
#
# 1. $BEFEHL          — roh. Nur hier stehen Umleitungen (`>`) so, wie die
#                       Shell sie sieht.
# 2. $OHNE_BOTSCHAFT  — ohne Commit-Botschaften. Der Text hinter `-m` ist Prosa
#                       und schreibt nichts; ihn mitzuprüfen erzeugte reine
#                       Fehlalarme (`git commit -m "install .gitattributes
#                       merge helper"` war blockiert, ebenso jede Botschaft, in
#                       der das Wort für "Datenträger formatieren" vorkam).
#                       Beide Fälle sind im Betrieb aufgetreten und stehen in
#                       QUESTIONS.md.
# 3. $PRUEFTEXT       — zusätzlich ohne Anführungszeichen. Ohne diese Fassung
#                       genügte ein Zeichen, um Regeln zu umgehen:
#                       `git push -u origin "main"` und
#                       `git commit --no-ver''ify` kamen beide durch.
#
# Die Reihenfolge ist wichtig: erst die Botschaft weg, dann entquoten. Umgekehrt
# wüsste der zweite Schritt nicht mehr, wo die Botschaft aufhört.
entferne_botschaft() {
  printf '%s' "$1" | sed -E \
    -e 's/(^|[[:space:]])(-m|--message)[[:space:]]+"[^"]*"/\1/g' \
    -e "s/(^|[[:space:]])(-m|--message)[[:space:]]+'[^']*'/\1/g" \
    -e 's/(^|[[:space:]])--message="[^"]*"/\1/g' \
    -e "s/(^|[[:space:]])--message='[^']*'/\1/g" \
    -e 's/(^|[[:space:]])(-m|--message)[[:space:]]+[^[:space:];&|<>]+/\1/g' \
    -e 's/(^|[[:space:]])--message=[^[:space:];&|<>]+/\1/g'
}

OHNE_BOTSCHAFT=$(entferne_botschaft "$BEFEHL")
PRUEFTEXT="${OHNE_BOTSCHAFT//\"/}"
PRUEFTEXT="${PRUEFTEXT//\'/}"

# Linke Wortgrenze eines Befehlsworts. Anführungszeichen, Klammern und
# Backticks gehören dazu: ohne sie schaltet ein vorangestelltes `bash -c "` die
# gesamte Pfadprüfung ab.
G='(^|[;&|(){}[:space:]"'"'"'`])'
# Rechte Wortgrenze. `"sed" -i ...` endet auf einem Anführungszeichen, nicht auf
# einem Leerzeichen — ohne diese Klasse trifft kein Befehlswort in Anführung.
GR='([;&|(){}[:space:]"'"'"'`]|$)'

# Sucht in beiden geprüften Fassungen. Eine Regel, die nur die rohe Fassung
# ansieht, ist mit einem Anführungszeichen zu umgehen; eine, die nur die
# entquotete ansieht, schlägt auf Commit-Botschaften an.
#
# Beide Fassungen stehen als zwei Zeilen in EINER Variablen, damit ein einziger
# grep-Aufruf genügt. grep arbeitet zeilenweise, `^` und `$` gelten also
# weiterhin je Fassung — die Semantik ist dieselbe wie bei zwei Aufrufen, nur
# ohne den zweiten Prozess. Auf Windows kostet jeder davon spürbar Zeit, und
# ein Guard läuft bei JEDEM Werkzeugaufruf des Agenten.
ZWEIFACH="$OHNE_BOTSCHAFT
$PRUEFTEXT"

im_befehl()   { grep -qE  "$1" <<< "$ZWEIFACH"; }
im_befehl_i() { grep -qiE "$1" <<< "$ZWEIFACH"; }

# --- 1. Guard-Umgehung und Unumkehrbares --------------------------------
# `git commit -n` ist die Kurzform von --no-verify und muss mitgefangen
# werden; bei `git push` heisst -n dagegen --dry-run und ist harmlos.
# `git` und `commit` dürfen dabei durch Optionen getrennt sein: `git -c x=y
# commit -n` kam sonst durch, während derselbe Fehler bei `git push` längst
# behoben war (Abweichung A5).
if im_befehl '(--no-verify|git\b[^;&|]*[[:space:]](commit|merge)([[:space:]]+[^[:space:]|;&]+)*[[:space:]]+-[a-zA-Z]*n([[:space:]]|$))'; then
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

# Git-Klempnerei. Diese Unterbefehle schreiben am Arbeitsverzeichnis vorbei
# direkt in den Index, in die Konfiguration oder auf Referenzen — ein Diff
# sieht hinterher unauffällig aus. `git update-index --cacheinfo` tauscht so
# den Inhalt einer verfolgten Testdatei aus, `git config core.hooksPath` hängt
# die Commit-Hooks aus, `git worktree add` legt einen zweiten Arbeitsbaum an,
# und `git symbolic-ref HEAD` schreibt den aktuellen Branch auf main um. Alle
# vier kamen durch (Befunde aus dem Review). Lesende Abfragen der Konfiguration
# bleiben erlaubt.
if im_befehl "${G}git\b[^;&|]*[[:space:]](update-index|update-ref|symbolic-ref|hash-object|mktree|commit-tree|fast-import|replace|worktree|filter-branch|reflog|prune|gc)${GR}"; then
  echo "Blocked: git plumbing writes past the working tree, so the round's diff no longer shows what happened. Use ordinary git commands." >&2
  exit 2
fi
if im_befehl "${G}git\b[^;&|]*[[:space:]]config${GR}" \
   && ! im_befehl "${G}git\b[^;&|]*[[:space:]]config[[:space:]]+(--get|--get-all|--get-regexp|--list|-l)${GR}"; then
  echo "Blocked: changing git configuration outlives the round and can redirect hooks, remotes and editors. Read it with 'git config --get' or add an entry to QUESTIONS.md." >&2
  exit 2
fi

# Etwas an einen fremden Rechner schicken ist ein äusserer Effekt und laut
# Charta ausserhalb der Entscheidungsgrenze.
if im_befehl "${G}(scp|sftp|ssh|rclone|aws|gcloud|az)${GR}"; then
  echo "Blocked: this reaches a machine outside this repository. Outward-facing effects are outside your decision boundary — add an entry to QUESTIONS.md." >&2
  exit 2
fi

# Ein Interpreter-Einzeiler, der ins Dateisystem schreibt, trägt seinen Pfad
# oft nicht als Token: `node -e "…writeFileSync(['loop','sh'].join('.'),'')"`
# baut ihn zur Laufzeit zusammen. Die Pfadprüfung kann das prinzipiell nicht
# sehen — also dieselbe Antwort wie bei `patch`: ablehnen, statt zu raten.
# Lesende Einzeiler bleiben erlaubt, und für Codeänderungen gibt es Edit.
if im_befehl "${G}(sed|perl|python[0-9.]*|py|node|deno|bun|ruby|php|pwsh|powershell)${GR}" \
   && im_befehl '(^|[[:space:]])--?[a-zA-Z]*(c|e)([[:space:]]|=|$)' \
   && im_befehl_i '(writeFile|appendFile|createWriteStream|\.write\(|unlink|rmSync|rmdir|mkdir|renameSync|copyFile|truncate|chmod|open[[:space:]]*\([^)]*[",'"'"']w|Set-Content|Add-Content|Out-File|Remove-Item|shutil\.|os\.remove|os\.rename|Path\([^)]*\)\.write)'; then
  echo "Blocked: a one-liner that writes to the filesystem hides which file it touches. Use the Edit or Write tool for file changes." >&2
  exit 2
fi

# Ein Skript ausserhalb des Projekts auszuführen ist genau der Fall, für den
# `patch` und `git apply` abgelehnt werden: der Inhalt steht nicht im Befehl.
# Skripte IM Projekt sind versioniert und im Diff sichtbar, die bleiben erlaubt.
if im_befehl "${G}(bash|sh|zsh|ksh|dash|python[0-9.]*|py|node|perl|ruby|pwsh|powershell)[[:space:]]"; then
  while IFS= read -r WORT; do
    [[ -z "$WORT" ]] && continue
    case "$WORT" in
      -*) continue ;;
    esac
    if ausserhalb_des_projekts "${WORT//\\//}" "$PROJEKT" streng; then
      echo "Blocked: running a script from outside the project hides what it does. Keep it in the repository, where the diff shows it." >&2
      exit 2
    fi
  # printf '%s\n', nicht '%s': ohne abschliessenden Zeilenumbruch liefert
  # `read` beim letzten Wort einen Fehlschlag, und die Schleife überspringt
  # genau das Token, auf das es hier ankommt — den Skriptpfad.
  done < <(printf '%s\n' "$PRUEFTEXT" | tr ' \t' '\n\n')
fi

# Dieselbe Begründung wie bei `patch`, nur für Befehle, die den auszuführenden
# Text irgendwoher beziehen statt ihn zu zeigen. `git apply` abzulehnen und
# `curl … | bash` durchzulassen war derselbe Fehler zweimal (Befund M-10).
if im_befehl '(^|[;&|(){}`])[[:space:]]*(source|\.)[[:space:]]+[^[:space:]]' \
   || im_befehl "${G}eval${GR}" \
   || im_befehl '(^|[[:space:]])BASH_ENV=' \
   || im_befehl "(curl|wget|Invoke-WebRequest|iwr)[^|;&]*\|[[:space:]]*(sudo[[:space:]]+)?(ba|z|k|d)?sh${GR}"; then
  echo "Blocked: running code that is not visible in the command line cannot be checked. Put the steps in the command itself." >&2
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

# `mkfs` traf nur als blosses Wort — `mkfs.ext4` und `mkfs.xfs` kamen durch.
# Der Loop hat diese Lücke selbst gefunden und in QUESTIONS.md eingetragen,
# konnte sie aber nicht beheben, weil ihm dieses Skript gesperrt ist.
if im_befehl_i "${G}mkfs(\.[a-z0-9]+)?${GR}|:\(\)\{|${G}(npm|yarn|pnpm)[[:space:]]+publish|${G}rm[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*-[a-zA-Z]*[rf][a-zA-Z]*[[:space:]]+(/|~|\.\.?)([[:space:]]|$)"; then
  echo "Blocked: this is irreversible or has external effects." >&2
  exit 2
fi

# --- 2. Prozesse beenden: der Agent laeuft selbst in einem -------------
# Diese Regel gibt es, weil genau das passiert ist: der grader hatte den
# Server gestartet, um ihn zu pruefen, und raeumte danach mit
# `taskkill //F //IM node.exe //T` auf. Das trifft nicht nur den Server,
# sondern JEDEN node-Prozess auf der Maschine -- also auch die Claude-Code-
# Sitzung, die den Befehl gerade ausfuehrte, und das Cockpit, das zusah.
# Der Ereignisstrom brach mitten im Wort ab, loop.sh hing vier Stunden an
# einem toten Kind, und das Dashboard zeigte die ganze Zeit "LIVE".
#
# Die anderen Regeln hier schuetzen die INTEGRITAET des Laufs (keiner faelscht
# Tests, keiner pusht mit Gewalt). Diese schuetzt seine VERFUEGBARKEIT: ein
# Lauf, der sich selbst abschiesst, hinterlaesst keine Spur, aus der man
# lernen koennte -- der Guard, der ihn haette warnen sollen, stirbt mit.
#
# Deshalb pauschal, nicht nach Ziel unterschieden: welcher Prozess hinter
# einer PID oder einem Abbildnamen steckt, weiss ein Hook nicht. Wer etwas
# gestartet hat, das wieder aufhoeren soll, startet es mit einer Zeitgrenze
# (`timeout 20 npm start`) statt es hinterher zu erschiessen.
TOETER="${G}(taskkill|tskill|pkill|killall|logoff|shutdown|reboot|halt|poweroff)${GR}"
TOETER_PS='(stop-process|stop-computer|restart-computer|stop-service|suspend-process)'
TOETER_DIENST="${G}(sc|net)[[:space:]]+stop${GR}|${G}wmic[[:space:]][^;&|]*process[^;&|]*(delete|terminate)"
# `xargs kill` traegt die PIDs erst in der Pipe, nicht im Befehl.
TOETER_XARGS="${G}xargs([[:space:]]+-[^[:space:]]+)*[[:space:]]+kill${GR}"
# Das blosse `kill` ist ein gewoehnliches englisches Wort: `grep -rn "kill"`
# und `git commit -m "kill 3 flaky tests"` duerfen nicht blockieren. Deshalb
# nur in Befehlsposition (Zeilenanfang oder nach einem Shell-Operator, NICHT
# nach einem Anfuehrungszeichen) und nur, wenn ein Signal, eine PID oder eine
# Job-Nummer folgt -- also nur dann, wenn es wirklich toetet.
BEFEHLSPOSITION='(^|[;&|(){}`])[[:space:]]*'
TOETER_KILL="${BEFEHLSPOSITION}kill([[:space:]]+-[a-zA-Z0-9]+)*[[:space:]]+(\\\$|[0-9]|%|\`|\")"

if im_befehl_i "$TOETER" \
   || im_befehl_i "$TOETER_PS" \
   || im_befehl_i "$TOETER_DIENST" \
   || im_befehl "$TOETER_XARGS" \
   || im_befehl "$TOETER_KILL"; then
  echo "Blocked: you are yourself a node process, and so is the cockpit watching you. Killing processes by name or PID ends your own run silently. Start anything long-running with a time limit instead, e.g. 'timeout 20 npm start'." >&2
  exit 2
fi

# Dieselbe Tat durch einen Interpreter. Die Pfadpruefung weiter unten kennt
# INTERPRETER und INLINE_SCHALTER schon; hier zaehlt nur, was der Einzeiler tut.
if im_befehl "${G}(perl|python[0-9.]*|node|ruby|php)${GR}" \
   && im_befehl '(^|[[:space:]])--?[a-zA-Z]*(c|e)([[:space:]]|=|$)' \
   && im_befehl_i '(process\.kill|os\.kill|killpg|\.Kill\(|TerminateProcess)'; then
  echo "Blocked: killing a process from a one-liner is the same act as taskkill. See above." >&2
  exit 2
fi

# --- 3. Pushen: nur auf einen Agenten-Branch, nie mit Gewalt -------------
# Am Verb ankern, damit `git -c foo=bar push` nicht am Muster vorbeiläuft.
# Geprüft wird auf der entquoteten Fassung: `git push -u origin "main"` traf
# das an Wortgrenzen verankerte Muster sonst nicht.
if printf '%s' "$PRUEFTEXT" | grep -qE "${G}git\b[^;&|]*[[:space:]]push([[:space:]]|$)"; then
  # `-fu` ist dasselbe wie `-uf`: das f darf irgendwo im Flag-Bündel stehen.
  if printf '%s' "$PRUEFTEXT" | grep -qE '(--force|--force-with-lease|--mirror|--delete|(^|[[:space:]])-[a-zA-Z]*f[a-zA-Z]*([[:space:]]|$)|(^|[[:space:]])\+[^[:space:]]*:|(^|[[:space:]:/])(refs/heads/)?(main|master)([[:space:]]|$))'; then
    echo "Blocked: no push to main and no force push. Push to an agent branch only." >&2
    exit 2
  fi
  # Ohne ausdrückliche Refspec pusht git den aktuellen Branch — und der kann
  # main sein, ohne dass das Wort im Befehl vorkommt.
  ZIEL=$(printf '%s' "$PRUEFTEXT" \
    | sed -E 's/.*[[:space:]]push([[:space:]]|$)/ /' \
    | tr ' \t' '\n\n' \
    | grep -vE '^(-|$)' \
    | tail -n +2)
  # Erlaubt sind genau zwei Namensräume: `agent/…` für die Runden von loop.sh
  # und `zyklus/…` für die Zyklen von zyklus.sh. Vorher stand hier nur eine
  # Sperrliste (HEAD, main, master); jeder andere Name kam durch, `zyklus/3`
  # also auch — aber nur, weil er auf keiner Liste stand, nicht weil er
  # vorgesehen war. Eine Erlaubnisliste sagt dasselbe wie die Meldung darunter
  # und deckt beide Treiber ab, ohne jeden dritten Namen mitzuerlauben.
  #
  # Doppelpunkte sind hier nicht zugelassen: bei `zyklus/3:irgendwas` steht das
  # wahre Ziel rechts, und was rechts steht, prüft die Sperrliste oben nur für
  # main und master. Fail-closed wie überall in diesem Skript — wer eine
  # Refspec braucht, schreibt beide Seiten als eigene Wörter.
  ERLAUBTER_ZWEIG='^(refs/heads/)?(agent|zyklus)/[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$'
  ZIEL_OK=1
  [[ -z "$ZIEL" ]] && ZIEL_OK=0
  while IFS= read -r REFSPEC; do
    [[ -z "$REFSPEC" ]] && continue
    printf '%s' "$REFSPEC" | grep -qE "$ERLAUBTER_ZWEIG" || ZIEL_OK=0
  done <<< "$ZIEL"
  if (( ! ZIEL_OK )); then
    echo "Blocked: push must name an agent branch explicitly — 'git push -u origin agent/<name>' or 'git push -u origin zyklus/<n>'." >&2
    exit 2
  fi
fi

# --- 3b. gh: lesen ja, die Welt verändern nein --------------------------
#
# `gh` stand in keinem einzigen Muster, obwohl loop.sh ohne `gh` nicht startet
# und das hinterlegte Token auf alle Repositories des Kontos schreiben darf.
# Damit war der Agent frei, `gh pr merge` zu rufen (der Branch-Schutz verlangt
# einen Pull Request, aber keine Freigabe), den Branch-Schutz per
# `gh api -X DELETE …/protection` selbst abzuräumen und mit `gh auth token`
# das Token auszugeben. Das war der schwerste Befund des Reviews (B-2): die
# zweite Schicht liess sich von der ersten aus entfernen.
#
# Aufzählen, was verboten ist, führt hier nicht zum Ziel — `gh` hat über
# vierzig Unterbefehle und bekommt neue. Deshalb umgekehrt: eine Erlaubnisliste
# aus lesenden Aufrufen, alles andere blockiert. Der Loop selbst ruft `gh pr
# create` in loop.sh, ausserhalb der Sitzung, und ist davon nicht betroffen.
if printf '%s' "$PRUEFTEXT" | grep -qE "${G}gh${GR}"; then
  # Die Wörter nach `gh`, ohne Optionen. Mehrere `gh`-Aufrufe in einer Zeile
  # werden einzeln geprüft.
  while IFS= read -r AUFRUF; do
    [[ -z "$AUFRUF" ]] && continue
    WORTE=$(printf '%s' "$AUFRUF" | tr ' \t' '\n\n' | grep -vE '^(-|$)' | head -3)
    THEMA=$(sed -n 1p <<< "$WORTE")
    VERB=$(sed -n 2p <<< "$WORTE")
    ERLAUBT=0
    case "$THEMA" in
      # Reine Auskunft, kein Unterbefehl nötig.
      status|version|help|"") ERLAUBT=1 ;;
      auth)   [[ "$VERB" == "status" ]] && ERLAUBT=1 ;;
      search) ERLAUBT=1 ;;
      pr|issue|repo|run|release|workflow|label|gist|cache|ruleset|project)
        case "$VERB" in view|list|diff|checks|status) ERLAUBT=1 ;; esac ;;
      api)
        # `gh api` ist ohne `-X` ein GET. Schreibend wird es durch eine
        # Methode oder durch Feld-Flags, die den Aufruf zu POST machen.
        if printf '%s' "$AUFRUF" | grep -qiE '(-X|--method)[[:space:]=]+(POST|PUT|PATCH|DELETE)|(^|[[:space:]])(-f|-F|--field|--raw-field|--input)([[:space:]]|=)'; then
          ERLAUBT=0
        else
          ERLAUBT=1
        fi ;;
    esac
    if (( ! ERLAUBT )); then
      echo "Blocked: gh may only read here (view, list, diff, checks, status, search, GET api). Merging, deleting branch protection, changing settings, secrets, workflows and releases are outward-facing effects and outside your decision boundary — add an entry to QUESTIONS.md. loop.sh opens the pull request itself after the run." >&2
      exit 2
    fi
  done < <(printf '%s' "$PRUEFTEXT" | grep -oE "${G}gh[[:space:]]+[^;&|]*" | sed -E 's/^[^g]*gh[[:space:]]+//')
fi

# --- 4. Schreibzugriff auf geschützte Pfade über die Shell ---------------
# Den Befehl in Tokens zerlegen, damit die Pfadmuster aus protected-paths.sh
# (die mit `$` ankern) gegen einzelne Pfade greifen und nicht gegen die ganze
# Zeile.
zerlegen() {
  printf '%s' "$1" \
    | tr '\\' '/' \
    | tr -s ' \t\n"'"'"'()`;&|<>=' '\n'
}

# Zusätzlich eine Fassung ohne Anführungszeichen: `.e""nv` würde sonst in zwei
# harmlose Tokens zerfallen. Beide aus $OHNE_BOTSCHAFT, damit Wörter aus einer
# Commit-Botschaft nicht als Dateinamen gelesen werden.
# Ein Backslash hat zwei Lesarten, und der Guard muss beide sehen. Unter
# Windows trennt er Pfade (`test\x.test.js`), in der Shell entwertet er das
# nächste Zeichen (`tasklist.tes\t.js` ist `tasklist.test.js`). `zerlegen`
# deckt die erste ab; ohne die zweite kam `sed -i 1d test/tasklist.tes\t.js`
# durch und traf die verfolgte Datei.
ohne_backslash() { printf '%s' "${1//\\/}"; }

ROH=$({ zerlegen "$OHNE_BOTSCHAFT"
        zerlegen "$PRUEFTEXT"
        zerlegen "$(ohne_backslash "$PRUEFTEXT")"; } | grep -v '^$' | sort -u)

# `~` ist für die Shell das Heimatverzeichnis, für ein Muster nur ein Zeichen.
# Ohne diese Auflösung war `rm -rf ~/Documents` ein Token, das nirgends traf.
if [[ -n "${HOME:-}" ]]; then
  HEIM="${HOME//\\//}"
  ROH=$(printf '%s\n' "$ROH" | sed -E "s#^~(/|$)#${HEIM//#/\\#}\1#")
fi

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
#
# Aus der ROHEN Fassung: nur dort steht die Umleitung so, wie die Shell sie
# sieht. Anführungszeichen werden hinterher entfernt — `cat > "loop.sh"` traf
# sonst kein einziges am Dateinamen verankertes Muster (Befund M-8).
# Ein Ziel in Anführungszeichen darf Leerzeichen enthalten — `> "  loop.sh"`
# ergab sonst ein leeres Ziel und war damit ungeprüft. Deshalb zuerst die
# quotierte Form, dann die unquotierte.
UMLEITUNGSZIELE=$(
  printf '%s' "$BEFEHL" \
    | tr '\\' '/' \
    | grep -oE '[0-9]?>>?[[:space:]]*("[^"]*"|'"'"'[^'"'"']*'"'"'|[^[:space:]|;&<>]+)' \
    | sed -E 's/^[0-9]?>>?[[:space:]]*//' \
    | tr -d '"'"'"'' \
    | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' \
    | grep -v '^$' || true
)
# `~` ist auch hier das Heimatverzeichnis. Ohne diese Auflösung sah
# `echo x > ~/.bashrc` nicht wie ein absoluter Pfad aus und entkam der Regel
# "nichts ausserhalb des Projekts".
if [[ -n "${HOME:-}" && -n "$UMLEITUNGSZIELE" ]]; then
  HEIM_U="${HOME//\\//}"
  UMLEITUNGSZIELE=$(printf '%s\n' "$UMLEITUNGSZIELE" | sed -E "s#^~(/|$)#${HEIM_U//#/\\#}\1#")
fi

# Ein Umleitungsziel oder ein Schreibziel, das erst zur Laufzeit entsteht
# (`> $(echo loop.sh)`, `> $ZIEL`, `sed -i 1d ${TEST}`, `> \`…\``, `tee >(sh)`),
# kann dieses Skript nicht ausrechnen. Raten wäre falsch, durchlassen auch —
# also dieselbe Antwort wie bei `patch`: ablehnen.
if printf '%s' "$BEFEHL" | grep -qE '[0-9]?>>?[[:space:]]*[^[:space:]|;&<>]*[$`]|>[[:space:]]*\('; then
  echo "Blocked: the guard cannot tell which file this redirection writes, because the target is computed at run time. Name the file directly." >&2
  exit 2
fi

# Alle Treffer, nicht nur den ersten. Vorher brach die Suche beim ersten
# passenden Token ab und stellte die Git-Frage nur für dieses eine — ein
# alphabetisch früherer, unverfolgter Testpfad im selben Befehl genügte
# deshalb, um eine verfolgte Testdatei zu überschreiben (`cp neu.test.js
# alt.test.js`, Befund M-2).
# Ein grep über die ganze Liste statt einer Schleife mit einem grep je Token:
# die Liste ist zeilenweise aufgebaut, also liefert grep genau die passenden
# Tokens zurück. Bei einem Dutzend Tokens spart das ein Dutzend Prozesse.
treffer_alle() {
  [[ -z "$2" ]] && return 0
  grep -iE "$1" <<< "$2" || true
}
# Kein `| head -1` hier: unter `set -o pipefail` bekommt treffer_alle dabei
# SIGPIPE, und der Rückgabewert der Pipeline wird ungleich 0, obwohl ein
# Treffer gefunden wurde. Das ist genau die Sorte stiller Fehlschlag, gegen die
# die Guards getestet werden — hier hätte sie jede Pfadprüfung abgeschaltet.
treffer() { [[ -n "$(treffer_alle "$1" "$2")" ]]; }

# Geheimnisse: in einem Shell-Befehl gibt es dafür hier keinen legitimen Grund.
while IFS= read -r GEHEIM; do
  [[ -z "$GEHEIM" ]] && continue
  if ! printf '%s' "$GEHEIM" | grep -qiE "$MUSTER_GEHEIM_HARMLOS"; then
    echo "Blocked: secrets." >&2
    exit 2
  fi
done <<< "$(treffer_alle "$MUSTER_GEHEIM" "$TOKENS")"

# Umleitungsziele werden immer geprüft, unabhängig vom Befehlswort.
for MUSTER in "$MUSTER_TESTS:existing tests must not be changed through the shell. Fix the code, or add an entry to QUESTIONS.md." \
              "$MUSTER_DEPS:dependencies and build configuration are a human decision. Add an entry to QUESTIONS.md." \
              "$MUSTER_SELBST:your own configuration and safeguards are immutable."; do
  M="${MUSTER%%:*}"; T="${MUSTER#*:}"
  while IFS= read -r ZIEL; do
    [[ -z "$ZIEL" ]] && continue
    # Eine NEUE Testdatei anzulegen ist erlaubt, genau wie beim Datei-Guard.
    if [[ "$M" == "$MUSTER_TESTS" ]] && ! ist_verfolgter_test "$ZIEL" "$PROJEKT"; then
      continue
    fi
    echo "Blocked: $T" >&2
    exit 2
  done <<< "$(treffer_alle "$M" "$UMLEITUNGSZIELE")"
done

# Auch ausserhalb des Projekts wird nicht umgeleitet.
while IFS= read -r ZIEL; do
  [[ -z "$ZIEL" ]] && continue
  if ausserhalb_des_projekts "$ZIEL" "$PROJEKT"; then
    echo "Blocked: this writes outside the project. The agent changes the repository it works in, nothing else. Use a temp directory for scratch files." >&2
    exit 2
  fi
done <<< "$UMLEITUNGSZIELE"

# Schreibende Befehlsworte. Interpreter zählen nur mit einem Inline- oder
# In-place-Schalter — sonst wäre `node --test test/foo.test.js`, der
# naheliegendste Schritt beim Eingrenzen eines Fehlschlags, gesperrt.
#
# Die Interpreterliste war unvollständig: `gawk` traf nicht, weil die
# Wortgrenze vor `awk` mitten im Wort liegt, und `deno`, `py`, `powershell`,
# `cmd`, `vim`, `sponge` standen gar nicht darin (Befund M-11). Ergänzt, ohne
# die Bedingung "nur mit Inline-Schalter" aufzuweichen — die verhindert genau
# die Fehlalarme, die Abweichung E10 beseitigt hat.
SCHREIBEND_IMMER="${G}(tee|dd|truncate|shred|install|rsync|ed|ex|vi|vim|nvim|emacs|sponge|xargs)${GR}"
SCHREIBEND_PFAD="${G}(rm|mv|cp|touch|chmod|chown|ln|mkdir|copy|move|del|erase)${GR}"
INTERPRETER="${G}([gmn]?awk|sed|perl|python[0-9.]*|py|node|deno|bun|ruby|php|pwsh|powershell|cmd|osascript)${GR}"
INLINE_SCHALTER='(^|[[:space:]])--?[a-zA-Z]*(i|c|e)([[:space:]]|=|$)|(^|[[:space:]])-(Command|EncodedCommand)([[:space:]]|$)'
# Ein Interpreter, der sein Programm über die Standardeingabe bekommt, trägt
# keinen Schalter: `python - <<< "open('loop.sh','w')"` kam deshalb durch.
STDIN_PROGRAMM='<<<|<<[[:space:]]*[A-Za-z_'"'"'"]'

SCHREIBT=0
im_befehl "$SCHREIBEND_IMMER" && SCHREIBT=1
im_befehl "$SCHREIBEND_PFAD"  && SCHREIBT=1
if im_befehl "$INTERPRETER" && { im_befehl "$INLINE_SCHALTER" || im_befehl "$STDIN_PROGRAMM"; }; then SCHREIBT=1; fi

if (( SCHREIBT )); then
  # Ein schreibender Befehl mit einem Ziel, das erst die Shell ausrechnet
  # (`sed -i 1d ${TEST}`, `rm $(cat liste)`), ist aus demselben Grund nicht
  # prüfbar wie eine berechnete Umleitung. Gleiche Antwort.
  if printf '%s' "$BEFEHL" | grep -qE '[$`]'; then
    echo "Blocked: this writing command computes its target at run time, so the guard cannot tell which file it touches. Name the file directly." >&2
    exit 2
  fi

  while IFS= read -r ZIEL; do
    [[ -z "$ZIEL" ]] && continue
    if ist_verfolgter_test "$ZIEL" "$PROJEKT"; then
      echo "Blocked: existing tests must not be changed through the shell. Fix the code, or add an entry to QUESTIONS.md." >&2
      exit 2
    fi
  done <<< "$(treffer_alle "$MUSTER_TESTS" "$TOKENS")"

  if treffer "$MUSTER_DEPS" "$TOKENS"; then
    echo "Blocked: dependencies and build configuration are a human decision. Add an entry to QUESTIONS.md." >&2
    exit 2
  fi
  if treffer "$MUSTER_SELBST" "$TOKENS"; then
    echo "Blocked: your own configuration and safeguards are immutable." >&2
    exit 2
  fi

  # Und alles ausserhalb des Projekts. Das ist die Regel, die `rm -rf
  # ~/Documents`, `dd of=/dev/sda` und ein überschriebenes
  # ~/.local/bin/claude auf einmal erledigt, statt sie einzeln aufzuzählen.
  while IFS= read -r TOKEN; do
    [[ -z "$TOKEN" ]] && continue
    if ausserhalb_des_projekts "$TOKEN" "$PROJEKT"; then
      echo "Blocked: this writes outside the project. The agent changes the repository it works in, nothing else. Use a temp directory for scratch files." >&2
      exit 2
    fi
  done <<< "$TOKENS"
fi

exit 0
