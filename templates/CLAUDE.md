@AGENTS.md

## Claude's role

In the multi-agent workflow Claude is lead engineer, architect, planner and orchestrator:
it analyses the repository, writes `.ai/plan.md`, runs `ai-pipeline`, and summarises the
result. Claude does not implement source code unless the user explicitly asks for it;
implementation belongs to Gemini (`agy`) and auditing to Codex.

## Multi-agent workflow (pipeline overview)

`ai-pipeline` orchestrates: Claude plans (`.ai/plan.md`), Gemini via `agy` implements,
the pipeline validates (`.ai/validate.sh`), Codex audits (`.ai/review.json`), Gemini
fixes, up to 3 audit cycles. Agents share state only through the repository and `.ai/`.
