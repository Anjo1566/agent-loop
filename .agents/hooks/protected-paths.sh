#!/usr/bin/env bash
# Gemeinsame Pfadmuster der beiden Guards.
#
# Diese Datei wird von guard-files.sh und guard-bash.sh eingelesen, damit beide
# exakt dieselbe Menge schützen. Ohne das driften Datei-Guard und Bash-Guard
# auseinander, und genau diese Lücke ist der bequemste Umweg für den Agenten:
# was das Edit-Werkzeug verbietet, erledigt sonst ein `sed -i`.
#
# Regeln für die Muster:
#   - Sie werden mit `grep -qiE` gegen EINEN Pfad geprüft, nicht gegen eine
#     ganze Kommandozeile. guard-bash.sh zerlegt den Befehl vorher in Tokens.
#   - Backslashes sind vorher zu Schrägstrichen normalisiert (Windows).
#   - Deshalb dürfen die Muster mit `$` ans Ende ankern.

# Bestehende Tests, Snapshots und Fixtures.
MUSTER_TESTS='(\.test\.|\.spec\.|_test\.[a-z0-9]+$|(^|/)test_[^/]*\.py$|(^|/)tests?/|(^|/)spec/|(^|/)__tests__/|(^|/)conftest\.py$|\.snap$)'

# Abhängigkeiten, Lockfiles, Build- und CI-Konfiguration.
MUSTER_DEPS='((^|/)package(-lock)?\.json$|(^|/)yarn\.lock$|(^|/)pnpm-lock\.[a-z]+$|(^|/)npm-shrinkwrap\.json$|(^|/)requirements([-.][^/]*)?\.txt$|(^|/)pyproject\.toml$|(^|/)poetry\.lock$|(^|/)uv\.lock$|(^|/)go\.(mod|sum)$|(^|/)Cargo\.(toml|lock)$|(^|/)pytest\.ini$|(^|/)tox\.ini$|(^|/)\.github/workflows/)'

# Die eigene Konfiguration und die Schutzmechanismen selbst. Ohne diese Regel
# schaltet eine Prompt-Injection über Repo-Inhalte die Guards einfach ab.
MUSTER_SELBST='((^|/)\.claude/|(^|/)CLAUDE\.md$|(^|/)\.agents/hooks/|(^|/)loop\.sh$|(^|/)abnahme\.sh$|(^|/)round\.md$|(^|/)\.mcp\.json$|(^|/)\.gitattributes$)'

# Geheimnisse.
MUSTER_GEHEIM='((^|/)\.env(\.[^/]*)?$|(^|/)id_rsa|(^|/)id_ed25519|\.pem$|\.key$|(^|/)credentials(\.[^/]*)?$|(^|/)\.ssh/|(^|/)\.aws/|(^|/)\.npmrc$|(^|/)\.netrc$)'
