'use strict'

// The guards are the only mechanical safeguard in this loop, and a guard that
// silently stops guarding looks exactly like a guard that works. So they are
// tested like production code, and the suite runs in every round.
//
// Contract under test: exit 2 blocks a tool call, every other exit code lets it
// through. That asymmetry is why "did not block" is the interesting failure.

const test = require('node:test')
const assert = require('node:assert/strict')
const { spawnSync } = require('node:child_process')
const path = require('node:path')

const REPO = path.resolve(__dirname, '..')
const HOOKS = path.join(REPO, '.agents', 'hooks')

// A real file inside the repo that the test-file rules must protect.
const EXISTING_TEST = path.join(REPO, 'test', 'tasklist.test.js')

function runGuard (script, payload) {
  const result = spawnSync('bash', [path.join(HOOKS, script)], {
    input: JSON.stringify(payload),
    encoding: 'utf8',
    cwd: REPO
  })
  if (result.error) throw result.error
  return { code: result.status, stderr: result.stderr }
}

const fileCall = (tool, filePath) => ({ tool_name: tool, tool_input: { file_path: filePath } })
const bashCall = command => ({ tool_name: 'Bash', tool_input: { command } })

function blocks (guard, payload, why) {
  const { code, stderr } = runGuard(guard, payload)
  assert.equal(code, 2, `${why}: expected exit 2, got ${code}. stderr: ${stderr.trim()}`)
  assert.match(stderr, /^Blocked:/m, `${why}: block must state a reason on stderr`)
}

function allows (guard, payload, why) {
  const { code, stderr } = runGuard(guard, payload)
  assert.equal(code, 0, `${why}: expected exit 0, got ${code}. stderr: ${stderr.trim()}`)
}

test('guard-files blocks writes to an existing test file', () => {
  blocks('guard-files.sh', fileCall('Write', EXISTING_TEST), 'write to existing test')
  blocks('guard-files.sh', fileCall('Edit', EXISTING_TEST), 'edit existing test')
})

test('guard-files allows a NEW test file', () => {
  // The charter lets the agent design tests for new code; only weakening an
  // existing test is forbidden. Without this the test count could never grow.
  allows('guard-files.sh', fileCall('Write', path.join(REPO, 'test', 'brand-new.test.js')), 'new test file')
})

test('guard-files allows READING a test file', () => {
  // The reviewer's second check is "was an existing test weakened?". Blocking
  // Read would make that check impossible.
  allows('guard-files.sh', fileCall('Read', EXISTING_TEST), 'read a test')
  allows('guard-files.sh', fileCall('Read', path.join(REPO, 'package.json')), 'read package.json')
})

test('guard-files blocks dependency and build configuration', () => {
  blocks('guard-files.sh', fileCall('Write', path.join(REPO, 'package.json')), 'package.json')
  blocks('guard-files.sh', fileCall('Write', path.join(REPO, '.github', 'workflows', 'ci.yml')), 'CI workflow')
})

test('guard-files blocks the safeguards themselves', () => {
  blocks('guard-files.sh', fileCall('Write', path.join(REPO, '.claude', 'settings.json')), 'settings.json')
  blocks('guard-files.sh', fileCall('Write', path.join(REPO, 'CLAUDE.md')), 'CLAUDE.md')
  blocks('guard-files.sh', fileCall('Write', path.join(HOOKS, 'guard-bash.sh')), 'guard script')
  blocks('guard-files.sh', fileCall('Write', path.join(REPO, 'loop.sh')), 'loop.sh')
  blocks('guard-files.sh', fileCall('Write', path.join(REPO, 'round.md')), 'round.md')
})

test('guard-files blocks the safeguards on a Windows-style path', () => {
  // Unnormalised backslashes would slip past every pattern.
  blocks('guard-files.sh', fileCall('Write', 'C:\\repo\\.claude\\settings.json'), 'backslash path')
})

test('guard-files blocks secrets for every tool, reading included', () => {
  blocks('guard-files.sh', fileCall('Read', path.join(REPO, '.env')), 'read .env')
  blocks('guard-files.sh', fileCall('Write', path.join(REPO, 'deploy.pem')), 'write a key')
})

test('guard-files blocks NotebookEdit, which carries a different path key', () => {
  blocks('guard-files.sh', {
    tool_name: 'NotebookEdit',
    tool_input: { notebook_path: path.join(REPO, '.claude', 'settings.json') }
  }, 'notebook_path')
})

test('guard-files allows ordinary source files', () => {
  allows('guard-files.sh', fileCall('Write', path.join(REPO, 'src', 'tasklist.js')), 'source file')
})

test('guard-files fails closed on an unusable payload', () => {
  // A guard that cannot judge must block. Anything else is a guard that is off.
  blocks('guard-files.sh', { tool_input: { file_path: '/repo/src/a.js' } }, 'payload without tool_name')
})

test('guard-bash blocks bypassing the commit hooks, long and short form', () => {
  blocks('guard-bash.sh', bashCall('git commit --no-verify -m "x"'), '--no-verify')
  blocks('guard-bash.sh', bashCall('git commit -n -m "x"'), '-n')
})

test('guard-bash blocks discarding work', () => {
  blocks('guard-bash.sh', bashCall('git stash'), 'stash')
  blocks('guard-bash.sh', bashCall('git reset --hard HEAD~1'), 'reset --hard')
  blocks('guard-bash.sh', bashCall('git clean -fdx'), 'clean')
  blocks('guard-bash.sh', bashCall('git restore test/tasklist.test.js'), 'restore')
  blocks('guard-bash.sh', bashCall('git checkout HEAD -- test/tasklist.test.js'), 'checkout a ref')
  blocks('guard-bash.sh', bashCall('rm -rf /'), 'rm -rf /')
})

test('guard-bash blocks every route to main and every force push', () => {
  blocks('guard-bash.sh', bashCall('git push origin main'), 'push main')
  blocks('guard-bash.sh', bashCall('git push origin HEAD:main'), 'push HEAD:main')
  blocks('guard-bash.sh', bashCall('git push --force origin agent/x'), '--force')
  blocks('guard-bash.sh', bashCall('git push -f origin agent/x'), '-f')
  blocks('guard-bash.sh', bashCall('git push --force-with-lease origin agent/x'), '--force-with-lease')
  blocks('guard-bash.sh', bashCall('git push origin +agent/x:agent/x'), '+refspec')
  blocks('guard-bash.sh', bashCall('git -c core.hooksPath=/dev/null push --force origin main'), 'git -c bypass')
  blocks('guard-bash.sh', bashCall('git push --delete origin agent/x'), '--delete')
})

test('guard-bash allows a push to the agent branch', () => {
  allows('guard-bash.sh', bashCall('git push -u origin agent/20260907-1030'), 'agent branch')
  // Regression: a substring match on "main" blocked legitimate branch names.
  allows('guard-bash.sh', bashCall('git push -u origin agent/maintenance'), 'branch containing "main"')
  allows('guard-bash.sh', bashCall('git push -u origin agent/20260907-domain-fix'), 'branch containing "domain"')
})

test('guard-bash closes the shell route around the file guard', () => {
  blocks('guard-bash.sh', bashCall("sed -i 's/assert/\\/\\/assert/' test/tasklist.test.js"), 'sed -i on a test')
  blocks('guard-bash.sh', bashCall('cat > test/tasklist.test.js'), 'redirect over a test')
  blocks('guard-bash.sh', bashCall('rm test/tasklist.test.js'), 'rm a test')
  blocks('guard-bash.sh', bashCall('echo x >> .claude/settings.json'), 'append to settings')
  blocks('guard-bash.sh', bashCall('chmod -x .agents/hooks/guard-bash.sh'), 'disarm a guard')
  blocks('guard-bash.sh', bashCall('cat .env'), 'read a secret')
})

test('guard-bash allows ordinary work', () => {
  allows('guard-bash.sh', bashCall('node --test'), 'run the tests')
  allows('guard-bash.sh', bashCall('git diff -- test/tasklist.test.js'), 'read a test through git')
  allows('guard-bash.sh', bashCall('git add -A && git commit -m "add close()"'), 'commit')
  allows('guard-bash.sh', bashCall('echo "module.exports = {}" > src/new-module.js'), 'write a source file')
})

test('guard-bash ignores a call without a command', () => {
  allows('guard-bash.sh', { tool_name: 'Bash', tool_input: {} }, 'empty command')
})
