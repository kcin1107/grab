# CLAUDE.md

Behavioral guidelines to reduce common LLM coding mistakes. Merge with project-specific instructions as needed.

**Tradeoff:** These guidelines bias toward caution over speed. For trivial tasks, use judgment.

## 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:
- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them - don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.
- **Design System:** Always check Apple's Human Interface Guidelines for design patterns or best practices (https://developer.apple.com/design/human-interface-guidelines/)
- **Subagents:** Use subagents whenever useful and especially when using a top-tier model (e.g. Sol or Opus), so the subagents can run on mid-tier models (e.g. Terra or Sonnet) to save tokens/usage and work simultaneously. If something is very easy, even take low-tier models for subagents (e.g. Luna or Haiku).

## 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

## 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it - don't delete it.

When your changes create orphans:
- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: Every changed line should trace directly to the user's request.

## 4. Documentation Is Part of the Change

**Read the docs before you start. Update them before you commit.**

Read first — before any work:
- Read `README.md` and `STRUCTURE.md` at the start of every task, before exploring the codebase and before editing anything. `STRUCTURE.md` is the project map; `README.md` is the user-facing contract. Don't skip either because the task looks small.
- Treat both as possibly stale. If they contradict the code, the code wins — and fixing the doc becomes part of the task.

Update before any commit or push — required, not optional cleanup:
- Re-check both files against your changes and update whatever is now wrong.
- Update `README.md` whenever a change affects setup, usage, behavior, requirements, permissions, versioning, or anything a user or maintainer would reasonably expect to find there.
- Update `STRUCTURE.md` whenever project structure, architecture, build configuration, dependencies, or version changes, so future chats have a current repository reference.
- If neither file needs a change, say so explicitly instead of silently skipping the check.

`AGENTS.md` and `CLAUDE.md` are kept byte-identical. Any edit to one must be mirrored to the other in the same commit.

## 5. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:
- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:
```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.

## 6. Commit Hygiene

**No AI attribution in commit messages.**

- Never add a `Co-Authored-By:` trailer for Claude, Anthropic, or any other assistant.
- GitHub reads co-author trailers as repository contributors. One such commit puts "Claude" back in the Contributors list, and removing it later means rewriting history and force-pushing.
- A local `commit-msg` hook strips these lines as a backstop. It is not versioned, so don't rely on it - don't write the trailer in the first place.

---

**These guidelines are working if:** fewer unnecessary changes in diffs, fewer rewrites due to overcomplication, and clarifying questions come before implementation rather than after mistakes.