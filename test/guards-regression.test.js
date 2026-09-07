'use strict'

// Regressions from the adversarial review of the first version.
//
// Every case below was either a working bypass or a wrong block. They live in
// their own file because they are not a description of the design — they are a
// list of the specific ways this design was already broken once. Each one is
// invisible in normal operation: a guard that stopped guarding looks exactly
// like a guard that works, and a guard that blocks too much only shows up when
// the coder is already stuck.

const test = require('node:test')
const assert = require('node:assert/strict')
const { spawnSync } = require('node:child_process')
const path = require('node:path')

const REPO = path.resolve(__dirname, '..')
const HOOKS = path.join(REPO, '.agents', 'hooks')
// This file itself: a tracked test file that travels with these tests, so they
// keep working after the example project is removed.
const EXISTING_TEST_REL = path.relative(REPO, __filename).replace(/\\/g, '/')

function runGuard (script, payload, cwd = REPO) {
  const result = spawnSync('bash', [path.join(HOOKS, script)], {
    input: JSON.stringify(payload),
    encoding: 'utf8',
    cwd,
    env: { ...process.env, CLAUDE_PROJECT_DIR: REPO }
  })
  if (result.error) throw result.error
  return { code: result.status, stderr: result.stderr }
}

const fileCall = (tool, filePath) => ({ tool_name: tool, tool_input: { file_path: filePath } })
const bashCall = command => ({ tool_name: 'Bash', tool_input: { command } })

function blocks (guard, payload, why) {
  const { code, stderr } = runGuard(guard, payload)
  assert.equal(code, 2, `${why}: expected exit 2, got ${code}. stderr: ${stderr.trim()}`)
}

function allows (guard, payload, why) {
  const { code, stderr } = runGuard(guard, payload)
  assert.equal(code, 0, `${why}: expected exit 0, got ${code}. stderr: ${stderr.trim()}`)
}

test('a wrapping shell, quotes or parentheses do not hide the command', () => {
  // The word boundary carried no quote and no paren, so one `bash -c` in front
  // of any blocked command turned the entire path check off.
  blocks('guard-bash.sh', bashCall(`bash -c "sed -i 1d ${EXISTING_TEST_REL}"`), 'bash -c wrapper')
  blocks('guard-bash.sh', bashCall(`sh -c 'sed -i 1d ${EXISTING_TEST_REL}'`), 'sh -c wrapper')
  blocks('guard-bash.sh', bashCall(`(sed -i 1d ${EXISTING_TEST_REL})`), 'subshell')
  blocks('guard-bash.sh', bashCall(`"sed" -i 1d ${EXISTING_TEST_REL}`), 'quoted verb')
})

test('globs are resolved the way the shell will resolve them', () => {
  // Every pattern anchored on a file name missed `loop.s[h]` and `loop.s?`,
  // which bash still expands to the real file.
  blocks('guard-bash.sh', bashCall('sed -i 1d loop.s[h]'), 'bracket glob')
  blocks('guard-bash.sh', bashCall('rm loop.s?'), 'question-mark glob')
  blocks('guard-bash.sh', bashCall('rm test/*.test.js'), 'star glob')
  blocks('guard-bash.sh', bashCall('cat .env*'), 'glob onto a secret')
})

test('tools whose target lives inside a file are refused, not inspected', () => {
  // git apply and patch carry the path in the diff, where no token check can
  // reach it. The coder has Edit for legitimate changes.
  blocks('guard-bash.sh', bashCall('git apply weaken.diff'), 'git apply')
  blocks('guard-bash.sh', bashCall('patch -p1 -i weaken.diff'), 'patch -i')
  blocks('guard-bash.sh', bashCall('patch -p1 < weaken.diff'), 'patch via stdin')
  blocks('guard-bash.sh', bashCall('find test -name "*.test.js" -delete'), 'find -delete')
  blocks('guard-bash.sh', bashCall('find . -name "*.js" -exec sed -i 1d {} +'), 'find -exec')
})

test('package managers cannot rewrite the manifest unnamed', () => {
  blocks('guard-bash.sh', bashCall('npm pkg set scripts.test="exit 0"'), 'npm pkg set')
  blocks('guard-bash.sh', bashCall('npm install --save-dev foo'), 'npm install')
  blocks('guard-bash.sh', bashCall('yarn add foo'), 'yarn add')
  blocks('guard-bash.sh', bashCall('npx json -I -f package.json -e "this.scripts={}"'), 'npx')
  blocks('guard-bash.sh', bashCall('pip install requests'), 'pip install')
})

test('a push must name the agent branch explicitly', () => {
  // A bare `git push` pushes the current branch, which can be main without the
  // word ever appearing in the command.
  blocks('guard-bash.sh', bashCall('git push'), 'bare push')
  blocks('guard-bash.sh', bashCall('git push origin'), 'push without refspec')
  blocks('guard-bash.sh', bashCall('git push origin HEAD'), 'push HEAD')
  blocks('guard-bash.sh', bashCall('git push -u origin HEAD'), 'push -u HEAD')
  // -fu is --force --set-upstream. The old pattern only caught f as the last
  // letter of the flag cluster, so -uf was blocked and -fu was not.
  blocks('guard-bash.sh', bashCall('git push -fu origin agent/x'), 'force in -fu')
  blocks('guard-bash.sh', bashCall('git push -uf origin agent/x'), 'force in -uf')
})

test('the coder can still narrow down a failing test', () => {
  // Interpreters were treated as writers unconditionally, so running a single
  // test file — the first thing anyone does with a red suite — was blocked.
  allows('guard-bash.sh', bashCall(`node --test ${EXISTING_TEST_REL}`), 'one test file')
  allows('guard-bash.sh', bashCall('python -m pytest tests/test_api.py -k foo'), 'one pytest file')
  allows('guard-bash.sh', bashCall(`sed -n 1,5p ${EXISTING_TEST_REL}`), 'sed without -i')
})

test('redirecting stderr is not a write', () => {
  // A bare `>` matched anywhere in the line, so 2>/dev/null and 2>&1 counted as
  // writes and blocked read-only inspection — including the reviewer's own job.
  allows('guard-bash.sh', bashCall(`grep -n assert ${EXISTING_TEST_REL} 2>/dev/null`), '2>/dev/null')
  allows('guard-bash.sh', bashCall('node --test 2>&1 | tail -20'), '2>&1')
  allows('guard-bash.sh', bashCall(`git diff -- ${EXISTING_TEST_REL} > /tmp/d.diff`), 'unprotected target')
  allows('guard-bash.sh', bashCall('cat package.json | jq -r .version > /tmp/v'), 'read a manifest')
})

test('both guards agree about what counts as a new test file', () => {
  // protected-paths.sh exists so the two cannot disagree. They did: the file
  // guard allowed a new test, the bash guard refused the same creation.
  allows('guard-bash.sh', bashCall('touch test/brand-new.test.js'), 'touch a new test')
  allows('guard-bash.sh', bashCall('echo x > test/brand-new.test.js'), 'redirect into a new test')
  blocks('guard-bash.sh', bashCall(`echo x > ${EXISTING_TEST_REL}`), 'redirect over an existing test')
})

test('"existing" means tracked by git, not present on disk', () => {
  // Otherwise delete-then-write defeats the rule, and both brakes in loop.sh
  // stay silent: the suite is green and the test count is unchanged.
  const tracked = spawnSync('git', ['ls-files', '--error-unmatch', '--', EXISTING_TEST_REL],
    { cwd: REPO, encoding: 'utf8' })
  assert.equal(tracked.status, 0, 'fixture must be a tracked file')
  blocks('guard-files.sh', fileCall('Write', __filename), 'tracked test')
})

test('the config file and the container are protected too', () => {
  // ~/.claude.json carries mcpServers — an entry there is an arbitrary command
  // launched at the start of every later round. .devcontainer/ carries the
  // egress firewall, which the concept calls the real security boundary.
  blocks('guard-files.sh', fileCall('Write', path.join(REPO, '..', '.claude.json')), '.claude.json')
  blocks('guard-files.sh', fileCall('Write', path.join(REPO, '.devcontainer', 'init-firewall.sh')), 'firewall')
  blocks('guard-files.sh', fileCall('Write', path.join(REPO, '.devcontainer', 'devcontainer.json')), 'devcontainer')
  blocks('guard-bash.sh', bashCall('echo x > .devcontainer/init-firewall.sh'), 'firewall via shell')
})

test('template files and source modules stay readable', () => {
  // The secrets rule runs for every tool, reading included, so over-blocking
  // here costs the reviewer its security checkpoint.
  allows('guard-files.sh', fileCall('Read', path.join(REPO, '.env.example')), '.env.example')
  allows('guard-files.sh', fileCall('Read', path.join(REPO, 'src', 'auth', 'credentials.js')), 'credentials.js')
  blocks('guard-files.sh', fileCall('Read', path.join(REPO, '.env.production')), 'a real .env')
})

test('relative paths resolve against the project, not the working directory', () => {
  // Hooks run in the session's working directory. With a cwd-relative
  // existence check, one `cd` turned the test protection off silently.
  const { code } = runGuard('guard-files.sh',
    fileCall('Write', EXISTING_TEST_REL),
    path.join(REPO, 'src'))
  assert.equal(code, 2, `expected exit 2 from a subdirectory, got ${code}`)
})
