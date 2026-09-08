'use strict'

// Was der zweite adversariale Durchgang gefunden hat.
//
// Jeder Fall hier ist ein Befehl, der zum Zeitpunkt des Reviews Exit 0 bekam
// und trotzdem eine geschuetzte Datei erreichte -- oder umgekehrt ein voellig
// harmloser Befehl, der blockiert wurde und den Agenten Runden gekostet hat.
// Beide Richtungen gehoeren in dieselbe Datei: ein Guard, der zu viel sperrt,
// bringt das Modell dazu, Umwege zu suchen, und ein Umweg, den es einmal
// gelernt hat, findet es beim naechsten Mal schneller.
//
// Die Faelle sind nach dem Befund aus REVIEW.md benannt, damit man von einer
// Regression zurueck zur Begruendung kommt.

const test = require('node:test')
const assert = require('node:assert/strict')
const { spawnSync } = require('node:child_process')
const path = require('node:path')

const REPO = path.resolve(__dirname, '..')
const HOOKS = path.join(REPO, '.agents', 'hooks')

// Diese Datei selbst ist der verfolgte Test, an dem die Pfadregeln haengen --
// so wandert die Suite mit, wenn jemand das Beispielprojekt entfernt (E11).
const TEST_REL = path.relative(REPO, __filename).replace(/\\/g, '/')

function runGuard (script, payload) {
  const r = spawnSync('bash', [path.join(HOOKS, script)], {
    input: JSON.stringify(payload),
    encoding: 'utf8',
    cwd: REPO,
    env: { ...process.env, CLAUDE_PROJECT_DIR: REPO }
  })
  if (r.error) throw r.error
  return { code: r.status, stderr: r.stderr }
}

const bash = command => ({ tool_name: 'Bash', tool_input: { command } })
const write = filePath => ({ tool_name: 'Write', tool_input: { file_path: filePath } })

function blocks (payload, why) {
  const { code, stderr } = runGuard(
    payload.tool_name === 'Bash' ? 'guard-bash.sh' : 'guard-files.sh', payload)
  assert.equal(code, 2, `${why}: expected exit 2, got ${code}. stderr: ${stderr.trim()}`)
  assert.match(stderr, /^Blocked:/m, `${why}: a block must state a reason`)
}

function allows (payload, why) {
  const { code, stderr } = runGuard(
    payload.tool_name === 'Bash' ? 'guard-bash.sh' : 'guard-files.sh', payload)
  assert.equal(code, 0, `${why}: expected exit 0, got ${code}. stderr: ${stderr.trim()}`)
}

// --- M-2: die Befehlsworte waren case-sensitive, NTFS ist es nicht ---------
//
// `type -a SED` liefert auf diesem Rechner /usr/bin/SED. Im Review hat
// `SED --in-place 1d test/guards.test.js` eine verfolgte Testdatei veraendert,
// waehrend der Guard 0 zurueckgab.
test('guard-bash blocks writing commands whatever their case', () => {
  for (const c of [
    `SED -i 1d ${TEST_REL}`,
    `SED --in-place 1d ${TEST_REL}`,
    'RM -rf test',
    `Rm ${TEST_REL}`,
    `CP neu.test.js ${TEST_REL}`,
    `Mv ${TEST_REL} test/weg.test.js`
  ]) blocks(bash(c), `uppercase: ${c}`)
})

// --- M-3: die lange Schreibweise des In-place-Schalters --------------------
//
// Das Muster suchte `(c|e)` direkt vor Leerzeichen, `=` oder Zeilenende. In
// `--in-place` steht das `e` mitten im Wort, also traf es nicht.
test('guard-bash blocks the long spelling of an in-place switch', () => {
  for (const c of [
    `sed --in-place 1d ${TEST_REL}`,
    `sed --in-place=.bak 1d ${TEST_REL}`,
    `sed --expression=1d --in-place ${TEST_REL}`
  ]) blocks(bash(c), `long option: ${c}`)
})

// --- M-4: der Windows-Suffix hebelte die Interpreterregeln aus -------------
test('guard-bash blocks an interpreter spelled with its .exe suffix', () => {
  for (const c of [
    'bash.exe /tmp/evil.sh',
    'node.exe /tmp/evil.js',
    'sh.exe /tmp/evil.sh',
    'python.exe /tmp/evil.py'
  ]) blocks(bash(c), `exe suffix: ${c}`)
})

// --- M-1: PowerShell ist die zweite Shell, und sie war unbewacht -----------
//
// settings.json fuehrt den Matcher `Bash|PowerShell` seit A8, aber das Skript
// kannte kein einziges PowerShell-Verb. Der Hook feuert -- das ist im Review
// direkt geprueft worden -- und gab 0 zurueck.
test('guard-bash blocks PowerShell write verbs on protected paths', () => {
  for (const c of [
    "Set-Content -Path .claude/settings.json -Value '{}'",
    "Add-Content .agents/hooks/guard-bash.sh 'exit 0'",
    `New-Item -Force -ItemType File -Path ${TEST_REL}`,
    'Rename-Item .agents/hooks .agents/hooks-off',
    'Move-Item .claude .claude-off',
    'Clear-Content loop.sh',
    'Remove-Item -Recurse -Force .agents/hooks',
    `Copy-Item neu.test.js ${TEST_REL} -Force`,
    'Out-File -FilePath loop.sh -InputObject x'
  ]) blocks(bash(c), `powershell: ${c}`)
})

test('guard-bash blocks the .NET file API, which carries no verb at all', () => {
  blocks(bash("[System.IO.File]::WriteAllText('loop.sh','')"), 'WriteAllText')
  blocks(bash(`[IO.File]::Delete('${TEST_REL}')`), 'Delete')
})

// --- M-8: Werkzeuge, deren Ziele im Archiv oder in der Pipe stehen ---------
//
// Dieselbe Begruendung, aus der `patch` und `git apply` schon abgelehnt
// werden: der Guard sieht die Pfade nicht, also kann er sie nicht pruefen.
test('guard-bash refuses archives and xargs, like it refuses patch', () => {
  for (const c of [
    'tar -xf payload.tar',
    'tar -xzf /tmp/x.tgz -C .',
    'unzip -o payload.zip',
    'cpio -i < archive.cpio',
    '7z x payload.7z -y',
    'xargs -a list.txt rm',
    'cat list.txt | xargs rm'
  ]) blocks(bash(c), `unnamed targets: ${c}`)
})

test('guard-bash still allows packing, which names its source', () => {
  allows(bash('tar -czf /tmp/backup.tgz src'), 'tar -c')
  // `--exclude` traegt ein x im Wort; das Muster verlangt Buchstaben direkt
  // hinter EINEM Bindestrich und trifft es deshalb nicht.
  allows(bash('tar --exclude=node_modules -czf /tmp/b.tgz .'), 'tar with --exclude')
})

// --- M-9: den Arbeitsbaum wegwerfen, ohne stash/clean/restore -------------
test('guard-bash blocks the force variants of checkout and switch', () => {
  for (const c of [
    'git checkout -f main',
    'git checkout -f .',
    'git checkout -f -- .',
    'git switch --discard-changes main',
    'git switch -f main'
  ]) blocks(bash(c), `discards work: ${c}`)
})

// Gegenprobe zum selben Muster: das alte verlangte hinter dem Ref nur die
// Zeichen `--`, und die stehen am Anfang jeder langen Option. Ein blosser
// Branchwechsel war dadurch gesperrt.
test('guard-bash allows an ordinary branch switch', () => {
  allows(bash('git checkout main --quiet'), 'checkout with a long option')
  allows(bash('git switch main'), 'switch')
  allows(bash('git checkout -b agent/x'), 'new branch')
})

// --- m-4 / m-6: Token, Aussenwirkung, fremde Vorlagen ---------------------
test('guard-bash blocks the other ways to read the token or reach outward', () => {
  // `gh auth token` war gesperrt; `git credential fill` druckt dasselbe.
  blocks(bash('git credential fill'), 'git credential')
  blocks(bash('git daemon --export-all --base-path=.'), 'git daemon')
  blocks(bash('git send-email --to x'), 'git send-email')
  blocks(bash('git init --template=/tmp/evil'), 'template directory')
  blocks(bash('git submodule add /tmp/evil sub'), 'submodule add')
})

// --- m-5: Paketmanager in anderer Schreibweise ----------------------------
test('guard-bash blocks npx under its other names', () => {
  blocks(bash('npm exec -- json -I -f package.json'), 'npm exec')
  blocks(bash('pnpm dlx cowsay hi'), 'pnpm dlx')
  blocks(bash('npm create vite'), 'npm create')
  blocks(bash('corepack yarn add foo'), 'corepack')
})

test('guard-bash still allows running the project own scripts', () => {
  // package.json ist fuer den Agenten unveraenderbar, der Inhalt stammt also
  // vom Menschen. Das Review hat `node --run` mit auf die Sperrliste gesetzt;
  // das war falsch und haette nur den Testlauf des Coders zerschlagen.
  allows(bash('npm test'), 'npm test')
  allows(bash('npm run build'), 'npm run')
  allows(bash('node --run build'), 'node --run')
})

// --- M-13: die Falschmeldungen, die im Betrieb Runden gekostet haben ------
//
// Alle drei sind echte Vorfaelle aus QUESTIONS.md von agent-cockpit. Der
// Guard setzte SCHREIBT, sobald irgendwo ein englisches Wort aus der Liste
// stand -- auch mitten in einem Satz in Anfuehrungszeichen -- und lehnte dann
// wegen eines `$` irgendwo in der Zeile ab.
test('guard-bash no longer blocks read-only commands that merely contain a write word', () => {
  for (const c of [
    'echo "the copy of the guards is stale, see $HOME"',
    'git log --oneline | grep -i "move the parser" | head -$N',
    'echo "install notes here"; ls $PWD',
    'echo "we need to copy the fixture"',
    'grep -rn "remove-item" src/ | head -20'
  ]) allows(bash(c), `false positive: ${c}`)
})

// Die Regel selbst bleibt scharf: steht die Ersetzung IM Schreibbefehl, ist
// sein Ziel nicht ausrechenbar und er wird abgelehnt.
test('guard-bash still refuses a write whose own target is computed', () => {
  blocks(bash('sed -i 1d ${TEST}'), 'variable target')
  blocks(bash('rm $(cat liste)'), 'command substitution')
  blocks(bash('echo x > $(echo loop.sh)'), 'computed redirection')
  blocks(bash('Z=loop.sh; echo x > $Z'), 'variable redirection')
})

// Ein `sed -i` auf eine gewoehnliche Quelldatei muss durchgehen, auch wenn im
// Ausdruck ein Schreibwort vorkommt: sonst waere die naheliegendste
// Codeaenderung gesperrt.
test('guard-bash allows sed -i on an ordinary source file', () => {
  allows(bash("sed -i 's/mkdir/x/' src/tasklist.js"), 'sed on source')
})

// --- Und was beim Angriff auf DIESE Fassung noch aufging -----------------
//
// Die Muster oben waren auf "schreibende Programme" ausgelegt und uebersahen
// die Programme, die ihr Ziel als OPTION tragen. Zwoelf Faelle, alle beim
// Nachtreten gegen die eigene neue Fassung gefunden, bevor jemand anders sie
// findet.

test('guard-bash blocks downloaders that write a named file', () => {
  for (const c of [
    'curl -o loop.sh http://example.invalid/x',
    `curl --output ${TEST_REL} http://x/y`,
    'wget -O loop.sh http://x/y',
    'wget --output-document=.claude/settings.json http://x/y',
    'Invoke-WebRequest -Uri http://x -OutFile loop.sh',
    'bitsadmin /transfer j http://x/y loop.sh'
  ]) blocks(bash(c), `downloader: ${c}`)
})

test('guard-bash still allows fetching without writing a protected file', () => {
  allows(bash('curl -sS http://example.invalid/x'), 'plain fetch')
  allows(bash('curl -s http://example.invalid/api > /tmp/antwort.json'), 'fetch into temp')
  allows(bash('wget -q -O /tmp/x http://example.invalid/y'), 'wget into temp')
})

test('guard-bash blocks the Windows file writers', () => {
  for (const c of [
    'certutil -decode payload.b64 loop.sh',
    'robocopy /tmp/src . loop.sh',
    'xcopy /Y C:\\tmp\\x loop.sh',
    "New-Object System.IO.StreamWriter('loop.sh')"
  ]) blocks(bash(c), `windows writer: ${c}`)
})

test('guard-bash blocks the uppercase long switch too', () => {
  // Lange Optionen gibt es in keinem Programm in Grossbuchstaben, also kostet
  // es nichts, sie case-insensitiv zu pruefen -- anders als bei -e gegen -E.
  blocks(bash(`SED --IN-PLACE 1d ${TEST_REL}`), 'uppercase long option')
})

test('guard-bash blocks the writing git-notes subcommands, not the reading ones', () => {
  blocks(bash('git no' + 'tes add -m x'), 'notes add')
  allows(bash('git no' + 'tes list'), 'notes list')
})
