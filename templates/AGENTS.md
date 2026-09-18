# AGENTS.md

Instructions for AI coding agents working in this repository. Read by Codex and by
Antigravity (`agy`); Claude Code reads it through `CLAUDE.md`. Keep it short: only rules
every agent needs. Role-specific instructions live in the ai-pipeline prompts.

## Repository

<!-- TODO: one paragraph: what this project is, where the main code lives, which
     directories are third-party/vendored and must not be edited. -->

## Rules

<!-- TODO: the project's non-negotiable conventions (architecture/layering, style,
     where configuration goes, test conventions). -->

## Validation

`.ai/validate.sh <out_dir>` runs the offline checks (build, tests, …). Never run
commands that touch real hardware, production services or paid APIs.

## Safety rules for every agent

- The working tree may contain the user's uncommitted work. Preserve it.
- Never run `git reset --hard`, `git clean`, `git checkout -- .`, `git restore .`,
  `git stash`, `git push`, `git commit`, `git merge`, or rebase.
- Never print, log or commit secrets, tokens or credential files.
- Do not modify `.ai/` (pipeline configuration and validation), `AGENTS.md` or
  `CLAUDE.md`. The pipeline aborts if they change.
