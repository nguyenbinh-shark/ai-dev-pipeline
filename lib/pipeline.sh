#!/usr/bin/env bash
# ai-pipeline — multi-agent development loop for the git repository in the current
# directory (or --repo DIR). Part of the ai-dev-pipeline toolkit; see README.md.
#
#   Claude (claude CLI)  plans        → .ai/plan.md           (read-only tools)
#   Gemini (agy CLI)     implements   → edits the working tree (file edits only, no shell)
#   pipeline             validates    → .ai/validate.sh
#   Codex  (codex CLI)   audits       → .ai/review.json       (read-only sandbox, JSON schema)
#   Gemini fixes, pipeline validates, Codex re-audits … at most MAX_CYCLES audits.
#   Claude summarises    → .ai/summary.md
#
# Usage:
#   ai-pipeline init                          set up .ai/ in the current repository
#   ai-pipeline doctor                        check CLIs, logins and models
#   ai-pipeline --task "Add X to Y"           plan with Claude, then run the loop
#   ai-pipeline --task-file task.md           same, task read from a file
#   ai-pipeline --task "…" --plan-only        write .ai/plan.md and stop for review
#   ai-pipeline --skip-plan                   use the existing .ai/plan.md
#   ai-pipeline --validate-only               run .ai/validate.sh once and exit
#
# Options:
#   --repo DIR       repository to work on (default: the one containing the current dir)
#   --max-cycles N   audit cycles, 1..3 (default 3). Every fix is followed by an audit,
#                    so N audits means at most N-1 fixes.
#   --no-baseline    skip validating the tree before implementation (then every
#                    validation failure counts as new)
#   --no-summary     skip the final Claude summary
#   --tier T         model tier: normal (default) or hard (stronger reasoning, more tokens)
#   -h, --help
#
# Model policy (every model/effort is passed explicitly and checked against the CLI's
# own model list before any agent runs; an unknown model or effort aborts, never falls
# back):
#                  normal                         hard
#   Gemini (agy)   gemini-3.8-flash, effort medium    gemini-3.8-flash, effort high
#   Codex          gpt-5.6-sol, effort medium         gpt-5.6-sol, effort high
#   Claude         CLI default unless AI_CLAUDE_MODEL / AI_CLAUDE_EFFORT are set
#
# Per-project settings live in .ai/pipeline.conf (created by `ai-pipeline init`); an
# environment variable of the same name overrides the file.
#
# Environment overrides (all optional):
#   AI_TIER                                   normal|hard (same as --tier)
#   AI_AGY_MODEL, AI_AGY_EFFORT               e.g. gemini-3.1-pro + high; set
#                                             AI_AGY_EFFORT="" to pass a model id that
#                                             already names its effort (…-low/-medium/-high)
#   AI_CODEX_MODEL, AI_CODEX_EFFORT           e.g. gpt-6-astra + high (stronger, costlier)
#   AI_CLAUDE_MODEL, AI_CLAUDE_EFFORT
#   AI_CLAUDE_BIN, AI_AGY_BIN, AI_CODEX_BIN   explicit CLI paths
#   AI_AGY_PROJECT                            agy project id for this repository
#   AI_AGY_WARN_TOKENS                        per-call warning ceiling for Gemini (default
#                                             40000 + 20000 per file in the plan's
#                                             Relevant Files); a warning never stops a run
#   AI_INLINE_DIFF_MAX (40000)                diffs up to this many bytes are inlined in
#                                             the audit prompt, larger ones are referenced
#   AI_FINDING_MAX_FIXES (2)                  stop and escalate when one blocking finding
#                                             survives this many fix attempts
#   AI_PLAN_TIMEOUT (1200), AI_AGY_TIMEOUT (3600), AI_AUDIT_TIMEOUT (1800) seconds
#
#   AI_REPORT_LANG (English)                  language of the final summary
#
# Token usage reported by the CLIs is collected in .ai/logs/<run>/usage.jsonl and
# appended to .ai/summary.md as a table (N/A where a CLI reports nothing).
#
# Exit codes: 0 PASS · 1 FAIL after the last cycle · 2 usage/prerequisite error ·
#             3 an agent step failed · 4 a protected file or HEAD was changed.
#
# Git safety: the script never commits, pushes, resets, cleans, stashes, checks out or
# restores. The user's uncommitted changes stay in place; the change under review is the
# difference between two snapshot tree objects built with a temporary index, so the
# user's work is never attributed to the implementer.
set -Eeuo pipefail
# bash ≥ 5.2 treats '&' in ${var//pat/rep} as the match; prompts may contain '&'.
shopt -u patsub_replacement 2>/dev/null || true

# ── constants ────────────────────────────────────────────────────────────────
readonly EXIT_FAIL=1 EXIT_USAGE=2 EXIT_AGENT=3 EXIT_TAMPER=4

# The toolkit (this script, prompts, schema, helpers) lives outside the repositories it
# works on, so an agent editing a repository cannot change the pipeline itself.
TOOLKIT="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/.." && pwd)"
readonly TOOLKIT
readonly LIB="$TOOLKIT/lib/pipeline_lib.py"
readonly SCHEMA_FILE="$TOOLKIT/schema/review.schema.json"

usage() { sed -n '2,/^set -Eeuo/{/^set -Eeuo/d;s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}"; }
for a in "$@"; do
  if [[ "$a" == -h || "$a" == --help ]]; then usage; exit 0; fi
done

# --repo must be known before anything else; the other options are parsed below.
REPO_ARG="."
prev=""
for a in "$@"; do
  [[ "$prev" == --repo ]] && REPO_ARG="$a"
  prev="$a"
done
ROOT="$(git -C "$REPO_ARG" rev-parse --show-toplevel 2>/dev/null)" || {
  echo "ai-pipeline: '$REPO_ARG' is not inside a git repository" >&2
  exit "$EXIT_USAGE"
}
readonly ROOT
readonly AI_DIR="$ROOT/.ai"
readonly PLAN_FILE="$AI_DIR/plan.md"
readonly REVIEW_FILE="$AI_DIR/review.json"
readonly SUMMARY_FILE="$AI_DIR/summary.md"
readonly VALIDATE="$AI_DIR/validate.sh"
readonly CONF="$AI_DIR/pipeline.conf"

# Project settings. The file is the user's own and is sourced as bash; it uses the
# `: "${VAR:=value}"` form so an exported variable of the same name wins.
AI_PROTECTED_FILES=()
if [[ -f "$CONF" ]]; then
  # shellcheck source=/dev/null
  source "$CONF" || { echo "ai-pipeline: error in $CONF" >&2; exit "$EXIT_USAGE"; }
fi

# prompt_file NAME — the project's .ai/prompts/NAME if present, else the toolkit default.
prompt_file() {
  if [[ -f "$AI_DIR/prompts/$1" ]]; then printf '%s\n' "$AI_DIR/prompts/$1"
  else printf '%s\n' "$TOOLKIT/prompts/$1"; fi
}

# Files the agents must not change; checked after every implementer run. Absolute
# toolkit paths, then repository-relative project files (absent ones are recorded as
# MISSING, so creating one is detected too).
PROTECTED=()
while IFS= read -r f; do PROTECTED+=("$f"); done < <(
  find "$TOOLKIT/lib" "$TOOLKIT/prompts" "$TOOLKIT/schema" -type f | sort)
PROTECTED+=(.ai/validate.sh .ai/pipeline.conf AGENTS.md CLAUDE.md GEMINI.md)
while IFS= read -r f; do PROTECTED+=(".ai/prompts/${f##*/}"); done < <(
  find "$AI_DIR/prompts" -maxdepth 1 -name '*.md' -type f 2>/dev/null | sort)
PROTECTED+=("${AI_PROTECTED_FILES[@]}")
readonly PROTECTED
# Human-readable list for the implementer prompts.
PROTECTED_LIST="the ai-dev-pipeline toolkit, \`.ai/\`"
for f in AGENTS.md CLAUDE.md GEMINI.md "${AI_PROTECTED_FILES[@]}"; do
  PROTECTED_LIST+=", \`$f\`"
done
REPORT_LANG="${AI_REPORT_LANG:-English}"
AUDIT_FOCUS="${AI_AUDIT_FOCUS:-none beyond the checklist}"

PLAN_TIMEOUT="${AI_PLAN_TIMEOUT:-1200}"
AGY_TIMEOUT="${AI_AGY_TIMEOUT:-3600}"
AUDIT_TIMEOUT="${AI_AUDIT_TIMEOUT:-1800}"
INLINE_DIFF_MAX="${AI_INLINE_DIFF_MAX:-40000}"
FINDING_MAX_FIXES="${AI_FINDING_MAX_FIXES:-2}"
TIER="${AI_TIER:-normal}"

# ── options ──────────────────────────────────────────────────────────────────
TASK="" TASK_FILE="" SKIP_PLAN=0 PLAN_ONLY=0 VALIDATE_ONLY=0
MAX_CYCLES=3 DO_BASELINE=1 DO_SUMMARY=1

die() { local code="$1"; shift; log "ERROR: $*"; exit "$code"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --task)          [[ $# -ge 2 ]] || { usage >&2; exit "$EXIT_USAGE"; }; TASK="$2"; shift 2 ;;
    --task-file)     [[ $# -ge 2 ]] || { usage >&2; exit "$EXIT_USAGE"; }; TASK_FILE="$2"; shift 2 ;;
    --skip-plan)     SKIP_PLAN=1; shift ;;
    --plan-only)     PLAN_ONLY=1; shift ;;
    --validate-only) VALIDATE_ONLY=1; shift ;;
    --max-cycles)    [[ $# -ge 2 ]] || { usage >&2; exit "$EXIT_USAGE"; }; MAX_CYCLES="$2"; shift 2 ;;
    --no-baseline)   DO_BASELINE=0; shift ;;
    --no-summary)    DO_SUMMARY=0; shift ;;
    --tier)          [[ $# -ge 2 ]] || { usage >&2; exit "$EXIT_USAGE"; }; TIER="$2"; shift 2 ;;
    --repo)          [[ $# -ge 2 ]] || { usage >&2; exit "$EXIT_USAGE"; }; shift 2 ;;
    -h|--help)       usage; exit 0 ;;
    *) echo "ai-pipeline: unknown option: $1" >&2; usage >&2; exit "$EXIT_USAGE" ;;
  esac
done

# ── logging ──────────────────────────────────────────────────────────────────
RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"   # pid: two runs in one second never share a dir
RUN_DIR="$AI_DIR/logs/$RUN_ID"
PIPELINE_LOG=""   # set once RUN_DIR exists

log() {
  local line
  line="[$(date +%H:%M:%S)] $*"
  printf '%s\n' "$line" >&2
  if [[ -n "$PIPELINE_LOG" ]]; then printf '%s\n' "$line" >> "$PIPELINE_LOG"; fi
}

LOCK_DIR="$AI_DIR/logs/.lock"
HAVE_LOCK=0
cleanup() { if [[ $HAVE_LOCK -eq 1 ]]; then rmdir -- "$LOCK_DIR" 2>/dev/null || true; fi; }
on_err() { log "ERROR: command failed (exit $1) at line $2: $3"; }
# Agents run as background children so a signal to this script is handled at once
# (bash defers traps while a foreground child runs) and the child is stopped too.
CHILD_PID=""
on_signal() {
  log "interrupted; stopping ${CHILD_PID:+agent process $CHILD_PID and }pipeline"
  if [[ -n "$CHILD_PID" ]]; then kill -TERM "$CHILD_PID" 2>/dev/null || true; fi
  exit 130
}
run_child() {
  local rc=0
  "$@" &
  CHILD_PID=$!
  wait "$CHILD_PID" || rc=$?
  CHILD_PID=""
  return "$rc"
}
trap cleanup EXIT
trap on_signal INT TERM
trap 'on_err "$?" "$LINENO" "$BASH_COMMAND"' ERR

# ── helpers ──────────────────────────────────────────────────────────────────

# newest_match GLOB — newest-version path matching GLOB that is executable.
newest_match() {
  local m
  m="$(compgen -G "$1" | sort -V | tail -n 1 || true)"
  if [[ -n "$m" && -x "$m" ]]; then printf '%s\n' "$m"; fi
}

# resolve_bin NAME OVERRIDE FALLBACK_GLOB — prints an executable path or nothing.
# Symlinks in ~/.local/bin point into versioned VS Code extension directories and
# break when the extension updates; the glob fallback finds the current version.
resolve_bin() {
  local name="$1" override="$2" glob="$3" p=""
  if [[ -n "$override" ]]; then
    [[ -x "$override" ]] && p="$override"
  else
    p="$(command -v -- "$name" 2>/dev/null || true)"
    [[ -n "$p" && -x "$p" ]] || p="$(newest_match "$glob")"
  fi
  printf '%s\n' "$p"
}

# render TEMPLATE KEY=VALUE… — substitutes {{KEY}} placeholders.
render() {
  local text kv key val
  text="$(< "$1")"; shift
  for kv in "$@"; do
    key="${kv%%=*}"; val="${kv#*=}"
    text="${text//\{\{$key\}\}/$val}"
  done
  printf '%s\n' "$text"
}

# lib SUBCOMMAND … — .ai/pipeline_lib.py (prompt inputs, usage accounting, preflight).
lib() { python3 "$LIB" "$@"; }

# record_usage KIND AGENT STAGE MODEL EFFORT RAW SECONDS [extra lib args…] — appends the
# CLI-reported token usage of one agent call to RUN_DIR/usage.jsonl. Never fatal.
record_usage() {
  local kind="$1" agent="$2" stage="$3" model="$4" effort="$5" raw="$6" secs="$7"
  shift 7
  lib usage-record --kind "$kind" --agent "$agent" --stage "$stage" --model "$model" \
      --effort "$effort" --raw "$raw" --seconds "$secs" --out "$RUN_DIR/usage.jsonl" "$@" \
      2>&1 | while IFS= read -r line; do log "usage: $line"; done || true
}

# write_digest LABEL — compact validation result for prompts: every step's status, and a
# filtered log excerpt only for failures that are new relative to the baseline.
# Writes digest.md (all steps) and digest-new.md (new failures only).
write_digest() {
  local dir="$RUN_DIR/validation-$1"
  lib digest "$dir/summary.json" "$BASELINE_SUMMARY" --mode all > "$dir/digest.md"
  lib digest "$dir/summary.json" "$BASELINE_SUMMARY" --mode new > "$dir/digest-new.md"
}

# protected_manifest — sha256 of every protected file (MISSING if absent).
protected_manifest() {
  local f
  local p
  for f in "${PROTECTED[@]}"; do
    if [[ "$f" == /* ]]; then p="$f"; else p="$ROOT/$f"; fi
    if [[ -f "$p" ]]; then
      printf '%s  %s\n' "$(sha256sum -- "$p" | cut -d' ' -f1)" "$f"
    else
      printf 'MISSING  %s\n' "$f"
    fi
  done
}

# snapshot_tree — tree object of the whole working tree (tracked + untracked, honouring
# .gitignore, excluding .ai/). Uses a throw-away index: the real index, HEAD, the
# working tree and the stash are untouched.
snapshot_tree() {
  local idx real_idx tree
  idx="$(mktemp "${TMPDIR:-/tmp}/ai-pipeline-index.XXXXXX")"
  real_idx="$(git -C "$ROOT" rev-parse --path-format=absolute --git-path index)"
  if [[ -f "$real_idx" ]]; then cp -- "$real_idx" "$idx"; else rm -f -- "$idx"; fi
  GIT_INDEX_FILE="$idx" git -C "$ROOT" add -A -- . ':(exclude).ai' >/dev/null
  tree="$(GIT_INDEX_FILE="$idx" git -C "$ROOT" write-tree)"
  rm -f -- "$idx"
  printf '%s\n' "$tree"
}

# check_integrity LABEL — abort if an agent changed a protected file or HEAD.
check_integrity() {
  local now
  now="$(protected_manifest)"
  if [[ "$now" != "$PROTECTED_BASE" ]]; then
    diff <(printf '%s\n' "$PROTECTED_BASE") <(printf '%s\n' "$now") \
      > "$RUN_DIR/$1.protected.diff" || true
    die "$EXIT_TAMPER" "$1 modified protected files (see $RUN_DIR/$1.protected.diff)." \
        "Nothing was reverted; inspect with git diff."
  fi
  if [[ "$(git -C "$ROOT" rev-parse -q --verify HEAD || true)" != "$HEAD_BASE" ]]; then
    die "$EXIT_TAMPER" "$1 moved HEAD (commit/checkout). Nothing was reverted."
  fi
}

# run_validation LABEL — runs .ai/validate.sh into RUN_DIR/validation-LABEL.
run_validation() {
  local out="$RUN_DIR/validation-$1"
  log "validation ($1) → ${out#"$ROOT"/}"
  if run_child "$VALIDATE" "$out" >> "$PIPELINE_LOG" 2>&1; then
    log "validation ($1): PASS"
  else
    log "validation ($1): FAIL (details in ${out#"$ROOT"/}/summary.json)"
  fi
  [[ -f "$out/summary.json" ]] || die "$EXIT_AGENT" "validation did not produce $out/summary.json"
}

# run_claude PROMPT_TEXT OUT_FILE LABEL — read-only Claude; result text → OUT_FILE.
run_claude() {
  local prompt="$1" out="$2" label="$3" raw="$RUN_DIR/$3.claude.json"
  local args=(-p "$prompt" --output-format json --no-session-persistence
              --permission-prompts none --tools "Read,Grep,Glob,Bash")
  [[ -n "$CLAUDE_MODEL" ]] && args+=(--model "$CLAUDE_MODEL")
  [[ -n "$CLAUDE_EFFORT" ]] && args+=(--effort "$CLAUDE_EFFORT")
  # --allowedTools is variadic; keep it last.
  args+=(--allowedTools "Bash(git status*)" "Bash(git diff*)" "Bash(git log*)" "Bash(git show*)")
  log "claude ($label) running… (model=${CLAUDE_MODEL:-cli-default} effort=${CLAUDE_EFFORT:-cli-default})"
  local rc=0 t0=$SECONDS
  run_child timeout --kill-after=30 "$PLAN_TIMEOUT" "$CLAUDE" "${args[@]}" \
      < /dev/null > "$raw" 2> "$RUN_DIR/$label.claude.stderr" || rc=$?
  record_usage claude claude "$label" "$CLAUDE_MODEL" "$CLAUDE_EFFORT" "$raw" "$((SECONDS - t0))"
  [[ $rc -eq 0 ]] || { log "claude ($label) exited $rc (stderr: $RUN_DIR/$label.claude.stderr)"; return 1; }
  python3 - "$raw" "$out" <<'EOF' || return 1
import json, sys
d = json.load(open(sys.argv[1]))
if d.get("is_error") or not (d.get("result") or "").strip():
    sys.exit(f"claude returned an error or empty result (subtype={d.get('subtype')})")
open(sys.argv[2], "w").write(d["result"].rstrip() + "\n")
EOF
  log "claude ($label) done → ${out#"$ROOT"/}"
}

# run_agy PROMPT_TEXT LABEL — Gemini via agy: file edits only (accept-edits, no shell
# grants), terminal sandbox on. Fails if agy reports anything but SUCCESS.
run_agy() {
  local prompt="$1" label="$2" raw="$RUN_DIR/$2.agy.json"
  local args=(-p "$prompt" --mode accept-edits --sandbox --output-format json
              --print-timeout "${AGY_TIMEOUT}s" --log-file "$RUN_DIR/$label.agy.log")
  if [[ -n "$AGY_PROJECT" ]]; then args+=(--project "$AGY_PROJECT"); else args+=(--new-project); fi
  args+=(--model "$AGY_MODEL")
  [[ -n "$AGY_EFFORT" ]] && args+=(--effort "$AGY_EFFORT")
  log "gemini/agy ($label) running… (model=$AGY_MODEL effort=${AGY_EFFORT:-in-model-id})"
  local rc=0 t0=$SECONDS
  run_child timeout --kill-after=30 "$((AGY_TIMEOUT + 120))" "$AGY" "${args[@]}" \
      < /dev/null > "$raw" 2> "$RUN_DIR/$label.agy.stderr" || rc=$?
  record_usage agy gemini "$label" "$AGY_MODEL" "${AGY_EFFORT:-in-model-id}" "$raw" \
      "$((SECONDS - t0))" --log "$RUN_DIR/$label.agy.log" \
      --models-tsv "$RUN_DIR/agy-models.tsv" --warn-threshold "$AGY_WARN_TOKENS"
  [[ $rc -eq 0 ]] || { log "agy ($label) exited $rc (stderr: $RUN_DIR/$label.agy.stderr)"; return 1; }
  python3 - "$raw" "$RUN_DIR/$label.agy.response.md" <<'EOF' || return 1
import json, sys
d = json.load(open(sys.argv[1]))
open(sys.argv[2], "w").write(d.get("response") or "")
denied = d.get("denied_actions") or []
if denied:
    print("agy denied actions: " + ", ".join(a.get("action", "?") for a in denied), file=sys.stderr)
if d.get("status") != "SUCCESS":
    sys.exit(f"agy status {d.get('status')}")
EOF
  log "gemini/agy ($label) done (response: ${RUN_DIR#"$ROOT"/}/$label.agy.response.md)"
}

# run_codex_audit PROMPT_TEXT OUT_JSON LABEL — Codex in a read-only sandbox, final
# message constrained to .ai/review.schema.json.
run_codex_audit() {
  local prompt="$1" out="$2" label="$3"
  local args=(exec --ephemeral --json --color never -s read-only -C "$ROOT"
              --output-schema "$SCHEMA_FILE" -o "$out")
  args+=(-m "$CODEX_MODEL" -c "model_reasoning_effort=\"$CODEX_EFFORT\"")
  local f
  for f in "${CODEX_DISABLE[@]}"; do args+=(--disable "$f"); done
  args+=("$prompt")
  log "codex ($label) auditing… (model=$CODEX_MODEL effort=$CODEX_EFFORT)"
  rm -f -- "$out"
  local rc=0 t0=$SECONDS
  # stdin must be closed: codex exec otherwise waits for more input when not on a TTY.
  run_child timeout --kill-after=30 "$AUDIT_TIMEOUT" "$CODEX" "${args[@]}" \
      < /dev/null > "$RUN_DIR/$label.codex.jsonl" 2> "$RUN_DIR/$label.codex.stderr" || rc=$?
  record_usage codex codex "$label" "$CODEX_MODEL" "$CODEX_EFFORT" \
      "$RUN_DIR/$label.codex.jsonl" "$((SECONDS - t0))"
  [[ $rc -eq 0 ]] || { log "codex ($label) exited $rc (stderr: $RUN_DIR/$label.codex.stderr)"; return 1; }
  [[ -s "$out" ]] || { log "codex ($label) produced no review"; return 1; }
  log "codex ($label) done → ${out#"$ROOT"/}"
}

# gate REVIEW VALIDATION_SUMMARY BASELINE_SUMMARY OUT — the pipeline's own PASS rule:
# review parses, no critical/major findings, auditor says PASS, and no validation step
# fails that passed at baseline. Exit 0 = PASS.
gate() {
  python3 - "$@" <<'EOF'
import json, os, sys
review_p, val_p, base_p, out_p = sys.argv[1:5]
reasons, new_fail, old_fail = [], [], []
try:
    r = json.load(open(review_p))
    for k in ("status", "summary", "critical", "major", "minor", "tests"):
        if k not in r:
            reasons.append(f"review.json missing key '{k}'")
except Exception as e:
    r = {}
    reasons.append(f"review.json unreadable: {e}")
if r.get("critical"):
    reasons.append(f"{len(r['critical'])} critical finding(s)")
if r.get("major"):
    reasons.append(f"{len(r['major'])} major finding(s)")
if r and r.get("status") != "PASS":
    reasons.append(f"auditor status {r.get('status')}")
val = json.load(open(val_p))
base = {}
if base_p != "-" and os.path.exists(base_p):
    base = {s["name"]: s["status"] for s in json.load(open(base_p))["steps"]}
for s in val["steps"]:
    if s["status"] == "PASS":
        continue
    if base.get(s["name"]) in ("FAIL", "SKIPPED"):
        old_fail.append(s["name"])
    else:
        new_fail.append(s["name"])
if new_fail:
    reasons.append("validation regressions: " + ", ".join(new_fail))
status = "FAIL" if reasons else "PASS"
json.dump({"status": status, "reasons": reasons, "new_validation_failures": new_fail,
           "preexisting_validation_failures": old_fail}, open(out_p, "w"), indent=2)
print(f"gate: {status}" + (" — " + "; ".join(reasons) if reasons else ""))
sys.exit(0 if status == "PASS" else 1)
EOF
}

# ── prerequisites ────────────────────────────────────────────────────────────
for tool in git python3 timeout sha256sum mktemp; do
  command -v -- "$tool" >/dev/null 2>&1 || die "$EXIT_USAGE" "missing required tool: $tool"
done
[[ -x "$VALIDATE" ]] \
  || die "$EXIT_USAGE" "missing or non-executable $VALIDATE (run: ai-pipeline init)"
for f in "$LIB" "$SCHEMA_FILE" "$TOOLKIT"/prompts/{plan,implement,fix,audit,audit-followup,summary}.md; do
  [[ -f "$f" ]] || die "$EXIT_USAGE" "toolkit file missing: $f"
done
if [[ $PLAN_ONLY -eq 0 ]] && grep -q '^# AI-PIPELINE: UNCONFIGURED' "$VALIDATE"; then
  die "$EXIT_USAGE" "$VALIDATE is still the template: define its STEPS and delete the" \
      "'# AI-PIPELINE: UNCONFIGURED' line"
fi

if [[ $VALIDATE_ONLY -eq 0 ]]; then
  [[ "$MAX_CYCLES" =~ ^[1-3]$ ]] || die "$EXIT_USAGE" "--max-cycles must be 1, 2 or 3"
  [[ "$FINDING_MAX_FIXES" =~ ^[1-9]$ ]] || die "$EXIT_USAGE" "AI_FINDING_MAX_FIXES must be 1..9"
  [[ "$INLINE_DIFF_MAX" =~ ^[0-9]+$ ]] || die "$EXIT_USAGE" "AI_INLINE_DIFF_MAX must be a byte count"
  [[ -z "${AI_AGY_WARN_TOKENS:-}" || "$AI_AGY_WARN_TOKENS" =~ ^[0-9]+$ ]] \
    || die "$EXIT_USAGE" "AI_AGY_WARN_TOKENS must be a token count"
  if [[ -n "$TASK_FILE" ]]; then
    [[ -z "$TASK" ]] || die "$EXIT_USAGE" "use either --task or --task-file"
    [[ -r "$TASK_FILE" ]] || die "$EXIT_USAGE" "cannot read task file: $TASK_FILE"
    TASK="$(< "$TASK_FILE")"
  fi
  if [[ $SKIP_PLAN -eq 1 ]]; then
    [[ -z "$TASK" && $PLAN_ONLY -eq 0 ]] || die "$EXIT_USAGE" "--skip-plan excludes --task/--plan-only"
    [[ -s "$PLAN_FILE" ]] || die "$EXIT_USAGE" "--skip-plan given but $PLAN_FILE is missing or empty"
  else
    [[ -n "${TASK//[[:space:]]/}" ]] || die "$EXIT_USAGE" "give --task, --task-file or --skip-plan"
  fi
fi
# ── model policy ─────────────────────────────────────────────────────────────
# Defaults come from the models the installed CLIs listed (agy models, codex debug
# models) when this policy was set; the preflight below re-checks them on every run.
case "$TIER" in
  normal) tier_agy_effort=medium tier_codex_effort=medium ;;
  hard)   tier_agy_effort=high   tier_codex_effort=high ;;
  *) die "$EXIT_USAGE" "--tier must be normal or hard (got: $TIER)" ;;
esac
AGY_MODEL="${AI_AGY_MODEL:-gemini-3.8-flash}"
AGY_EFFORT="${AI_AGY_EFFORT-$tier_agy_effort}"   # set but empty: effort is in the model id
CODEX_MODEL="${AI_CODEX_MODEL:-gpt-5.6-sol}"
CODEX_EFFORT="${AI_CODEX_EFFORT:-$tier_codex_effort}"
CLAUDE_MODEL="${AI_CLAUDE_MODEL:-}"
CLAUDE_EFFORT="${AI_CLAUDE_EFFORT:-}"
AGY_WARN_TOKENS=0
readonly CODEX_UNUSED_FEATURES=(plugins apps multi_agent image_generation browser_use
                                computer_use goals in_app_browser)
CODEX_DISABLE=()

# Everything below runs from the repository root (task file already read above);
# the agents use the current directory as their workspace.
cd -- "$ROOT"

mkdir -p -- "$AI_DIR/logs"
mkdir -- "$LOCK_DIR" 2>/dev/null \
  || die "$EXIT_USAGE" "another ai-pipeline run holds $LOCK_DIR (remove it if stale)"
HAVE_LOCK=1
mkdir -p -- "$RUN_DIR"
PIPELINE_LOG="$RUN_DIR/pipeline.log"
log "run $RUN_ID in $ROOT (toolkit: $TOOLKIT)"

if [[ $VALIDATE_ONLY -eq 1 ]]; then
  run_validation only
  python3 -c 'import json,sys; sys.exit(json.load(open(sys.argv[1]))["status"] != "PASS")' \
    "$RUN_DIR/validation-only/summary.json" && exit 0 || exit "$EXIT_FAIL"
fi

CLAUDE="$(resolve_bin claude "${AI_CLAUDE_BIN:-}" \
  "$HOME/.vscode/extensions/anthropic.claude-code-*-linux-x64/resources/native-binary/claude")"
AGY="$(resolve_bin agy "${AI_AGY_BIN:-}" "$HOME/.gemini/bin/agy")"
CODEX="$(resolve_bin codex "${AI_CODEX_BIN:-}" \
  "$HOME/.vscode/extensions/openai.chatgpt-*-linux-x64/bin/linux-x86_64/codex")"
needs_claude=$(( SKIP_PLAN == 0 || DO_SUMMARY == 1 ))
[[ $needs_claude -eq 0 || -n "$CLAUDE" ]] || die "$EXIT_USAGE" "claude CLI not found (set AI_CLAUDE_BIN)"
if [[ $PLAN_ONLY -eq 0 ]]; then
  [[ -n "$AGY" ]] || die "$EXIT_USAGE" "agy CLI not found (set AI_AGY_BIN)"
  [[ -n "$CODEX" ]] || die "$EXIT_USAGE" "codex CLI not found (set AI_CODEX_BIN)"
fi
log "claude: ${CLAUDE:-n/a}"
log "agy:    ${AGY:-n/a}"
log "codex:  ${CODEX:-n/a}"

# Model preflight: fail before any agent spends tokens if a requested model or effort
# is not offered by the installed CLI. Nothing falls back to another model.
if [[ $PLAN_ONLY -eq 0 ]]; then
  timeout 120 "$AGY" models < /dev/null 2> "$RUN_DIR/agy-models.stderr" \
    | grep $'\t' > "$RUN_DIR/agy-models.tsv" || true
  [[ -s "$RUN_DIR/agy-models.tsv" ]] \
    || die "$EXIT_USAGE" "could not list agy models (see $RUN_DIR/agy-models.stderr)"
  agy_id="$(lib check-agy-model "$RUN_DIR/agy-models.tsv" "$AGY_MODEL" "$AGY_EFFORT" 2>&1)" \
    || die "$EXIT_USAGE" "$agy_id"
  timeout 120 "$CODEX" debug models < /dev/null > "$RUN_DIR/codex-models.json" \
      2> "$RUN_DIR/codex-models.stderr" \
    || die "$EXIT_USAGE" "could not list codex models (see $RUN_DIR/codex-models.stderr)"
  codex_chk="$(lib check-codex-model "$RUN_DIR/codex-models.json" "$CODEX_MODEL" "$CODEX_EFFORT" 2>&1)" \
    || die "$EXIT_USAGE" "$codex_chk"
  # Codex features an auditor never uses; each one adds instructions/tool schemas to every
  # model request (measured: 15077 → 12290 input tokens for a one-word reply). Only
  # disable names this Codex knows: an unknown name makes codex exec fail.
  CODEX_DISABLE=()
  known_features="$(timeout 60 "$CODEX" features list < /dev/null 2>/dev/null | awk '{print $1}' || true)"
  for f in "${CODEX_UNUSED_FEATURES[@]}"; do
    if grep -qxF -- "$f" <<< "$known_features"; then CODEX_DISABLE+=("$f")
    else log "codex feature '$f' not listed by this codex; not disabling it"; fi
  done
  log "tier $TIER; requested models: gemini=$agy_id codex=$CODEX_MODEL/$CODEX_EFFORT" \
      "claude=${CLAUDE_MODEL:-cli-default}/${CLAUDE_EFFORT:-cli-default}"
fi

# agy's project for this folder: file edits inside a registered project's folder are
# auto-approved in accept-edits mode; outside one they are denied in headless mode.
AGY_PROJECT="${AI_AGY_PROJECT:-}"
if [[ $PLAN_ONLY -eq 0 && -z "$AGY_PROJECT" ]]; then
  AGY_PROJECT="$(python3 - "$ROOT" <<'EOF' || true
import glob, json, os, sys, urllib.parse
root = os.path.realpath(sys.argv[1])
for f in sorted(glob.glob(os.path.expanduser("~/.gemini/config/projects/*.json"))):
    try:
        d = json.load(open(f))
    except Exception:
        continue
    for r in (d.get("projectResources") or {}).get("resources") or []:
        u = r.get("folderUri", "")
        if u.startswith("file://") and os.path.realpath(urllib.parse.unquote(u[7:])) == root:
            print(d.get("id", "")); sys.exit(0)
sys.exit(1)
EOF
)"
  if [[ -n "$AGY_PROJECT" ]]; then log "agy project: $AGY_PROJECT"
  else log "agy project: none registered for this folder; agy will create one (--new-project)"; fi
fi

# ── git safety snapshot ──────────────────────────────────────────────────────
git -C "$ROOT" status --short > "$RUN_DIR/git-status-before.txt"
n_changes="$(wc -l < "$RUN_DIR/git-status-before.txt")"
if [[ "$n_changes" -gt 0 ]]; then
  log "working tree has $n_changes pre-existing change(s); they are kept and excluded from review"
fi
HEAD_BASE="$(git -C "$ROOT" rev-parse -q --verify HEAD || true)"
PROTECTED_BASE="$(protected_manifest)"

# ── 1. plan (Claude) ─────────────────────────────────────────────────────────
if [[ $SKIP_PLAN -eq 0 ]]; then
  prompt="$(render "$(prompt_file plan.md)" "TASK=$TASK" "PLAN_FILE=.ai/plan.md")"
  printf '%s\n' "$TASK" > "$RUN_DIR/task.md"
  run_claude "$prompt" "$PLAN_FILE" plan || die "$EXIT_AGENT" "planning failed"
fi
cp -- "$PLAN_FILE" "$RUN_DIR/plan.md"
if [[ $PLAN_ONLY -eq 1 ]]; then
  log "plan written to .ai/plan.md; review it, then run: scripts/ai-pipeline.sh --skip-plan"
  exit 0
fi

# ── 2. baseline validation ───────────────────────────────────────────────────
BASELINE_SUMMARY="-"
if [[ $DO_BASELINE -eq 1 ]]; then
  run_validation baseline
  BASELINE_SUMMARY="$RUN_DIR/validation-baseline/summary.json"
fi

BASE_TREE="$(snapshot_tree)"
log "base tree: $BASE_TREE"
printf '%s\n' "$BASE_TREE" > "$RUN_DIR/tree-base.txt"

# ── 3. implement (Gemini) ────────────────────────────────────────────────────
# Per-call warning ceiling for Gemini, scaled by the plan's file scope. agy offers no
# token cap, and a long run is not necessarily wrong, so this only warns.
if [[ -n "${AI_AGY_WARN_TOKENS:-}" ]]; then
  AGY_WARN_TOKENS="$AI_AGY_WARN_TOKENS"
else
  n_rel="$(lib relevant-count "$PLAN_FILE" 2>/dev/null || echo 0)"
  [[ "$n_rel" -gt 0 ]] || log "WARNING: plan has no '## Relevant Files' list; Gemini must explore"
  AGY_WARN_TOKENS=$(( 40000 + 20000 * (n_rel > 0 ? n_rel : 5) ))
fi
log "gemini per-call token warning ceiling: $AGY_WARN_TOKENS"
PLAN_TEXT="$(< "$PLAN_FILE")"
PLAN_EXCERPT="$(lib plan-excerpt "$PLAN_FILE")"

prompt="$(render "$(prompt_file implement.md)" "PLAN_FILE=.ai/plan.md" \
  "PROTECTED_LIST=$PROTECTED_LIST" "PLAN_TEXT=$PLAN_TEXT")"
run_agy "$prompt" implement || die "$EXIT_AGENT" "implementation step failed"
check_integrity implement
CUR_TREE="$(snapshot_tree)"
if [[ "$CUR_TREE" == "$BASE_TREE" ]]; then
  die "$EXIT_AGENT" "implementer made no changes (see ${RUN_DIR#"$ROOT"/}/implement.agy.response.md)"
fi
PREV_TREE="$BASE_TREE"

# ── 4. validate → audit → fix loop ───────────────────────────────────────────
result=FAIL
cycle=0
escalations=0
ESCALATION="none"
prev_review=""
# diff_section FROM TO FILE — inline the diff when small, else stat + path (the auditor
# can run git diff itself).
diff_section() {
  local size
  size="$(wc -c < "$3")"
  if (( size <= INLINE_DIFF_MAX )); then
    printf '```diff\n%s\n```\n' "$(< "$3")"
  else
    printf 'Diff is %s bytes, too large to inline. Stat:\n```\n%s\n```\nFull diff: `%s`\n' \
      "$size" "$(git -C "$ROOT" diff --stat "$1" "$2")" "${3#"$ROOT"/}"
  fi
}
while (( cycle < MAX_CYCLES )); do
  cycle=$((cycle + 1))
  log "── audit cycle $cycle/$MAX_CYCLES ──"
  printf '%s\n' "$CUR_TREE" > "$RUN_DIR/tree-cycle-$cycle.txt"
  diff_file="$RUN_DIR/cycle-$cycle.diff"
  git -C "$ROOT" diff --binary "$BASE_TREE" "$CUR_TREE" > "$diff_file"
  git -C "$ROOT" diff --stat "$BASE_TREE" "$CUR_TREE" | tee -a "$PIPELINE_LOG" >&2

  run_validation "cycle-$cycle"
  val_summary="$RUN_DIR/validation-cycle-$cycle/summary.json"
  write_digest "cycle-$cycle"
  val_digest="$RUN_DIR/validation-cycle-$cycle/digest.md"

  review_out="$RUN_DIR/review-cycle-$cycle.json"
  if (( cycle == 1 )); then
    prompt="$(render "$(prompt_file audit.md)" \
      "CYCLE=$cycle" "MAX_CYCLES=$MAX_CYCLES" "AUDIT_FOCUS=$AUDIT_FOCUS" \
      "BASE_TREE=$BASE_TREE" "CURRENT_TREE=$CUR_TREE" \
      "DIFF_SECTION=$(diff_section "$BASE_TREE" "$CUR_TREE" "$diff_file")" \
      "VALIDATION_DIGEST=$(< "$val_digest")" "PLAN_TEXT=$PLAN_TEXT")"
  else
    # Follow-up audit: previous findings + only what changed since the previous audit.
    delta_file="$RUN_DIR/cycle-$cycle.delta.diff"
    git -C "$ROOT" diff --binary "$PREV_TREE" "$CUR_TREE" > "$delta_file"
    prompt="$(render "$(prompt_file audit-followup.md)" \
      "CYCLE=$cycle" "MAX_CYCLES=$MAX_CYCLES" "AUDIT_FOCUS=$AUDIT_FOCUS" \
      "BASE_TREE=$BASE_TREE" "PREV_TREE=$PREV_TREE" "CURRENT_TREE=$CUR_TREE" \
      "PREVIOUS_BLOCKING=$(lib findings "$prev_review" blocking)" \
      "PREVIOUS_MINOR=$(lib findings "$prev_review" minor)" \
      "DIFF_SECTION=$(diff_section "$PREV_TREE" "$CUR_TREE" "$delta_file")" \
      "VALIDATION_DIGEST=$(< "$val_digest")" "PLAN_EXCERPT=$PLAN_EXCERPT")"
  fi
  run_codex_audit "$prompt" "$review_out" "audit-$cycle" || die "$EXIT_AGENT" "audit step failed"
  cp -- "$review_out" "$REVIEW_FILE"
  prev_review="$review_out"

  gate_file="$RUN_DIR/gate-cycle-$cycle.json"
  if gate "$REVIEW_FILE" "$val_summary" "$BASELINE_SUMMARY" "$gate_file" 2>&1 \
       | tee -a "$PIPELINE_LOG" >&2; [[ ${PIPESTATUS[0]} -eq 0 ]]; then
    result=PASS
    break
  fi
  # Stop rather than spend another fix on a finding that already survived
  # FINDING_MAX_FIXES fix attempts; Claude analyses it in the summary.
  if stuck="$(lib repeat-check "$RUN_DIR" "$cycle" "$FINDING_MAX_FIXES")"; then :; else
    escalations=$((escalations + 1))
    ESCALATION="blocking finding(s) still present after $FINDING_MAX_FIXES fix attempt(s): $stuck"
    printf '%s\n' "$stuck" > "$RUN_DIR/escalation.json"
    log "ESCALATION: $ESCALATION; stopping with FAIL"
    break
  fi
  if (( cycle == MAX_CYCLES )); then
    log "cycle limit reached ($MAX_CYCLES); stopping with FAIL"
    break
  fi

  prompt="$(render "$(prompt_file fix.md)" \
    "CYCLE=$cycle" "MAX_CYCLES=$MAX_CYCLES" "PROTECTED_LIST=$PROTECTED_LIST" \
    "AFFECTED_FILES=$(lib affected "$review_out" "$ROOT" "$BASE_TREE" "$CUR_TREE")" \
    "BLOCKING_FINDINGS=$(lib findings "$review_out" blocking)" \
    "VALIDATION_DIGEST=$(< "$RUN_DIR/validation-cycle-$cycle/digest-new.md")" \
    "PLAN_EXCERPT=$PLAN_EXCERPT")"
  # Snapshot right before the fix: validation may leave non-ignored files behind, and
  # those must not count as the fixer's work.
  pre_fix_tree="$(snapshot_tree)"
  run_agy "$prompt" "fix-$cycle" || die "$EXIT_AGENT" "fix step $cycle failed"
  check_integrity "fix-$cycle"
  PREV_TREE="$CUR_TREE"
  CUR_TREE="$(snapshot_tree)"
  if [[ "$CUR_TREE" == "$pre_fix_tree" ]]; then
    log "fixer made no changes in cycle $cycle; stopping with FAIL"
    break
  fi
done

# ── 5. summary (Claude) + token usage ────────────────────────────────────────
summary_ok=0
if [[ $DO_SUMMARY -eq 1 ]]; then
  prompt="$(render "$(prompt_file summary.md)" \
    "RESULT=$result" "CYCLES_RUN=$cycle" "PLAN_FILE=.ai/plan.md" \
    "REVIEW_FILE=.ai/review.json" "GATE_FILE=${gate_file#"$ROOT"/}" \
    "VALIDATION_DIGEST_FILE=${val_digest#"$ROOT"/}" \
    "BASE_TREE=$BASE_TREE" "CURRENT_TREE=$CUR_TREE" "RUN_DIR=${RUN_DIR#"$ROOT"/}" \
    "REPORT_LANG=$REPORT_LANG" "ESCALATION=$ESCALATION")"
  if run_claude "$prompt" "$SUMMARY_FILE" summary; then
    summary_ok=1
  else
    log "WARNING: summary step failed; results are still in ${RUN_DIR#"$ROOT"/}"
  fi
fi
lib usage-table "$RUN_DIR/usage.jsonl" --cycles "$cycle" --escalations "$escalations" \
  > "$RUN_DIR/usage.md" || log "WARNING: could not build the token usage table"
if [[ $summary_ok -eq 1 && -s "$RUN_DIR/usage.md" ]]; then
  printf '\n' >> "$SUMMARY_FILE"
  cat -- "$RUN_DIR/usage.md" >> "$SUMMARY_FILE"
fi
grep -E '^- (Total|Gemini|Codex|Escalations)|^- WARNING' "$RUN_DIR/usage.md" 2>/dev/null \
  | while IFS= read -r line; do log "usage ${line#- }"; done || true

log "RESULT: $result after $cycle audit cycle(s). Logs: ${RUN_DIR#"$ROOT"/}"
log "Nothing was committed. Review the change with: git diff $BASE_TREE  (or plain git diff)"
[[ "$result" == PASS ]] && exit 0 || exit "$EXIT_FAIL"
