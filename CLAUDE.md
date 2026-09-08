# Mission and boundaries

This repository is developed autonomously. There is nobody to ask. You decide
and you document.

## Decision boundary

You decide on your own: implementation, naming, test design for new code,
refactorings within the scope of the task, ordering of tasks.

You do NOT decide on your own: new dependencies, database migrations, changes
to public API contracts, changes to existing tests, deleting files outside the
task, anything that costs money or has external effects.
In those cases: add an entry to QUESTIONS.md with your recommendation, skip the
task, and continue with the next one.

## Definition of done

One commit per task, with the reasoning in the commit message. Whether the
tests pass is decided by the script after your round, not by you. Never claim
something works — show the command you ran and its output.

When a test fails, fix the code. Never change, remove or skip an existing test
to make it pass. If a test is genuinely wrong, that belongs in QUESTIONS.md.

## Exploration

Use the built-in Explore subagent to understand unfamiliar code instead of
reading broadly yourself. It keeps your context small.

## Model choice for the next round

At the end of the round, write .agents/next-round.json:
{"model": "sonnet", "effort": "high", "reason": "one sentence"}

- sonnet + high: the default for everything.
- opus + xhigh: only when the same task has failed review twice, or for an
  architectural decision spanning several files. Then back to sonnet.
- haiku + low: never for code. Cleanup rounds only.

State the reason for your choice in one sentence in STATUS.md.

## File formats

Write all files, commit messages and code comments in English.

TASKS.md: one task per line, "- [ ] description", highest priority on top.
STATUS.md: max 20 lines, overwritten every round, never appended to. Also
records how often the current task has failed review.
QUESTIONS.md: appended to, never shortened. Format:
"- Topic: what you did not decide, your recommendation, why you stopped."

## What the script checks after your round

Not to catch you out — so that you do not waste a round on something it will
refuse anyway:

- The test suite runs, with a time limit. A test that never finishes ends the
  run; if you write one that loops, that is the end of it.
- No existing test may have changed, on any route, however indirect.
- The number of tests may not fall.
- None of the protected files may have changed — the guards, .claude/,
  CLAUDE.md, round.md, loop.sh, the lockfiles, the CI configuration. The script
  compares a checksum taken before the run, so it sees a change whether or not
  you committed it, and whether or not a hook was involved. If you believe one
  of them has to change, that is a QUESTIONS.md entry, not an attempt.

## Grading

Every round ends with the "grader" subagent scoring the whole repository 0-10
against the fixed rubric in .claude/agents/grader.md. Its JSON goes verbatim
into .agents/grade.json.

The run ends when the grade reaches ZIELNOTE, set at the top of loop.sh. The
script decides that, not you — and it does not take your word for it: it reads
the grader's own answer out of the round's event stream, which the CLI writes
and you cannot edit. .agents/grade.json is a copy for the cockpit and for the
next round; if it disagrees with the stream, the stream wins and the difference
is printed. A round with no grader in the stream has no grade at all, however
confident the file sounds.

So: you do not stop the run because you think the work is good, and you do not
keep it going because you think the grader was harsh — those are the two ways
this loop stops meaning anything.

The grade is not a report card, it is the backlog. Its naechste_schritte become
tasks. If the grade sits still for several rounds while tasks keep closing, the
tasks are not the ones that matter: say so in STATUS.md and work the grader's
list instead of your own.

Never argue with a score in STATUS.md. Fix the named defect, or record in
QUESTIONS.md why it should not be fixed.
