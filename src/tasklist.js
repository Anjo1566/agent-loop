'use strict'

// Parser and serializer for the TASKS.md backlog format.
//
// A backlog line is "- [ ] description" for an open task and "- [x] description"
// for a done one. Highest priority is on top. Anything that is not a task line
// (headings, blank lines, prose) is preserved as-is so the file stays readable
// for a human.

const TASK_LINE = /^(\s*)-\s\[( |x|X)\]\s?(.*)$/

/**
 * Parse a TASKS.md document into a list of entries.
 * Every input line becomes exactly one entry, so parse/format round-trips.
 *
 * @param {string} text
 * @returns {Array<{kind: 'task', done: boolean, text: string, indent: string}
 *               | {kind: 'other', raw: string}>}
 */
function parse (text) {
  if (typeof text !== 'string') throw new TypeError('parse expects a string')
  if (text === '') return []
  return text.split('\n').map(line => {
    const match = TASK_LINE.exec(line)
    if (!match) return { kind: 'other', raw: line }
    return {
      kind: 'task',
      done: match[2].toLowerCase() === 'x',
      text: match[3].trim(),
      indent: match[1]
    }
  })
}

/**
 * Serialize entries back into a TASKS.md document.
 *
 * @param {ReturnType<typeof parse>} entries
 * @returns {string}
 */
function format (entries) {
  if (!Array.isArray(entries)) throw new TypeError('format expects an array')
  return entries.map(entry => {
    if (entry.kind === 'other') return entry.raw
    return `${entry.indent}- [${entry.done ? 'x' : ' '}] ${entry.text}`
  }).join('\n')
}

/**
 * The open tasks of a document, in file order (highest priority first).
 *
 * @param {string} text
 * @returns {string[]}
 */
function openTasks (text) {
  return parse(text)
    .filter(entry => entry.kind === 'task' && !entry.done)
    .map(entry => entry.text)
}

/**
 * Put a task at the top of the document, above every existing task line.
 * Leading non-task lines (a heading, for example) keep their position.
 *
 * @param {string} text
 * @param {string} task
 * @returns {string}
 */
function prepend (text, task) {
  if (typeof task !== 'string' || task.trim() === '') {
    throw new TypeError('prepend expects a non-empty task description')
  }
  const entries = parse(text)
  const firstTask = entries.findIndex(entry => entry.kind === 'task')
  const insertAt = firstTask === -1 ? entries.length : firstTask
  const entry = { kind: 'task', done: false, text: task.trim(), indent: '' }
  entries.splice(insertAt, 0, entry)
  return format(entries)
}

module.exports = { parse, format, openTasks, prepend }
