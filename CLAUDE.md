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
