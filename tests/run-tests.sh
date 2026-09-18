#!/usr/bin/env bash
# run-tests.sh — offline tests of ai-pipeline with fake agy/codex/claude CLIs.
# Uses no tokens and no network. Creates a throw-away repository (path with a space)
# under a temp dir, runs each scenario and checks exit code and safety invariants.
#
#   tests/run-tests.sh            run all scenarios
#   KEEP=1 tests/run-tests.sh     keep the temp dir for inspection
set -Euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TOOLKIT="$(cd -- "$HERE/.." && pwd)"
FAKES="$HERE/fakes"
AIP="$TOOLKIT/bin/ai-pipeline"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ai-pipeline tests.XXXXXX")"
REPO="$WORK/demo repo"
pass=0 fail=0
cleanup() { if [[ -z "${KEEP:-}" ]]; then rm -rf -- "$WORK"; else echo "kept: $WORK"; fi; }
trap cleanup EXIT

check() {  # check NAME CONDITION_RESULT(0/1) DETAIL
  if [[ "$2" -eq 0 ]]; then pass=$((pass + 1)); printf '  ok    %s\n' "$1"
  else fail=$((fail + 1)); printf '  FAIL  %s  %s\n' "$1" "${3:-}"; fi
}

# ── demo repository ─────────────────────────────────────────────────────────
mkdir -p -- "$REPO"
cd -- "$REPO"
git init -q
git config user.email test@example.invalid
git config user.name test
printf 'def mean(xs):\n    return sum(xs) / len(xs)\n' > app.py
printf '#!/bin/sh\necho build\n' > build.sh
chmod +x build.sh
"$AIP" init > "$WORK/init.out" 2>&1
check "init creates project files" \
  "$([[ -f .ai/pipeline.conf && -x .ai/validate.sh && -f AGENTS.md && -f CLAUDE.md ]]; echo $?)"
"$AIP" --skip-plan > "$WORK/unconf.out" 2>&1; rc=$?
check "unconfigured validate.sh refused (exit 2)" "$([[ $rc -eq 2 ]]; echo $?)" "rc=$rc"

# Configure: one unit step that fails while FAILFLAG exists; build.sh is protected.
python3 - <<'EOF'
p = ".ai/validate.sh"; s = open(p).read()
s = s.replace("# AI-PIPELINE: UNCONFIGURED  (delete this line once STEPS below are filled in)\n", "")
s = s.replace('  # "build|1800|make -j4"\n',
              '  "unit|60|test ! -e FAILFLAG && python3 -c \'import app\' && echo ok || { echo \\"app.py:3: error: FAILFLAG present\\"; exit 1; }"\n')
open(p, "w").write(s)
c = ".ai/pipeline.conf"; s = open(c).read()
open(c, "w").write(s.replace("  # tools/build.sh\n", "  build.sh\n"))
EOF
printf '# Plan: guard\n\n## Objective\nx\n\n## Relevant Files\n- `app.py` — edit — y\n\n## Required Changes\n1. z & \\\\ {{CYCLE}}\n\n## Acceptance Criteria\n- a\n\n## Out of Scope\n- b\n' > .ai/plan.md
git add -A && git commit -qm init
BASE_COMMITS="$(git rev-list --count HEAD)"
"$AIP" --validate-only > "$WORK/val.out" 2>&1; rc=$?
check "validate-only passes on a clean tree" "$([[ $rc -eq 0 ]]; echo $?)" "rc=$rc"

# ── scenarios ───────────────────────────────────────────────────────────────
# run NAME EXPECTED_RC [ENV=VALUE…] [-- extra pipeline args]
run() {
  local name="$1" want="$2"; shift 2
  local envs=() args=(--skip-plan)
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == -- ]]; then shift; args=("$@"); break; fi
    envs+=("$1"); shift
  done
  ST="$WORK/state-$name"; mkdir -p -- "$ST"
  git checkout -q -- app.py build.sh .ai/validate.sh; rm -f FAILFLAG
  echo "# user's uncommitted note" >> app.py
  env FAKE_STATE="$ST" AI_AGY_BIN="$FAKES/agy" AI_CODEX_BIN="$FAKES/codex" \
      AI_CLAUDE_BIN="$FAKES/claude" AI_AGY_PROJECT=fake "${envs[@]}" \
      "$AIP" "${args[@]}" > "$ST/out.txt" 2>&1
  RC=$?
  check "$name → exit $want" "$([[ $RC -eq $want ]]; echo $?)" "rc=$RC (log: $ST/out.txt)"
  check "$name keeps user change" "$(grep -qF "# user's uncommitted note" app.py; echo $?)"
  check "$name made no commit/stash" \
    "$([[ "$(git rev-list --count HEAD)" == "$BASE_COMMITS" && -z "$(git stash list)" ]]; echo $?)"
  check "$name released lock" "$([[ ! -d .ai/logs/.lock ]]; echo $?)"
}

echo "scenarios:"
run pass-first 0 FAKE_CODEX_PASS_AT=1
run fail-then-pass 0 FAKE_CODEX_PASS_AT=2
run always-fail-escalates 1
grep -q ESCALATION "$ST/out.txt"; check "always-fail logs ESCALATION" $?
run distinct-findings-no-escalation 1 FAKE_CODEX_VARY=1
grep -q 'cycle limit reached' "$ST/out.txt"; check "distinct findings stop at cycle limit" $?
run fixer-noop 1 FAKE_AGY_NOOP_AFTER=1
run validation-regression-fixed 0 FAKE_AGY_MODE=failflag FAKE_CODEX_PASS_AT=1
grep -q 'FAILFLAG present' "$ST/agy-prompt-2.txt"; check "fix prompt carries the failing log excerpt" $?
run tamper-validate 4 FAKE_AGY_MODE=tamper
run tamper-project-protected 4 FAKE_AGY_MODE=tamper-extra
run bad-codex-effort 2 AI_CODEX_EFFORT=turbo
run bad-agy-model 2 AI_AGY_MODEL=gemini-nope
run bad-tier 2 AI_TIER=ultra
run plan-only 0 -- --task "add a guard" --plan-only
grep -q '## Relevant Files' .ai/plan.md; check "plan-only wrote .ai/plan.md" $?
run full-with-plan 0 FAKE_CODEX_PASS_AT=1 -- --task "add a guard"
grep -q '## Token usage' .ai/summary.md; check "summary has the token usage table" $?
grep -q -- '--disable plugins' "$ST/codex-args"; check "codex gets --disable for known features" $?
if grep -q -- '--disable browser_use' "$ST/codex-args"; then r=1; else r=0; fi
check "unknown codex features are not disabled" $r

# Prompt override in the project is used and protected.
mkdir -p .ai/prompts
{ cat "$TOOLKIT/prompts/implement.md"; echo "PROJECT-OVERRIDE-MARKER"; } > .ai/prompts/implement.md
git add .ai/prompts && git commit -qm override && BASE_COMMITS="$(git rev-list --count HEAD)"
run prompt-override 0 FAKE_CODEX_PASS_AT=1
grep -q PROJECT-OVERRIDE-MARKER "$ST/agy-prompt-1.txt"; check "project prompt override used" $?

# SIGTERM: agent child stopped, lock released, exit 130.
ST="$WORK/state-sigterm"; mkdir -p -- "$ST"
env FAKE_STATE="$ST" FAKE_AGY_SLEEP=41 AI_AGY_BIN="$FAKES/agy" AI_CODEX_BIN="$FAKES/codex" \
    AI_CLAUDE_BIN="$FAKES/claude" AI_AGY_PROJECT=fake "$AIP" --skip-plan > "$ST/out.txt" 2>&1 &
pid=$!
for _ in $(seq 1 100); do [[ -f "$ST/agy-prompt-1.txt" ]] && break; sleep 0.1; done
sleep 0.3
kill -TERM "$pid"; wait "$pid"; rc=$?
sleep 1
check "SIGTERM → exit 130" "$([[ $rc -eq 130 ]]; echo $?)" "rc=$rc"
check "SIGTERM stops the agent" "$([[ "$(pgrep -x sleep -a | grep -c 'sleep 41')" -eq 0 ]]; echo $?)"
check "SIGTERM releases the lock" "$([[ ! -d .ai/logs/.lock ]]; echo $?)"

echo
echo "passed: $pass  failed: $fail"
[[ $fail -eq 0 ]]
