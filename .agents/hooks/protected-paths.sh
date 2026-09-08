#!/usr/bin/env bash
# Gemeinsame Pfadmuster der beiden Guards und von loop.sh.
#
# Diese Datei ist die einzige Quelle dafür, was geschützt ist. guard-files.sh,
# guard-bash.sh und loop.sh lesen sie ein — sonst driften Datei-Guard und
# Bash-Guard auseinander, und genau diese Lücke ist der bequemste Umweg für den
# Agenten: was das Edit-Werkzeug verbietet, erledigt sonst ein `sed -i`.
#
# Regeln für die Muster:
#   - Sie werden mit `grep -qiE` gegen EINEN Pfad geprüft, nicht gegen eine
#     ganze Kommandozeile. guard-bash.sh zerlegt den Befehl vorher in Tokens.
#   - Backslashes sind vorher zu Schrägstrichen normalisiert (Windows).
#   - Deshalb dürfen die Muster mit `$` ans Ende ankern.

# Version des Schutzsatzes. Sie wird hochgezählt, sobald sich an den Mustern
# oder an den Regeln in guard-bash.sh etwas Sicherheitsrelevantes ändert.
#
# Es gibt sie, weil der Loop kopiert wird: `agent-cockpit` lief acht echte
# Runden mit einer Fassung, die `rm -rf .agents/hooks`, `git push -u origin
# "main"` und `gh api -X DELETE …/protection` durchliess — alles drei in der
# Fassung daneben längst blockiert. Von aussen sah das identisch aus. loop.sh
# vergleicht diese Zahl mit der, die es selbst erwartet, und verweigert den
# Start bei einem Rückstand; das Cockpit zeigt sie je Projekt an.
SCHUTZ_VERSION=2

# Bestehende Tests, Snapshots und Fixtures.
# `spec/` ist bewusst eng gefasst: ein Verzeichnis dieses Namens enthält oft
# eine OpenAPI-Spezifikation, und die ist kein Test.
#
# Die Liste muss decken, was der Testläufer entdeckt, sonst ist eine Datei zwar
# ein Test, aber ungeschützt: `node --test` findet auch `helper-test.js` und
# `test.js`, nicht nur `*.test.js`.
#
# Die Verzeichnisformen `tests?` und `__tests__` sind zusätzlich OHNE
# Schlussstrich aufgeführt. `rm -r test` trug sonst ein Token, das kein Muster
# traf, und löschte die halbe Suite — derselbe Fehler, der bei `.agents/hooks`
# beide Guards abschaltete.
MUSTER_TESTS='(\.test\.|\.spec\.|[-_]test\.[a-z0-9]+$|(^|/)test\.[a-z0-9]+$|(^|/)test_[^/]*\.py$|(^|/)tests?(/|$)|(^|/)__tests__(/|$)|(^|/)spec/[^/]*[._-](spec|test)\.[a-z0-9]+$|(^|/)conftest\.py$|\.snap$)'

# Abhängigkeiten, Lockfiles, Build- und CI-Konfiguration.
#
# Der Kommentar verspricht "Build- und CI-Konfiguration", die Liste deckte aber
# nur Paketmanager ab: Makefile, Dockerfile und alles unterhalb von .github/
# ausser workflows/ waren frei beschreibbar, obwohl jedes davon beim naechsten
# Build oder CI-Lauf beliebige Befehle ausfuehrt. Ein Review hat das gefunden
# (Befund M-12); die Liste deckt jetzt, was der Kommentar behauptet.
MUSTER_DEPS='((^|/)package(-lock)?\.json$|(^|/)yarn\.lock$|(^|/)pnpm-lock\.[a-z]+$|(^|/)npm-shrinkwrap\.json$|(^|/)requirements([-.][^/]*)?\.txt$|(^|/)pyproject\.toml$|(^|/)poetry\.lock$|(^|/)uv\.lock$|(^|/)go\.(mod|sum)$|(^|/)Cargo\.(toml|lock)$|(^|/)pytest\.ini$|(^|/)tox\.ini$|(^|/)\.github(/|$)|(^|/)[Mm]akefile$|(^|/)Dockerfile([.-][^/]*)?$|(^|/)docker-compose([.-][^/]*)?\.ya?ml$|(^|/)compose\.ya?ml$|(^|/)justfile$|(^|/)Taskfile\.ya?ml$)'

# Die eigene Konfiguration und die Schutzmechanismen selbst. Ohne diese Regel
# schaltet eine Prompt-Injection über Repo-Inhalte die Guards einfach ab.
#
# `.claude(/|\.json$)` deckt beides ab: das Verzeichnis .claude/ und die Datei
# ~/.claude.json, in der die MCP-Server und die Vertrauensfreigaben stehen —
# ein dort eingetragener Server ist ein beliebiger Befehl, der in jeder
# folgenden Runde startet.
# `.devcontainer/` gehört dazu, weil das Konzept die Containergrenze die
# eigentliche Sicherheitsgrenze nennt: wer init-firewall.sh umschreiben darf,
# hebt sie auf.
#
# ACHTUNG, hier lag ein Loch, das beide Guards auf einen Schlag abschaltete
# (Befund B-1): die Verzeichnismuster endeten auf einem Schrägstrich, also traf
# `.agents/hooks/` nur ein Token MIT Schrägstrich. `rm -rf .agents/hooks` trägt
# das Token OHNE, kam durch — und danach lieferte jeder Hook-Aufruf 127, was
# nicht blockiert. Jedes Verzeichnismuster endet deshalb auf `(/|$)`: es trifft
# das Verzeichnis selbst genauso wie alles darin.
#
# `.git/` ist neu dabei. Dort liegen `hooks/pre-commit` (beliebiger Code bei
# jedem Commit, auch bei dem, den loop.sh selbst macht) und `config`
# (Remote-URL, core.hooksPath, Aliase). Gewöhnliche git-Befehle nennen `.git`
# nicht auf der Kommandozeile, sind davon also nicht betroffen.
MUSTER_SELBST='((^|/)\.claude(/|\.json$|$)|(^|/)CLAUDE\.md$|(^|/)\.agents(/hooks(/|$)|$)|(^|/)\.devcontainer(/|$)|(^|/)\.git(/|$)|(^|/)loop\.sh$|(^|/)abnahme\.sh$|(^|/)round\.md$|(^|/)\.mcp\.json$|(^|/)\.gitattributes$)'

# Geheimnisse. `credentials` ist auf Konfigurationsendungen eingegrenzt, damit
# ein Quellmodul src/auth/credentials.js lesbar bleibt — der Reviewer soll
# genau das prüfen können.
MUSTER_GEHEIM='((^|/)\.env(\.[^/]*)?$|(^|/)id_rsa|(^|/)id_ed25519|\.pem$|\.key$|(^|/)credentials$|(^|/)credentials\.(json|ini|cfg|ya?ml|toml|txt)$|(^|/)\.ssh/|(^|/)\.aws/|(^|/)\.npmrc$|(^|/)\.netrc$)'

# Vorlagendateien tragen per Konvention keine Geheimnisse und müssen lesbar
# und schreibbar bleiben.
MUSTER_GEHEIM_HARMLOS='(^|/)\.env\.(example|sample|template|dist|defaults)$'

# --- Schreiben ausserhalb des Projekts ------------------------------------
#
# Bis hierher zählt dieses Skript auf, WAS geschützt ist. Das ist eine
# Verbotsliste, und eine Verbotsliste ist nie fertig: ein Review fand
# `~/.bashrc`, `~/.gitconfig` und `~/.local/bin/claude` — letzteres genau das
# Binary, das loop.sh jede Runde startet (Befund M-12). Sie einzeln
# nachzutragen hätte beim nächsten Mal wieder eine Lücke gelassen.
#
# Deshalb hier stattdessen die Umkehrung, eine ERLAUBNISLISTE: der Agent
# schreibt im Projekt, sonst nirgends. Ausgenommen sind nur Temp-Verzeichnisse,
# weil Zwischendateien ein legitimes Werkzeug sind — und die sind selbst kein
# Ziel, weil dort nichts liegt, was in der nächsten Runde ausgeführt wird.
MUSTER_TEMP='^(/tmp/|/var/tmp/|/dev/(null|stdout|stderr|fd/)|[A-Za-z]:/(Windows/)?Temp/|[A-Za-z]:/Users/[^/]+/AppData/Local/Temp/)'

# Wahr, wenn $1 ein absoluter Pfad ausserhalb von $2 ist, der nicht in einem
# Temp-Verzeichnis liegt. Rein textuell — der Aufrufer kanonisiert vorher, wo er
# das kann. Gross-/Kleinschreibung wird ignoriert, weil Windows-Dateisysteme
# das auch tun.
# Git Bash kennt denselben Ort in zwei Schreibweisen: `C:/Users/x` und
# `/c/Users/x`. Ohne Vereinheitlichung sähe jeder MSYS-Pfad wie "ausserhalb"
# aus und jeder Windows-Pfad wie "innerhalb", je nachdem, welche Form die
# Wurzel gerade hat.
laufwerk_vereinheitlichen() {
  printf '%s' "$1" | sed -E 's#^/([A-Za-z])(/|$)#\1:\2#' | tr '[:upper:]' '[:lower:]'
}

# $3 = "streng": ohne die Temp-Ausnahme. Für das SCHREIBEN ist ein
# Temp-Verzeichnis harmlos — dort liegt nichts, was in der nächsten Runde
# ausgeführt wird. Für das AUSFÜHREN ist es das Gegenteil: /tmp ist genau der
# Ort, an dem ein heruntergeladenes Skript landet. `bash /tmp/evil.sh` kam
# durch, weil beide Fälle dieselbe Funktion benutzten.
ausserhalb_des_projekts() {
  local pfad="$1" wurzel="$2" modus="${3:-}"
  case "$pfad" in
    /*|[A-Za-z]:/*) ;;
    *) return 1 ;;                       # relativ: der Aufrufer löst selbst auf
  esac
  local p_klein w_klein
  p_klein=$(laufwerk_vereinheitlichen "$pfad")
  w_klein=$(laufwerk_vereinheitlichen "$wurzel")
  if [[ "$modus" != "streng" ]]; then
    printf '%s' "$pfad"   | grep -qiE "$MUSTER_TEMP" && return 1
    printf '%s' "$p_klein" | grep -qiE "$MUSTER_TEMP" && return 1
  fi
  [[ -n "$w_klein" && ( "$p_klein" == "$w_klein" || "$p_klein" == "$w_klein"/* ) ]] && return 1
  return 0
}

# --- Ist diese Datei ein bestehender, versionierter Test? ------------------
#
# Die Frage "kennt Git diese Datei" wurde bisher mit
# `git ls-files --error-unmatch <token>` gestellt. Das war an zwei Stellen
# falsch (Befunde M-1 und M-6):
#
#   1. Der Token wird gegen die Repository-Wurzel aufgelöst. `cd test && sed -i
#      1d tasklist.test.js` fragt also nach `tasklist.test.js` im Wurzelver-
#      zeichnis, findet nichts, und die Datei galt als neu — obwohl die Shell
#      gleich `test/tasklist.test.js` trifft.
#   2. Der Git-Index unterscheidet Gross- und Kleinschreibung, NTFS nicht.
#      `TEST/tasklist.test.js` galt als neu und überschrieb die verfolgte Datei.
#
# Beides fällt weg, wenn nicht nach dem Pfad, sondern nach dem DATEINAMEN
# gefragt wird: heisst eine versionierte Testdatei irgendwo im Repository genau
# so, ist der Token gesperrt — egal aus welchem Verzeichnis, in welcher
# Schreibweise und über welchen Umweg er dorthin zeigt.
#
# Das ist strenger als vorher und bleibt trotzdem genau innerhalb der Charta:
# eine WIRKLICH neue Testdatei trägt einen Namen, den es noch nicht gibt, und
# ist weiterhin erlaubt (Abweichung A3).
# Die Liste der Dateinamen aller versionierten Tests, kleingeschrieben, je
# Prozess genau einmal erhoben. Ein Guard-Aufruf prüft leicht ein Dutzend
# Tokens; `git ls-files` je Token kostete gemessen 3,3 s pro Werkzeugaufruf,
# und diese Zeit zahlt jede Runde bei jedem einzelnen Befehl.
VERFOLGTE_TESTNAMEN=""
VERFOLGTE_TESTNAMEN_GELADEN=0

ist_verfolgter_test() {
  local token="$1" projekt="$2" name
  # Schlussstriche weg, sonst ist der "Dateiname" von `test/` leer.
  while [[ "$token" == */ && ${#token} -gt 1 ]]; do token="${token%/}"; done
  # Ein Verzeichnis, in dem Tests liegen, ist so schützenswert wie die Tests
  # darin: `rm -r test` löscht sie alle auf einmal.
  case "$(printf '%s' "${token##*/}" | tr '[:upper:]' '[:lower:]')" in
    test|tests|__tests__|spec) return 0 ;;
  esac
  name=$(printf '%s' "${token##*/}" | tr '[:upper:]' '[:lower:]')
  [[ -z "$name" ]] && return 1
  if (( ! VERFOLGTE_TESTNAMEN_GELADEN )); then
    VERFOLGTE_TESTNAMEN_GELADEN=1
    VERFOLGTE_TESTNAMEN=$(
      git -C "$projekt" ls-files 2>/dev/null \
        | grep -iE "$MUSTER_TESTS" \
        | sed -E 's#.*/##' \
        | tr '[:upper:]' '[:lower:]' \
        | sort -u
    )
  fi
  [[ -z "$VERFOLGTE_TESTNAMEN" ]] && return 1
  grep -qxF -- "$name" <<< "$VERFOLGTE_TESTNAMEN"
}
