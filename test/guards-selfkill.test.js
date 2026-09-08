'use strict'

// The bypass that was not a bypass.
//
// Every other rule in guard-bash.sh protects the INTEGRITY of a run: nobody
// weakens a test, nobody force-pushes, nobody hides a change behind a patch
// file. Sixteen bypasses of that kind were found and closed by an adversarial
// review. None of them was the one that actually ended a run.
//
// On 2026-09-07 the grader subagent of the sibling project started the program
// under test — its own instructions demand it ("Run things. Start the program
// if it can be started.") — and then tidied up:
//
//     taskkill //F //IM node.exe //T
//
// By image name, not by PID. That is every node process on the machine: the
// server it had started, the cockpit watching the run, and the Claude Code
// session executing the command. The event stream stops mid tool call, no
// stop-reason.txt is ever written, and loop.sh waited four hours on a child
// that no longer existed.
//
// So this file tests the other axis: AVAILABILITY. A run that shoots itself
// leaves nothing behind to learn from, because the guard that should have
// warned dies with it.

const test = require('node:test')
const assert = require('node:assert/strict')
const { spawnSync } = require('node:child_process')
const path = require('node:path')

const REPO = path.resolve(__dirname, '..')
const HOOKS = path.join(REPO, '.agents', 'hooks')

function runGuard (command) {
  const result = spawnSync('bash', [path.join(HOOKS, 'guard-bash.sh')], {
    input: JSON.stringify({ tool_name: 'Bash', tool_input: { command } }),
    encoding: 'utf8',
    cwd: REPO,
    env: { ...process.env, CLAUDE_PROJECT_DIR: REPO }
  })
  if (result.error) throw result.error
  return { code: result.status, stderr: result.stderr }
}

function blocks (command) {
  const { code, stderr } = runGuard(command)
  assert.equal(code, 2, `expected exit 2 for ${command}, got ${code}. stderr: ${stderr.trim()}`)
  assert.match(stderr, /^Blocked:/m, `block must state a reason: ${command}`)
}

function allows (command) {
  const { code, stderr } = runGuard(command)
  assert.equal(code, 0, `expected exit 0 for ${command}, got ${code}. stderr: ${stderr.trim()}`)
}

test('guard-bash blocks the exact command that ended the run', () => {
  blocks('taskkill //F //IM node.exe //T 2>/dev/null; echo done')
})

test('guard-bash blocks killing processes as a class, not as one spelling', () => {
  // A rule that only knows the one spelling is open again after the first
  // rephrasing, and the model has no reason to prefer the blocked spelling.
  for (const command of [
    'taskkill /F /IM node.exe /T',           // single slashes, as cmd.exe takes them
    'TASKKILL /F /IM node.exe',              // cmd.exe is not case sensitive
    'bash -c "taskkill //F //IM node.exe"',  // hidden behind a second interpreter
    'pkill -9 node',
    'pkill -f claude',
    'killall node',
    'tskill node',
    'kill -9 $PPID',
    'kill 12345',
    'kill -STOP $$',                         // suspending ends the run just as well
    'echo 1234 | xargs kill',
    'echo 1234 | xargs -r kill -9',
    'powershell -c "Stop-Process -Name node -Force"',
    'powershell -Command "Get-Process node | Stop-Process -Force"',
    'wmic process where "name=\'node.exe\'" delete',
    'sc stop W32Time',
    'net stop W32Time',
    'shutdown /s /t 0',
    'logoff',
    'node -e "process.kill(process.ppid)"',
    'python -c "import os,signal; os.kill(os.getppid(), 9)"'
  ]) {
    blocks(command)
  }
})

test('guard-bash still allows ordinary work', () => {
  // A guard that blocks too much gets worked around instead of obeyed. And
  // "kill" is an ordinary English word: it appears in search patterns, in
  // commit messages, and in this very file.
  for (const command of [
    'node --test',
    'npm test',
    'git status --porcelain',
    'grep -rn "kill" src/tasklist.js',
    'git commit -m "kill 3 flaky tests"',
    'grep -c "skill" README.md',
    'echo "the process was killed by the reviewer"',
    'timeout 20 npm start'   // the recommended way, instead of shooting it afterwards
  ]) {
    allows(command)
  }
})

test('the block explains what to do instead', () => {
  // A refusal the model cannot act on gets retried in another spelling until
  // one slips through.
  const { stderr } = runGuard('taskkill //F //IM node.exe //T')
  assert.match(stderr, /timeout/i, 'the message must name the alternative')
  assert.match(stderr, /node process/i, 'the message must say why it hits the agent itself')
})
