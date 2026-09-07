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

# Bestehende Tests, Snapshots und Fixtures.
# `spec/` ist bewusst eng gefasst: ein Verzeichnis dieses Namens enthält oft
# eine OpenAPI-Spezifikation, und die ist kein Test.
#
# Die Liste muss decken, was der Testläufer entdeckt, sonst ist eine Datei zwar
# ein Test, aber ungeschützt: `node --test` findet auch `helper-test.js` und
# `test.js`, nicht nur `*.test.js`.
MUSTER_TESTS='(\.test\.|\.spec\.|[-_]test\.[a-z0-9]+$|(^|/)test\.[a-z0-9]+$|(^|/)test_[^/]*\.py$|(^|/)tests?/|(^|/)__tests__/|(^|/)spec/[^/]*[._-](spec|test)\.[a-z0-9]+$|(^|/)conftest\.py$|\.snap$)'

# Abhängigkeiten, Lockfiles, Build- und CI-Konfiguration.
MUSTER_DEPS='((^|/)package(-lock)?\.json$|(^|/)yarn\.lock$|(^|/)pnpm-lock\.[a-z]+$|(^|/)npm-shrinkwrap\.json$|(^|/)requirements([-.][^/]*)?\.txt$|(^|/)pyproject\.toml$|(^|/)poetry\.lock$|(^|/)uv\.lock$|(^|/)go\.(mod|sum)$|(^|/)Cargo\.(toml|lock)$|(^|/)pytest\.ini$|(^|/)tox\.ini$|(^|/)\.github/workflows/)'

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
MUSTER_SELBST='((^|/)\.claude(/|\.json$)|(^|/)CLAUDE\.md$|(^|/)\.agents/hooks/|(^|/)\.devcontainer/|(^|/)loop\.sh$|(^|/)abnahme\.sh$|(^|/)round\.md$|(^|/)\.mcp\.json$|(^|/)\.gitattributes$)'

# Geheimnisse. `credentials` ist auf Konfigurationsendungen eingegrenzt, damit
# ein Quellmodul src/auth/credentials.js lesbar bleibt — der Reviewer soll
# genau das prüfen können.
MUSTER_GEHEIM='((^|/)\.env(\.[^/]*)?$|(^|/)id_rsa|(^|/)id_ed25519|\.pem$|\.key$|(^|/)credentials$|(^|/)credentials\.(json|ini|cfg|ya?ml|toml|txt)$|(^|/)\.ssh/|(^|/)\.aws/|(^|/)\.npmrc$|(^|/)\.netrc$)'

# Vorlagendateien tragen per Konvention keine Geheimnisse und müssen lesbar
# und schreibbar bleiben.
MUSTER_GEHEIM_HARMLOS='(^|/)\.env\.(example|sample|template|dist|defaults)$'
