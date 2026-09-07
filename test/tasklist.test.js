'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const { parse, format, openTasks, prepend } = require('../src/tasklist.js')

test('parse recognises open and done tasks', () => {
  const entries = parse('- [ ] write the loop\n- [x] read the concept')
  assert.equal(entries.length, 2)
  assert.deepEqual(entries[0], { kind: 'task', done: false, text: 'write the loop', indent: '' })
  assert.equal(entries[1].done, true)
})

test('parse keeps non-task lines verbatim', () => {
  const entries = parse('# Backlog\n\n- [ ] one')
  assert.deepEqual(entries[0], { kind: 'other', raw: '# Backlog' })
  assert.deepEqual(entries[1], { kind: 'other', raw: '' })
})

test('parse and format round-trip a document unchanged', () => {
  const text = '# Backlog\n\n- [ ] one\n- [x] two\n\nnotes below'
  assert.equal(format(parse(text)), text)
})

test('openTasks returns only open tasks, in file order', () => {
  assert.deepEqual(openTasks('- [x] done\n- [ ] first\n- [ ] second'), ['first', 'second'])
})

test('prepend puts the task above every existing task', () => {
  const text = '# Backlog\n\n- [ ] old'
  assert.equal(prepend(text, 'urgent'), '# Backlog\n\n- [ ] urgent\n- [ ] old')
})

test('prepend appends when the document has no task line yet', () => {
  assert.equal(prepend('# Backlog', 'first'), '# Backlog\n- [ ] first')
})

test('prepend rejects an empty description', () => {
  assert.throws(() => prepend('- [ ] old', '   '), TypeError)
})
